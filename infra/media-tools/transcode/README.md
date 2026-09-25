# TV bloat re-encode (QSV HEVC)

Shrinks bloated 1080p episodes (high-bitrate h264, e.g. Bluray remuxes) to HEVC
using the Intel iGPU via QuickSync. Typical result: 18 Mbps → ~4 Mbps
(75–80 % smaller) at ~9–10× realtime.

**Status: retired (2026-09).** The library pass is complete — **180 files,
503 GiB reclaimed** (TV 2.9 TB → 2.3 TB). The nightly CronJobs
(`jellyfin-halt`, `tv-transcode-nightly`, `jellyfin-restore`) and their RBAC
have been deleted; only the manual one-shot Job remains for ad-hoc runs.
The `TranscodeQueueEmpty` Pushover notice was removed with them.

| File | Purpose |
| ---- | ------- |
| `candidates.txt` | Input list (`/media/tv` paths), highest bitrate first |
| `transcode.sh` | The encoder; resumable, deadline-aware, safe replace + rename |
| `tv-transcode-job.yaml` | One-off `Job` (+ `ResourceClaimTemplate/transcode-gpu`) for manual runs |

## Manual run

The GPU is a single exclusive DRA device, so Jellyfin must be scaled to 0 and
its Flux Kustomization suspended first, then restored afterwards:

```bash
cd infra/media-tools/transcode

# ship the script + candidate list
kubectl -n default create configmap tv-transcode \
  --from-file=transcode.sh --from-file=files.txt=candidates.txt \
  --dry-run=client -o yaml | kubectl apply -f -

# free the GPU
kubectl -n default patch kustomization jellyfin --type merge -p '{"spec":{"suspend":true}}'
kubectl -n default scale deployment/jellyfin --replicas=0

# run one pass (the Job also creates ResourceClaimTemplate/transcode-gpu)
kubectl -n default apply -f tv-transcode-job.yaml

# restore
kubectl -n default scale deployment/jellyfin --replicas=1
kubectl -n default patch kustomization jellyfin --type merge -p '{"spec":{"suspend":false}}'
```

Progress persists in `/media/tv/.transcode/done.txt`, so re-runs resume.

## What the encoder does

1. Skips anything already HEVC.
2. `hevc_qsv -preset veryfast -global_quality:v 20`, audio → AAC 256k,
   subtitles copied.
3. Replaces the original only when it is ≥10 % smaller **and** the duration
   matches within 2 s; otherwise keeps the original.
4. **Renames** the result to reflect the new codec — `[x264]`/`[h264]`/`XviD`/
   `DivX` → `[x265]` (appends `[x265]` if absent, normalises to `.mkv`).
5. Stops at `DEADLINE`; remaining files wait for a later run.

Tunables (job env): `QUALITY` (QSV ICQ; 20 used), `DEADLINE` (`HHMM` local),
`MARGIN` (min % saved to replace).

## Notes

- `done.txt`, logs and temps live in `/media/tv/.transcode/` — outside series
  folders, so Sonarr/Jellyfin do not scan them.
- Sonarr/Radarr own final filenames: the encoder only writes tags into the
  filename to reflect the codec, then a `RescanSeries` + `RenameSeries` pass
  normalises everything from MediaInfo.
- To queue more, regenerate `candidates.txt` (e.g. lower the bitrate floor) and
  refresh the ConfigMap; `done.txt` prevents re-doing old files.