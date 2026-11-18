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

- `infra/k8s/kyz/apps/default/forgejo` — chart `forgejo-helm` 17.3.2, Forgejo 15
  rootless, SQLite on a 10Gi `openebs-hostpath` PVC (`forgejo-data`).
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

Each step is reversible until step 6.

1. **Merge this, log in** at `https://git.waltr.tech` through Kanidm.
2. **Import the repo** (as `forgejo-admin` or yourself): _New migration → GitHub_,
   `https://github.com/rwaltr/home-ops`, **not** as a mirror, owner `rwaltr`.
   Re-point your clone: `git remote set-url origin https://git.waltr.tech/rwaltr/home-ops.git`
   (keep GitHub as a second remote, `github`, for break-glass).
3. **GitHub credential for the push mirror.** Use a deploy key, not a PAT: scoped to
   one repo, never expires, no human account.
   - _Settings → Mirror settings → Push mirror_: remote
     `git@github.com:rwaltr/home-ops.git`, **Use SSH authentication**, branch
     filter `master`, **Sync when commits are pushed**, interval `8h`.
   - Forgejo shows a public key; add it on GitHub as a deploy key **with write**.
4. **GitHub `master` accepts only the mirror.** Replace the PR-required branch
   protection with a ruleset on `master`: restrict updates, block force-push, and
   give the deploy key bypass. Without the bypass every mirror push is rejected.
5. **Forgejo branch protection on `master`:** require PR, 1 approval, dismiss stale
   approvals, require the `lint` status check (once the runner exists), no
   force-push. Forgejo's own push mirror is not affected by this rule.
6. **Bots move.** Per bot: `forgejo admin user create --username teletran --email
teletran@waltr.tech --random-password` (exec into the pod as the break-glass
   admin), then a token with `write:repository` + `write:issue` stored in 1Password
   and delivered by ExternalSecret. Hermes swaps the `gitcreds` sidecar for that
   static token and `gh` for `tea`/the API. Add the bot as a repo collaborator
   (write), **not** an admin, so branch protection still binds it.
7. **Close the GitHub side.** Archive open GitHub PRs (or re-open them on Forgejo),
   disable the GitHub `lint`/`meta-*` workflows, and point the README at Forgejo.

## Not done yet

- **Forgejo runner** (in-cluster, DinD) and `.forgejo/workflows/lint.yml` — the
  existing `lint.yml` should work as-is since `DEFAULT_ACTIONS_URL` is GitHub.
  Branch protection's required check waits on this.
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
