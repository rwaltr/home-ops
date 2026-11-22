# Distributed tracing

VictoriaTraces stores OpenTelemetry traces in namespace `o11y`. Grafana queries
it through the built-in Jaeger datasource. No collector or Grafana traces plugin
is required.

## Pipeline

- VictoriaTraces accepts OTLP/gRPC on the cluster-internal service port `4317`.
- Envoy Gateway sends traces for ingress traffic. It samples 10% of requests.
- agentgateway sends traces for its HTTP, MCP, and LLM traffic. It samples 10%
  of requests that do not inherit a sampling decision.
- VictoriaTraces retains data for 14 days, with an 8 GiB data cap on a 10 Gi PVC.
- Grafana exposes the datasource as `VictoriaTraces` with UID `jaeger`.

The trace store requests 128Mi and has a 512Mi memory limit. Treat this as an
initial budget. Check measured use after the pipeline has collected traffic.

agentgateway's default spans include model and token-use metadata. This config
does not add prompt or response content. Do not add `llm.prompt` or
`llm.completion` attributes without reviewing the privacy impact first.

## Failure behavior

The trace store is not a prerequisite for either gateway. Envoy Gateway and
agentgateway start and serve traffic while VictoriaTraces is down or absent, and
trace export fails on its own. Neither Flux Kustomization declares a
`dependsOn` on `victoria-traces` on purpose: a trace store outage must not gate
ingress or LLM traffic. Losing traces during that window is the accepted cost.

## Using traces

Open **Explore** in Grafana and choose `VictoriaTraces`. The Jaeger query editor
can search by service, operation, tags, and duration. Trace IDs open a span
waterfall, and the dependency graph summarizes service relationships.

The VictoriaLogs datasource adds a trace link when a log has a `trace_id` field.
The collector does not generate IDs or add them to application logs, so this
link requires the application to log its trace ID. Trace-to-logs is not wired
because Grafana's Jaeger datasource documents that feature for Loki and Splunk.

## TraceQL and Traces Drilldown

TraceQL is a query language for selecting spans by attributes and relationships
between spans. Its metrics functions can aggregate trace data into rates,
counts, and latency summaries.

Traces Drilldown is a visual workflow for exploring those metrics without
writing TraceQL. It shows RED views (rate, errors, and duration) and helps find
which service or operation changed.

VictoriaTraces implements Grafana's Tempo API, which enables the Tempo
datasource, TraceQL, and Drilldown. VictoriaMetrics documents that API as
experimental. This setup uses the Jaeger API instead. It provides basic search,
trace details, and dependency graphs without depending on the experimental API.
Revisit Tempo API support if TraceQL or Drilldown becomes useful enough to
accept that compatibility risk.
