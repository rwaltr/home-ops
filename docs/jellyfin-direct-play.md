# Jellyfin direct play: making the library stop transcoding

## Why

Jellyfin re-encodes on every play for a large slice of the library. The server
has no problem doing it, but it costs CPU/GPU on every stream and means the
Intel iGPU is busy for something the file could have avoided entirely. The goal
is **direct play**: the client decodes the file as-is, no server work.

## What the library actually looks like

Audit of 5,900 movie + episode items taken from Jellyfin's `MediaStreams`:

| Video codec       | Items     | Direct play?               |
| ----------------- | --------- | -------------------------- |
| h264              | 3,257     | yes                        |
| mpeg4 (XviD/DivX) | **1,448** | **never**                  |
| hevc              | 906       | yes (modern Android/Apple) |
| theora            | **161**   | **never**                  |
| msmpeg4v3         | **108**   | **never**                  |
| vp9 / vc1 / av1   | 20        | mixed                      |

Containers: `mkv` 3,692, **`avi` 1,553**, `mp4` 480, `ogg` 161.

Audio (single-codec sets): `aac` 2,054, `mp3` 1,476, `ac3` 1,108, `opus` 362,
`eac3` 304, **`dts` 297** (+28 mixed), `vorbis` 162, `wmav2` 24, `truehd` 11.

Subtitles: `subrip` 4,050, `ass` 668, `PGSSUB` 517, `DVDSUB` 174.

**Conclusion:** ~1,617 items (27 %) use a video codec that no client can direct
play, and ~700 streams use audio that most clients cannot decode (DTS, TrueHD,
Opus). Those are the permanent transcode tax.

## Target profile

| Stream    | Target                           | Rationale                                   |
| --------- | -------------------------------- | ------------------------------------------- |
| Video     | H.264 (High@L4.1) or HEVC        | universally / widely direct-playable        |
| Audio     | AAC, DD+, DD, AC3, MP3           | decoded natively by Android + Apple clients |
| Container | MKV or MP4                       |                                             |
| Subtitles | SRT preferred; PGS ok on Android |                                             |

Audio-only transcodes are cheap compared to video, but they still burn CPU on
every play, so they are worth avoiding too.

## Part 1 — prevention (stop importing the problem)

`recyclarr` syncs TRaSH Guides into Sonarr/Radarr nightly
(`infra/k8s/kyz/apps/default/recyclarr/app/recyclarr.yaml`).

Before this change only the **WEB-2160p (Combined)** profile was managed, and
the Radarr half of the config used **Sonarr's trash_ids** — every Radarr custom
format was silently skipped (Radarr had _zero_ custom formats). The profile the
library actually uses, **HD-1080p (id 4)**, was unmanaged in both apps.

Now Recyclarr manages, by explicit `name` so existing assignments survive:

| Service | Profile  | TRaSH source                                           |
| ------- | -------- | ------------------------------------------------------ |
| Sonarr  | HD-1080p | `WEB-1080p` (`72dae194fc92bf828f32cde7744e51a1`)       |
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

### Profile hygiene (audit 2026-09-25)

- **`HD - 720p/1080p` cannot match SD.** It allows only 720p/1080p — no SDTV,
  DVD or 480p. Five SD-era kids series sat on it with **zero** files while
  monitored (Wishbone, Bear in the Big Blue House, Mister Rogers'
  Neighborhood, Bob the Builder, Sesame Street — ≈3,200 episodes), so Sonarr
  could never match a release. Moved to `SD`. `I Love Lucy` was already on `SD`
  and working (118/180), which is what pointed at the profile rather than the
  indexers.
- **`Planes: Fire & Rescue` was on `Any`**, which permits CAM/TS/WORKPRINT →
  moved to `HD-1080p`.
