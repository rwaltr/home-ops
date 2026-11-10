# LiteLLM gateway (cloud chat + audio)

One OpenAI-compatible endpoint for cloud models, self-hosted models and
speech: OpenRouter chat, Dan Manners' shared LiteLLM gateway (self-hosted
Qwen3-32B / Llama / gpt-oss), plus whisper / piper audio, with key auth, spend
tracking and model aliasing. Defined in `infra/k8s/kyz/apps/default/litellm/`.

|              |                                                                           |
| ------------ | ------------------------------------------------------------------------- |
| Proxy API    | `http://litellm.default.svc.cluster.local:4000/v1`                        |
| Admin UI     | `https://litellm.waltr.tech` (envoy-internal)                             |
| Speaches API | `http://litellm.default.svc.cluster.local:8000`                           |
| Master key   | 1Password item `litellm`, field `master_key` → `litellm-secret`           |
| Consumers    | hermes (`providers.litellm`), Home Assistant (native LiteLLM integration) |

## No local LLM (removed 2026-11-09)

The `ollama` sidecar served exactly one model, `qwen3-1.7b-nothink`, and it was
ripped out along with the sidecar, its `model-import` init container and the
`11434` service port. As a chat model it was fine (~41 tok/s, byte-stable at
`temperature=0`); it could not do the job the cluster actually had for it —
classify text. Measured on synthetic data (10 mock credentials + 7 decoys):

| Behaviour                           | Result                                                                   |
| ----------------------------------- | ------------------------------------------------------------------------ |
| JSON `{value}` extraction           | returned **variable names**, not values — 0/7 real secrets quoted        |
| Compact `<line>\|<type>\|<value>`   | 6/7 in a `.env`, but **3/9** in a 1.9k-token context, all from the head  |
| Line classifier (Yes/No + logprobs) | **F1 0.632** vs **0.875** for a 7-pattern regex                          |
| Confidence                          | `P=1.000` on `${API_TOKEN}`/`<REDACTED>`, `P=0.146` on a real `AKIA` key |
| "Rewrite with secrets replaced"     | echoed the input unchanged — 0 markers, credential leaked                |
| Line numbers in findings            | sequential (`1,2,3…`), not real line numbers                             |

Its probabilities were confidently wrong at the extremes, so no threshold fixed
it. `seed` is ignored, so there was no reproducible sampling knob either.

A local model belongs in its **own sidecar**, not bolted back onto this pod.
Cactus Needle 3 (Apache-2.0, 8–29 MB, 25–121M params) is the interesting one
for tool calls and structured extraction, but it ships as `needle3.cact` at
~2.125 bits/weight on the cactus-compute runtime — no GGUF, so ollama could
never have hosted it. Community OpenAI-compatible wrappers exist
(`sirmmo/needle-openai`, `kortexa-ai/needle.server`).

## Live models

| Model                 | Backend       | Notes                                                                     |
| --------------------- | ------------- | ------------------------------------------------------------------------- |
| `deepseek-v4.1-flash` | OpenRouter    | Cloud; key reused from `hermes-secret`.                                   |
| `nvidia-llama`        | Dan's gateway | Self-hosted **Qwen3-32B** (vLLM, nvfp4). 151k context. Best local pick.   |
| `intel-llama`         | Dan's gateway | Self-hosted Llama on Intel hardware. 229k context.                        |
| `gptoss-llama`        | Dan's gateway | Self-hosted `gpt-oss-20b-f16`. 114k context.                              |
| `qwen3.8-omni-flash`  | OpenRouter    | **Vision + audio + video.** Image/audio/video input. Companion's default. |
| `gpt-5.6-luna`        | OpenRouter    | **Vision.** Image input; no video (404s on a video part).                 |
| `whisper`             | speaches      | `audio_transcription` (faster-whisper small-int8).                        |
| `piper`               | speaches      | `audio_speech`. Pass `voice` through, e.g. `en_US-glados-medium`.         |

The two vision aliases exist for photo/video intake (homebox-companion and the
walkthrough-to-CSV route). Both read image barcodes well enough to be useful but
not perfectly: on a 49-frame test, each produced one ISBN-13 whose check digit
did **not** validate, while the same library read in a single native-video pass
validated 3/3. Validate the check digit before trusting a barcode, and prefer a
video pass to supply ISBNs — rationale and numbers in `REFACTOR_PLANS.md`.

## Dan Manners' gateway

