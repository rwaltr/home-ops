# Hermes Agent

**Status:** GitOps manifests are prepared. The Matrix bot items in 1Password must exist before Flux can start the new configuration.

Hermes provides three agents:

| Agent                 | Deployment                         | Matrix identity                   | Access                                             |
| --------------------- | ---------------------------------- | --------------------------------- | -------------------------------------------------- |
| rwaltr personal       | `hermes-personal`, default profile | `@rwaltr-agent:matrix.waltr.tech` | Personal tools, no cluster or GitHub credentials   |
| Wife's personal agent | `hermes-personal`, profile `wife`  | `@wife-agent:matrix.waltr.tech`   | Personal tools, no cluster or GitHub credentials   |
| Teletran sysadmin     | `hermes`                           | `@teletran:matrix.waltr.tech`     | Existing GitHub App broker and narrow cluster RBAC |

The personal pod follows Hermes' upstream multi-profile deployment. The profiles
have separate sessions, memory, config, credentials, and Matrix identities. They
share one process, filesystem, and PVC. **They are not a privacy or security
boundary.** Either personal agent can read the other profile's files and tokens
through its terminal. This is an accepted household trust boundary. The sysadmin
agent runs in a separate pod so personal profiles cannot reach its ServiceAccount,
GitHub credentials, or workspace.

## Upstream deployment guidance

The deployment follows Hermes' Docker and profile guidance:

