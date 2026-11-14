# MikroTik MCP (MikroMCP)

`AliKarami/MikroMCP` — a typed MCP server for RouterOS (133 tools, roles,
dry-run, audit). Deployed read-only at
`infra/k8s/kyz/apps/default/mikrotik-mcp/`, service
`http://mikrotik-mcp.default.svc.cluster.local:3000`, HTTP (streamable) transport.
Not exposed outside the cluster; an agent reaches it through agentgateway.

Chosen over the alternatives for one reason: it publishes versioned images
(`ghcr.io/alikarami/mikromcp:1.9.0`). `wiresage/mikrotik-mcp` is better starred
and Python, but its registry carries only `sha-*` tags; `mikrotik-mcp/mikrotik-mcp`
advertises +980 tools but its image is not pullable; `thalisantunes/mcp-mikrotik`
is read-only by default but has two stars.

## Router-side prerequisites (checked from the cluster, not assumed)

The router (`gateway-132l`, RB5009, `10.10.0.1`) answers REST on **plain `www`
port 80** — `GET /rest/system/resource` returns `401` without credentials — and
**refuses 443**, so `www-ssl` is not enabled and there is no certificate
installed. `api-ssl` on 8729 is open but irrelevant: MikroMCP speaks RouterOS
_REST_, not the binary API.

So the current config is `tls.enabled: false, port: 80`, which works today. The
trade-off is explicit: the API user's password crosses the management LAN in the
clear. Closing it is a router change, not a cluster change:

```
# issue/reuse a certificate, then:
/ip service set www-ssl certificate=<cert> port=443 address=10.10.0.10/32 disabled=no
```

then flip `routers.yaml` in the ConfigMap to `tls.enabled: true, port: 443`.
`address=` also applies to WebFig, so include whatever subnet you administer from.

The API user itself should be the minimum policy for what the deployment is:

```
/user add name=mcp-api group=read password=<strong>
```

`read` covers the inspection tools. Anything beyond that needs `write`, `api`,
`rest-api` (and `ssh`/`test`/`sniff` for the tools that shell out or capture) —
do not grant those while the identity role is `readonly`.

## Credentials

1Password item `microtik`, vault `home-ops`, Login type — note the spelling. Field labels are the
contract in `app/externalsecret.yaml`:

- `username` → `ROUTER_MOUSE_USER` (must match `envPrefix` in `routers.yaml`)
- `password` → `ROUTER_MOUSE_PASS`
- `confirmsecret` → `MIKROMCP_CONFIRMATION_SECRET` (HMAC key for destructive action
  confirmations — required in HTTP mode even read-only)
- `mcptoken` is **not** on this item. The inbound bearer token is a _generated_
  credential, so it is minted by Terraform into its own item `microtik-mcp`
  (`infra/terraform/bootstrap/mikrotik-mcp.tf`), where it lives in the login's
  `password` field — the only top-level shape the 1Password provider can write and
  External Secrets can read back. The ExternalSecret reads both items.

The item's `website` field (`10.10.0.1`) is deliberately **not** mapped: 1Password
Connect exposes a Login's URL under `urls`, not `fields`, so an ExternalSecret
cannot read it — asking for it fails with
`expected one 1Password ItemField matching: 'website' in 'microtik', got 0`. The
address that matters is the one in the ConfigMap's `routers.yaml`.

Renaming a label in 1Password silently costs the pod that variable, and a missing
_item_ fails the whole ExternalSecret rather than one key, so change both sides in
the same breath.

**The item title is `microtik`** (spelled with an `r`), and 1Password matches
titles literally — referencing `mikrotik` produced
`key not found in 1Password Vaults: mikrotik in: map[home-ops:1]`, which reads
like a caching problem and is not one. If the title is ever corrected in
1Password, this line in `app/externalsecret.yaml` has to change in the same breath.

1Password Connect _does_ also cache vault/item metadata, so a genuinely
just-created item can lag; the tell-tale is that the error names the item you
asked for. Clearing it:

```sh
kubectl -n external-secrets rollout restart deploy/onepassword-connect
```

## Why an initContainer

HTTP transport refuses to start without `identities.yaml`, whose tokens must be
bcrypt hashes. Rather than commit a hash (and thereby the raw token's provenance),
an initContainer hashes `MIKROMCP_CLIENT_TOKEN` at pod start with the image's own
`bcryptjs` and writes `identities.yaml` into an emptyDir alongside a copy of
`routers.yaml`. The raw token exists only in the Secret; the hash is regenerated
every start.

The token is named explicitly on the initContainer, **not** inherited: `env` and
`envFrom` are per-container, so an `envFrom` on the app container never reaches an
init container. The failure looks like a bcrypt problem rather than a wiring
problem — `Error: Illegal arguments: undefined, number` from inside `hash()` — and
the pod sits in `Init:Error` forever.

Identity role is `readonly`: read tools, and confirmation required for anything
destructive.

## `rosVersion` is required and is not cosmetic

`routers.yaml` sets `rosVersion: "7.16"`. Upstream requires it because it selects
REST paths that moved between 7.x releases. Confirm it against the router's own
`/system/resource` on the first read — if the tools that touch version-sensitive
subsystems fail, that field is the first suspect.

## Checking it

```sh
# No health endpoint is documented; liveness/readiness are TCP on 3000.
kubectl -n default logs deploy/mikrotik-mcp

# MCP initialize, then tools/list, with the client token from 1Password:
curl -s -X POST http://mikrotik-mcp.default.svc.cluster.local:3000/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```
