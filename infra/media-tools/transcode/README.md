# TV bloat re-encode (QSV HEVC)

Shrinks bloated 1080p episodes (high-bitrate h264, e.g. Bluray remuxes) to HEVC
using the Intel iGPU via QuickSync. Typical result: 18 Mbps → ~4 Mbps (75–80 %
smaller) at ~9–10× realtime.

These manifests are **applied manually**, not by Flux (the GPU is a single
exclusive DRA device, and Jellyfin must be scaled to 0 while the job runs).

## Pieces

| File | Purpose |
| ---- | ------- |
| `candidates.txt` | Input list (`/media/tv` paths), highest bitrate first |
| `transcode.sh` | Runs in the job; resumable, deadline-aware, safe replace |
| `tv-transcode-job.yaml` | The transcode `Job` (+ `ResourceClaimTemplate/transcode-gpu`) |
| `restore-cronjob.yaml` | Safety net: at 05:50 local, scale Jellyfin to 1 + resume Flux |

## How it works

1. Flux Kustomization `jellyfin` is suspended and the Deployment scaled to 0 —
   this frees the exclusive `gpu.intel.com` DRA device.
2. The job requests the GPU via `ResourceClaimTemplate/transcode-gpu`, mounts
   the TV hostPath (`/var/tank/nas/library/media/tv` → `/media/tv`, rw), and
   encodes each candidate with `hevc_qsv` (`-global_quality:v 20`), audio →
   AAC 256k, subtitles copied.
3. A re-encode only replaces the original when it is ≥10 % smaller **and** the
   duration matches within 2 s. Otherwise the original is kept.
4. Progress persists in `/media/tv/.transcode/done.txt`, so re-running the job
   resumes where it left off. `DEADLINE` (local time) stops the run cleanly.
5. `jellyfin-restore` CronJob (05:50 daily) scales Jellyfin back to 1 and
   un-suspends Flux regardless of job state.

## Running a night

```bash
# 1. build candidate list (host-side analysis; see git history for the prober)
#    or reuse candidates.txt
# 2. suspend flux + scale down
kubectl -n default patch kustomization jellyfin --type merge -p '{"spec":{"suspend":true}}'
kubectl -n default scale deploy/jellyfin --replicas=0
# 3. ship the script + list and run
kubectl -n default create configmap tv-transcode \
  --from-file=transcode.sh --from-file=files.txt=candidates.txt \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n default apply -f tv-transcode-job.yaml
# 4. (optional) watch
kubectl -n default logs -f job/tv-transcode
# 5. restore (if not waiting for the CronJob)
kubectl -n default scale deploy/jellyfin --replicas=1
kubectl -n default patch kustomization jellyfin --type merge -p '{"spec":{"suspend":false}}'
```

Tunables (env on the Job): `QUALITY` (QSV ICQ, lower = better/bigger; 20 used),
`DEADLINE` (`HHMM` local), `MARGIN` (min % saved to replace).

## Notes

- The single GPU is exclusive, so Jellyfin is down while a night runs — only
  schedule inside the overnight window.
- Source files that are already HEVC are skipped.
- `done.txt`, logs and temps live in `/media/tv/.transcode/` (not scanned by
  Sonarr/Jellyfin, since they are outside series folders).