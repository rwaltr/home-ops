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
`intel-vl`, `gptoss-llama` (Manners' gateway), plus three subscription aliases that
resolve through cliproxyapi to the account logged in there — `claude-sonnet-5-5`,
`claude-opus-5-5`, `claude-haiku-5-5`. Each alias is the upstream id verbatim, so a
response always names the model that answered.

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
- `claude-sonnet-5-5` — a real Anthropic message back from the subscription session, via cliproxyapi.
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
| `pi`           | `pi`           | the three `claude-*-5-5` aliases            | all four targets                           |

Claude is deliberately absent from the phone clients' allow-lists: it is the paid
subscription, and a leaked client key should not be able to spend it. `pi` is the
exception — it is the operator's own agent client, and the subscription is the one
credential it cannot hold itself. It reaches every other model directly, so its
allow-list is the three subscription aliases and nothing else, and a request for any
other model through this door is refused rather than silently served. `allowedModels`
also
filters `/v1/models`, and a disallowed model is refused before any provider is
contacted.

### Verified live

After the auth landed, from inside the cluster: 8080 and 8081 both return `401
authentication failed` with no key, and 8080 also rejects the literal string
`${GROK_API_KEY}`. That second one is the useful one — a literal placeholder would
have been a known-plaintext key, so a 401 proves the substitution happened.

## Public door — published

`llm.waltr.tech` is published again: `app/httproute.yaml`, attached to
`envoy-external`, with external-dns creating the record from the route itself.
Nothing else is involved — no Terraform record and no tunnel edit — so unpublishing
is deleting the file, the same as navidrome.

Four rules, split by credential rather than by hostname:

- `/v1` → 8080, `apiKey` strict.
- `/mcp` → 8081, `apiKey` strict plus the per-client tool rules.
- `/oauth/mcp` → 8083, rewritten onto `/mcp`. JWT bearer tokens.
- `/.well-known/oauth-protected-resource` → 8082, the unauthenticated listener. The\n document has to be readable by a client that holds no credential yet, so it is the\n one path deliberately published from the internal listener.

The OAuth surface is a second path to the same servers rather than a second
hostname, because a client's identity travels in its credential: Grok presents a
token, the ring presents a key, and one URL cannot accept both.

### Why it came down, and what changed

Grok's consumer MCP connector will not accept a static header for a server that
answers `401`. It probes the URL, sees the challenge, and demands an OAuth client.
`apiKey` cannot satisfy that, however the header is configured. What changed is not
the gateway's auth model but the arrival of an authorization server: Kanidm issues
**RFC 9068 JWT access tokens**, so this gateway can verify a bearer token against
Kanidm's JWKS instead of needing the token to be opaque to it.

Three details are load-bearing:

- **A fourth listener (8083), not another rule on 8081.** `apiKey` and JWT cannot
  share a listener — a key is not a token — so the JWT authentication sits at the
  gateway level, exactly as `apiKey` does for the other two.
- **`mode: strict`.** `optional` and `permissive` both suppress the 401, and without
  the 401 no client begins an OAuth flow. The refusal is the feature.
- **`mcpAuthentication` lives in the `mcp` block's policies with `mode: optional`.**
  That object is what serves the protected-resource metadata (RFC 9728) a client
  fetches before it holds a token, and `resourceMetadata` is required on it. It is
  permissive because `mcp.policies` attaches to every gateway the servers are served
  on, and the apiKey and internal listeners have to keep working without a token.
  Enforcement is the gateway-level JWT — the same placement argument as `apiKey`.

### The Kanidm client, and the two values still placeholder

`oauth2client.yaml` in this app's directory is the client the connector signs in with,
the same shape Grafana's takes. It is confidential rather than public, because xAI's
connector accepts a client secret and that keeps the token exchange on their server.
PKCE is required regardless. The operator mints the secret into a Secret in this
namespace; read it with `kubectl -n default get secret grok-mcp -o jsonpath='{.data}'`.

Two fields are **placeholders**: `origin` and `redirectUrl`. Both are xAI's, not ours.
They are not in xAI's documentation, and nothing on our side can infer them — the
connector sends them when it starts a flow. They are set to a reserved `.invalid` host
so a placeholder cannot be mistaken for a working value, and they are kept consistent
with each other because Kanidm expects the origin to be the origin of the redirect.

The real values come from the connector UI at `grok.com/connectors`, which shows the
callback it will use, or from Kanidm's log, which names the rejected `redirect_uri`
when a first attempt fails. `strictRedirectUrl` is left at its default — exact
matching — so a wrong value is surfaced rather than papered over by origin-only
matching.

Until they are replaced the client exists, its signing key resolves, and any
authorization attempt is refused. That is the correct state for a client whose callback
is not yet known: it also means the JWT listener's JWKS URL is live rather than
pointing at a 404.

## MCP

8081 multiplexes four servers behind one endpoint — `flux`, `kubectl`,
`home-assistant`, `mikrotik` — returning 197 tools in a single `tools/list` page
with no cursor. Per-client subsets come from `mcpAuthorization` CEL rules, and a
denied tool is hidden from `tools/list` rather than refused when called, so a
client only ever sees its own surface.

Tool arguments are not visible to `mcpAuthorization`. Argument-level rules would
belong to `mcpGuardrails`, which filters content rather than identity.
