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
- Config is seeded from the `hermes-config` ConfigMap on every pod start, and
  is _also_ mounted read-only at `/etc/hermes-policy` as Hermes' **managed
  scope** (2026-10-08) — see below. `stakater/reloader` rolls the pod when the
  ConfigMap or `hermes-secret` changes.
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

## Managed scope: policy pinned by git (2026-10-08)

The `hermes-config` ConfigMap is mounted **read-only** into the `app` container
at `/etc/hermes-policy`, and `HERMES_MANAGED_DIR` names it. Hermes deep-merges
that layer on top of `$HERMES_HOME/config.yaml` on every config load, leaf by
leaf: keys the ConfigMap sets win, everything else stays agent-owned.
Reference: <https://hermes-agent.nousresearch.com/docs/user-guide/managed-scope>.

**Why.** The `config` init container `install`ed the ConfigMap over
`/opt/data/config.yaml` on every start. That file is also the agent's own
mutable state, so each restart discarded what the agent had accumulated —
`_config_version`, `command_allowlist`, `onboarding.seen`. Command approvals
had to be re-taught after every pod roll. Under managed scope the pinned keys
come from git on every load, and the PVC copy is no longer overwritten for
them.

**Design notes.**

- **Path is not `/etc/hermes`.** That directory holds the image-baked
  `image-provenance.json`; mounting a volume there would hide it and flip the
  runtime out of image-managed mode. A dedicated directory keeps both.
- **Failure mode is fail-open.** A missing directory, a missing file, or
  malformed YAML resolves to "no managed scope" and the agent starts on
  `$HERMES_HOME/config.yaml` exactly as before. That is what makes this safe to
  roll onto a running agent.
- **Verified as a no-op before merge.** Resolving the config with and without
  the live ConfigMap as a managed layer produced identical values across all
  933 resolved keys.
- **Managed keys are immutable at runtime.** `hermes config set` refuses them
  and names the source. Pin policy only (model, toolsets, terminal, display,
  web) and leave tunables unpinned.
- **This is not `HERMES_MANAGED`.** That is a separate, coarser
  package-manager lock that blocks all config mutation; setting it would break
  the agent.

## Second agent: the household (`hermes-ha`) — 2026-10-08

A separate Hermes instance whose only reach is Home Assistant. It exists
because of blast radius, not tidiness: before this, one identity held repo
write access, cluster read access, and device control — including locks,
alarms, and power. A single misread message or injected instruction could
reach any of them. `hermes-ha` holds device control and nothing else.

**What it deliberately lacks.** No `gitcreds` sidecar, no git-broker, no repo
checkout, no `gh`, no kubeconfig, no ServiceAccount, no RBAC, no toolchain init
container. Its container cannot run commands at all — `terminal`, `file`, and
`delegation` are absent from its toolset list, and that list is the access
control: an unlisted platform falls back to the full ~50-schema preset, so
`platform_toolsets.discord` is always enumerated and is pinned read-only by
managed scope.

**Ordering matters.** The operator agent keeps the `homeassistant` toolset
until `hermes-ha` is live and answering. Dropping it first would remove device
control before its replacement exists. Step 2, after this lands and the bot
replies, is removing `homeassistant` from `hermes`'s toolset list.

**Owner step before it can start.** A second Discord application, because two
gateway processes cannot share one bot token. Create the application, add the
bot to the server, and store the token in 1Password as item `discordbot-ha`
with fields `token` and `rwaltruserid`. Until that item exists the
`hermes-ha` ExternalSecret reports `SecretSyncedError`, the pod sits in `Init`,
and nothing else is wrong — kubelet retries the mount in place, so the pod
starts on its own once the item appears. No reconcile or restart is needed.

**Persona.** `SOUL.md` names it Hearth, provisionally — one line to change. Its
hard rules mirror the operator agent's: report state before acting, confirm
before locks/alarms/power, and refuse anything needing a terminal or repo
access as a handoff to Teletran.

## Decisions (2026-09-25)

1. **Phone channel: Discord.** rwaltr already uses Discord; the adapter uses
   `discord.py`'s gateway (outbound websocket), so it needs **no public
   ingress** and works behind CGNAT. SMS (Twilio, needs an inbound webhook) and
   email (IMAP poll) are deferred as optional async channels.
