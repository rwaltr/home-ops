# Cluster logging

Grafana's **VictoriaLogs** datasource contains container stdout collected by
Fluent Bit. The pipeline runs in `o11y` and is managed by Flux under
`infra/k8s/kyz/apps/o11y/`.

## Pipeline

- Fluent Bit runs as a DaemonSet and tails `/var/log/containers/*.log`.
- Its Kubernetes filter adds namespace, pod, and container metadata.
- Fluent Bit sends records to VictoriaLogs over the cluster network.
- VictoriaLogs retains data for 14 days, with an 8 GiB data cap on a 10 Gi PVC.
- Grafana uses the pinned `victoriametrics-logs-datasource` plugin.

The store has a 64Mi memory request and 256Mi limit. Fluent Bit has a 32Mi
request and 96Mi limit. Review actual working sets before changing those budgets.
VictoriaLogs also stores trace IDs and supports links to traces when an
application includes a `trace_id` field in its logs. Fluent Bit does not create
trace IDs or inject them into log messages.

## Scope and limits

This pipeline collects container stdout only. It does not collect host or
kubelet journald, Home Assistant's log file, or application PVC data. A
Fluent Bit restart can lose its small in-memory buffer. It retries failed
writes five times, then drops the buffered records.

VictoriaLogs is not Loki-compatible. The Grafana plugin is required. Keep the
VictoriaLogs and Fluent Bit chart versions pinned in their OCIRepository files.
The VictoriaLogs disk-size flag expects `GiB`, not the Kubernetes `Gi` suffix.

## Troubleshooting

- Check the `victoria-logs` and `fluent-bit` Flux Kustomizations in namespace
  `o11y`.
- Check the VictoriaLogs StatefulSet, PVC, and Service in namespace `o11y`.
- Check Fluent Bit DaemonSet pods and their logs in namespace `o11y`.
- In Grafana Explore, select the `victoria-logs` datasource.
- For recent logs without a working pipeline, use `kubectl logs` directly.

See `REFACTOR_PLANS.md` under **2026-09-26 (later) — log system:
VictoriaLogs + Fluent Bit** for the original design decisions and
**2026-11-07 — efficiency review** for the decommission history.
