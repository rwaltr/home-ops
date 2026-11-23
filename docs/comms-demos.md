# Comms-channel demo: Matrix

> **Restored in GitOps.** The previous demo was retired on 2026-11-09, which
> pruned `tuwunel`, `element-web` and the 5Gi `tuwunel-data` PVC. Enabling the
> `matrix` Kustomization again creates a fresh homeserver: old accounts and
> messages are gone; people create accounts through Kanidm, bots through the
> operator-only provisioning endpoint below.

A self-hosted communication stack first stood up **internal-only** on 2026-11-01
to serve Hermes. Matrix is the selected primary communication channel for
Hermes. It remains demo-grade: single namespace,
low resource limits, Kanidm SSO for people, and manually provisioned bot
accounts. Federation is on but allow-listed to `beeper.com` only, so Beeper can
reach the server (MVP; see the federation section below).

|                | Matrix                                               |
| -------------- | ---------------------------------------------------- |
| Web UI         | <https://element.waltr.tech>                         |
| API host       | <https://matrix.waltr.tech>                          |
| Server         | Tuwunel v1.9.4 (Rust)                                |
| Storage        | `tuwunel-data` (5Gi, RocksDB)                        |
| Memory limit   | 512Mi                                                |
| Human login    | Kanidm SSO via Tuwunel OIDC                          |
| Federation     | allow-listed to `beeper.com` only                    |
| Hermes adapter | native Matrix adapter, dashboard plus per-agent bots |

## How it is deployed

`infra/k8s/kyz/apps/default/matrix/` holds Tuwunel + Element Web. The default
apps Kustomization includes `matrix/ks.yaml`, so Flux reconciles both services
and the Tuwunel data PVC from Git. Human accounts are created at first Kanidm
login; bot accounts use Tuwunel's shared-secret registration API below.

## Why Matrix

Matrix has the only first-class, _interactive_ agent adapter in Hermes: rooms,
threads, reactions, typing, E2EE, and per-user/room allowlists. Tuwunel was
chosen over Synapse because it is a single Rust binary on an embedded database —
no PostgreSQL — which matters on a single-node cluster. Tuwunel is the official
successor to conduwuit; Dendrite is in maintenance mode as of 2026 and was not
considered.

### Why XMPP was dropped

XMPP (Prosody + Converse) was deployed first and removed the same day. It is the
lightest server and the most "correct" protocol, and the web client worked — but
it fails the deployability bar for this setup:

- **Hermes has no XMPP adapter**, so an agent integration means a custom
  `slixmpp` bot or an XMPP-to-webhook bridge.
- **Native clients need raw c2s on 5222.** Browser transports (BOSH/WebSocket)
  ride the normal HTTP gateway on 443, but Gajim, Conversations, Dino and Monal
  authenticate over c2s, and `envoy-internal` is HTTP-only. Serving it meant a
  second Cilium LoadBalancer VIP, Prosody's own cert-manager certificate (it
  ships no usable self-signed cert), and `consider_*_secure` tweaks — a lot of
  moving parts for a demo.
- **Cloudflare cannot carry 5222.** Tunnel public hostnames proxy HTTP/HTTPS
  only; Spectrum can do arbitrary TCP but is Enterprise for all ports, and its
  TCP mode cannot originate from a Tunnel — it needs a public origin IP, which
  CGNAT does not have. Off-LAN native clients would need Tailscale (not yet
  running on `mouse`) or a VPS TCP relay.

The lesson generalises: a channel whose clients cannot be served over plain
HTTPS/443 behind Cloudflare is expensive here.

### On a web UI instead of a protocol

