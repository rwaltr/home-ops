# Navidrome (music server)

Music streaming for the house, served off the same ZFS library the other media
apps read. Navidrome speaks the **Subsonic / OpenSubsonic API**, which is the
part that decides it: there are mature native clients on both phone platforms
(play:Sub, substreamer, Symfonium, DSub), plus web playback — no transcoding
server, no per-client setup.

```
 iPhone / Android (Subsonic client) ─┐
 Desktop browser ────────────────────┼─ HTTPS → k8s-gateway DNS → envoy-internal ┐
                                     │   (navidrome.waltr.tech — LAN only)        ├→ navidrome:4533
 Jellyfin (unchanged, its own music library) ─────────────────────────────────────┘   │
                                                                     navidrome-data PVC (SQLite)
 /var/tank/nas/library/music ──(hostPath, read-only)──────────────────→ /music
```

Jellyfin already lists the music folder and is untouched — this is a second
reader of the same files, not a replacement. Nothing writes to the library:
Navidrome is mounted read-only, because it never does more than read tags and
artwork.

## Manifests

`infra/k8s/kyz/apps/default/navidrome/` — `ks.yaml` plus `app/` (HelmRelease,
OCIRepository, kustomization). Registered in `apps/default/kustomization.yaml`.

| Piece    | Value                                                        |
| -------- | ------------------------------------------------------------ |
| Image    | `docker.io/navidrome/navidrome:0.64.2` (index digest pinned) |
| Chart    | shared `app-template` `5.2.1` (no Navidrome-specific chart)  |
| Port     | 4533 (`/ping` = chi heartbeat, used by all three probes)     |
| Config   | env only — no `navidrome.toml` is rendered or created        |
| Music    | `hostPath` `/var/tank/nas/library/music` → `/music` (ro)     |
| State    | PVC `navidrome-data` (10Gi, openebs-hostpath) → `/data`      |
| Temp     | emptyDir → `/tmp` (ffmpeg + scanner scratch)                 |
| Root FS  | read-only, runs as `1000:1000`, `ND_ENFORCENONROOTUSER=true` |
| Backup   | kopiur component, `H 1 * * *`                                |
| Exposure | `envoy-internal` only — **not** published publicly           |

Config being env-only is deliberate: the app keeps its mutable state —
including the JWT secrets it generates on first run — in the SQLite DB under
`/data`, so there is no generated config file to fight a ConfigMap over. Change
a setting by editing `env:` in the HelmRelease; a restart is required.

## First run: one browser step

There is no secret in git and nothing to provision in 1Password. While the
instance has no users, `/app/` serves Navidrome's own signup form; the first
account it creates is the admin. Deploy is complete only after that:

1. Open `https://navidrome.waltr.tech/app/` from a device on the LAN.
2. Create the admin account (username + password of your choosing).
3. Settings → _Music folders_ is already `/music`; the initial scan starts on
   its own. Add one folder per mount if the library layout ever changes.

Then point clients at `https://navidrome.waltr.tech` with that account.

## Scanning

The real-time **watcher** is on by default and is what notices new files; the
periodic full-scan schedule is **off** (`scanner.schedule` defaults to disabled,
confirmed against 0.64.2). That is fine while the library is close to static.
If files start arriving by another path and the watcher ever misses them, set:

```yaml
ND_SCANNER_SCHEDULE: "0 3 * * *" # nightly full scan as a safety net
```

Full scans are CPU-bursty and memory-heavy on a large library — the pod has no
CPU limit on purpose, and its memory limit is 1Gi.

## Backup and recovery

The kopiur `SnapshotPolicy` covers the `navidrome-data` PVC nightly at `H 1`
(crash-consistent `copyMethod: Direct`, so a write landing mid-copy is possible;
worst case is a re-scan, since the DB is a derived index of the library). The
library itself is on the tank and is not snapshotted by this policy.

## Publishing it publicly (not done)

Internal-only is the default here. Exposing it is a one-line edit in the
HelmRelease (`route.app.parentRefs`: add `envoy-external`), and `external-dns`
writes the record from the route — no Certificate or tunnel change, the
`*.waltr.tech` wildcard already covers the hostname. It was **not** done
because exposure is a deliberate decision, not a default: a public music server
means the login page is reachable by anyone, and Navidrome's own auth is then
the only gate. Ask first.

## Verification

```bash
kubectl get hr,pvc,httproute -n default | grep navidrome
kubectl get httproute navidrome -n default -o jsonpath='{.status.parents[*].name}'  # envoy-internal accepted
curl -s https://navidrome.waltr.tech/ping   # 200 once resolved on the LAN
```

Post-merge, read the deployed objects rather than the merge commit (see
`gitops-merge-verification`).
