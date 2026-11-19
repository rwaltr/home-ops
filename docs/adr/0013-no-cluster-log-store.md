# No cluster log store

Status: accepted (2026-11-07); supersedes the 2026-09-26 VictoriaLogs + Fluent Bit decision

There is no log aggregation. VictoriaLogs and Fluent Bit were switched off during a
memory incident on 2026-09-28 and never came back; on 2026-11-07 the manifests,
datasource, plugin and PVC were removed. Container logs live in `kubectl logs` and the
kubelet's journal. A pipeline that had to be killed to keep the node alive is not the
first thing to bring back.

## Consequences

- Anything before the current pod's lifetime is gone unless the app writes its own log
  to a PVC.
- Bringing it back starts from the 2026-09-26 design in `REFACTOR_PLANS.md`, not from
  scratch; memory is the constraint to solve first.

Runbook: `docs/logging.md`.
