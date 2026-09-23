# TV bloat re-encode (QSV HEVC)

Shrinks bloated 1080p episodes (high-bitrate h264, e.g. Bluray remuxes) to HEVC
using the Intel iGPU via QuickSync. Typical result: 18 Mbps → ~4 Mbps
(75–80 % smaller) at ~9–10× realtime. First night reclaimed **312 GiB from
76 files**.

Runs **nightly via CronJobs**, not Flux (the GPU is a single exclusive DRA
device, so Jellyfin must be scaled to 0 while encoding).

| File | Purpose |
| ---- | ------- |
| `candidates.txt` | Input list (`/media/tv` paths), highest bitrate first |
| `transcode.sh` | The encoder; resumable, deadline-aware, safe replace + rename |
| `nightly.yaml` | SA/RBAC + the three CronJobs (halt / transcode / restore) |
| `tv-transcode-job.yaml` | One-off `Job` (+ `ResourceClaimTemplate/transcode-gpu`) for manual runs |

## Nightly pipeline (America/Chicago)

```
00:30  jellyfin-halt          suspend Flux, scale Jellyfin to 0 (frees GPU)
                               — no-op if no candidates remain
00:35  tv-transcode-nightly   QSV HEVC encode; stops at DEADLINE (05:45)
05:50  jellyfin-restore       scale Jellyfin to 1, resume Flux
```

The `tv-transcode` and `tv-transcode-gpu` ConfigMap/`ResourceClaimTemplate`
must exist first (see below). Progress persists in
`/media/tv/.transcode/done.txt`, so each night resumes where the last stopped.

## What the encoder does

1. Skips anything already HEVC.
2. `hevc_qsv -preset veryfast -global_quality:v 20`, audio → AAC 256k,
   subtitles copied.
3. Replaces the original only when it is ≥10 % smaller **and** the duration
   matches within 2 s; otherwise keeps the original.
4. **Renames** the result to reflect the new codec — `[x264]`/`[h264]`/`XviD`/
   `DivX` → `[x265]` (appends `[x265]` if absent, normalises to `.mkv`).
5. Stops at `DEADLINE`; remaining files wait for the next night.

Tunables (job env): `QUALITY` (QSV ICQ; 20 used), `DEADLINE` (`HHMM` local),
`MARGIN` (min % saved to replace).

## First-time setup / manual run

```bash
cd infra/media-tools/transcode

# ship the script + candidate list
kubectl -n default create configmap tv-transcode \
  --from-file=transcode.sh --from-file=files.txt=candidates.txt \
  --dry-run=client -o yaml | kubectl apply -f -

# the GPU claim
kubectl -n default apply -f tv-transcode-job.yaml -l '' --dry-run=client -o yaml | kubectl apply -f -  # or apply the template only

# schedule the nightly pipeline
kubectl apply -f nightly.yaml

# or run a single night by hand
kubectl -n default apply -f tv-transcode-job.yaml
```

## Notes

- The single GPU is exclusive, so Jellyfin is **offline 00:30–05:50** on nights
  the job has work; `jellyfin-restore` guarantees it comes back even if a run
  wedges.
- `done.txt`, logs and temps live in `/media/tv/.transcode/` — outside series
  folders, so Sonarr/Jellyfin do not scan them.
- When the queue empties, `jellyfin-halt` becomes a no-op and Jellyfin stays
  up; delete the CronJobs (`kubectl -n default delete cronjob jellyfin-halt
  tv-transcode-nightly jellyfin-restore`) once done.
- **Completion notification:** when no candidates remain, `jellyfin-halt` posts a
  one-shot alert (`TranscodeQueueEmpty`) to Alertmanager, which pushes to
  Pushover via the `pushover-once` receiver (`sendResolved: false`, so no
  follow-up "resolved" push). A marker (`.transcode/.queue-empty-notified`)
  ensures it fires once; it re-arms if new candidates are added.
- To queue more, regenerate `candidates.txt` (e.g. lower the bitrate floor to
  6 Mbps) and refresh the ConfigMap; `done.txt` prevents re-doing old files.
