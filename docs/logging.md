# Cluster logging — DECOMMISSIONED 2026-11-07

There is no cluster log store. VictoriaLogs and Fluent Bit were switched off on
2026-09-28 and formally decommissioned on 2026-11-07; the manifests, the Grafana
datasource, the Grafana plugin and the PVC are all gone. Container logs live
only in `kubectl logs` and in the kubelet's journal (journald currently holds
4 GiB on the node).

## Why it was removed

It had already been switched off, and what was left was drift:

- Commit `6d0a60bf` ("oom oom oh pls no oom", 2026-09-28) commented
  `victoria-logs/ks.yaml` and `fluent-bit/ks.yaml` out of
  `infra/k8s/kyz/apps/o11y/kustomization.yaml` to relieve memory pressure on
  `mouse`. The workload never ran again.
- The store stopped writing on that date, so everything in it was already more
  than five weeks past its own 14-day retention. Nothing of value was deleted.
- What remained was a Bound 10 Gi PVC (`o11y/server-volume-victoria-logs-0`)
  with no consumer, a Grafana datasource pointing at a Service that no longer
  existed, an installed Grafana plugin nothing used, and this document
  describing the pipeline as live.

The alternative was re-enabling it now that memory requests are being
right-sized. It was retired instead: a pipeline that had to be killed during a
memory incident is not the first workload to bring back.

## What was deleted

| Removed                                                                   |
| ------------------------------------------------------------------------- |
| `infra/k8s/kyz/apps/o11y/victoria-logs/` (HelmRelease, OCIRepository, ks) |
| `infra/k8s/kyz/apps/o11y/fluent-bit/` (HelmRelease, OCIRepository, ks)    |
| the `victoria-logs` GrafanaDatasource                                     |
| `GF_INSTALL_PLUGINS=victoriametrics-logs-datasource` on the Grafana CR    |
| PVC `o11y/server-volume-victoria-logs-0`                                  |

## Bringing it back

The design reasoning is preserved in `REFACTOR_PLANS.md` under **2026-09-26
(later) — log system: VictoriaLogs + Fluent Bit**. That entry is the spec: why
VictoriaLogs single rather than Loki, why Fluent Bit rather than the chart's
default Vector, the `Keep_Log On` and stream-field constraints, and the
`8GiB`-vs-`8Gi` flag bug that crashlooped the first deploy — K8s quantities and
VictoriaMetrics byte-size flags look interchangeable and are not.

Budget it before rebuilding: the original ask was 64Mi request / 256Mi limit for
the store and 32Mi / 96Mi for the collector, plus a 10 Gi PVC on
`openebs-hostpath`, and a new workload fits only because the request budget has
room now.
