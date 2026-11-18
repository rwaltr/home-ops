# PR review

How a pull request in this repo gets reviewed, and what makes one ready for rwaltr to
merge. The reviewer is an agent, and this file is its procedure — the point of writing
it down is that the bar stops depending on who is reviewing and on how the diff happens
to read.

## Who reviews

- **The author never reviews their own PR.** A review is performed by a separate agent
  instance with a fresh context, given the diff, konflate's rendered output, and this
  file. Self-review is how a plausible-but-wrong change gets a green light, because the
  reasoning that produced the change is the reasoning checking it.
- **rwaltr is the only approver.** A completed review makes a PR _ready for him_; it
  never makes it merged. Flux reconciles on merge, so the last step is his.

## What the reviewer works from

- **konflate** — deployed in-cluster (`infra/k8s/kyz/apps/flux-system/konflate`) against
  `github://rwaltr/home-ops`, with `prComments`, `statusChecks`, `verifyImages` and its
  MCP server enabled. It renders Helm charts and Kustomizations into their final
  Kubernetes manifests, so **its diff is the cluster impact; the git diff is not.** A
  one-line `values` change can fan out across dozens of resources, and a version bump
  can rewrite a whole manifest.
- **The repo's own lint surface** — `mise run lint` (wraps `hk check --all`: yamllint,
  markdownlint, oxfmt, typos, gitleaks, trivy) plus `.github/workflows/lint.yml`. Run it
  before pushing; a review that finds what lint would have found wasted a cycle.
- **`AGENTS.md`** — the hard rules. They are not suggestions and a review does not need
  to restate them; it needs to catch their violation.
- **`REFACTOR_PLANS.md`** — the decision log. Read it before flagging a pattern as a
  concern, because the answer is frequently already recorded there.

## Evidence rules

- **A version bump needs upstream evidence.** For a chart or image change, read the
  release notes, the changelog, the source diff between the two tags, or the image
  metadata. Renovate's description is a lead, not evidence, and a green status check is
  not a review.
- **Unavailable evidence is reported as unverified, never as clean.** "I could not check
  X" is a finding. It is never a pass.
- **Never invent a result.** No tool output, no upstream note, and no compatibility claim
  that was not actually read.
- **Version floors are stated as floors.** "Needs >= X" is an answer; "supported" is not,
  unless the release notes for the pinned version say so.
- **Pins, not `latest`** — for charts and images alike.

## Severity

**Blocker — fix before this is ready.**

- A secret, token, key or password anywhere in the diff, or a value that belongs in
  1Password committed instead. See `docs/secrets.md`.
- A rendered change that destroys or immobilises state: a PVC or StorageClass deletion,
  an immutable field on a live CRD, a StatefulSet volume change.
- A render failure. If the manifests do not render, they may not apply.
- A host or Flatcar change that was not exercised in a VM first
  (`mise run flatcar:bootstrap <host>`). Never on the live host.
- A workload change made outside git — no `kubectl apply`, no imperative edits.
- A dependency bump with no upstream evidence, or an evidence source that came back
  unavailable and was reported as clean.

**Caveat — answer it in the PR body; it does not have to be fixed.**

- A widened RBAC scope, a new egress path, a new public hostname.
- Resource requests or limits that look optimistic for what the workload does.
- A same-tag digest refresh with missing OCI revision/source labels.
- An alert that will fire until something else lands, or a silence that expires before
  the work finishes.

**Note — context, no action.**

## What every PR must carry

- **The doc update.** Every infra change carries its `docs/` update — `AGENTS.md` rule 8.
  A change with no doc line is incomplete, not merely undocumented.
- **A body that says what changed, why, and what would make it wrong.** The third part is
  the one that is usually missing and the one that makes a review cheap.
- **The verification actually performed, with its output.** The command and what it
  returned — not "verified". A claim of verification is not verification.
- **Nothing else.** Unrelated reformatting, drive-by fixes and generated noise belong in
  their own PR.

## Reading konflate

- **Its cautions are advisory by design — it is not a gate.** They are handled in the
  same branch before the PR is ready; precedent is PR #870, where both cautions were
  answered in the branch rather than deferred.
- **Render failures are blockers.** Cautions map to the severity list above by what they
  would do to the cluster, not by how they are phrased.
- **If a PR is not tracked by konflate, the rendered evidence is Unknown — not clean.**
  Say which one you could not see.
- **Do not treat a green status check as a review.** It means the pipeline ran.

## The review output

One comment, in this order:

1. **Verdict** — ready, ready with caveats, or not ready. One line.
2. **Findings**, grouped by severity, each with the evidence that produced it: the
   command and its output, or the file and line. A finding without evidence is an
   opinion, and opinions belong in a chat message.
3. **What was not verified**, and why — an auth wall, a missing upstream note, a PR
   konflate is not tracking.

If nothing is wrong, say so in one line and stop. Manufacturing findings to look
thorough is the failure mode this document exists to prevent.

## Not in scope

- Style and formatting. Lint owns that.
- Re-litigating a decision already recorded in `REFACTOR_PLANS.md`. If the decision looks
  wrong, that is a new PR with its own argument, not a review comment.
- Flagging a documented, deliberate pattern as a concern. If the repo does it on purpose
  and wrote down why, it is not a finding.
