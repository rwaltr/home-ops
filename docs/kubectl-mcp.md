# kubectl-mcp

A read-only MCP server over the cluster API, for the agent's triage work. It is the
kubectl-shaped sibling of `flux-mcp` and reaches the API the way any in-cluster
workload does: its own ServiceAccount, no kubeconfig file.

Upstream: [`rohitg00/kubectl-mcp-server`](https://github.com/rohitg00/kubectl-mcp-server)
(MIT), image `ghcr.io/rohitg00/kubectl-mcp-server:2.0.0`.

Chosen over `containers/kubernetes-mcp-server` and `Flux159/mcp-server-kubernetes`
for one reason: it is the only one of the three whose in-cluster path actually works.
Flux159's server resolves an in-cluster config but its tools shell out to the `kubectl`
binary, which never receives that config — a combination that fails at the first tool
call. `containers/kubernetes-mcp-server` documents its read-only mode as a
"best-effort guardrail"; this one enforces it in middleware and backs it with RBAC.

## Endpoint

`http://kubectl-mcp.default.svc.cluster.local:8000/mcp` — Streamable HTTP, stateless,
no session pinning. Legacy `sse` is deprecated upstream and not used here.

Health and introspection live on the same port: `/health` (used by both probes),
plus `/stats`, `/metrics`, `/safety`.

## The boundary

Three layers, deliberately redundant:

1. `--read-only` / `MCP_SAFETY_MODE=read-only` — write tools are hidden from
   `on_list_tools` and rejected in `on_call_tool`, not merely filtered.
2. The `kubectl-mcp-read` ClusterRole — `get`, `list`, `watch` only. There are no
   write verbs to reach, so a bypass of layer 1 lands on a denial.
3. **No `secrets` access at all.** `MCP_MASK_SECRETS=true` redacts values in output,
   but masking is a formatting step over a value the process already holds. The verb
   not being granted is the actual boundary.

There is also **no bearer-token auth** on this server. Its only auth modes are OAuth
2.1 JWT or `--allow-unauthenticated`. We use the latter plus a ClusterIP service:
this endpoint is for in-cluster callers and must not be published beyond the cluster
without an OAuth issuer in front of it. The startup check that enforces that
(`ensure_network_exposure_allowed`) is why the env var is set explicitly rather than
left to default.

## Toolset

`MCP_TOOLSETS=default,diagnostics`. Default alone is core+helm; diagnostics adds
describe/events/logs. Further toolsets (`security`, `multicluster`, `cilium`) are
available upstream and are a one-line change if triage wants them.

## Verifying it

```sh
kubectl -n default get pods -l app.kubernetes.io/name=kubectl-mcp
kubectl -n default get --raw "/api/v1/namespaces/default/pods" >/dev/null  # sanity

# the server answers MCP initialize on the endpoint
curl -sS -X POST http://kubectl-mcp.default.svc.cluster.local:8000/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-07-28","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

Then confirm the denial path, which matters more than the success path: a tool that
writes must be absent from `tools/list` and rejected if called by name.

## Gotchas

- The image bakes `MCP_SERVER_TRANSPORT=stdio` and `MCP_SERVER_HOST=0.0.0.0`. Both
  the `--transport http` argument and the unauthenticated flag are mandatory, and
  without either the container either listens on nothing useful or refuses to start.
- `readOnlyRootFilesystem` requires emptyDirs at `/tmp` and `/home/mcp` (HOME is
  `/home/mcp`, uid 10001).
- Release cadence is slow — v1.24 in February, v2.0 in October. Pin the digest, not
  the tag.
- Chart RBAC in the upstream repo is cluster-wide only, and enables `secrets` with a
  flag. Both are why the RBAC here is hand-written and narrower.