- **`Baby Einstein Classics` is not trackable.** TVDB series `112061` has no
  year and **all 34 episodes have no air date**, so Sonarr counts
  `episodeCount: 0` and will never search. `year` is TVDB-owned and a `PUT
/api/v3/series/{id}` with `year: 2010` (TMDB's value) is silently ignored, as
  is a forced `RefreshSeries`. A replacement entry does not exist. Left in
  place but **unmonitored**; the real fix is adding the year/air dates upstream
  at TVDB.
- **342/346 movies and 60/87 series are intentionally unmonitored.** Both apps
  are archives here, not active fetchers — worth remembering before assuming a
  missing profile is why something is not downloading.

### Audio scores are deliberately _not_ TRaSH defaults

TRaSH scores lossless audio highly — TrueHD ATMOS **+5000**, TrueHD +2750,
DTS-HD MA +2500, FLAC/PCM +2250, while AAC is only +1000. Those defaults assume
an AV receiver doing passthrough. Here the clients are Android/Apple, where
DTS/TrueHD/FLAC/PCM force a server-side audio transcode, so the scores are
inverted for the HD profile:

| Score | Formats                         |
| ----- | ------------------------------- |
| +1000 | AAC, DD+                        |
| +750  | DD                              |
| +500  | MP3                             |
| −500  | DTS                             |
| −1000 | DTS-HD MA, TrueHD, FLAC, PCM    |
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
`05fbf054ac8ad0303335026cc2632f1a` (_WEBDL 2160p (Combined)_).

## Part 2 — remediation (fix what is already on disk)

**Unmanic** (`infra/k8s/kyz/apps/default/unmanic/`) is the standing worker.
It scans the TV + movie libraries hourly, on inotify for new files, and
re-encodes anything that cannot direct play. CPU-only, so Jellyfin never goes
offline.

- Image: `ghcr.io/unmanic/unmanic:0.4.1` (the app repo's own registry), pinned
  by digest. `unmanic-config` 5Gi + `unmanic-cache` 50Gi PVCs; the cache is
  excluded from the kopia SnapshotPolicy.
- 250m CPU request and **no CPU limit**. Kubernetes derives CPU shares from
  requests, so the request is what stops a long re-encode starving Jellyfin — the
  old 4-core limit only added throttling on a node with 20 cores and ~4.3 cores
  of requests committed. Memory is capped at 6Gi: memory is not reclaimed fairly
  and the node has no swap. Budget is ~1 GiB idle floor plus ~1.4 GiB per worker
  at peak — the pod measured 3.8 GiB with two workers, so 6Gi covers three with
  headroom. (The HelmRelease also sets `NUMBER_OF_WORKERS`, which does nothing —
  see the worker-count bullet below.)
- **Worker count lives in the worker group — the env var is inert.** Neither the
  env var nor `settings.number_of_workers` is the control:
  - `NUMBER_OF_WORKERS` does **nothing**. Unmanic imports env into settings by
    matching the lowercase setting key (`if setting in os.environ`, in
    `unmanic/config.py`), and the variable is upper-case, so it never maps.
    Verified 2026-10-04: the pod ran with it set to 2, then to 3, and the worker
    count never moved.
  - `settings.number_of_workers` only _seeds_ the default worker group on first
    run; `unmanic/libs/worker_group.py` then resets it to `null` and reads the
    count from the `worker_groups` table. Writing it on an established install is
    a no-op — confirmed by setting it to 3 and watching nothing happen.
  - The live control is the group, via
    `POST /unmanic/api/v2/settings/worker_group/write`. The schema requires every
    field, so send the whole object back:

    ```json
    {
      "id": 1,
      "locked": false,
      "name": "Hamedi",
      "number_of_workers": 3,
      "worker_event_schedules": [],
      "tags": []
    }
    ```

    Read it with `GET /unmanic/api/v2/settings/worker_groups`.

  - The foreman reconciles on each tick, so a change lands within about a minute
    and **no restart is needed**. It only adds or removes _idle_ workers — a
    running transcode is never interrupted. Current count: **3**.
- **Restarts keep the pending queue.** `clear_pending_tasks_on_restart` is set to
  `false` (default `true`). With `true`, every restart wipes the pending list,
  which then has to be rebuilt by a full library scan — measured at roughly 70
  minutes of idle workers for a ~1,900-file backlog.
- **Background priority**: `priorityClassName: unmanic-background` — a
  `PriorityClass` with `value: -100`, `preemptionPolicy: Never`. Every other pod
  in this cluster carries the implicit priority 0, so Unmanic schedules behind
  all of them, never preempts, and is the first pod node-pressure eviction
  takes. Its 250m CPU request keeps the cgroup CPU weight low for the same
  reason: it only gets CPU nobody else wants, and a killed transcode is
  re-queued rather than lost.
- **Its CPU alerts do not page**: the blackhole route is now a guard, not a
  standing condition. With no CPU quota there is no CFS throttling, so
  `CPUThrottlingHigh` (severity `info`) should stop firing entirely — it was
  firing around the clock solely because of the removed 4-core cap. A route in
  `infra/k8s/kyz/apps/o11y/kube-prometheus-stack/app/alertmanagerconfig.yaml`
  still sends CPU alerts for `pod =~ "unmanic-.*"` to the `blackhole` receiver,
  so a re-introduced cap stays visible in the Alertmanager UI without paging.
- Libraries: **TV** `/media/tv` and **Movies** `/media/movies`,
  scanner + inotify enabled, scan every 60 min.

### Plugin feed

The official repo (`Unmanic/unmanic-plugins`, branch `repo` — 56 plugins).
Note the stock example in Unmanic's own schema points at `Josh5/unmanic-plugins`,
which is the author's _personal_ repo (10 plugins); use the `Unmanic/` one.

### The flow

**File test** (what enters the queue) — `limit_library_search_by_ffprobe_data`
is deliberately **first**:

| #   | Plugin                                 | Purpose                                  |
| --- | -------------------------------------- | ---------------------------------------- |
| 1   | `limit_library_search_by_ffprobe_data` | the gate (below)                         |
| 2   | `ignore_files_recently_modified`       | `10min` — don't grab an in-flight import |
| 3   | `ignore_hardlinked_files`              | don't disturb torrent seeding hardlinks  |
| 4   | `reject_files_larger_than_original`    | safety net                               |
| 5   | `audio_transcoder`                     |                                          |
| 6   | `video_transcoder`                     |                                          |

**Worker** — `video_transcoder`, `audio_transcoder`,
`reject_files_larger_than_original`.
**Post-processor (task result)** — `notify_sonarr`, `notify_radarr`
(`rename_files: true`, so the \*arr apps re-read MediaInfo and rename).

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
> in `LibraryPluginFlow.position` order — _not_ the order shown by
> `POST /plugins/flow`. The gate must therefore be **first**. Put it last and
> it never runs: `video_transcoder` votes first and every H.264/HEVC file gets
> queued. (Also: the gate only ever sets `add_file_to_pending_tasks = False`;
> `add_all_matching_values` must stay false so matching files fall through to
> the encoder.)

### Output profile

`video_transcoder`: `h264` / `libx264` / `veryfast` / CRF 20 / container `mkv`.
`audio_transcoder`: `aac`, `max_channel_count: same_as_source`.

### Audio loudness normalization (2026-09-26)

Enabled on `audio_transcoder` for **both** libraries: `enable_smart_audio_filters:
true` **and** `normalize_audio_volume: true`, which applies

```
loudnorm=I=-16:TP=-1.5:LRA=11
```

**The trap:** `normalize_audio_volume` is a `sub_setting` with `display: hidden`,
and in `lib/plugin_stream_mapper.py` the loudnorm append sits _inside_ the
`if enable_smart_audio_filters:` block:

```python
if self.settings.get_setting('enable_smart_audio_filters'):
    ...
    if self.settings.get_setting('normalize_audio_volume'):
        smart_filters.append({"loudnorm": {"filter": "loudnorm=I=-16:TP=-1.5:LRA=11"}})
```

Setting `normalize_volume` alone does **nothing**. `test_stream_needs_processing`
returns `True` only when smart filters is on _and_ (normalize is on _or_ a
downmix is needed), which is why both had to be flipped.

**Why `audio_transcoder` and not the stock `normalise_aac` plugin:**

|            | `normalise_aac`                                   | `audio_transcoder` (chosen)          |
| ---------- | ------------------------------------------------- | ------------------------------------ |
| Target     | `I=-24 LRA=7` — broadcast, squashes film dynamics | `I=-16 LRA=11` — preserves range     |
| Codecs     | AAC only                                          | whatever the flow already re-encodes |
| Bitrate    | none set → ffmpeg default (~128k)                 | explicit `-b:a 192k`                 |
| Extra cost | new plugin in the flow                            | none — same op                       |

Because it rides along on files the flow was _already_ re-encoding to lossy AAC
(the DTS/TrueHD/lossless/old-video-codec set), normalization adds no additional
fidelity loss. It does **not** touch the ~2,054 AAC files that never enter the
flow — those already direct play, and normalizing them would mean re-encoding
audio for no compatibility gain.

Measured on a representative quiet rip (`I Love Lucy S05E18 [SDTV][MP3 2.0]`):
input **-18.5 LUFS** / LRA 7.9 → output **-15.2 LUFS**. Single-pass `loudnorm`
lands ~1 dB off target; 0.8 dB of that is the LRA compression, which is expected
and not a bug.

> Runtime proof pending: the two jobs running when the setting changed had
> already launched their `ffmpeg`, so the first task picked up _after_ the change
> is the one to inspect (`cat /proc/$(pgrep ffmpeg | head -1)/cmdline | tr '\0'
' ' | grep -c loudnorm`).

Validated on `Beast Wars S02E05 [SDTV][MP3 2.0][XviD].avi` (216 MB) →
`[SDTV][AAC 2.0][x264].mkv` (151 MB, H.264 + AAC 2.0), with `notify_sonarr`
queueing a rescan and rename.

### The size gate rejects audio-only remuxes (2026-10-05)

`reject_files_larger_than_original` is the flow's safety net, and its
`size_threshold_percent` sat at `0` from 2026-09-26 to 2026-10-05. That pairing
quietly created an infinite loop on every file the flow rewrites **audio-only**:

- `audio_transcoder` copies the video and re-encodes DTS/TrueHD to AAC at the
  plugin's Basic-mode smart target. The resulting track is about the same size as
  the DTS core it replaces, so the remuxed file lands **1.3-2.9% larger** than
  the source.
- At a threshold of `0`, that is a rejection. The plugin resets the task to the
  original file:

  ```
  Resetting task file back to original source as current cache file is larger
  than the original file
  ```

- **The task still reports success.** Nothing surfaces in the UI, in task
  history, or through the notification path.
- The source file is unchanged, so the gate still matches it (`dts` is in the
  gate's `allowed_values`) and the next hourly scan re-queues it. Forever.

Measured cost over those 8 days: 806 completions, 179 distinct files, **644 of
them — 80% of all work this worker had ever done — were re-work of 17 files**.
Zootopia alone ran 147 times, starting 2026-09-26 21:22Z.

`size_threshold_percent: 5` permits the small increase while still rejecting a
runaway output. The plugin's own description covers this case verbatim: _"Set a
positive value to permit a small increase, for tasks that only rewrite the
container and can add a few bytes without re-encoding."_

> **The setting is per-library, and that is a second trap.** Writing
> `size_threshold_percent` on the global scope (library_id 0) does **nothing**
> for a library that carries its own copy of the plugin's settings. On this
> install the Movies library kept `0` while global and TV read `5`, so the loop
> continued untouched after the "fix" was applied, and the only visible clue was
> that one library logged the new threshold text and the other logged the old.
> Read and write it per library:
>
> ```
> POST /unmanic/api/v2/plugins/info
>   {"plugin_id": "reject_files_larger_than_original", "library_id": 3}
> ```
>
> Library ids here: `1` = TV (/media/tv), `3` = Movies (/media/movies). Set it on
> **every** library the flow is enabled in.
>
> **Do not set `size_threshold_percent` back to `0`.** Any audio-only remux whose
> AAC track is not smaller than the source will loop silently, and the history
> will report it as a success.
>
> **Diagnosing a suspected loop:** a filename appearing repeatedly in
> `POST /unmanic/api/v2/history/tasks` is the signal. Confirm with
> `POST /history/task/log` (`{"task_id": N}`) and search for `larger than the
original`. `task_success: true` does not mean the file was replaced.

### Reproducing the configuration

Unmanic's libraries/plugins/flows are runtime state on the config PVC (like
Sonarr/Radarr), configured here through the API v2:

| Call                                                      | Purpose                                             |
| --------------------------------------------------------- | --------------------------------------------------- |
| `POST /unmanic/api/v2/settings/write`                     | global settings (workers, scan interval)            |
| `POST .../settings/library/write`                         | create a library / enable its plugins               |
| `POST .../plugins/repos/update` + `/plugins/repos/reload` | add the official repo                               |
| `POST .../plugins/install`                                | install a plugin by `plugin_id`                     |
| `POST .../plugins/settings/update`                        | write a plugin's settings (send the full list back) |
| `POST .../plugins/flow/save`                              | set flow membership/order                           |
| `POST .../pending/test`                                   | dry-run the file test for one path                  |

The UI is at `unmanic.waltr.tech`. API keys for the notify plugins live in the
global (library-independent) plugin settings — not SOPS, same as the \*arr apps'
own configs.

## Backlog size

The pre-existing incompatible set is ≈1,617 files / ≈514 GB. CPU-only
transcoding measured ~49.6× realtime (x264 veryfast) on the i9-13900H, so the
backlog is roughly a 30-hour CPU job — no GPU contention, Jellyfin stays up.
