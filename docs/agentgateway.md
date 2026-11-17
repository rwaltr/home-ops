# agentgateway

`cr.agentgateway.dev/charts/agentgateway-standalone` — one LLM endpoint in front of
several upstreams, plus (later) an MCP multiplexer. Runs in `default`, cluster-internal
only, `mode: readonly` so the config comes from git and the admin API is off.

The chart is not app-template. Its `config` value renders verbatim into a ConfigMap
key named `config.yaml`, and the container is started with `-f /config/config.yaml`.
The chart also injects `config.storage.mode: file` itself; `session.secretName` is
optional and unused here (that is only for the admin UI's cookie).

## Why it exists next to litellm

litellm stays the endpoint hermes and homebox-companion use. agentgateway is a
second, independent front door carrying the same upstreams, and it is deliberately
**not** chained to litellm — a hop through our own proxy would add a failure mode
without adding anything.

`${VAR}` in the config is interpolated at runtime from the container environment, so
no key ever appears in the ConfigMap or in git. Three keys are wired the same way
litellm wires them:

| Env                      | Source                                             |
| ------------------------ | -------------------------------------------------- |
| `OPENROUTER_API_KEY`     | `hermes-secret` — the same item litellm reads      |
| `DANMANNERS_LLM_API_KEY` | 1P `llm.cloud.danmanners.com` / `credential`       |
| `CLIPROXYAPI_API_KEY`    | 1P `cliproxyapi` / `password`, minted by Terraform |

## Models

Seven aliases, mirroring litellm's list exactly: `deepseek-v4.1-flash`,
`qwen3.8-omni-flash`, `gpt-5.6-luna` (OpenRouter), `nvidia-llama`, `intel-llama`,
`intel-vl`, `gptoss-llama` (Manners' gateway), plus `claude`, which resolves through
cliproxyapi to the subscription account logged in there.

Two litellm aliases are **not** here: `whisper` and `piper`. They point at
`127.0.0.1:8000`, a sidecar inside the litellm pod, and they are transcription and
synthesis endpoints rather than chat completions. Copying the alias without the
sidecar would produce a model that always fails.

## Calling it

```sh
curl -s http://agentgateway.default.svc.cluster.local:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"ping"}]}'
```

`/healthz` on 15021 is for the probes; 15020 is Prometheus metrics.

### Verified

Every model was called through the service on 8080, from inside the cluster:

- `deepseek-v4.1-flash` — real completion, with OpenRouter cost accounting in the response.
- `claude` — a real Anthropic message back from the subscription session, via cliproxyapi.
- `nvidia-llama`, `intel-vl` — local hardware on Manners' gateway, both answering.

That covers all three upstream credentials: OpenRouter from `hermes-secret`,
danmanners from the ExternalSecret, and cliproxyapi's Terraform-minted key.

## Listeners and auth

Three listeners, two of them authenticated:

- **8080 `llm-public`** — `apiKey` in strict mode, published at `/v1`.
- **8081 `mcp-public`** — `apiKey` in strict mode, published at `/mcp`.
- **8082 `internal`** — no auth, ClusterIP only, never routed.

Auth sits at the **gateway** level rather than on the `llm:`/`mcp:` blocks,
because `llm.policies` and `mcp.policies` apply to every gateway they attach to.
Port-level placement is therefore the only split that is a real boundary; a
hostname split would not be, since the `Host` header is client-controlled.

`mode: strict` matters. The default is `optional`, which validates a key when one
is present and lets unauthenticated requests through.

Keys are minted by `infra/terraform/bootstrap/agentgateway-clients.tf` into the
`home-ops` vault — one item per client, consumed as `keys[].key` by environment
substitution. A key's `metadata` carries the client identity, and that becomes the
CEL variable `apiKey.client`, which the model allow-lists and the MCP
authorization rules are written against. Clients send it as
`Authorization: Bearer <key>`; the gateway strips it before forwarding.

`SESSION_KEY` comes from the `agentgateway-session` Secret. Without it MCP session
IDs are base64 rather than encrypted, which discloses the multiplexed target names
to any client that can read its own session id.

### Clients

| Client         | 1Password item | Models                                      | MCP targets                                |
| -------------- | -------------- | ------------------------------------------- | ------------------------------------------ |
| `grok`         | `grok`         | `deepseek-v4.1-flash`, `qwen3.8-omni-flash` | `home-assistant` (read-only)               |
| `pebble-index` | `pebble-index` | `deepseek-v4.1-flash`                       | `home-assistant`, `home-assistant-control` |

Claude is deliberately absent from both allow-lists: it is the paid subscription,
and a leaked client key should not be able to spend it. `allowedModels` also
filters `/v1/models`, and a disallowed model is refused before any provider is
contacted.

### Verified live

After the auth landed, from inside the cluster: 8080 and 8081 both return `401
authentication failed` with no key, and 8080 also rejects the literal string
`${GROK_API_KEY}`. That second one is the useful one — a literal placeholder would
have been a known-plaintext key, so a 401 proves the substitution happened.

## Public door — unpublished

`llm.waltr.tech` was published and then removed, pending an authorization server.
The route was `/v1` → 8080 and `/mcp` → 8081, attached to `envoy-external`, with
external-dns creating the record from the HTTPRoute. Republishing is restoring
`app/httproute.yaml`; nothing else changed, so there is no Terraform record and no
tunnel edit to undo either.

Why it came down: Grok's consumer MCP connector will not accept a static header
for a server that answers `401`. It probes the URL, sees the challenge, and
demands an OAuth client — authorization endpoint, token endpoint, PKCE. Our
gateway authenticates with `apiKey`, which no amount of header configuration
satisfies. The intended authorization server is Kanidm, whose OAuth2 client
endpoints (`/oauth2/authorise`, `/oauth2/token`, ES256 JWTs, PKCE-only public
clients) match that form field for field.

Until then the surfaces stay cluster-internal. 8082 is not routed at all: it
stays on the ClusterIP Service for in-cluster callers, which is what the Hermes
agent's own model config points at.

## MCP

8081 multiplexes four servers behind one endpoint — `flux`, `kubectl`,
`home-assistant`, `mikrotik` — returning 197 tools in a single `tools/list` page
with no cursor. Per-client subsets come from `mcpAuthorization` CEL rules, and a
denied tool is hidden from `tools/list` rather than refused when called, so a
client only ever sees its own surface.

Tool arguments are not visible to `mcpAuthorization`. Argument-level rules would
belong to `mcpGuardrails`, which filters content rather than identity.
