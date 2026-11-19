# Forgejo is authoritative; Flux reads the GitHub mirror

Status: accepted (2026-11-17)

Work happens on Forgejo (`git.waltr.tech`), which runs inside the cluster. `master` is
push-mirrored to `github.com/rwaltr/home-ops`, and Flux syncs from GitHub. Reading
from Forgejo would make the cluster depend on itself: a dead cluster could not rebuild,
because its manifest source would be one of the things that is down. Forgejo owns
review and bots (plain users with tokens, no GitHub App broker).

## Consequences

- A merged change is not live until the mirror has pushed it; check the GitHub
  revision before treating a missing rollout as a manifest bug.
- Losing Forgejo loses PRs and review history, not code.

Contract: `openspec/specs/gitops-reconciliation`. Runbook: `docs/forgejo.md`.
