# flux-mcp

An MCP server for Flux CD state and diagnostics, so the agent can answer "why is
this Kustomization not ready" without a shell.

Upstream: `cmd/mcp` in
[`controlplaneio-fluxcd/flux-operator`](https://github.com/controlplaneio-fluxcd/flux-operator),
published as `ghcr.io/controlplaneio-fluxcd/flux-operator-mcp:v0.62.1`. The binary is
named `flux-operator-mcp`; this deployment is named `flux-mcp` to match how it is
referenced elsewhere.

Two things to know before touching it. The upstream README labels it **"in preview and
under development"** — breaking changes are expected, which is why the image is pinned
by digest. And it is **AGPL-3.0**, unlike everything else we run. Neither is a problem
for a binary that only reads our own API; both are worth stating plainly.

## Endpoint

`http://flux-mcp.default.svc.cluster.local:8000/mcp` — Streamable HTTP, stateless.

There is **no HTTP health endpoint**: the mux registers only `/mcp`, so `/healthz` and
`/readyz` are 404s. The probes are therefore `tcpSocket` on 8000, which proves the
process is listening and nothing more. That is the honest check available; a wedged
server passes it. This also means a probe failure is meaningful and a probe success
is not.

## Configuration

```
serve --transport=http --port=8000 --read-only
```

- Upstream defaults are `stdio` and port `8080`; both differ here. `sse` was removed
  upstream, so SSE clients cannot connect.
- In-cluster config is auto-detected from `KUBERNETES_SERVICE_HOST` and the mounted
  ServiceAccount token. Unset and out-of-cluster, the process exits with a
  `KUBECONFIG` warning.
- `--read-only` hides reconcile, suspend, resume, apply, delete and patch.
- `--mask-secrets` defaults to true.
- Only the local cluster is visible; multi-cluster means one deployment per cluster.

## The boundary

Contract shared by every MCP server: `openspec/specs/agent-tool-boundary`.

`flux-mcp-read` grants `get`/`list`/`watch` on the Flux API groups, the workload kinds
Flux reconciles, `pods/log`, `events`, and discovery non-resource URLs. No write verbs.

Two deliberate omissions:

- **No `secrets`.** Reading them would only be needed to resolve `substituteFrom` /
  `copyFrom` during a manifest diff. That path also performs a server-side dry run,
  which needs `patch` on arbitrary kinds — a permission this identity must not have.
  The consequence is that `diff_kubernetes_manifest` is unusable from this server.
  That is the trade: diagnosis without the ability to diff.
- **No cluster-admin.** The official chart's `rbac.create: true` binds `cluster-admin`;
  that is why this RBAC is hand-written. `bjw-s-labs/home-ops` makes the same choice
  and binds its own read-only roles.

## Verifying it

```sh
kubectl -n default get pods -l app.kubernetes.io/name=flux-mcp
kubectl -n default logs deploy/flux-mcp --tail=20   # should show the http listener

curl -sS -X POST http://flux-mcp.default.svc.cluster.local:8000/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-07-28","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

Then ask it for a Kustomization that is known-broken; a server that initializes but
cannot list Flux objects is the failure mode the RBAC is there to prevent.

## Gotchas

- `get_flux_instance` errors without a `FluxInstance` resource. We run plain Flux, not
  the operator's instance CR, so that tool will fail here — expected, not a deployment
  bug.
- `yaml_path` for diffs only works over local stdio; HTTP clients must send
  `yaml_content`.
- `RUNTIME_NAMESPACE` is set by the upstream chart and by bjw-s, but the binary never
  reads it. Harmless.
- Stateless HTTP: no sticky sessions, safe to scale.
