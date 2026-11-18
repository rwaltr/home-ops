# Forgejo

The forge where work happens. Bots and humans push branches, open PRs, review and
merge on `https://git.waltr.tech`. `master` is then **push-mirrored to GitHub**, and
Flux keeps reading GitHub exactly as it does today.

```
bot/human ──push/PR──▶ Forgejo (git.waltr.tech) ──review+lint──▶ merge to master
                                                                     │ push mirror (on commit)
                                                                     ▼
                                      Flux ◀──poll/webhook── github.com/rwaltr/home-ops
```

## Why this shape

- **GitHub stays the Flux source.** Forgejo runs in the cluster it deploys, so if
  Flux read from Forgejo a dead cluster could not rebuild itself. GitHub holds every
  merged commit, so a cold start needs nothing from the cluster.
- **Forgejo owns the workflow.** Bot accounts are plain users with tokens: no GitHub
  App, no hourly installation-token broker, no `[bot]` identity quirks.
- **Losing Forgejo loses PRs and review history, not code.** `master` is on GitHub;
  the PVC is backed up nightly by kopiur (`H 15`).

## Deployment

- `infra/k8s/kyz/apps/default/forgejo` — chart `forgejo-helm` 17.3.2 with the image pinned
  ahead of it to Forgejo **17.0.1** rootless (kritika needs 16+; see docs/kritika.md), SQLite on a 10Gi `openebs-hostpath` PVC (`forgejo-data`).
- Internal only: `envoy-internal`, no `envoy-external`, so no public DNS. HTTPS git
  only; the SSH server is off.
- Login is Kanidm (`oauth2client.yaml`). Accounts are auto-created on first login
  with the local part of the Kanidm mail address as the username (`rwaltr`), so
  every person account needs `mail` set — see docs/kanidm.md. Members of the Kanidm group `forgejo_admins`
  (`identity/resources/app/group-forgejo-admins.yaml`) are site admins.
- Break-glass admin: `forgejo-admin`, password generated into the `forgejo-admin`
  Secret on first install. Use it only for bot accounts and recovery.

```sh
kubectl -n default get secret forgejo-admin -o jsonpath='{.data.password}' | base64 -d
```

**First Kanidm login may fail once** with `No PKCE code challenge` in Kanidm's log:
the source is registered after the first request decided not to send PKCE. Retry.
A user who gets admin from the group may need to log out and back in once.

## Cutover (in order)

Done 2026-11-18 for home-ops, dotfiles, beancount-stack, rwaltpro, branding,
resume, naming-scheme and waltr-clan-branding: imported with issues/PRs/labels,
push mirror over an SSH deploy key (all branches + tags, sync on commit, 8h
interval), and — public repos only, the free plan has no private rulesets — two
GitHub rulesets (`forgejo-mirror-only-branches` / `-tags`) that only the deploy
key and repo admins bypass. GitHub Renovate and opencode workflows are disabled.

**Mirror semantics:** Forgejo pushes `--mirror --force`, so GitHub is an exact
copy. New commits go out on push; **branch deletions only go out at the 8h
interval** (or _Settings → Mirror → Synchronize now_). Anything written only to
GitHub is overwritten.

GitHub had **no** branch protection before the cutover, so nothing was replaced.

**State now:**

- Forgejo `master` on home-ops is protected. It requires a PR, the
  `Lint / mise run lint (pull_request)` check and 1 approval. Stale approvals
  are dismissed, and nobody may push directly. Site admins can still force a
  merge, which the API exposes as `force_merge`. The push mirror is not
  affected.
- Hermes still holds the `teletraan-x` GitHub App. The rulesets reject its
  GitHub pushes. It moves to a Forgejo bot account with a static token, as a
  write collaborator and **not** an admin, so branch protection binds it.
- The GitHub PRs from before the cutover were imported to Forgejo. Close the
  GitHub copies.

## Actions runner

`infra/k8s/kyz/apps/actions-runner/forgejo-runner` — one pod, `forgejo-runner`
13 plus a **privileged** `docker:dind` sidecar, alone in the `actions-runner`
namespace (PSA `privileged`) so nothing else shares the blast radius. Jobs run as
containers on that daemon and never see its socket.

- Labels: `ubuntu-latest` / `ubuntu-24.04` → `ghcr.io/catthehacker/ubuntu:act-24.04`,
  `docker` → `code.forgejo.org/oci/node:22-bookworm`. GitHub-style workflows run
  unchanged; `uses:` resolves on github.com.
- Registration is offline and global: uuid/token minted once with
  `POST /api/v1/admin/actions/runners` into 1Password item `forgejo-runner`
  (`uuid`, `token`). No register step, so restarts never duplicate the runner.
  To rotate: delete the runner in _Site administration → Actions → Runners_,
  register a new one, update the item.
- Workflows live in `.forgejo/workflows/`. Forgejo reads only that directory when
  it exists, so the `.github/workflows` jobs stay GitHub-only.
- The GitHub workflow can't be copied unchanged. On Forgejo, `github.token` and
  `GITHUB_TOKEN` hold a **Forgejo** job token, and tools that send it to
  github.com get a 401. That broke mise's attestation checks and zizmor's online
  audits. `lint.yml` passes no token to mise-action and unsets
  `GITHUB_TOKEN` for the lint step. `zizmor` rejects an empty value, so it has to
  be unset. `MISE_SKILLS_FETCH=false` stops the helmfile/pitchfork agent-skill
  downloads, and `uv` in `.mise.toml` replaces the image's old pipx.

## Not done yet

- **Renovate** as an in-cluster CronJob with `platform: forgejo` and its own bot
  account; retire `.github/workflows/renovate.yml` at the same time.
- **Flux webhook** is unchanged: GitHub still fires the push webhook when the mirror
  pushes, so reconciles stay immediate.

## Break-glass: cluster down, need a change

Push straight to GitHub `master` (`git push github master`, as an admin bypassing
the ruleset); Flux picks it up when the cluster returns. **Then reconcile Forgejo
before anything merges there**, or the next mirror push is non-fast-forward and
fails:

```sh
git fetch github && git push origin github/master:master
```