`Open WebUI` (or CopilotKit's AG-UI) is a _frontend_, not a transport, so it is
complementary rather than an alternative: Open WebUI talks the OpenAI API and
would point straight at the existing agentgateway LLM endpoint
(`http://agentgateway.default.svc.cluster.local:8082/v1`), giving a rich desktop chat
console. The Matrix channel matters for the cases a single web app does not
cover — mobile push, multiple devices, async delivery, and long-lived per-room
state. If a custom agent frontend is built later, AG-UI is the protocol to embed
agent state/streaming into it; Open WebUI is the ready-made option. Neither is
deployed here.

## Human sign-in (Kanidm)

Element talks to Tuwunel's built-in Matrix OIDC server, which delegates the
interactive login to Kanidm. Tuwunel's upstream-provider client is declared as a
`KanidmOAuth2Client` named `matrix`; kaniop writes its credentials to
`matrix-kanidm-oauth2-credentials` in `default`. The callback is
`https://matrix.waltr.tech/_matrix/client/unstable/login/sso/callback/matrix`.

Local password login and password/token registration are disabled. Kanidm SSO
can create Matrix users on first login; on this empty server, the first SSO user
is granted admin privileges by Tuwunel. Matrix localparts are derived from
Kanidm's `preferred_username` (or its email address if needed). The Element
server picker should use `matrix.waltr.tech`, not `idm.waltr.tech`.

`TUWUNEL_SINGLE_SSO=true` is enabled because Element Classic on iOS appends the
IdP ID to the legacy `/_matrix/client/r0/login/sso/redirect` endpoint. Tuwunel
1.9.4 returns `M_UNRECOGNIZED` for that path. With a single IdP, this setting
omits the provider list, so the client uses the bare redirect endpoint instead.
The trade-off is that clients show a generic SSO button rather than a
provider-specific Kanidm button.

## Bot accounts (one-time per bot)

Hermes' native adapter needs a normal Matrix user ID and access token; it is not
an appservice. Password login is disabled, so Hermes cannot use a user-password
pair on this server.

Tuwunel's Synapse-compatible shared-secret registration endpoint creates a
non-admin account and returns its access token. The helper script reads the
signing secret directly from Kubernetes. It never prints that secret or the
throwaway password:

```bash
./scripts/provision-matrix-bot.py teletran
./scripts/provision-matrix-bot.py rwaltr-agent
./scripts/provision-matrix-bot.py wife-agent
```

Run each command once per bot. Store the printed access token in that bot's
1Password item, as listed in [`docs/hermes-agent.md`](hermes-agent.md). The
registration secret lives in the `matrix-secret` Secret and can create admin
accounts. Never put it in a bot's environment or paste it into chat. The script
needs a `kubectl` context that can read that Secret.

Re-minting the Secret (delete it and let Flux reconcile) changes only the key
future provisioning calls sign with; existing accounts and tokens keep working.

Beeper's apps and Bridge Manager are not generic clients for this homeserver:
Bridge Manager expects Beeper's own Matrix server and account. For bridges on
this homeserver, use a standard Matrix appservice bridge (for example a mautrix
bridge); Tuwunel lets an admin register its YAML in the admin room. Appservices
are separate from user login and do not need password login enabled. No Matrix
client adapter or extension is currently installed for pi; a future surface
would use a normal user token like Hermes.

After the Secret exists, create a non-admin bot account and store the returned
access token in the appropriate 1Password item (for Hermes, add
`matrix_access_token` to `hermes`; wiring the adapter is a separate change):

```bash
REGISTRATION_SHARED_SECRET=$(kubectl -n default get secret matrix-secret \
  -o jsonpath='{.data.registration_shared_secret}' | base64 -d) \
  python3 - <<'PY'
import hashlib
import hmac
import json
import os
import secrets
import urllib.request

base = "https://matrix.waltr.tech/_synapse/admin/v1/register"
username = input("Bot localpart (for example, hermes): ").strip()
if not username:
    raise SystemExit("username is required")
password = secrets.token_urlsafe(32)
with urllib.request.urlopen(base) as response:
    nonce = json.load(response)["nonce"]
mac_data = b"\0".join((nonce.encode(), username.encode(), password.encode(), b"notadmin"))
mac = hmac.new(os.environ["REGISTRATION_SHARED_SECRET"].encode(), mac_data, hashlib.sha1).hexdigest()
body = json.dumps({"nonce": nonce, "username": username, "password": password, "admin": False, "mac": mac}).encode()
request = urllib.request.Request(base, data=body, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(request) as response:
    result = json.load(response)
print(f"User: {result['user_id']}")
print(f"Access token (store in 1Password): {result['access_token']}")
PY
```

Treat the printed token as a password. It grants full access to that bot account;
revoke it by logging out that account's sessions. The registration HMAC itself
can create administrator accounts and must remain with the operator.

## Hermes integration

Hermes uses Matrix as its primary chat platform. GitOps deploys two independent
workloads:

- `hermes` runs the Teletran sysadmin agent with its own bot identity.
- `hermes-personal` runs the rwaltr and wife profiles in one multi-profile
  container. Their profile data and secrets are not isolated from each other.

Each bot needs its own access token plus `MATRIX_ALLOWED_USERS` and
`MATRIX_ALLOWED_ROOMS`. Keep the room list narrow. Hermes treats direct messages
separately from the room allowlist. See [`docs/hermes-agent.md`](hermes-agent.md)
for item names, OIDC setup, and the profile security boundary.

A Beeper identity works as a second sender: `MATRIX_ALLOWED_USERS` is a
comma-separated set, and the federation allow-list above covers `beeper.com`.
Do not allowlist bridge ghost users; add them to `MATRIX_IGNORE_USER_PATTERNS`
instead.

Invite each bot only to the intended private rooms. Keep `MATRIX_E2EE_MODE` set
to `required`.

## Federation (beeper.com only, MVP)

Federation is on so Beeper can reach this homeserver: Beeper Desktop can DM a
Matrix user by ID, and the agent's own user ID becomes reachable from Beeper.
The MVP is deliberately narrow — one allow-list entry, nothing else.

- `allow_federation = true`.
- `allowed_remote_server_names_experimental = ["(^|\\.)beeper\\.com$"]`. A
  non-empty allow-list means **every other remote server is denied**; the
  server's own name is always permitted. The regex is anchored so
  `evilbeeper.com` does not match.
- The route now also attaches to `envoy-external`, so external-dns publishes
  `matrix.waltr.tech` as a CNAME to the Cloudflare tunnel and the existing
  `*.waltr.tech` certificate covers it. Tuwunel's well-known already points at
  `matrix.waltr.tech:443`, so no `:8448` listener is needed — which matters,
  because CGNAT blocks inbound ports.

Why the allow-list rather than opening federation: without it the server accepts
signed events from any server that can find it. With it, only Beeper's server can
complete a federation handshake.

Cloudflare caveat: Bot Fight Mode is off on this zone (checked via the API), so
federation traffic is not challenged. If it is ever turned on, it cannot be
bypassed by WAF skip rules on the free plan — federation would start failing
with 403s.

Not done in the MVP: presence/typing federation stays at defaults, and no
appservice bridges are registered. Encryption is the real follow-on cost: Beeper
requires per-device verification, so a bot reading encrypted rooms needs a
recovery key and device handling.

## Operational notes

- **Internal routes, one public exception.** Every app route attaches to
  `envoy-internal`; k8s-gateway publishes the `*.waltr.tech` names from the
  HTTPRoutes. Tuwunel is the exception: it also attaches to `envoy-external` so
  Beeper can federate, gated by the allow-list above.
- **Federation is allow-listed.** `allow_federation = true` with only
  `beeper.com` permitted; see the section above.
- **Secrets.** No secret enters git. The registration HMAC is generated in the
  cluster into `matrix-secret` and is powerful enough to create server
  administrators; only read it to provision a bot.
- **openebs-hostpath ignores `fsGroup`.** The data volume is chowned to its
  unprivileged uid by an init container, because hostPath-backed PVCs are not
  group-owned by kubelet.
- **Removing the demo:** delete `infra/k8s/kyz/apps/default/matrix/` and its
  entry in `apps/default/kustomization.yaml`, then
  `kubectl -n default delete pvc tuwunel-data`.

## Verification

```bash
kubectl -n default get helmrelease,pod,pvc,httproute | grep -E 'tuwunel|element'
curl -sS -o /dev/null -w 'element %{http_code}\n' https://element.waltr.tech/
curl -fsS https://matrix.waltr.tech/_matrix/client/versions
```
