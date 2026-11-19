# OpenSpec

Planning artifacts for behaviour changes, kept next to the manifests they
describe. The manifests remain the implementation, `AGENTS.md` remains canonical
policy, `REFACTOR_PLANS.md` remains the decision log, and `docs/*.md` remains the
per-service runbook. Specs exist so a proposed change survives longer than the
chat session that proposed it.

## Layout

- `config.yaml` — project constraints and rules per artifact.
- `specs/<capability>/spec.md` — durable, testable requirements (scenarios).
- `changes/<change>/` — proposal, spec deltas, design, tasks for in-flight work.
- `changes/archive/` — completed changes, kept as history.

Seeded capabilities: `gitops-reconciliation`, `secrets-delivery`,
`agent-tool-boundary`, `service-exposure`, `pvc-backups`, `alert-routing`,
`host-provisioning`. Each is a baseline read off the existing manifests —
evidence for what the repo already does, not a new deployment and not proof of
live state. The _why_ behind them lives in `docs/adr/`.

## Workflow

Run from the repo root; the CLI comes from `.mise.toml`.

1. Read `AGENTS.md`, the relevant spec, and any `docs/` runbook.
2. `/skill:openspec-propose "<idea>"` — creates the change and its artifacts.
3. Review proposal, delta scenarios, design, and tasks before implementing.
4. `/skill:openspec-apply-change` in a **later** request to implement approved scope.
5. Validate (`openspec validate <change> --strict`), then archive with
   `/skill:openspec-archive-change`.

Useful checks:

```sh
openspec list --json
openspec list --specs --json
openspec show gitops-reconciliation --type spec
openspec validate --all --strict --no-interactive
```

`mise run lint` runs the validate above through `hk.pkl`.

A change with no spec delta yet fails that validate — intentional: a half-written
proposal should be visible. For a pure tooling/docs change, set `skip_specs: true`
in its `.openspec.yaml`.

`openspec update` regenerates `.agents/skills/openspec-*` with curly quotes, which
the pre-commit hook rejects — run `mise run fmt` after regenerating. markdownlint
skips those files via `.markdownlint-cli2.yaml`.

Passing validation means the artifacts are well-formed. It does not mean a
manifest renders or a rollout succeeded — say which of the two you actually ran.

## Adding a capability

Add one when the next real change needs it, not one per app or per namespace.
Trace the source and its consumers, write observable scenarios, cite evidence paths, and
state the verification limits. Keep service runbooks in `docs/`.
