# Comms-channel demo: Matrix

A self-hosted communication stack stood up **internal-only** on 2026-11-01 to
evaluate it as a channel for the self-hosted agent (Hermes / whatever
pi-durable-based agent replaces it). It is demo-grade: single namespace, no
federation, low resource limits, and first-run accounts created by hand rather
than declared in git.

|                | Matrix                                              |
| -------------- | --------------------------------------------------- |
| Web UI         | <https://element.waltr.tech> (deployed)             |
| Web UI (alt)   | Cinny — manifests only, not deployed                |
| API host       | <https://matrix.waltr.tech>                         |
| Server         | Tuwunel v1.9.4 (Rust)                               |
| Storage        | `tuwunel-data` (5Gi, RocksDB)                       |
| Memory limit   | 512Mi                                               |
| Hermes adapter | native (rooms, threads, E2EE) — not wired           |
| Bridges        | Signal / Discord / Google Messages — manifests only |

## What runs, and what is only written down

| Path                                         | State                              |
| -------------------------------------------- | ---------------------------------- |
| `infra/k8s/kyz/apps/default/matrix/`         | **deployed** (Tuwunel + Element)   |
| `infra/k8s/kyz/apps/default/matrix-bridges/` | written only — `ks.yaml` commented |
| `infra/k8s/kyz/apps/default/cinny/`          | written only — `ks.yaml` commented |

Matrix itself was applied out-of-band on 2026-11-01 (`kubectl apply -k`), which
is why its objects predate the manifests being in git; Flux owns them now. The
other two trees exist so the shape is reviewable and so enabling either is one
uncomment in `apps/default/kustomization.yaml` — neither is referenced from any
kustomization, so neither has objects in the cluster.

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

### Why Cinny is written down but not running

Element Web is the reference client and the one that is deployed. Cinny is the
lighter, faster client a lot of people prefer day-to-day, so its manifests sit
alongside ready to compare — as a static SPA on the image's own nginx, pointed at
`matrix.waltr.tech` by a `config.json` ConfigMap, with an unlisted
`cinny.waltr.tech` route. It is not running because a second web surface for the
same homeserver is not worth memory on a node already at 58% committed, and
because nothing here needs it yet. Turning it on is one uncomment.

## The Beeper shape (bridges)

Beeper's whole product is one client over many networks, and on Matrix that means
mautrix bridges: each bridge is a Matrix "appservice" that puppets an account on
another network and mirrors its conversations into rooms usable from any Matrix
client. Three are written down, chosen over WhatsApp/Telegram because they are
the networks actually worth consolidating here:

| Bridge              | Network                   | Port  | State          |
| ------------------- | ------------------------- | ----- | -------------- |
| `mautrix-signal`    | Signal                    | 29328 | manifests only |
| `mautrix-discord`   | Discord                   | 29334 | manifests only |
| `mautrix-gmessages` | Google Messages (RCS/SMS) | 29348 | manifests only |

Manifests: `infra/k8s/kyz/apps/default/matrix-bridges/` — **not wired in**, so
nothing is deployed. `mautrix-gmessages` is the one that makes this feel like
Beeper rather than "another chat app": paired with Google Messages on the phone,
SMS/RCS lands in the same client as the other networks and the agent.

### What a bridge actually requires

A bridge is not a container you can just run — it is a new participant in the
homeserver's trust model, and it cannot work without a registration the
homeserver accepts:

1. **Confirm the homeserver supports appservices at all.** Tuwunel should, as the
   successor to conduwuit, but this is unverified here and is the first thing to
   check.
2. **Generate `config.yaml` and `registration.yaml` with the bridge image.**
   `registration.yaml` holds the appservice credentials (`as_token`, `hs_token`);
   run the image interactively to emit both, then `-g` to regenerate the
   registration after editing.
3. **Keep the port in step.** `appservice.address` in `config.yaml`, the `url` in
   `registration.yaml`, and the port in the manifest and its Service are four
   copies of one number — they must agree or the homeserver cannot reach the
   bridge.
4. **Store both files in 1Password** (one item per bridge) and project them with
   an ExternalSecret into the Secret the HelmRelease mounts
   (`mautrix-<bridge>-config`). Neither file may enter git.
5. **Register the appservice with Tuwunel** (admin API or command — check the
   mechanism for the version in use), then uncomment the kustomization entry and
   pair from the room the bridge creates.

### Cost and risk

- **Cost** — 3 × 128Mi requests (512Mi limits) ≈ 384Mi committed, plus a 1Gi
  `openebs-hostpath` PVC each for SQLite. Affordable after the 2026-11-07
  right-sizing pass (17.9Gi of 30.97Gi committed), but not free.
- **Risk** — every mautrix bridge is an unofficial client of a closed network.
  Discord does not permit self-bots and can ban the account; the Google Messages
  bridge drives the same private web protocol the web app uses. Signal has
  historically been tolerant of bridges. That risk is precisely why these are
  written down and not running.

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

Nothing is wired. The shape mirrors how the Discord adapter already works in
`apps/default/hermes/`: `DISCORD_*` env inline on the HelmRelease, secrets from
the `hermes` ExternalSecret projected into `hermes-secret`, which the container
consumes with `envFrom`, and the 1Password items in vault `home-ops`.

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
  is generated at runtime; bridge registrations would live in 1Password.
- **openebs-hostpath ignores `fsGroup`.** The data volume is chowned to its
  unprivileged uid by an init container, because hostPath-backed PVCs are not
  group-owned by kubelet.
- **Removing the demo:** delete `infra/k8s/kyz/apps/default/matrix/` and its
  entry in `apps/default/kustomization.yaml`, then
  `kubectl -n default delete pvc tuwunel-data`. The unused `matrix-bridges/` and
  `cinny/` trees delete with their commented-out lines and need no cluster
  cleanup — they never had objects.

## Verification

```bash
kubectl -n default get helmrelease,pod,pvc,httproute | grep -E 'tuwunel|element'
curl -sS -o /dev/null -w 'element %{http_code}\n' https://element.waltr.tech/
curl -sS https://matrix.waltr.tech/_matrix/client/versions

# the two written-only trees must render and must NOT be reconciled
kubectl kustomize infra/k8s/kyz/apps/default/matrix-bridges/app
kubectl kustomize infra/k8s/kyz/apps/default/cinny/app
kubectl get kustomization -n flux-system cinny matrix-bridges   # expect NotFound
```
