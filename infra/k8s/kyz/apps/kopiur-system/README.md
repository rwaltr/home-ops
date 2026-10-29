# kopiur-system — PVC backups (kopiur + kopia + RustFS)

Kopia-native PVC backups for the mouse cluster. Three apps, one namespace:

| App            | What it is                                                                                                                  |
| -------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `rustfs/`      | S3 backend (official chart, standalone) on a static hostPath PV → `tank/backup/k8s`, node-pinned to mouse (follows the DAS) |
| `kopiur/`      | The operator (CRDs, controller, webhook; self-managed webhook TLS — no cert-manager)                                        |
| `kopiur-repo/` | The repository config: `ClusterRepository/cluster-kopia` + credential fanout                                                |

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
   (already set on `default`)
2. Find the app's actual PVC — do **not** assume it is named after the app or
   `<app>-config`:

   ```bash
   kubectl get pvc -n default
   ```

3. Reference the shared component from the app's `ks.yaml` and pass two
   variables. Nothing else is needed — no `app/kopia.yaml`, no `resources:`
   entry:

   ```yaml
   spec:
     components:
       - ../../../../components/kopiur/backup
     postBuild:
       substitute:
         APP: sonarr # policy/schedule name — match the ks.yaml name
         PVC: sonarr # the PVC from step 2
         KOPIUR_CRON: "H 7 * * *" # spread the mover Jobs across the night
         # KOPIUR_RUNAS: "10000"  # only if the app does not run as 1000:1000
   ```

`components/kopiur/backup/` owns `copyMethod: Direct`, `sourcePathStrategy:
PvcName`, the mover uid/gid, retention (7 latest / 14 daily / 4 weekly), and
`jitter: 30m`. Change them once, for every app.

**Gotcha — Flux substitutes `spec.postBuild` into every resource the app's
Kustomization renders.** If any manifest under `app/` contains a shell
`${VAR}`, Flux will blank it out. Annotate that resource (Flux honours this on
any kind, not just ConfigMaps):

```yaml
metadata:
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
```

`hermes/app/helmrelease.yaml` does exactly this for its init container's
`${GH}`/`${GO}`.

**Multi-PVC apps opt out.** `home-assistant/app/kopia.yaml` is deliberately
hand-written: it backs up two PVCs, and Flux substitution is string-level, so a
variable-length `sources` list cannot be templated. Prefer one component-backed
PVC per app and list extras only when a second PVC genuinely needs backup.

Manual trigger: a `Snapshot` CR with `policyRef`. Restore: a `Restore` CR with
`source.snapshotRef` + `target.pvc` (creates a new PVC) — see
[kopiur examples](https://github.com/home-operations/kopiur/tree/main/deploy/examples).

### Verifying a policy before it fails

A wrong PVC name does not fail fast — the operator parks the snapshot, then
fails it hours later (`SourcePvcMissing`). Check what the cluster actually has:

```bash
kubectl get snapshotpolicies -A
# LAST-SNAPSHOT empty + Stalled = the policy names a PVC that does not exist
kubectl get snapshots -n default --sort-by=.metadata.creationTimestamp | tail
```

### Verifying the backups themselves

A snapshot reaching `Succeeded` proves the mover wrote _something_ to the
repository. It does not prove the data is readable, and it does not prove it can
be restored. The shared component therefore sets `spec.verification` on every
policy, which is opt-in in kopiur: without the block the operator verifies
nothing and `status.lastVerified` stays empty forever, so an unreadable backup
looks exactly like a good one.

- **`quick`** — `kopia snapshot verify` at blob level, daily at `H 4` (after the
  backup window). Every stored blob is read and hash-checked. This is the tier
  that catches silent corruption.
- **`deep`** — a scratch **restore** of the latest snapshot into a throwaway
  20Gi PVC, weekly at `H 5` on Sunday. This is the only tier that proves
  restorability; it costs a full read of the source.
- **`successExpr: stats.files > 0 && stats.errors == 0`** fails a run that read
  no files. Without it a verify of an empty snapshot reports success.

Read the verdict — the `LAST-VERIFIED` column is the whole point:

```bash
kubectl get snapshotpolicies -n default          # LAST-VERIFIED per policy
kubectl get snapshots -n default --sort-by=.metadata.creationTimestamp | tail
kubectl get jobs -n default | grep -iE 'verify|deep'   # the verify Jobs
```

`status.lastVerified` is the RFC3339 stamp of the most recent _successful_
verification, any tier. It is empty until the first run lands, and it does not
move when a run fails — a stale stamp next to a failing verify Job is the
signal, which is why the column is read together with the Jobs, not alone.

Cadence and scratch size are overridable per app from its `ks.yaml`
(`KOPIUR_VERIFY_QUICK_CRON`, `KOPIUR_VERIFY_DEEP_CRON`, `KOPIUR_VERIFY_SCRATCH`).
The scratch must hold the restored data, which cannot exceed the source PVC's own
capacity — the largest backed-up PVC here is 10Gi, so the 20Gi default clears
every current source. Do not omit `capacity`: the fallback is a node-ephemeral
`emptyDir`, unbounded against the node's disk.

## Validated end-to-end (2026-09-06)

PVC → 10MB random data → `Snapshot` Succeeded → data verified on
`/var/tank/backup/k8s/kopia` → original PVC **deleted** → `Restore` into a fresh
PVC → `sha256sum -c` matched the original.

## Ops notes

- RustFS follows the tank DAS via `nodeSelector: kubernetes.io/hostname: mouse`
  — hardcode swaps to a pool-presence label when node labels/feature detection land.
- If the `kopia` bucket is ever wiped (data loss), recreate with `mc mb` and
  `kubectl delete clusterrepository cluster-kopia` (then Flux re-creates it).
- **CRDs upgrade via the HelmRelease, not by hand.** The `kopiur` HelmRelease
  sets `spec.upgrade.crds: CreateReplace`, because Helm's `crds/` directory is
  install-only and a plain chart bump never touches CRD schemas. Without it a
  chart bump ships a newer controller against an older schema, and the apiserver
  silently **prunes** any field the controller writes that the installed schema
  does not declare — a configured feature ends up inert with no error anywhere.
  `CreateReplace` creates missing CRDs and replaces existing ones on each
  upgrade; it never deletes, and replacing a CRD keeps its custom resources.
  Kopiur's own upgrade guide names this as the Flux/Argo answer. Do not "fix" a
  schema drift with `kubectl apply -f deploy/crds/` — that reintroduces the
  out-of-band write the GitOps rule exists to prevent.
- 3-2-1 offsite leg (planned): kopiur `RepositoryReplication` → Backblaze B2
  (bucket exists in `infra/terraform/backblaze`; creds via 1Password).
