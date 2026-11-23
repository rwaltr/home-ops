# agentgateway

`cr.agentgateway.dev/charts/agentgateway-standalone` — the cluster's only LLM
endpoint, in front of several upstreams, plus an MCP multiplexer. Runs in `default`,
`mode: readonly` so the config comes from git and the admin API is off.

The chart is not app-template. Its `config` value renders verbatim into a ConfigMap
key named `config.yaml`, and the container is started with `-f /config/config.yaml`.
The chart also injects `config.storage.mode: file` itself; `session.secretName` is
optional and unused here (that is only for the admin UI's cookie).

## Replaced litellm (2026-11-18)

litellm was the first door: one OpenAI-compatible proxy in front of OpenRouter and
Dan Manners' gateway, with a speaches sidecar for whisper/piper audio. It ran until
2026-11-18 and was deleted whole — app, `litellm-config`, `litellm-secret`, the
`litellm-models` PVC, the `litellm.waltr.tech` route, its Homepage tile and its docs.
`docs/local-llm.md` is gone; anything still true from it lives here.

**Audio went with it.** agentgateway is chat/completions, not STT/TTS, so the
`whisper` and `piper` aliases had no successor and neither did the speaches sidecar.
Nothing in the cluster called litellm's port 8000 — Home Assistant has always used
the `wyoming-*` pods over the Wyoming protocol — so the second copy of whisper/piper
(and the ~20Gi PVC holding its HF cache) was duplication all along. `parakeet` serves
OpenAI-compatible transcriptions on 10301 if that door is ever wanted again.

Everything that used to point at `litellm.default.svc.cluster.local:4000` now points
at **8082, the unauthenticated in-cluster listener** — same trust boundary as before,
since every one of them shared litellm's master key:

| Consumer            | Model                | Env                                           |
| ------------------- | -------------------- | --------------------------------------------- |
| `hermes`            | local aliases        | `providers.agentgateway`                      |
| `hermes-personal`   | `auto-work`          | authenticated 8080 / `providers.agentgateway` |
| `homebox-companion` | `qwen3.8-omni-flash` | `HBC_LLM_API_BASE`                            |
| `paperless`         | `intel-vl`           | `PAPERLESS_AI_LLM_ENDPOINT`                   |

8082 wants no key, so the in-cluster callers on that listener carry a placeholder
(`unused`) rather than a Secret — the OpenAI-shaped clients refuse to run without one.
`hermes-personal` instead calls the authenticated 8080 listener with its dedicated,
model-restricted key.

**One consumer cannot move in git.** Home Assistant's native LiteLLM integration
(Settings → Devices & services) is config-flow only and lives in `.storage` on the HA
PVC. It needs repointing by hand: set the base URL to
`http://agentgateway.default.svc.cluster.local:8082` and any non-empty key, then keep
the existing `conversation.deepseek_v4_1_flash` entity in the Glados pipeline. 8082
comes from a ClusterIP Service, so a pod in this cluster reaches it the same way HA
reached litellm.

What litellm did that agentgateway does not: `drop_params: true` and `num_retries: 2`.
A parameter or alias an upstream rejects is now surfaced rather than retried or
stripped — which is the better default for a proxy whose failures should be visible.

`${VAR}` in the config is interpolated at runtime from the container environment, so
no key ever appears in the ConfigMap or in git. Three keys are wired this way:

| Env                       | Source                                                              |
| ------------------------- | ------------------------------------------------------------------- |
| `OPENROUTER_API_KEY`      | `hermes-secret` — the sysadmin agent's key                          |
| `DANMANNERS_LLM_API_KEY`  | 1P `llm.cloud.danmanners.com` / `credential`                        |
| `CLIPROXYAPI_API_KEY`     | 1P `cliproxyapi` / `password`, minted by Terraform                  |
| `HERMES_PERSONAL_API_KEY` | 1P `hermes-personal-agentgateway` / `password`, minted by Terraform |

## Models

`deepseek-v4.1-flash`, `qwen3.8-omni-flash`, `gpt-5.6-luna` (OpenRouter) and
`voyage-code-4` (embeddings, for kritika's index); `nvidia-llama`, `intel-llama`,
`intel-vl`, `gptoss-llama` (Manners' gateway); `go/deepseek-v4.1-flash` (OpenCode Go);
and three subscription aliases that resolve through cliproxyapi to the account logged
in there — `claude-sonnet-5-5`, `claude-opus-5-5`, `claude-haiku-5-5`. Each alias is
the upstream id verbatim, so a response always names the model that answered.

The four `auto-*` virtual models sit on top of those — see
[Failover chains](#failover-chains). Their name is not an upstream id: the response
names the target that served the request, not the alias that was asked for. The
`pi` extension classifies individual turns and routes physical models directly;
these gateway aliases provide the same tier choices to other clients.

Where each one really runs matters more than the alias, because it decides whether a
request leaves the house and whether it is billed:

| Alias                 | Backend       | Notes                                                                  |
| --------------------- | ------------- | ---------------------------------------------------------------------- |
| `deepseek-v4.1-flash` | OpenRouter    | Cloud, billed. The sysadmin Hermes fallback and phone-client default.  |
| `qwen3.8-omni-flash`  | OpenRouter    | Cloud. **Vision + audio + video.** homebox-companion's default.        |
| `gpt-5.6-luna`        | OpenRouter    | Cloud. **Vision**; 404s on a video part.                               |
| `voyage-code-4`       | OpenRouter    | Cloud. Embeddings, 1024 dims. Not on any client's allow-list.          |
| `nvidia-llama`        | Dan's gateway | Self-hosted `inkling-2-mini` (vLLM), 151k context. Best local pick.    |
| `intel-llama`         | Dan's gateway | Self-hosted Llama on Intel hardware, 229k context. PARKED on his side. |
| `intel-vl`            | Dan's gateway | **Vision**: Qwen3-VL-8B on an Intel Arc. Paperless + Immich use it.    |
| `gptoss-llama`        | Dan's gateway | Self-hosted `gpt-oss-20b-f16`, 114k context.                           |
| `claude-*-5-5`        | cliproxyapi   | The paid subscription. `pi` only — see the allow-lists below.          |

The two OpenRouter vision aliases exist for photo/video intake (homebox-companion and
the walkthrough-to-CSV route). Both read image barcodes well enough to be useful but
not perfectly: on a 49-frame test, each produced one ISBN-13 whose check digit did
**not** validate, while the same library read in a single native-video pass
validated 3/3. Validate the check digit before trusting a barcode, and prefer a
video pass to supply ISBNs — rationale and numbers in `REFACTOR_PLANS.md`.

## Dan Manners' gateway

A shared LiteLLM proxy at `https://llm.cloud.danmanners.com/v1`, reached with its own
outbound key (1P `llm.cloud.danmanners.com` / `credential`). It exposes ~28 models;
only the four backed by hardware on his network are aliased here — the rest of his
catalog is cloud-backed and proxying it would just be a second hop to
OpenRouter/Z.ai.

**What it retains.** Prompt/response content is **not** stored —
`store_prompts_in_spend_logs` is unset (→ false), and spend-log rows come back with
`messages={}` / `response={}` / `proxy_server_request={}`. Metadata _is_ kept:
`maximum_spend_logs_retention_period` is unset (→ no pruning), so the model, token
counts, cost, timing, hashed key, requester IP and user agent of every request
persist indefinitely. The key we hold is admin-level — an unfiltered `/spend/logs`
returns global rows from other users, and `/config/list` answers — so treat it as
broad read on his proxy, not a scoped virtual key.

Useful distinction when adding more: query `GET /v1/model/info` with the key and read
`litellm_params.model` / `litellm_params.api_base`. Anything with an `api_base`
pointing at `*.aiml.svc.cluster.local` or a LAN IP is self-hosted; an empty `api_base`
with an `openrouter/...` or vendor `/...` model is cloud. Names can lie — his
`media-analysis`, `decision` and `embed-text` are cloud (Google, OpenAI, OpenRouter),
not local.

## Failover chains

Four virtual models give one name per capability tier. Work stays on the proven,
low-cost Luna model; deep and max start on the Claude subscription, then drop to
Luna when that subscription is exhausted rather than paying OpenRouter's Claude
prices.

| Alias        | priority 0               | priority 1                 | priority 2        | priority 3        |
| ------------ | ------------------------ | -------------------------- | ----------------- | ----------------- |
| `auto-quick` | `go/deepseek-v4.1-flash` | `deepseek-v4.1-flash` (OR) |                   |                   |
| `auto-work`  | `go/gpt-6-luna`          | `gpt-6-luna` (OR)          |                   |                   |
| `auto-deep`  | `claude-sonnet-5-5`      | `go/gpt-6-luna`            | `gpt-6-luna` (OR) |                   |
| `auto-max`   | `claude-opus-5-5`        | `claude-sonnet-5-5`        | `go/gpt-6-luna`   | `gpt-6-luna` (OR) |

(OR = OpenRouter.)

The targets are `visibility: internal`, so they do not appear in `/v1/models` and
cannot be requested directly. The alias is the only name a client sees.

**The tier is the caller's choice, not the gateway's guess.** agentgateway routes on
health and priority; it cannot read a prompt. Pi uses heuristics plus a classifier to
choose each turn's tier and directly routes to the equivalent physical-model chain.
Other clients choose a tier alias and get subscription-first routing without learning
about OpenRouter or needing to implement their own fallback.

Three details are load-bearing:

- **`health.unhealthyExpression` is what makes quota fail over.** The default
  unhealthy classifier covers `5xx`, server-side gRPC failures and connection
  failures only. A subscription running out arrives as `429`, or `402`/`403` from a
  proxy that wants a top-up, so without this expression the chain never moves — the
  identical trap a retry-based router hits, because Pi treats those as non-retryable
  too. Setting `health` _replaces_ default eviction rather than adding to it, which
  is why `eviction` is spelled out beside the expression.
- **Failover is eviction, not a rewrite.** The request that trips eviction still
  fails; the next one lands on the next priority group. No retry policy is set here
  on purpose: a silently replayed completion is worse than a visible error, and every
  caller already retries.
- **Being visible is not enough for a client to reach it.** A client's `allowedModels`
  filters `/v1/models` and refuses the request before any provider is contacted, so a
  new alias also needs adding to the keys that should see it.

Adding another chain is one `llm.models` entry per target plus one `virtualModels`
entry. Validate before committing — the chart renders a ConfigMap the binary reads,
and the binary can check it without starting:

```sh
yq '.spec.values' infra/k8s/kyz/apps/default/agentgateway/app/helmrelease.yaml > /tmp/values.yaml
helm template agentgateway oci://cr.agentgateway.dev/charts/agentgateway-standalone \
  --version v1.7.0 -f /tmp/values.yaml | yq 'select(.kind=="ConfigMap") | .data["config.yaml"]' > /tmp/rendered.yaml
podman run --rm --security-opt label=disable -v /tmp/rendered.yaml:/config.yaml:ro \
  -e OPENROUTER_API_KEY=dummy -e OPENCODE_GO_API_KEY=dummy -e CLIPROXYAPI_API_KEY=dummy \
  cr.agentgateway.dev/agentgateway:v1.7.0 -f /config.yaml --validate-only
```

## Adding a model

Add an entry to the `llm.models` list in this app's `helmrelease.yaml`:

```yaml
- name: <alias>
  provider: openAI
  params:
    apiKey: ${OPENROUTER_API_KEY}
    baseUrl: https://openrouter.ai/api/v1
    model: <vendor>/<model>
```

Flux reconciles the ConfigMap and the pod rolls itself (`mode: readonly`, file
config). Outside Git/Flux: `kubectl rollout restart deploy/agentgateway -n default`.
The alias is the upstream id verbatim by convention, so a response names what
answered.

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

| Client            | 1Password item                 | Models                                                     | MCP targets                                |
| ----------------- | ------------------------------ | ---------------------------------------------------------- | ------------------------------------------ |
| `grok`            | `grok`                         | `deepseek-v4.1-flash`, `qwen3.8-omni-flash`                | `home-assistant` (read-only)               |
| `pebble-index`    | `pebble-index`                 | `deepseek-v4.1-flash`                                      | `home-assistant`, `home-assistant-control` |
| `pi`              | `pi`                           | the three `claude-*-5-5` aliases, the four `auto-*` chains | all four targets                           |
| `hermes-personal` | `hermes-personal-agentgateway` | the four `auto-*` chains                                   | none                                       |

Direct Claude model aliases are absent from phone-client allow-lists because they
consume the paid subscription. `pi` is the operator's client and can request those
aliases directly. `hermes-personal` can request only the four `auto-*` aliases. Its
`auto-deep` and `auto-max` chains can consume Claude subscription quota, so use those
tiers deliberately. The personal key cannot request direct Claude aliases, physical
provider models, or MCP tools. `allowedModels` also filters `/v1/models`, and a
disallowed model is refused before any provider is contacted.

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

## Rolling restarts

A restart of this pod used to break whatever was mid-request, and it was not the
rollout strategy's fault: `maxUnavailable` resolves to 0 at one replica, so a new pod
is always Ready before the old one goes. The problem was the old pod's own shutdown.
agentgateway's drain is bounded by two config fields, and both defaults are hostile to
a long-lived LLM response — `connectionMinTerminationDeadline` defaults to **zero**, so
the listener closes the instant SIGTERM arrives, and `connectionTerminationDeadline`
falls back to **5s** when the pod's grace period is not in the environment (the chart
sets no `TERMINATION_GRACE_PERIOD_SECONDS`, and no value for the pod's grace period).
Any completion slower than five seconds was cut as a bare EOF with no status code, and
any connection still being routed to the dying pod was refused.

Three settings now fix that, and they have to agree with each other:

| Setting                            | Where                                            | Value                                                               |
| ---------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------- |
| `connectionMinTerminationDeadline` | the config                                       | `10s` — keep accepting while endpoints converge                     |
| `connectionTerminationDeadline`    | the config                                       | `295s` — the total drain window for in-flight streams               |
| `terminationGracePeriodSeconds`    | pod spec, via `postRenderers` in the HelmRelease | `300` — must exceed the drain window, or kubelet SIGKILLs mid-drain |

The chart has no value for the pod's grace period, which is why it arrives through a
post-renderer rather than `values`. Readiness flips immediately on SIGTERM, so the pod
leaves the Service at once while it finishes what it was doing; the proxy exits as soon
as its connections are done, so the 300s ceiling costs nothing on an idle roll.

## MCP

8081 multiplexes four servers behind one endpoint — `flux`, `kubectl`,
`home-assistant`, `mikrotik` — returning 197 tools in a single `tools/list` page
with no cursor. Per-client subsets come from `mcpAuthorization` CEL rules, and a
denied tool is hidden from `tools/list` rather than refused when called, so a
client only ever sees its own surface.

Tool arguments are not visible to `mcpAuthorization`. Argument-level rules would
belong to `mcpGuardrails`, which filters content rather than identity.
