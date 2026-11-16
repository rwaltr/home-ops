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

## No inbound auth — deliberate, and temporary

8080 answers anyone inside the cluster, so any pod can spend these keys. That is the
same posture the MCP servers in this namespace already have, and it is why the
service has no HTTPRoute. Before anything outside the cluster calls it, add the
chart's `policies.apiKey` block:

```yaml
llm:
  policies:
    apiKey:
      mode: strict
      keys:
        - key: ${SOME_CLIENT_KEY}
          metadata:
            client: hermes
```

`mode: strict` rejects unkeyed callers; per-client `allowedModels` limits which
aliases a key may reach.

## MCP

The chart's other gateway (`gateways.mcp` on 8081, `routes[].backends[].mcp`) is
where the MCP servers get multiplexed behind one endpoint. Not configured yet — that
arrives with the MCP set, and each route gets its own `urlRewrite` plus an
`mcpAuthorization` CEL rule.