2. **Push identity: reuse the existing GitHub App `teletraan-x`**, not rwaltr's
   account. The app is wired for CI (`BOT_APP_ID`/`BOT_APP_PRIVATE_KEY`
   secrets); its client ID and private key live in 1Password item
   `teletraan-x github app` (fields `client` / `secret`).
3. **Name: Teletran.** The agent adopts the Autobot supercomputer identity —
   Discord application/bot display name, `SOUL.md` persona, dashboard title.
   The G1 archetype (loyal, watchful, dryly put-upon, precise) seeds the soul.
4. **No secret handling.** Teletran never decrypts, edits, or commits secret
   material, and does not use SOPS/age. 1Password and ExternalSecrets remain
   rwaltr's to manage; if a change needs a secret, it stops and asks.
5. **Cluster access: direct is allowed**, but the PR loop must stay tight
   (see below). Read-only by default; scoped writes only if earned. One has been
   earned: `delete` on pods (2026-10-04) so a restart does not need a human. See
   the RBAC note below — the grant is a restart lever, not a configuration path.
6. **Autonomy: approve destructive commands.** Reads and builds run freely;
   destructive/irreversible ops require an explicit in-chat approval.
7. **Exposure: Tailscale is the intended answer but not yet established.**
   Discord needs none, so external reachability is not on the critical path.
   The Tailscale operator (`envoy.yaml` already references it as future) stays
   the eventual path for the dashboard/other clients.

## GitHub App: `teletraan-x` (brokered by the `gitcreds` sidecar)

Hermes has **no native GitHub App support**, and GitHub App installation tokens
**expire after one hour**. So the app cannot be dropped in as a static
`GH_TOKEN`. The app identity must be brokered:

- Credentials: 1Password item **`teletraan-x github app`** (`client`, `secret`).
  The client ID is a valid JWT issuer (GitHub recommends it over the numeric
  App ID); the broker resolves the installation ID from the repo at runtime.
- **Approach A (preferred): token-broker sidecar.** A tiny container mints a
  JWT from the App ID + private key, exchanges it for an installation token
  every ~45 min, and writes it to `gh`'s `hosts.yml` / a git credential store on
  the shared `/opt/data`. `gh` and `git` then act as `teletraan-x`; secrets stay
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

## Cluster RBAC (read-only)

All grants live in `infra/k8s/kyz/apps/default/hermes/app/rbac.yaml` and use
`get`/`list`/`watch` only — no verb outside the read set exists anywhere in the
file.

| Role                  | Covers                                                                                                                 |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `view` (ClusterRole)  | stock namespaced reads                                                                                                 |
| `hermes-pod-logs`     | `pods/log` (the `view` role omits it; logs are the main debugging surface)                                             |
| `hermes-cluster-read` | `nodes`, `persistentvolumes`, `namespaces`, `storageclasses`, `volumeattachments`, `scheduling.k8s.io/priorityclasses` |
| `hermes-crd-read`     | Cilium, Gateway API, `storage.k8s.io`, `coordination.k8s.io/leases`, kopiur                                            |

The `priorityclasses` rule is the newest addition. A pod spec proves only that
a `PriorityClass` _name_ resolved at admission; it cannot prove that the class
carries the intended `value`, `preemptionPolicy` or `globalDefault`. Reading
the object is the only way to check that after the fact, which matters for the
`unmanic-background` class (`value: -100`, `preemptionPolicy: Never`). One
cluster-scoped resource in `scheduling.k8s.io`, read-only.

The kopiur rule follows the same principle — it exists to reach evidence that
does not survive elsewhere. Backups are the one thing in this
cluster where a silent failure costs data rather than uptime, and the failure
evidence does not survive on its own: the mover Job and its pod are TTL'd away
within minutes, so by the time a `KubeJobFailed` is triaged there is nothing left
to read except the `Snapshot`/`SnapshotPolicy` status. The rule grants read on
exactly nine resources in `kopiur.home-operations.com` — `clusterrepositories`
(cluster-scoped) plus the eight namespaced kinds — and nothing else in the group.
`pods/log` already covers the mover pod while it is alive.

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

1. 1Password item `discordbot` already holds `token` and `rwaltruserid`;
   `externalsecret.yaml` reads them and maps to `DISCORD_BOT_TOKEN` and
   `DISCORD_ALLOWED_USERS`. (A home channel for cron/notification delivery,
   `DISCORD_HOME_CHANNEL`, can be added later once a channel is chosen.)
