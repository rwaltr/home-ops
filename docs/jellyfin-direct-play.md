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

Prevention only helps future grabs; the existing ~1,617 incompatible files
still transcode. A persistent worker (**Unmanic**) watches the libraries,
transcodes to the target profile and leaves the result in place for
Sonarr/Radarr to rename. See the next section once deployed.

## Backlog size

The pre-existing incompatible set is ≈1,617 files / ≈514 GB. CPU-only
transcoding measured ~49.6× realtime (x264 veryfast) on the i9-13900H, so the
backlog is roughly a 30-hour CPU job — no GPU contention, Jellyfin stays up.