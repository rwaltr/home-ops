# Hermes Agent — remote operations from a phone

**Status:** draft plan (2026-09-25). Not yet implemented.
**Goal:** let the in-cluster Hermes Agent do the work we normally do in a pi
session (GitOps edits, cluster debugging, docs, PRs) and let rwaltr drive it
from a phone, instead of having to be at the computer.

## Current state (as deployed)

`apps/default/hermes` — `nousresearch/hermes-agent` v2026.9.21, 10Gi PVC on
`openebs-hostpath` mounted at `/opt/data`.

- Gateway + dashboard (`hermes.waltr.tech`, **envoy-internal only**) + OpenAI
  API on `8642`. Dashboard requires basic auth (`hermes-secret`).
- Toolsets: `terminal, file, web` for `cli` and `api_server` **only**.
- `tools` init container installs `mise`, `uv`, `gh`, `go`, `homebrew` into
  `/opt/data/.local` (persisted, guarded).
- Config is re-seeded from the `hermes-config` ConfigMap on every pod start;
  `stakater/reloader` rolls the pod when the ConfigMap or `hermes-secret`
  changes.
- No messaging platform is configured; the gateway currently serves only the
  dashboard/API.

### What pi does here that Hermes cannot (yet)

Repo edits → Flux GitOps (`ks.yaml`, HelmRelease, ExternalSecret), `kubectl`
debugging, `mise run` tasks, docs, conventional commits and
PRs, o11y dashboards, Flatcar/Butane work validated in a VM.

| Capability                          | Hermes today                      |
| ----------------------------------- | --------------------------------- |
| `rwaltr/home-ops` checkout          | ❌ (only a scratch workspace dir) |
| `kubectl`/`flux`/`helm`/`jq`        | ❌                                |
| `git`/`go`/`mise`/`uv`/`gh`         | ✅ (gh **not authenticated**)     |
| Cluster credentials                 | ❌ SA token not mounted           |
| Secret material (SOPS/1P)           | 🚫 out of scope — rwaltr manages  |
| Phone channel                       | ❌ none configured                |
| Secrets to decrypt SOPS / 1Password | ❌                                |

## Decisions (2026-09-25)

1. **Phone channel: Discord.** rwaltr already uses Discord; the adapter uses
   `discord.py`'s gateway (outbound websocket), so it needs **no public
   ingress** and works behind CGNAT. SMS (Twilio, needs an inbound webhook) and
   email (IMAP poll) are deferred as optional async channels.
2. **Push identity: reuse the existing GitHub App `teletran-x`**, not rwaltr's
   account. The app is already wired for CI (`BOT_APP_ID`/`BOT_APP_PRIVATE_KEY`
   secrets) and its private key lives in 1Password item `github-bot` (used by
   `konflate` as `GITHUB_BOT_APP_CLIENT_ID`/`GITHUB_BOT_APP_PRIVATE_KEY`).
3. **Name: Teletran.** The agent adopts the Autobot supercomputer identity —
   Discord application/bot display name, `SOUL.md` persona, dashboard title.
   The G1 archetype (loyal, watchful, dryly put-upon, precise) seeds the soul.
4. **No secret handling.** Teletran never decrypts, edits, or commits secret
   material, and does not use SOPS/age. 1Password and ExternalSecrets remain
   rwaltr's to manage; if a change needs a secret, it stops and asks.
5. **Cluster access: direct is allowed**, but the PR loop must stay tight
   (see below). Start read-only; add scoped writes only if it earns them.
6. **Autonomy: approve destructive commands.** Reads and builds run freely;
   destructive/irreversible ops require an explicit in-chat approval.
7. **Exposure: Tailscale is the intended answer but not yet established.**
   Discord needs none, so external reachability is not on the critical path.
   The Tailscale operator (`envoy.yaml` already references it as future) stays
   the eventual path for the dashboard/other clients.

## GitHub App: `teletran-x` (the open engineering question)

Hermes has **no native GitHub App support**, and GitHub App installation tokens
**expire after one hour**. So the app cannot be dropped in as a static
`GH_TOKEN`. The app identity must be brokered:

- Known-good inputs already exist: 1Password item **`github-bot`** holds
  `GITHUB_BOT_APP_CLIENT_ID` and `GITHUB_BOT_APP_PRIVATE_KEY`.
- Needed additionally: the **numeric App ID** and the **installation ID** for
  `rwaltr/home-ops` (resolvable from the API once App ID + key are available).
- **Approach A (preferred): token-broker sidecar.** A tiny container mints a
  JWT from the App ID + private key, exchanges it for an installation token
  every ~45 min, and writes it to `gh`'s `hosts.yml` / a git credential store on
  the shared `/opt/data`. `gh` and `git` then act as `teletran-x`; secrets stay
  out of the agent's own environment. One new container, no new service.
- Approach B: on-demand git/gh credential helper (no sidecar, but secrets in
  the app container env and added latency/caching complexity).
- Approach C: a fine-grained PAT scoped to `rwaltr/home-ops` (simplest, but
  abandons the app identity the user asked for).

Branch protection does the heavy lifting regardless: the app/bot cannot approve
or merge its own PR.

## The tight PR loop

This is the safety spine — Hermes gets real write access, so the gate must be
structural, not prompt-based.

- **Branch protection on `master`:** require a PR, require the `lint` check
  (`.github/workflows/lint.yml` runs `mise run lint`), require 1 approving
  review, dismiss stale reviews, no force-push, no direct pushes.
- **The bot cannot approve or self-merge.** Branch protection enforces this
  regardless of the token it holds.
- **Flow:** `git switch -c hermes/<slug>` → edit → `mise run lint:all` →
  conventional commit → `gh pr create` with a body that states what changed,
  what was verified, and what is left → stop. rwaltr reviews and merges; Flux
  reconciles `master` as usual.
