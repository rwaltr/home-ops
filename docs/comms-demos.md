# Comms-channel demo: Matrix

A self-hosted communication stack stood up **internal-only** on 2026-11-01 to
evaluate it as a channel for the self-hosted agent (Hermes / whatever
pi-durable-based agent replaces it). It is demo-grade: single namespace, no
federation, low resource limits, and first-run accounts created by hand rather
than declared in git.

|                | Matrix                                    |
| -------------- | ----------------------------------------- |
| Web UI         | <https://element.waltr.tech> (deployed)   |
| API host       | <https://matrix.waltr.tech>               |
| Server         | Tuwunel v1.9.4 (Rust)                     |
| Storage        | `tuwunel-data` (5Gi, RocksDB)             |
| Memory limit   | 512Mi                                     |
| Hermes adapter | native (rooms, threads, E2EE) — not wired |

## How it is deployed

`infra/k8s/kyz/apps/default/matrix/` holds Tuwunel + Element Web, reconciled by
the Flux `matrix` Kustomization. It was applied out-of-band on 2026-11-01
(`kubectl apply -k`), which is why its objects predate the manifests being in
git; Flux owns them now.

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
would point straight at the existing LiteLLM gateway
(`http://litellm.default.svc.cluster.local:4000/v1`), giving a rich desktop chat
console. The Matrix channel matters for the cases a single web app does not
cover — mobile push, multiple devices, async delivery, and long-lived per-room
state. If a custom agent frontend is built later, AG-UI is the protocol to embed
agent state/streaming into it; Open WebUI is the ready-made option. Neither is
deployed here.

## First run (one-time, in a browser)

The registration token is generated on first start and printed by the init
container. Open Element at <https://element.waltr.tech>, choose
`matrix.waltr.tech` under "Host account on", click **Create account**, and paste
the token when asked.

```bash
kubectl -n default logs deploy/tuwunel -c registration-token | grep token
# later, to read it from the PVC:
kubectl -n default exec deploy/tuwunel -- cat /var/lib/tuwunel/.registration_token
```

Once accounts exist, set `TUWUNEL_ALLOW_REGISTRATION: "false"` in the HelmRelease.
The first account to register becomes the server admin, which is exactly why
open registration is not enabled.

## Wiring an agent in (later)

Nothing is wired. There are two paths, and they are not the same amount of work.

**Hermes** already has a native Matrix adapter, so this is configuration only. The
shape mirrors how its Discord adapter works in `apps/default/hermes/`: `DISCORD_*`
env inline on the HelmRelease, secrets from the `hermes` ExternalSecret projected
into `hermes-secret`, which the container consumes with `envFrom`, and the
1Password items in vault `home-ops`.

**A `pi-durable` agent** (TeleVect) has no Matrix adapter, because `pi-durable` is
a conversation runtime and not a chat client: it commits turns, tools and
documents and offers `submit()` in and `viewState()`/`watch()` out, but nothing
that speaks Matrix. Matrix would be a _surface_ to build, beside the web, hook,
email and notification surfaces its spec already defines — its open item O13 is
exactly "whether a chat channel (Matrix/Signal) replaces email as the phone
surface". Two properties make that smaller than it sounds: one room maps to one
conversation, and a chat message is an anticipated input shape (the runtime
documents `chat.mention` entries and treats a mid-run message as a follow-up or a
steer). The access token belongs to the surface, in the host process, never to
the executor or the model's reach.

1. Register a dedicated `@hermes:matrix.waltr.tech` account. Registration is
   token-gated, so this is a manual step.
2. Put its access token in a 1Password item (vault `home-ops`) and add it to the
   `hermes` ExternalSecret; the container already consumes `hermes-secret`.
3. Set the adapter env on the hermes container: `MATRIX_HOMESERVER_URL`, the
   token, and — non-negotiable — `MATRIX_ALLOWED_USERS` and
   `MATRIX_ALLOWED_ROOMS`.
4. Invite `@hermes` to the rooms it should answer in.

Both allowlists are the whole point: without them, any sender in any room the
agent has joined can trigger agent turns, which turns every joined room into a
prompt-injection surface. This stays written down rather than wired because
Matrix is a demo channel, and making the agent answer in it is a promotion to a
live channel — deliberate, and separate from this.

## Operational notes

- **Internal only.** Every route attaches to `envoy-internal`; k8s-gateway
  publishes the `*.waltr.tech` names from the HTTPRoutes. Nothing is reachable
  off-LAN.
- **No federation.** Tuwunel has `allow_federation = false`.
- **Secrets.** No secret enters git. The registration token lives on the PVC and
  is generated at runtime.
- **openebs-hostpath ignores `fsGroup`.** The data volume is chowned to its
  unprivileged uid by an init container, because hostPath-backed PVCs are not
  group-owned by kubelet.
- **Removing the demo:** delete `infra/k8s/kyz/apps/default/matrix/` and its
  entry in `apps/default/kustomization.yaml`, then
  `kubectl -n default delete pvc tuwunel-data`.

## Verification

````bash
kubectl -n default get helmrelease,pod,pvc,httproute | grep -E 'tuwunel|element'
curl -sS -o /dev/null -w 'element %{http_code}\n' https://element.waltr.tech/
curl -sS https://matrix.waltr.tech/_matrix/client/versions```
````
