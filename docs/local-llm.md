# Local LLM gateway (LiteLLM + Ollama + Speaches)

One OpenAI-compatible endpoint for everything: local models, OpenRouter cloud
models, and speech-to-text / text-to-speech. Defined in
`infra/k8s/kyz/apps/default/litellm/`.

|              |                                                                           |
| ------------ | ------------------------------------------------------------------------- |
| Proxy API    | `http://litellm.default.svc.cluster.local:4000/v1`                        |
| Admin UI     | `https://litellm.waltr.tech` (envoy-internal)                             |
| Ollama API   | `http://litellm.default.svc.cluster.local:11434`                          |
| Speaches API | `http://litellm.default.svc.cluster.local:8000`                           |
| Master key   | 1Password item `litellm`, field `master_key` → `litellm-secret`           |
| Consumers    | hermes (`providers.litellm`), Home Assistant (native LiteLLM integration) |

## Live models

| Model                 | Backend    | Notes                                                             |
| --------------------- | ---------- | ----------------------------------------------------------------- |
| `qwen3-1.7b-nothink`  | ollama     | Local chat. ~34 tok/s here, answers immediately.                  |
| `deepseek-v4.1-flash` | OpenRouter | Cloud; key reused from `hermes-secret`.                           |
| `whisper`             | speaches   | `audio_transcription` (faster-whisper small-int8).                |
| `piper`               | speaches   | `audio_speech`. Pass `voice` through, e.g. `en_US-glados-medium`. |

## Adding a model

**Registry model** (simplest) — add to the `model-import` init container and
the `model_list`:

```yaml
# helmrelease.yaml, initContainers.model-import command
ollama pull <model>:<tag>
```

```yaml
# helmrelease.yaml, configMaps.litellm-config model_list
- model_name: <alias>
  litellm_params:
    model: openai/<ollama-model-name>
    api_base: http://127.0.0.1:11434/v1
    api_key: ollama # required by the openai provider; unused
```

Use the generic `openai/` provider (not `ollama_chat`) so `logprobs` /
`top_logprobs` pass through spec-faithfully.

**GGUF model** — you need a curl init container to fetch it (the ollama image
is minimal: no curl/wget), sha256-pinned, then `ollama create -f` a Modelfile.
That machinery was removed when FunctionGemma was dropped; re-add both stages
together. Verify the model actually _stops_ generating before trusting it (see
"Traps" below).

Then reload: models are baked at pod start, so
`kubectl rollout restart deploy/litellm -n default`.

## Traps

- **ollama's OpenAI endpoint drops `think`.** Verified across `/v1/chat/
completions`, `/api/chat`, and prompt-level `/no_think`. Only the native
  `/api/chat` honours it. Through LiteLLM, a thinking model therefore _always_
  thinks. To serve one, rebuild it with the nothink generation prompt baked in
  — that's how `qwen3-1.7b-nothink` is produced:

  ```sh
  ollama show qwen3:1.7b --modelfile > /tmp/mf
  sed 's/if and \$\.IsThinkSet (not \$\.Think) -/if true -/' /tmp/mf > /tmp/mf-nothink
  ollama create qwen3-1.7b-nothink -f /tmp/mf-nothink
  ```

  This is regenerated from upstream at boot, so bumping the ollama tag is safe.
  Don't hand-edit the variant.

- **Verify stop behaviour before trusting a converted GGUF.**
  `acon96/Home-FunctionGemma-270m` repeated its function call forever — the
  template emitted `<end_function_call>` as text, so there was no stop token.
  Ask for a short completion and count: if it repeats instead of stopping, drop
  it.

- **Audio models are duplicated.** The wyoming-_ pods serve Home Assistant over
  the Wyoming TCP protocol, which LiteLLM cannot speak, and no
  OpenAI→Wyoming shim exists (`roryeckel/wyoming_openai` is the reverse
  direction). So speaches holds its own whisper + piper. That's bounded by
  `STT_MODEL_TTL=300` (whisper unloads after 5m idle). To de-duplicate, bridge
  HA at the wyoming_openai server and delete the wyoming-_ pods.

- **First STT call downloads ~460MB** (Systran/faster-whisper-small) onto the
  models PVC. Expect a slow first request.

## Memory discipline

The node has **no disk swap**, only 4Gi zram, so:

- `OLLAMA_KEEP_ALIVE=10m`, `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`
  — one model resident, unloaded when idle.
- `OLLAMA_CONTEXT_LENGTH=8192` bounds the KV cache. Overridable per request.
- ollama is capped at 4Gi, speaches 2Gi, litellm 512Mi. Largest local model is
  1.4GB; 4Gi leaves room for a 4B-class swap.
- Model weights are re-downloadable artifacts and are deliberately **not**
  kopia-backed.

## Decision scoring (SemIf-style)

LiteLLM passes logprobs through, so a first-token classifier works without
SemIf's in-process GGUF:

```sh
curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-1.7b-nothink","messages":[{"role":"user","content":"…"}],
       "max_tokens":1,"logprobs":true,"top_logprobs":20}' \
  http://litellm.default.svc.cluster.local:4000/v1/chat/completions
```

Always set `top_logprobs` explicitly — with `logprobs: true` alone LiteLLM
returns an invalid `top_logprobs: null` (litellm#21932). Options outside the
returned top-N are invisible, so this suits binary/small-option decisions; it
is not a substitute for SemIf's arbitrary-option logit readout.

## Home Assistant

HA 2026.9+ has a **native LiteLLM integration** (Settings → Devices & services
→ Add Integration → LiteLLM): give it the base URL
(`http://litellm.default.svc.cluster.local:4000`) and master key, and it creates
a conversation agent per model it discovers. HA's own OpenAI integration cannot
do this — it's hardcoded to OpenAI with no base-URL option.

It's config-flow only, so the config lives in `.storage` on the HA PVC rather
than this repo. Assign the agent under Settings → Voice assistants.

STT/TTS for voice still come from the wyoming-\* pods; the LiteLLM integration
is conversation-only.

## Expectations

Generation is memory-bandwidth bound (`tok/s ≈ bandwidth / model_size`). This
i9-13900H gets ~60-70GB/s effective → ~30 tok/s for a 1.6GB Q4 model, ~220 tok/s
for a 270M one. That's the ceiling; the Iris Xe iGPU shares the same RAM and
buys little. Want fast _and_ good locally? That's a GPU.

## Verifying

```sh
KEY=$(kubectl get secret litellm-secret -n default -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
# from inside the cluster (the litellm image has python, no curl):
kubectl exec -n default -c app deploy/litellm -- \
  env KEY="$KEY" python3 -c 'import json,os,urllib.request as u;
  r=u.Request("http://127.0.0.1:4000/v1/models",headers={"Authorization":"Bearer "+os.environ["KEY"]});
  print([m["id"] for m in json.loads(u.urlopen(r).read())["data"]])'
```

Raw model troubleshooting belongs on the ollama container:
`kubectl exec -n default -c ollama deploy/litellm -- ollama list`.