A second LiteLLM proxy at `https://llm.cloud.danmanners.com/v1`, reached with
its own outbound key (1P item `llm.cloud.danmanners.com`, field `credential` →
`DANMANNERS_LLM_API_KEY` in `litellm-secret`; the pod picks it up via the
existing `envFrom`). It exposes ~28 models; only the three backed by hardware on
his network are aliased here — the rest of his catalog is cloud-backed and
proxying it would just be a second hop to OpenRouter/Z.ai.

**What it retains.** Prompt/response content is **not** stored —
`store_prompts_in_spend_logs` is unset (→ false), and spend-log rows come back
with `messages={}` / `response={}` / `proxy_server_request={}`. Metadata _is_
kept: `maximum_spend_logs_retention_period` is unset (→ no pruning), so the
model, token counts, cost, timing, hashed key, requester IP and user agent of
every request persist indefinitely. Daily aggregates currently span the
instance's whole life (2026-10-11 → now). The key we hold is admin-level — an
unfiltered `/spend/logs` returns global rows from other users, and
`/config/list` answers — so treat it as broad read on his proxy, not a scoped
virtual key.

Useful distinction when adding more: query
`GET /v1/model/info` with the key and read
`litellm_params.model` / `litellm_params.api_base`. Anything with an
`api_base` pointing at `*.aiml.svc.cluster.local` or a LAN IP is self-hosted;
an empty `api_base` with an `openrouter/...` or vendor `/...` model is cloud.
Names can lie — his `media-analysis`, `decision` and `embed-text` are cloud
(Google, OpenAI, OpenRouter), not local.

## Adding a model

**Cloud** — add to the `model_list` in the `litellm-config` ConfigMap:

```yaml
- model_name: <alias>
  litellm_params:
    model: openrouter/<vendor>/<model>
    api_key: os.environ/OPENROUTER_API_KEY
```

`stakater/reloader` watches this ConfigMap, so the pod rolls on its own. Outside
Git/Flux: `kubectl rollout restart deploy/litellm -n default`.

**Audio** — speaches already fronts whisper and piper; see its env for the
STT model and `STT_MODEL_TTL`.

**Local** — a new sidecar with its own runtime, a new `model_list` entry
pointing at it over pod localhost, and a note here about why. Do not reach for
ollama: whatever you pick has to be GGUF, which ruled out Needle above.

## Traps

- **Audio is duplicated.** The `wyoming-*` pods serve Home Assistant over the
  Wyoming TCP protocol, which LiteLLM cannot speak, and no OpenAI→Wyoming shim
  exists (`roryeckel/wyoming_openai` is the reverse direction). So speaches
  holds its own whisper + piper. That's bounded by `STT_MODEL_TTL=300` (whisper
  unloads after 5m idle). To de-duplicate, bridge HA at the wyoming_openai
  server and delete the `wyoming-*` pods.
- **First STT call downloads ~460MB** (Systran/faster-whisper-small) onto the
  models PVC. Expect a slow first request.
- **The litellm cap is tight.** The `app` container gets 1Gi with a 512Mi
  request. At 512Mi a burst of short chat requests OOMKilled it (30d p95 507Mi,
  peak 511Mi — ~1MiB under the limit) and a newer `main-stable` digest
  (`c169fb3`) OOMKilled it at startup. Re-check headroom before any digest bump;
  a bump alone can crashloop.
- Model weights are re-downloadable artifacts and are deliberately **not**
  kopia-backed. The `litellm-models` PVC now only holds the speaches HF cache.

## Decision scoring (SemIf-style)

LiteLLM passes logprobs through, so a first-token classifier works for any
backend that returns them — OpenRouter included, no local model required:

```sh
curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"…"}],
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

**The `qwen3-1.7b-nothink` conversation subentry was removed with the model.**
The `deepseek-v4.1-flash` subentry remains, and the `Glados` pipeline must point
at `conversation.deepseek_v4_1_flash` (or `conversation.home_assistant` for
local intents only) — it previously pointed at the qwen entity. Pipelines are
UI-only: Settings → Voice assistants.

STT/TTS for voice still come from the wyoming-\* pods; the LiteLLM integration
is conversation-only.

## Verifying

```sh
KEY=$(kubectl get secret litellm-secret -n default -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
# from inside the cluster (the litellm image has python, no curl):
kubectl exec -n default -c app deploy/litellm -- \
  env KEY="$KEY" python3 -c 'import json,os,urllib.request as u;
  r=u.Request("http://127.0.0.1:4000/v1/models",headers={"Authorization":"Bearer "+os.environ["KEY"]});
  print([m["id"] for m in json.loads(u.urlopen(r).read())["data"]])'
```

Expect `deepseek-v4.1-flash`, `nvidia-llama`, `intel-llama`, `gptoss-llama`,
`whisper`, `piper`.
