# kubesearch-mcp

Search over other people's Flux HelmReleases, from inside the cluster.

kubesearch.dev has **no live API**. It publishes its index as dated SQLite databases
(`repos.db` ~7 MB, `repos-extended.db` ~37 MB) as GitHub release assets of
[`whazor/k8s-at-home-search`](https://github.com/whazor/k8s-at-home-search), refreshed
daily. There is no official MCP server; this deployment uses
[`perfectra1n/kubesearch-mcp`](https://github.com/perfectra1n/kubesearch-mcp) (MIT),
which downloads those databases and queries them locally.

Endpoint: `http://kubesearch-mcp.default.svc.cluster.local:3000/mcp`, Streamable HTTP.

## Why the index is on a volume

~44 MB is downloaded per boot without `/data`. The PVC (`kubesearch-mcp-data`, 2Gi,
`openebs-hostpath`) makes that a once-a-day refresh instead. `/readyz` returns 503
until the download completes, which is why readiness — not liveness — is the probe
that gates traffic. A fresh pod is live immediately and answerable only after the
index arrives.

## Two behaviours switched off

`KUBESEARCH_POOL_SIZE=0` and `KUBESEARCH_ENABLE_CLONE=false`:

- The warm pool permanently clones 15 popular repos (~4 MB each) and refreshes them.
- `repo_clone` / `repo_grep_all` fetch arbitrary repositories on request, guarded only
  by an SSRF filter.

Neither is needed to search the released index, and both are egress from a pod whose
only job is reading a local SQLite file. Flipping either is one line if repo review
ever becomes the point.

## Auth

`MCP_AUTH_TOKEN` — without it the HTTP transport is wide open (binds `0.0.0.0`, CORS
`*`, warning on boot). The token is minted by
`infra/terraform/bootstrap/kubesearch-mcp.tf` into the 1Password item
`kubesearch-mcp` (field `password`), same pattern as the MikroTik MCP token, and read
by the ExternalSecret `kubesearch-mcp`.

The pod stays in `CreateContainerConfigError` until that item exists. That is the
expected failure, not a broken manifest: `mise run tf:plan bootstrap`, `tf:apply`.

## Verifying

```sh
kubectl -n default get pods -l app.kubernetes.io/name=kubesearch-mcp
kubectl -n default logs deploy/kubesearch-mcp --tail=20   # index download
curl -sS http://kubesearch-mcp.default.svc.cluster.local:3000/readyz   # 200 when loaded
```

An unauthenticated `POST /mcp` must return 401 — if it answers, the token did not
reach the pod.

Tools: `search_releases`, `get_release`, `search_images`, `grep_values`, `status`
(the `repo_*` family is disabled above).

## Gotchas

- The image runs as uid **1000** and `/data` must be writable by it; the PVC uses
  `fsGroup: 1000` so no initContainer chown is needed.
- No TLS of its own; terminate at the gateway.
- Rate limit without `GITHUB_TOKEN` is 60 requests/hour — only affects resolving which
  daily release to download.
