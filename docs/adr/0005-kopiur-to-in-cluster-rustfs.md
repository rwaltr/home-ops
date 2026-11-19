# PVC backups: kopiur + kopia into an in-cluster RustFS

Status: accepted (2026-09-06)

PVCs are backed up by kopiur (a kopia operator) to an S3 endpoint served by RustFS
inside the cluster, on a static hostPath PV over `tank/backup/k8s`. Plain HTTP inside
the cluster is fine because kopia encrypts client-side with `KOPIA_PASSWORD` before
upload. One 1Password item feeds both RustFS and, through a ClusterExternalSecret,
every namespace labelled `kopiur.home-operations.com/repo: cluster-kopia` — so kopiur's
cluster-wide credential projection (and its secrets RBAC) is not needed.

Validated end-to-end: seed → snapshot → wipe PVC → restore → sha256 match.

## Consequences

- Backups live on the same box as the data. The 3-2-1 offsite leg (Backblaze B2 via
  `RepositoryReplication`) is planned, not built.
- Onboarding is the `components/kopiur/backup` component plus a namespace label. A
  policy naming a missing PVC does not fail fast — four apps failed silently for 11
  nights before the component made the PVC name visible.

See `infra/k8s/kyz/apps/kopiur-system/README.md` and `REFACTOR_PLANS.md` →
"What the backup-component refactor exposed".
