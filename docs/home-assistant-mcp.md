# home-assistant-mcp

Home Assistant state and services as MCP tools, read-only.

Upstream: [`homeassistant-ai/ha-mcp`](https://github.com/homeassistant-ai/ha-mcp) (MIT),
image `ghcr.io/homeassistant-ai/ha-mcp:9.2.0`, pinned by digest. Chosen over
`voska/hass-mcp` (no documented auth or read-only mode) and `tevonsb/homeassistant-mcp`
(last pushed January 2026).

Endpoint: `http://home-assistant-mcp.default.svc.cluster.local:8086/mcp`.

## The token is not new

`HOMEASSISTANT_TOKEN` is the long-lived token Home Assistant already issues for
Prometheus scraping — item `home-assistant-secret`, field `prometheus_token`. No second
credential was created.

That token carries **its own permissions**, and ha-mcp adds none of its own: anything
the token can do, a tool call can do. Which is why:

- `READ_ONLY_MODE=true`. State and history are readable; service calls that change
  anything are not offered. Flipping it to `false` is a one-line change and a pod roll,
  and should be a deliberate act rather than a convenience — the tools it enables reach
  locks, covers and climate.
- `HA_MCP_DISABLE_SETTINGS_UI=1`. The settings UI sits under the MCP path and would let
  any holder of that path rewrite the entity allow/deny filters.

## Auth: the URL path is the credential

In standard mode this server has **no bearer-token auth**. It authenticates by path
secrecy — `MCP_SECRET_PATH`, default `/mcp`. OAuth and OIDC entrypoints exist upstream
(`ha-mcp-oauth`, `ha-mcp-oidc`) if per-user tokens are ever wanted.

So the service is cluster-internal and nothing routes to it except agentgateway. If it
is ever exposed directly, change `MCP_SECRET_PATH` to a high-entropy value first — the
default path on a reachable port is the misconfiguration the upstream SECURITY.md names.

## Probes

`MCP_HEALTHZ=true` is required: without it there is no health endpoint and there is
nothing to probe. With it, `/healthz` answers unauthenticated on 8086.

## Verifying

```sh
kubectl -n default get pods -l app.kubernetes.io/name=home-assistant-mcp
kubectl -n default logs deploy/home-assistant-mcp --tail=20   # ws connection to HA
curl -sS http://home-assistant-mcp.default.svc.cluster.local:8086/healthz
```

Then ask it for an entity's state; a server that connects but returns nothing is
usually the websocket, not the REST API — service calls go over
`ws://home-assistant:8123/api/websocket` and that connection is separate.

## Gotchas

- The image's default command is the **stdio** binary. `command: [ha-mcp-web]` is what
  makes it serve HTTP; without it the pod starts and answers nothing.
- `~/.ha-mcp` holds entity filters and tool settings, mounted `emptyDir`, so they reset
  on restart. Intended: filters belong in git.
- Changing `READ_ONLY_MODE` or `DISABLED_TOOLS` requires the client to refresh its tool
  list; a cached list keeps offering tools the server no longer has.
- DNS-rebinding protection is off upstream by default (`FASTMCP_HTTP_HOST_ORIGIN_PROTECTION`).
  Any deployment that front-does it with a host-based router should set it.
