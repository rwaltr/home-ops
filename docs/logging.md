# Cluster logging (VictoriaLogs + Fluent Bit)

Every container log on the node, kept for two weeks and queryable from Grafana.
Defined in `infra/k8s/kyz/apps/o11y/victoria-logs/` and
`infra/k8s/kyz/apps/o11y/fluent-bit/`.

|               |                                                                                        |
| ------------- | -------------------------------------------------------------------------------------- |
| Store         | VictoriaLogs single (StatefulSet `victoria-logs`), chart `victoria-logs-single` 0.12.3 |
| Query API     | `http://victoria-logs.o11y.svc.cluster.local:9428`                                     |
| Collector     | Fluent Bit DaemonSet, chart `fluent-bit` 0.58.2                                        |
| Grafana       | datasource `victoria-logs` (plugin `victoriametrics-logs-datasource` 0.32.0)           |
| Retention     | 14d, with an 8GiB disk ceiling                                                         |
| Memory budget | VL 64Mi request / 256Mi limit · Fluent Bit 32Mi request / 96Mi limit                   |
| Disk          | 10Gi PVC `openebs-hostpath`                                                            |

Ingest and query both land on port `9428`. Nothing is exposed outside the
cluster; there is no HTTPRoute, so the only UI is Grafana.

## Why this and not Loki

Memory, because the node has no disk swap and ~6Gi `MemAvailable` (see the
[2026-09-24 memory audit](../REFACTOR_PLANS.md)). VictoriaLogs is one process
whose full-text index lives in the same files as the log data: no memcached, no
boltdb-shipper cache, no separate index store, no compactor. The smallest sane
Loki single-binary asks for 500Mi+; this asks for 64Mi.

Fluent Bit rather than the Vector agent that the VictoriaLogs chart pulls in by
default (`vector.enabled: true`): Fluent Bit with this pipeline settles at
30-50Mi against Vector Agent's 150-250Mi. Vector is disabled in the HelmRelease
so only one collector tails `/var/log`.

## How logs flow

1. Fluent Bit's `tail` input reads `/var/log/containers/*.log` (kubelet CRI
   symlinks on a hostPath mount), one record per line, with the `docker, cri`
   multiline parser.
2. The `kubernetes` filter adds `kubernetes.*` metadata from the API (`Keep_Log
On`, so the raw line always survives in the `log` field).
3. The `http` output POSTs gzip'd JSON lines to
   `/insert/jsonline?_stream_fields=kubernetes.namespace_name,kubernetes.pod_name,kubernetes.container_name,stream&_msg_field=log&_time_field=date`.

Stream fields are what VictoriaLogs indexes per-stream, so keep that list small
and high-cardinality-free — adding `log.offset` or a request id there is how you
blow up the index.

## Permissions

The collector runs with the chart's own ServiceAccount and ClusterRole:
`get`/`list`/`watch` on **`pods` and `namespaces` only**, cluster-wide. That is
what the `kubernetes` filter needs to attach pod/namespace/container fields to
each record; without it records arrive unlabelled. No secrets, no
`nodes`/`nodes/proxy`, no write verbs — the chart's `rbac.nodeAccess` and
`rbac.eventsAccess` are both off. The log store itself needs no RBAC
(`victoria-logs` runs as an ordinary workload with a PVC).

## Querying

Grafana → **Explore** → datasource **victoria-logs**. LogsQL, not PromQL.

```logsql
# everything from one pod
kubernetes.namespace_name:default AND kubernetes.pod_name:home-assistant

# errors only, last 24h
kubernetes.pod_name:home-assistant AND log:~"(?i)error|critical"

# a specific integration, ignoring the noise of others
_msg:~"tesla_fleet"

# what went quiet: count by pod
* | stats by (kubernetes.pod_name) count()
```

`_time` is the container timestamp, so Grafana's time picker works normally.
Logs survive pod restarts here — that is the point of the PVC, and it is what
`kubectl logs` could not do.

From a shell, the same API:

```bash
kubectl -n o11y port-forward svc/victoria-logs 9428:9428
curl -s 'http://127.0.0.1:9428/select/logsql/query' \
  -d 'query=kubernetes.pod_name:home-assistant AND log:~"(?i)error"'
```

## Operating it

```bash
kubectl -n o11y get pods,sts,ds,pvc
kubectl -n o11y logs ds/fluent-bit --tail=50      # collector health
kubectl -n o11y logs sts/victoria-logs --tail=50  # ingest errors
```

Change retention in `victoria-logs/app/helmrelease.yaml`
(`server.retentionPeriod`, `server.retentionDiskSpaceUsage`) and let Flux
reconcile. Raising `persistentVolume.size` needs the PVC replaced by hand —
`openebs-hostpath` cannot expand a bound volume.

`retentionDiskSpaceUsage` is passed straight to
`-retention.maxDiskSpaceUsageBytes`, and that flag takes a size with a specific
suffix: `8GiB`, **not** `8Gi`. VictoriaLogs exits at flag parse on an unknown
suffix, so a wrong unit is a CrashLoopBackOff rather than a warning, and
`helm template` cannot catch it — the value renders; only the binary judges it.

## Known limits

- **Container logs only.** The Fluent Bit chart's second default input reads the
  host systemd journal (kubelet). It is intentionally not used: it would need
  `/var/log/journal` mounted from the host. Host and Flatcar logs are not in
  this pipeline.
- **Home Assistant's file log and recorder DB are not collected.** HA is
  captured at stdout, which is WARNING+ only. `home-assistant.log` and
  `home-assistant_v2.db` live on the HA PVC and stay out of reach of a
  read-only service account (no `pods/exec`). If HA needs deeper review, that is
  a separate decision.
- **In-flight lines can be lost on a collector restart.** Buffering is
  memory-only by design (`Mem_Buf_Limit 2MB`, `Retry_Limit 5`); a filesystem
  buffer would need another hostPath and unbounded disk on the node's only OS
  disk.
- **Nothing alerts on log content.** This is a store, not an alerting path.
  Prometheus rules and Alertmanager are unchanged.
- **Single node, single replica, no redundancy.** The log store is on
  `openebs-hostpath` like every other PVC; losing the node loses the logs with
  everything else.

## Verifying a change

Both charts render from the values committed in the HelmReleases:

```bash
# extract spec.values from the committed HelmRelease, then:
helm template victoria-logs oci://ghcr.io/victoriametrics/helm-charts/victoria-logs-single \
  --version 0.12.3 -f <extracted-values>
helm template fluent-bit oci://ghcr.io/fluent/helm-charts/fluent-bit \
  --version 0.58.2 -f <extracted-values>
kustomize build infra/k8s/kyz/apps/o11y
```

Chart bumps are single-line `OCIRepository` tag changes; the datasource URL and
the collector's output host both ride on `server.fullnameOverride: victoria-logs`
in the VictoriaLogs HelmRelease, so keep that pin if the chart is ever
re-templated.
