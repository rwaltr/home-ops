# The tank pool stays outside the PVC lifecycle

Status: accepted (2026-09-06)

Workload PVCs use `openebs-hostpath` on the OS NVMe (non-default class), and the ZFS
pool `tank` is never provisioned into by Kubernetes. Bulk data on tank is hand-managed
datasets, reached by apps as hostPath mounts. ZFS-LocalPV was tested live and rejected:
its `poolname` must be a zpool, not a dataset, so CSI volumes would land as
`tank/pvc-*` at the pool root with no way to quarantine them.

## Consequences

- Hostpath PVs are node-pinned, snapshot-less and on the OS disk — acceptable for
  app config and scratch; anything precious lives on tank or is backed up (ADR 0005).
- Every backup policy must use `copyMethod: Direct`, because there is no CSI snapshot
  stack.
- Tank is created by hand and only **imported** by Ignition; a rebuild never touches it.

See `REFACTOR_PLANS.md` → "Additional decisions (2026-09-06)".
