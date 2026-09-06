# kopiur-system — PVC backups (kopiur + kopia + RustFS)

Kopia-native PVC backups for the mouse cluster. Three apps, one namespace:

| App                | What it is                                                              |
| ------------------ | ----------------------------------------------------------------------- |
| `rustfs/`          | S3 backend (official chart, standalone) on a static hostPath PV → `tank/backup/k8s`, node-pinned to mouse (follows the DAS) |
| `kopiur/`          | The operator (CRDs, controller, webhook; self-managed webhook TLS — no cert-manager) |
| `kopiur-repo/`     | The repository config: `ClusterRepository/cluster-kopia` + credential fanout |

## Data flow

```
SnapshotPolicy (ns, per-PVC) ──▶ Snapshot CR ──▶ mover Job (in the app ns)
   reads PVC (copyMethod: Direct) ──▶ kopia encrypts client-side (KOPIA_PASSWORD)
   ──▶ S3 over plain HTTP ──▶ rustfs pod ──▶ /var/tank/backup/k8s (tank DAS)
```

- **Plain HTTP is deliberate**: kopia encrypts before upload; the S3 keys never
  leave the node (pod-to-pod on mouse).
- **`copyMethod: Direct` is mandatory** here: `openebs-hostpath` has no CSI
  snapshots, so the mover reads the live PVC read-only. Crash-consistent, not
  point-in-time — DBs need `beforeSnapshot` hooks or app-native dumps.
- **Maintenance** is operator-managed (quick q6h / full nightly). Repo tuned:
  `epoch.minDuration: 6h` (index compaction), bootstrap deadline 600s.

## Credentials (all via 1Password)

Item **`kopia`** in vault **`home-ops`** holds: `RUSTFS_ACCESS_KEY`,
`RUSTFS_SECRET_KEY`, `KOPIA_PASSWORD` (the kopia repo encryption password —
lose it and the backups are unrecoverable, even though the data sits on tank).

- `rustfs-credentials` (ExternalSecret) — feeds the rustfs pod
- `kopiur-rustfs` (ClusterExternalSecret) — fans all three keys into **every
  namespace labeled `kopiur.home-operations.com/repo: cluster-kopia`** (1m refresh)

## Onboarding an app for backups

1. Label its namespace: `kopiur.home-operations.com/repo: cluster-kopia`
2. Add to the app's manifests:

```yaml
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotPolicy
metadata:
  name: <app>
  namespace: <ns>
spec:
  repository:
    kind: ClusterRepository
    name: cluster-kopia
  copyMethod: Direct # mandatory — hostpath storage, no CSI snapshots
  sources:
    - pvc:
        name: <pvc>
  retention:
    keepDaily: 14
    keepWeekly: 4
---
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotSchedule
metadata:
  name: <app>-nightly
  namespace: <ns>
spec:
  policyRef:
    name: <app>
  schedule:
    cron: "H 2 * * *"
    jitter: 30m
```

Manual trigger: a `Snapshot` CR with `policyRef`. Restore: a `Restore` CR with
`source.snapshotRef` + `target.pvc` (creates a new PVC) — see
[kopiur examples](https://github.com/home-operations/kopiur/tree/main/deploy/examples).

## Validated end-to-end (2026-09-06)

PVC → 10MB random data → `Snapshot` Succeeded → data verified on
`/var/tank/backup/k8s/kopia` → original PVC **deleted** → `Restore` into a fresh
PVC → `sha256sum -c` matched the original.

## Ops notes

- RustFS follows the tank DAS via `nodeSelector: kubernetes.io/hostname: mouse`
  — hardcode swaps to a pool-presence label when node labels/feature detection land.
- If the `kopia` bucket is ever wiped (data loss), recreate with `mc mb` and
  `kubectl delete clusterrepository cluster-kopia` (then Flux re-creates it).
- 3-2-1 offsite leg (planned): kopiur `RepositoryReplication` → Backblaze B2
  (bucket exists in `infra/terraform/backblaze`; creds via 1Password).