2. `helmrelease.yaml` config: add an explicit
   `platform_toolsets.discord: [terminal, file, web]`.
   **Gotcha:** a platform with no `platform_toolsets` entry falls back to the
   full ~50-schema preset — always list it explicitly.
3. Seed a `SOUL.md` naming the agent Teletran. It currently lives only on the
   PVC; move it into the `hermes-config` ConfigMap and have the config init
   container install it alongside `config.yaml` so it is git-tracked.
4. PR → merge → reloader rolls the pod. Verify `hermes gateway status` shows
   Discord connected and send a test message from the phone.

### Phase 1.5 — Home Assistant control

Give Teletran the `homeassistant` toolset so it can read and act on the smart
home from Discord ("turn off the office lights", "is the dryer still
running?", "what's the bedroom temperature?").

- Credentials: `HASS_URL=http://home-assistant.default.svc.cluster.local:8123`
  (plain env) and `HASS_TOKEN` from 1P item `home-assistant-secret`
  (`prometheus_token` — the long-lived token Prometheus already scrapes with).
- Tools: `ha_list_entities`, `ha_get_state`, `ha_list_services`,
  `ha_call_service`. Dangerous domains (`shell_command`, `python_script`,
  `hassio`, `rest_command`, ...) are hard-blocked inside the tool.
- Added to `platform_toolsets` for discord/cli/api_server.

Deliberately **not** enabled yet:

- The HA **platform** adapter (state-change events → agent, replies as
  persistent notifications). It is closed by default and needs an explicit
  `watch_domains`/`watch_entities` allowlist; useful if Teletran should
  _react_ to the house (dryer finished, door opened) rather than only answer.
- Routing HA **Assist** conversations to Teletran's OpenAI-compatible API, so
  voice/text in the Home Assistant app reaches the agent.

### Phase 2 — Repo + toolchain

Implemented with three pieces in the Hermes pod:

1. **`gitcreds` sidecar** — mints a `teletraan-x` GitHub **App installation
   token** (JWT from the client ID + private key in 1P item
   `teletraan-x github app`),
   resolves the repo's installation, and writes `gh`'s `hosts.yml` plus a git
   credential store. Refreshes every 40 min (installation tokens expire hourly).
   No static PAT, no long-lived token in the pod spec.
2. **`repo` init** — clones `rwaltr/home-ops` to `/opt/data/workspace/home-ops`
   (persisted) before the app starts; non-fatal, so a GitHub hiccup cannot block
   the pod. `terminal.cwd` points at the checkout.
3. **Toolchain** — the sidecar runs `mise install` once in the checkout, which
   pulls the repo's pinned `kubectl`, `flux`, `helm`, `kustomize`, `terraform`,
   `pre-commit`, and linters. (Teletran does not use the `sops`/`age` entries.)

Hermes loads `AGENTS.md` from the working directory and `REFACTOR_PLANS.md` is
the map, so conventions come for free. The App needs Contents/Pull
requests read-write (and Workflows write to touch `.github/workflows`).

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
- **RBAC is read-only except for one operational verb.** Every grant is
  `get`/`list`/`watch` except `delete` on `pods` (`hermes-pod-restart`,
  2026-10-04). That grant exists so Teletran can restart a workload itself rather
  than asking rwaltr to type `kubectl` for something mechanical. A restart is not
  a configuration change — the owning controller recreates the pod, PVCs and
  Secrets are untouched, and desired state is unchanged. It is deliberately
  pods-only: it does not extend to workload objects, replica counts,
  `deletecollection`, or `pods/exec`. Cluster-scoped roles are enumerated above
  so a bulk widening (e.g. adding a whole API group) is visible in the diff
  rather than hidden behind a wildcard.
- **Prompt budget** grows with every toolset; measure `hermes prompt-size`
  after each phase.
- **Two write paths exist** (git and `kubectl`). The policy is git-only for
  changes; keep it explicit so the agent does not drift into imperative fixes.
  Deleting a pod is the one exception, and only because it changes no desired
  state — it is a restart, not an edit.

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
- RBAC grants apply immediately to a running pod: the API server authorises every
  request against the live ClusterRole/Binding, so no restart or token re-issue
  is needed after Flux applies a new grant.
- Repo `.mise.toml` is the toolchain source of truth; `mise install` beats
  hand-pinned binaries.
