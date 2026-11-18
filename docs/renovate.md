# Renovate

Renovate runs in the cluster against `git.waltr.tech`, using
[renovate-operator](https://github.com/mogenius/renovate-operator) (mogenius),
the same setup bjw-s uses. It's defined in
`infra/k8s/kyz/apps/renovate/renovate-operator/`: `app/` is the operator,
`jobs/` is the RenovateJob and its secrets. The GitHub Actions workflow is
gone.

|            |                                                                      |
| ---------- | -------------------------------------------------------------------- |
| UI         | `https://renovate.waltr.tech` (envoy-internal), Kanidm sign-in       |
| UI admins  | Kanidm group `renovate_admins` (trigger and cancel runs)             |
| Forge user | `renovate`: repo **write** collaborator, not admin                   |
| Schedule   | hourly, plus webhook-triggered runs from dashboard/PR checkboxes     |
| Config     | `.renovaterc.json5` and `.renovate/*.json` in each repo              |
| Secrets    | 1Password `renovate` (Forgejo token), `teletraan-x github app` (PEM) |

## Credentials

- **`RENOVATE_TOKEN`**: an access token for the Forgejo user `renovate`. Its
  scopes are `write:repository`, `write:issue`, `read:user` and
  `read:organization`. It was minted once with
  `forgejo admin user generate-access-token -u renovate` straight into
  1Password item `renovate`. To rotate, mint a new token, update the item,
  then delete the old token under the user's settings.
- **`RENOVATE_GITHUB_COM_TOKEN`**: for github.com lookups (release notes,
  `github-releases`/`github-tags`). Without it, Renovate is limited to 60
  anonymous requests an hour. This is not a PAT. External Secrets'
  `GithubAccessToken` generator mints a **read-only** installation token from
  the existing `teletraan-x` GitHub App every 45 minutes, and each token
  lasts an hour. The app's PEM is stored in 1Password on one line with spaces
  instead of newlines, so `teletraan-x-app-key` puts the line breaks back.

`git.waltr.tech` resolves to an internal address. Renovate refuses those
unless told otherwise, so the job sets
`RENOVATE_HOST_RULES` to `allowInternal: true` for that host only.

## Automerge and branch protection

`master` requires a PR, a passing `Lint / mise run lint (pull_request)` check
and one approval, and nobody can push to it directly. Renovate's old
**branch** automerge pushed straight to the base branch, so it can't work
here. Instead:

1. Renovate opens the PR. Where a `.renovate/autoMerge.json` rule matches,
   it asks Forgejo to merge once checks pass (`platformAutomerge`).
2. Lint runs on the in-cluster runner.
3. kritika reviews. It approves **only** PRs opened by `renovate`
   (`review.approve.when` in kritika's HelmRelease, which a repo's
   `.kritika.yaml` can't widen), and only when it finds nothing at P0 or P1.
4. Forgejo merges once lint passes and the approval lands.

PRs that don't match an automerge rule, and every PR from anyone else, wait
for you. A later kritika review that finds a problem withdraws its approval,
and a new push dismisses stale approvals.

## Webhooks

The operator adds its own webhook to every discovered repo
(`webhook.sync.enabled`). That webhook points at
`https://renovate.waltr.tech/webhook/v1/forgejo`, so ticking a Dependency
Dashboard or "rebase" checkbox starts a run right away. The webhook is served
on the UI hostname (`unifiedWebhookHost`) and skips UI auth. It only acts on
events that carry Renovate's own markers. Forgejo may send webhooks there
because of `webhook.ALLOWED_HOST_LIST` in the Forgejo HelmRelease.

## Policy

The operator's policy engine is **on**. A RenovateJob can only target
`git.waltr.tech` (plus the operator's own webhook host) and can only run the
`ghcr.io/renovatebot/renovate` image. That stops anyone who can edit a
RenovateJob from aiming Renovate, and its token, somewhere else.