- **Every infra change carries its doc update** (this repo's convention:
  `REFACTOR_PLANS.md` and/or `docs/`), so the history explains itself.
- **Direct cluster writes are not the deploy path.** `kubectl` is for
  observation (get/logs/events) and debugging; changes land via PR → merge →
  Flux. If a scoped write role is ever added, it is explicit and reviewed.

## Phases

### Phase 1 — Discord channel (fast, reversible)

Discord requirements (developer portal):

- Application/bot display name **Teletran**; bot token (copy once).
- Privileged intent **Message Content** ON. Server Members stays **off** — the
  adapter only requests it for `DISCORD_ALLOWED_ROLES`, and we allowlist by
  user ID.
- Invite scopes `bot` + `applications.commands`; permissions: View Channels,
  Send Messages, Send Messages in Threads, Read Message History, Embed Links,
  Attach Files, Add Reactions. A shared server is required for DMs to work.
- rwaltr's user ID (Developer Mode → Copy User ID) as the allowlist entry, and
  a home channel ID for cron/notifications.

Wiring:

1. 1Password item `hermes`: `discord_bot_token`, `discord_allowed_users`,
   `discord_home_channel`, `discord_home_channel_name`.
2. `externalsecret.yaml`: map them to `DISCORD_BOT_TOKEN`,
   `DISCORD_ALLOWED_USERS`, `DISCORD_HOME_CHANNEL`, `DISCORD_HOME_CHANNEL_NAME`.
3. `helmrelease.yaml` config: add an explicit
   `platform_toolsets.discord: [terminal, file, web]`.
   **Gotcha:** a platform with no `platform_toolsets` entry falls back to the
   full ~50-schema preset — always list it explicitly.
4. Seed a `SOUL.md` naming the agent Teletran. It currently lives only on the
   PVC; move it into the `hermes-config` ConfigMap and have the config init
   container install it alongside `config.yaml` so it is git-tracked.
5. PR → merge → reloader rolls the pod. Verify `hermes gateway status` shows
   Discord connected and send a test message from the phone.

### Phase 2 — Repo + toolchain

1. **Toolchain for free:** clone `rwaltr/home-ops` and run `mise install` in
   it — the repo's `.mise.toml` pins `kubectl`, `flux`, `helm`,
   `kustomize`, `terraform`, `pre-commit`, and the linters. (Teletran does
   not use the `sops`/`age` entries — see the no-secret-handling decision.)
2. Clone to `/opt/data/workspace/home-ops` (persisted on the PVC); set git
   identity to the bot; point `terminal.cwd` at the repo; register a project.
3. `gh` auth: inject `GH_TOKEN` from 1P via ESO so push/PR work.
4. Ship repo conventions to the agent: Hermes loads `AGENTS.md` from the CWD,
   and `REFACTOR_PLANS.md` is the map — no extra wiring needed.

### Phase 3 — Cluster access (read-first)

1. Create ServiceAccount `hermes` + a `view` binding in `default` and
   `kube-system`; mount a kubeconfig/token (the pod currently has
   `automountServiceAccountToken: false`, so this is a deliberate change).
2. `kubectl` (from mise) then works in-cluster for get/logs/events/exec.
3. No `cluster-admin`, no `kubectl apply` in the default flow.

### Phase 4 — Safety rails

- Branch protection (above), plus Hermes' own `approvals` command allowlist and
  hooks for destructive commands.
- Evaluate `hermes egress` (iron-proxy credential injection) so secrets never
  sit in the agent's environment.
- Explicit rule: never touch the live host directly; Flatcar/infra changes are
  validated in a VM with `mise run flatcar:bootstrap <host>` first.

### Phase 5 — Capabilities

- Enable `memory`, `session_search`, `todo`, `skills`, `delegation`,
  `homeassistant`, `cronjob` as useful.
- Add MCP servers (`github`, `kubernetes`) via `hermes mcp`.
- Author a home-ops skill capturing the lint/PR/PR-loop conventions.
- Keep tool schemas lean — prompt cost is a real constraint here (the 26k-turn
  finding from the original Hermes setup).

### Phase 6 — Exposure (later)

- Tailscale operator + tailnet access for the dashboard (the "clients-tier
  trust" already sketched in `REFACTOR_PLANS.md`), or a Cloudflare Access route
  on `envoy-external`. Discord needs none of this.

## Risks / open items

- **SOPS/1Password: resolved — out of scope.** Teletran does not hold an age
  key and never touches secret material; secrets stay human-managed via
  1Password and ExternalSecrets. This removes the highest-risk grant.
- **GitHub App details needed:** numeric App ID + installation ID for
  `rwaltr/home-ops`; confirm the app already has Contents/Pull requests
  read-write (and Workflows write if it edits `.github/workflows`).
- **In-cluster `kubectl` via SA** changes `automountServiceAccountToken`; review
  the RBAC diff before merge.
- **Prompt budget** grows with every toolset; measure `hermes prompt-size`
  after each phase.
- **Two write paths exist** (git and `kubectl`). The policy is git-only for
  changes; keep it explicit so the agent does not drift into imperative fixes.

## Gotchas captured while planning

- `platform_toolsets.<platform>` is required per platform or the full preset
  loads.
- Config is a ConfigMap re-seeded each start; reloader handles rollouts, so no
  manual pod cycles.
- The HelmRelease already carries
  `kustomize.toolkit.fluxcd.io/substitute: disabled` (protects the `${GH}`/
  `${GO}` init-container shell).
- `automountServiceAccountToken: false` today — any cluster access is a
  conscious change.
- Repo `.mise.toml` is the toolchain source of truth; `mise install` beats
  hand-pinned binaries.
