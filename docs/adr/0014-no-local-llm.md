# No local LLM in the gateway

Status: accepted (2026-11-09)

The LLM gateway fronts cloud and shared models only. The ollama sidecar that once ran
inside LiteLLM, and its single model (`qwen3-1.7b-nothink`), were removed. The
cluster's real job for a local model was classification, and that model failed it on
measurement: F1 0.632 against 0.875 for a seven-pattern regex, confident at the wrong
extremes, and it echoed credentials back when asked to redact them. No threshold fixed
it and there was no reproducible sampling knob.

## Consequences

- A future local model gets its own workload, not a slot inside the gateway.
  agentgateway replaced LiteLLM as the gateway on 2026-11-18 (`docs/agentgateway.md`).
- Anything that needs pattern detection uses deterministic tools first.
- `docs/local-llm.md`, which held the full measurement table, was deleted with
  LiteLLM. The numbers above are the surviving record; the table itself is in git
  history.
