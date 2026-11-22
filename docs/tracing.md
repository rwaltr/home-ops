# Distributed tracing

Grafana queries OpenTelemetry traces from **Grafana Tempo** in namespace `o11y`.
Tempo runs as one StatefulSet with local storage. It accepts OTLP/gRPC on `4317`
and OTLP/HTTP on `4318`. Both ports stay cluster-internal.

Tempo replaced VictoriaTraces. VictoriaTraces only offered the Jaeger API, which
has no TraceQL and no Traces Drilldown. Traces stored there were dropped.

## Trace sources

- Envoy Gateway exports 10% of ingress traces.
- agentgateway exports 10% of HTTP, MCP, and LLM traces.
- Grafana exports 10% of its own server traces.
- Prometheus exports 10% of its own traces. The Prometheus Operator marks this
  field experimental.
- Tempo's metrics generator writes span metrics and service-graph metrics to
  Prometheus. Tempo 3 removed the `local-blocks` processor, so it is not used.

agentgateway's default spans include model and token-use metadata. This setup
does not add prompt or response content. Do not add `llm.prompt` or
`llm.completion` attributes without reviewing the privacy impact first.

## What does not emit traces yet

Everything else logs to VictoriaLogs but produces no spans. I checked these:

- **Kanidm 1.11.2** has a native exporter. The binary reads
  `KANIDM_OTEL_GRPC_ENDPOINT`. I did not enable it. It needs a Kanidm restart,
  and I could not confirm the operator passes the variable through. Try it in a
  separate change so a bad value cannot take sign-in down with it.
- **Immich** has an OpenTelemetry SDK, but the project documents only metrics.
  Traces need a modified build or auto-instrumentation.
- **Jellyfin** has a third-party OpenTelemetry plugin for 10.11. Built-in support
  is an open pull request.
- **Home Assistant** has third-party HACS integrations only.
- **Forgejo** and **CloudNativePG** did not return a documented trace exporter.
  I did not verify either.
- **Cilium Hubble** exports network flows, not traces. It is not enabled.

## Storage and failure behavior

Tempo retains trace blocks for seven days on a 10 Gi `openebs-hostpath` PVC.
Its 256Mi memory request and 1Gi limit are initial budgets. Tempo's local
backend has age-based retention but no hard disk cap. Check disk growth and
working set after traffic accumulates.

Neither gateway depends on Tempo being ready. Envoy and agentgateway keep
serving traffic during a Tempo outage, and traces may be lost until export
recovers.

## Where to go

Open [Grafana Explore](https://grafana.waltr.tech/explore) and choose `Tempo`.
Search for service `agentgateway`, `envoy-internal.network`, or
`envoy-external.network`. Click a result to view its span waterfall.

In **Drilldown → Traces**, the RED views compare request rate, errors, and
duration without writing TraceQL. In Explore, try:

```text
{ resource.service.name = "agentgateway" }
```

### If Explore is missing

Explore needs the Grafana Editor or Admin role. The Kanidm mapping gives Admin to
members of `grafana_admins` or `idm_admins`, and Viewer to everyone else. Viewer
cannot open Explore.

`grafana_admins` is declared in
`infra/k8s/kyz/apps/identity/resources/app/group-grafana-admins.yaml`. After the
group reconciles, sign out of Grafana and sign in again. The role is set at login.

## Linking traces and logs

From a trace, the Tempo datasource searches VictoriaLogs for the trace ID as text.
That matches agentgateway access logs, which write `trace.id=<hex>` into the
message. Envoy access logs and other containers do not include a trace ID, so
those spans have no log link.

From a log line, a derived field opens the trace in Tempo. It matches a
`trace.id` or `trace_id` field, or the `trace.id=<hex>` text in agentgateway logs.
