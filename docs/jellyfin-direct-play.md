# Jellyfin direct play: making the library stop transcoding

## Why

Jellyfin re-encodes on every play for a large slice of the library. The server
has no problem doing it, but it costs CPU/GPU on every stream and means the
Intel iGPU is busy for something the file could have avoided entirely. The goal
is **direct play**: the client decodes the file as-is, no server work.

## What the library actually looks like

Audit of 5,900 movie + episode items taken from Jellyfin's `MediaStreams`:

| Video codec | Items | Direct play? |
| ----------- | ----- | ------------ |
| h264        | 3,257 | yes          |
| mpeg4 (XviD/DivX) | **1,448** | **never** |
| hevc        | 906   | yes (modern Android/Apple) |
| theora      | **161** | **never** |
| msmpeg4v3   | **108** | **never** |
| vp9 / vc1 / av1 | 20 | mixed |

Containers: `mkv` 3,692, **`avi` 1,553**, `mp4` 480, `ogg` 161.

Audio (single-codec sets): `aac` 2,054, `mp3` 1,476, `ac3` 1,108, `opus` 362,
`eac3` 304, **`dts` 297** (+28 mixed), `vorbis` 162, `wmav2` 24, `truehd` 11.

Subtitles: `subrip` 4,050, `ass` 668, `PGSSUB` 517, `DVDSUB` 174.

**Conclusion:** ~1,617 items (27 %) use a video codec that no client can direct
play, and ~700 streams use audio that most clients cannot decode (DTS, TrueHD,
Opus). Those are the permanent transcode tax.

## Target profile

| Stream | Target | Rationale |
| ------ | ------ | --------- |
| Video  | H.264 (High@L4.1) or HEVC | universally / widely direct-playable |
| Audio  | AAC, DD+, DD, AC3, MP3 | decoded natively by Android + Apple clients |
| Container | MKV or MP4 | |
| Subtitles | SRT preferred; PGS ok on Android | |

Audio-only transcodes are cheap compared to video, but they still burn CPU on
every play, so they are worth avoiding too.

## Part 1 — prevention (stop importing the problem)

`recyclarr` syncs TRaSH Guides into Sonarr/Radarr nightly
(`infra/k8s/kyz/apps/default/recyclarr/app/recyclarr.yaml`).

Before this change only the **WEB-2160p (Combined)** profile was managed, and
the Radarr half of the config used **Sonarr's trash_ids** — every Radarr custom
format was silently skipped (Radarr had *zero* custom formats). The profile the
library actually uses, **HD-1080p (id 4)**, was unmanaged in both apps.

Now Recyclarr manages, by explicit `name` so existing assignments survive:

| Service | Profile | TRaSH source |
| ------- | ------- | ------------ |
| Sonarr  | HD-1080p | `WEB-1080p` (`72dae194fc92bf828f32cde7744e51a1`) |
| Radarr  | HD-1080p | `HD Bluray + WEB` (`d1d67249d3890e49bc12e275d989a7e9`) |

`upgrade.allowed: false` is set on both so adopting the TRaSH quality set does
**not** trigger a mass re-download of the existing library.

### The auxiliary profiles (scores only)

TRaSH has **no SD, no 720p-only and no "Any" profile** — the lowest it goes is
`WEB 1080p` / `HD Bluray + WEB` / `Base Profile`. So `Any`, `SD`, `HD-720p`,
`Ultra-HD` and `HD - 720p/1080p` are declared by `name` with the `qualities`
key **omitted**: Recyclarr then manages only their custom-format scores and
leaves each quality list exactly as-is. That matters, because `SD` and
`HD - 720p/1080p` carry the SD-only kids catalogue (Sesame Street, Mister
Rogers, Bob the Builder, Wishbone, I Love Lucy) — point them at a TRaSH 1080p
list and those shows stop matching anything.

Every profile gets the Unwanted set and the full direct-play audio scores. A
sync should report `0 contain quality changes and N contain updated scores`;
if it reports quality changes on an aux profile, `qualities` has been added by
mistake.

### Audio scores are deliberately *not* TRaSH defaults

TRaSH scores lossless audio highly — TrueHD ATMOS **+5000**, TrueHD +2750,
DTS-HD MA +2500, FLAC/PCM +2250, while AAC is only +1000. Those defaults assume
an AV receiver doing passthrough. Here the clients are Android/Apple, where
DTS/TrueHD/FLAC/PCM force a server-side audio transcode, so the scores are
inverted for the HD profile:

| Score | Formats |
| ----- | ------- |
| +1000 | AAC, DD+ |
| +750  | DD |
| +500  | MP3 |
| −500  | DTS |
| −1000 | DTS-HD MA, TrueHD, FLAC, PCM |
| −1500 | TrueHD ATMOS, ATMOS (undefined) |

TRaSH's `x265 (HD)` custom format lands at −10000 in both profiles, which is
consistent with this goal (H.264 HD releases win).

Verify after a sync:

```bash
kubectl -n default exec deploy/jellyfin -- sh -c \
  "curl -s -H 'X-Api-Key: <key>' http://radarr.default.svc:7878/api/v3/qualityprofile"
```

### Radarr gotcha

TRaSH trash_ids are **per-application**. Flux was applying a config whose
Radarr `custom_formats` used Sonarr ids, and Recyclarr warns
`Invalid trash_id: …` and continues. Always re-check the sync log:

```bash
kubectl -n default logs job/recyclarr-sync | grep -i "invalid"
```

Correct Radarr ids: `FLUX e098247bc6652dd88c76644b275260ed`,
`Bad Dual Groups b6832f586342ef70d9c128d40c07b872`,
`No-RlsGroup ae9b7c9ebde1f3bd336a8cbd1ec4c5e5`,
`Obfuscated 7357cf5161efbf8c4d5d0c30b4815ee2`,
`Retags 5c44f52a8714fdd79bb4d98e2673be1f`, 4K profile
`05fbf054ac8ad0303335026cc2632f1a` (*WEBDL 2160p (Combined)*).

## Part 2 — remediation (fix what is already on disk)

**Unmanic** (`infra/k8s/kyz/apps/default/unmanic/`) is the standing worker.
It scans the TV + movie libraries hourly, on inotify for new files, and
re-encodes anything that cannot direct play. CPU-only, so Jellyfin never goes
offline.

- Image: `ghcr.io/unmanic/unmanic:0.4.1` (the app repo's own registry), pinned
  by digest. `unmanic-config` 5Gi + `unmanic-cache` 50Gi PVCs; the cache is
  excluded from the kopia SnapshotPolicy.
- `NUMBER_OF_WORKERS=2`, CPU limit 4 cores — a long re-encode cannot starve
  Jellyfin.
- Libraries: **TV** `/media/tv` and **Movies** `/media/movies`,
  scanner + inotify enabled, scan every 60 min.

### Plugin feed

The official repo (`Unmanic/unmanic-plugins`, branch `repo` — 56 plugins).
Note the stock example in Unmanic's own schema points at `Josh5/unmanic-plugins`,
which is the author's *personal* repo (10 plugins); use the `Unmanic/` one.

### The flow

**File test** (what enters the queue) — `limit_library_search_by_ffprobe_data`
is deliberately **first**:

| # | Plugin | Purpose |
| - | ------ | ------- |
| 1 | `limit_library_search_by_ffprobe_data` | the gate (below) |
| 2 | `ignore_files_recently_modified` | `10min` — don't grab an in-flight import |
| 3 | `ignore_hardlinked_files` | don't disturb torrent seeding hardlinks |
| 4 | `reject_files_larger_than_original` | safety net |
| 5 | `audio_transcoder` | |
| 6 | `video_transcoder` | |

**Worker** — `video_transcoder`, `audio_transcoder`,
`reject_files_larger_than_original`.
**Post-processor (task result)** — `notify_sonarr`, `notify_radarr`
(`rename_files: true`, so the *arr apps re-read MediaInfo and rename).

### The gate

```
stream_field   = $.streams[*].codec_name            (JSONata)
allowed_values = mpeg4,msmpeg4v3,theora,vc1,mpeg2video,\
                 dts,truehd,flac,pcm_s16le
add_all_matching_values = false
```

So only files whose video is XviD/DivX/Theora/VC-1/MPEG-2 **or** whose audio
is DTS/TrueHD/FLAC/PCM get queued. H.264/HEVC video and AAC/AC3/MP3/Opus audio
are left alone.

> **Ordering is load-bearing.** In `unmanic/libs/filetest.py` the plugin loop
> `break`s on the **first** plugin that returns a verdict, and plugins execute
> in `LibraryPluginFlow.position` order — *not* the order shown by
> `POST /plugins/flow`. The gate must therefore be **first**. Put it last and
> it never runs: `video_transcoder` votes first and every H.264/HEVC file gets
> queued. (Also: the gate only ever sets `add_file_to_pending_tasks = False`;
> `add_all_matching_values` must stay false so matching files fall through to
> the encoder.)

### Output profile

`video_transcoder`: `h264` / `libx264` / `veryfast` / CRF 20 / container `mkv`.
`audio_transcoder`: `aac`, `max_channel_count: same_as_source`.

Validated on `Beast Wars S02E05 [SDTV][MP3 2.0][XviD].avi` (216 MB) →
`[SDTV][AAC 2.0][x264].mkv` (151 MB, H.264 + AAC 2.0), with `notify_sonarr`
queueing a rescan and rename.

### Reproducing the configuration

Unmanic's libraries/plugins/flows are runtime state on the config PVC (like
Sonarr/Radarr), configured here through the API v2:

| Call | Purpose |
| ---- | ------- |
| `POST /unmanic/api/v2/settings/write` | global settings (workers, scan interval) |
| `POST .../settings/library/write` | create a library / enable its plugins |
| `POST .../plugins/repos/update` + `/plugins/repos/reload` | add the official repo |
| `POST .../plugins/install` | install a plugin by `plugin_id` |
| `POST .../plugins/settings/update` | write a plugin's settings (send the full list back) |
| `POST .../plugins/flow/save` | set flow membership/order |
| `POST .../pending/test` | dry-run the file test for one path |

The UI is at `unmanic.waltr.tech`. API keys for the notify plugins live in the
global (library-independent) plugin settings — not SOPS, same as the *arr apps'
own configs.

## Backlog size

The pre-existing incompatible set is ≈1,617 files / ≈514 GB. CPU-only
transcoding measured ~49.6× realtime (x264 veryfast) on the i9-13900H, so the
backlog is roughly a 30-hour CPU job — no GPU contention, Jellyfin stays up.