- [Docker setup](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
  recommends one official container for multiple profiles.
- [Profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles)
  isolate agent state, not filesystem access. The docs recommend a separate
  container when different people's data must be isolated.
- [Dashboard authentication](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard)
  supports self-hosted OIDC. A non-loopback dashboard fails closed without an
  auth provider.
- [Matrix](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/matrix)
  recommends sender and room allowlists for private deployments.

Both deployments use the official `nousresearch/hermes-agent:v0.23.3` image,
pinned to digest
`sha256:3e9fe4c6ef36490f43aa0d0d80f9df64e9c92a576eee3042f1a97c8813c05355`.
This matches upstream's stable v0.23.3 release from 2026-11-20.

## Matrix

Tuwunel is the primary communication channel. The Matrix adapter is native to
Hermes. Each agent uses a separate bot account and access token. Bot accounts are
created through Tuwunel's shared-secret registration API, documented in
[`docs/comms-demos.md`](comms-demos.md#bot-accounts-one-time-per-bot). Use
localparts `teletran`, `rwaltr-agent`, and `wife-agent`. The Matrix display names
can differ from these account IDs. Each agent chooses its conversational name
from its SOUL instructions.

Create these 1Password items in the `home-ops` vault before merging:

| Item                     | Fields                                                        | Consumer                     |
| ------------------------ | ------------------------------------------------------------- | ---------------------------- |
| `hermes-matrix-teletran` | `access_token`, `allowed_users`, `allowed_rooms`, `home_room` | Sysadmin ExternalSecret      |
| `hermes-matrix-rwaltr`   | `access_token`, `allowed_user`, `allowed_rooms`               | rwaltr profile dotenv Secret |
| `hermes-matrix-wife`     | `access_token`, `allowed_user`, `allowed_rooms`               | wife profile dotenv Secret   |

Set each sender allowlist to the full Matrix user ID. Start with the exact user
for that agent. Sign your wife into Element first so Kanidm creates her Matrix
account. Set `allowed_rooms` to an exact room ID. Use
`!disabled:matrix.waltr.tech` to allow direct messages only. Hermes' adapter
exempts direct-message rooms from the room allowlist. Replace the sentinel with
explicit room IDs if an agent should answer in a group room. Require a mention in
rooms.

Use the existing private admin room as the common agent room if it is a regular
Matrix room. Set its exact room ID in `allowed_rooms` for all three bots. Invite
all three bots. The personal agents accept only their respective user, and
Teletran accepts only rwaltr. All require mentions in group rooms. Set the same
room ID as Teletran's `home_room` for cron delivery. Do not use Tuwunel's
internal server-admin room for agent conversation.

Existing cron jobs stored on `hermes-data` may still target Discord. Change
their delivery target to Matrix after the new pod starts.

All Matrix profiles require E2EE. Do not use the bot token in a shared shell
environment. The personal profiles receive separate ESO-generated `.env` Secrets
as read-only mounts. Those files are not copied to the PVC. The profiles can still
read each other's mounted secrets because they share the personal pod.

## Dashboard OIDC

Both dashboards require Kanidm OIDC. Neither keeps a basic-auth fallback.
Kaniop creates confidential OIDC clients with PKCE enabled:

| Dashboard         | URL                                  | Kanidm client     | Who can log in    |
| ----------------- | ------------------------------------ | ----------------- | ----------------- |
| Teletran          | <https://hermes.waltr.tech>          | `hermes`          | `idm_admins`      |
| Personal profiles | <https://hermes-personal.waltr.tech> | `hermes-personal` | `idm_all_persons` |

The callback URLs are `/auth/callback` on each hostname. The personal dashboard
can switch between both personal profiles. Anyone allowed to log into it can
access both profiles through the dashboard. This follows the shared-pod decision.

Both HTTPRoutes attach only to `envoy-internal`. The dashboard hostnames are not
published externally. Kanidm provides the authorization and token endpoints at
`https://idm.waltr.tech`.

## Deployment layout

### Personal profiles

`infra/k8s/kyz/apps/default/hermes-personal/` deploys one official Hermes gateway
with two profiles:

- The default profile serves rwaltr.
- The `wife` profile serves the Matrix account owner.
- The dashboard manages both profiles.
- Each profile has its own Matrix token, sender allowlist, room allowlist, SOUL,
  working directory, memory, and sessions.
- Neither profile receives a Kubernetes ServiceAccount token, the GitHub App, or
  the Home Assistant token.

The image's s6 supervisor runs the gateway and dashboard. Hermes multiplexes the
profiles through one gateway. A config init container seeds the profile files
from ConfigMaps on first initialization. Profile config files are not
re-seeded on pod restarts, so Hermes retains mutable state. SOUL files are
re-seeded. ESO Secrets supply each profile's `.env` through read-only volumes.

### Sysadmin agent

`infra/k8s/kyz/apps/default/hermes/` continues to deploy Teletran. It keeps the
existing `hermes-data` PVC, GitHub App broker, repo checkout, toolchain, and
cluster access. Its Matrix and dashboard credentials are separate from the
personal deployment. The OpenAI-compatible API server is disabled because no
in-cluster consumer uses it.

Cluster permissions remain narrow. The `view` binding and custom roles grant
`get`, `list`, and `watch`. The only write verbs are `delete` on `pods` and
`batch/jobs` for controller-managed restart and stuck-job cleanup. Desired-state
changes still go through a branch, lint, and pull request. Flux deploys after
merge.

The sysadmin agent does not decrypt or handle SOPS or 1Password data. It never
commits secrets. It does not touch the live Flatcar host. It follows the existing
home-ops PR workflow and validates host changes in a VM.

## Secrets and prerequisites

No secret values belong in Git. Add the Matrix bot tokens and allowlists to the
1Password items above. Existing ExternalSecrets supply the other sysadmin
credentials:

- `OpenRouter API Key` supplies the model API key.
- `home-assistant-secret` supplies the Home Assistant token.
- `teletraan-x github app` supplies the GitHub App client ID and private key.
- The `hermes` and `hermes-personal` KanidmOAuth2Client resources create their
  own OIDC credential Secrets in `default`.

The generated Matrix registration shared secret lives in `matrix-secret`. It can
create administrator accounts. Use it only for the bot account registration
procedure. Never put it in a Hermes Secret or commit it.

## Verification

After Flux applies the change and the required 1Password items exist:

```bash
kubectl -n default get helmrelease,pod,pvc,externalsecret | grep hermes
kubectl -n default get httproute | grep hermes
curl -fsS https://matrix.waltr.tech/_matrix/client/versions
curl -sS -o /dev/null -w 'sysadmin dashboard %{http_code}\n' https://hermes.waltr.tech/
curl -sS -o /dev/null -w 'personal dashboard %{http_code}\n' https://hermes-personal.waltr.tech/
```

The dashboards should redirect unauthenticated requests to Kanidm. After login,
verify the sysadmin dashboard accepts only the admin group. Verify the personal
dashboard shows both profiles. Message each Matrix bot from its allowlisted account
and confirm an unlisted sender or room gets no response.
