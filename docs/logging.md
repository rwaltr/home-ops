# Cluster and network-device logging

Grafana's **VictoriaLogs** datasource now contains container stdout, host
journald entries, Kubernetes events, and syslog from the RouterOS gateway. The
pipeline runs in `o11y` under `infra/k8s/kyz/apps/o11y/`.

## Pipeline

- Fluent Bit tails `/var/log/containers/*.log` from every namespace.
- Its Kubernetes filter adds namespace, pod, and container metadata.
- Fluent Bit reads new entries from `/var/log/journal`. `Read_From_Tail On`
  skips the node's existing 4 GiB journal on first start.
- Fluent Bit watches Kubernetes events with read-only `events` permission.
  The event input starts with recent events and follows new events.
- VictoriaLogs accepts syslog on `10.10.100.13:514/udp` for the RB5009 and
  `10.10.100.13:5141/udp` for Wi-Fi events. Nothing sends to either port until
  RouterOS log actions are added. See the router section below.
- The syslog LoadBalancer only accepts the management VLAN ranges.
- VictoriaLogs retains all sources for 14 days, capped at 8 GiB on a 10 Gi PVC.

The store has a 192Mi memory request and 512Mi limit, sized from its own
working set (p95 188Mi, peak 250Mi over 12h). It sizes its caches from the
container limit, so a limit below the peak it reaches during merges makes it
OOM. Fluent Bit has a 32Mi request and 192Mi limit. Review actual working sets
before changing those budgets. VictoriaLogs also stores trace IDs and supports
links to traces when an application includes a `trace_id` field in its logs.
Fluent Bit does not create trace IDs or inject them into log messages.

## Router and access point

The RB5009 (`gateway-132l`) is the CAPsMAN controller for `ap1-132l`. The AP
reports its Wi-Fi events to the router, which logs them under the `wireless` and
`caps` topics. The MikroTik integration manages only the router, so the AP's own
system log is not collected.

The router needs two log actions, both of type `remote` and protocol `udp`:

- `victoria-logs` sends `info`, `warning`, `error`, and `critical` to
  `10.10.100.13:514`. Records get `source=routeros`.
- `victoria-logs-wifi` sends `wireless` and `caps` to `10.10.100.13:5141`.
  Records get `source=ap1-132l`. These events also reach the first action, so
  the same line is stored once under each source.

The router has only the default `remote` action today, pointed at `0.0.0.0`, so
nothing leaves it. Apply the actions after the `victoria-logs-syslog` Service
has its address.

The UDP syslog listener has no transport authentication or encryption. Keep it
on the management VLAN. RouterOS accepts an unauthenticated datagram from any
host on that VLAN, so a device there could forge syslog records.

## Resource and loss limits

VictoriaLogs requests 64Mi and has a 256Mi limit. Fluent Bit requests 64Mi and
has a 192Mi limit. `/var/log` is mounted read-only. Fluent Bit runs as root with
all capabilities dropped, because pod log files are `root:root 0640` and a
non-root user reads none of them. It starts at the journal tail, so it does not
backfill the existing 4 GiB.

Fluent Bit's log buffer is memory-only. A restart can lose the small in-flight
queue. It has no durable journal cursor. `Read_From_Tail On` avoids replaying
old entries after Pod replacement, but can skip entries written during downtime.
Kubernetes events keep a 30-minute input window. VictoriaLogs is not
Loki-compatible and needs the pinned Grafana
`victoriametrics-logs-datasource` plugin.

Container logs may include trace IDs when applications write them. Fluent Bit
preserves structured fields, but it does not create IDs or add them to plain
log messages. See `docs/tracing.md` for the log-to-trace links.

## Where to look

- In Grafana, open `Explore` and select `victoria-logs`.
- Filter `source` to `routeros` or `ap1-132l` for network-device messages.
- Filter `log_type` to `host-journal` or `kubernetes-event` for those sources.
- Check the `victoria-logs`, `fluent-bit`, and `tempo` Flux Kustomizations in
  namespace `o11y`.

Explore requires the Grafana Editor, Admin, or datasource Explorer permission.
Kanidm maps `grafana_admins` and `idm_admins` to Grafana Admin. See `docs/tracing.md` if Explore is
missing from the navigation.

The original VictoriaLogs + Fluent Bit design and its decommission history stay
in `REFACTOR_PLANS.md` under **2026-09-26 (later) — log system** and
**2026-11-07 — efficiency review**.
