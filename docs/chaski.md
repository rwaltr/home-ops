# chaski — webhook relay

`chaski` (home-operations) is a small stateless relay: an app `POST`s JSON to
`/hooks/{route}`, chaski gates it with a CEL expression, renders title/message
with Go templates, and forwards the result to an Apprise notification or a plain
HTTP target. It exists here so that "notify me about X" is one route in one
config file instead of bespoke plumbing per app.

Deployed at `infra/k8s/kyz/apps/default/chaski/`, service
`http://chaski.default.svc.cluster.local:8080`.

## Exposure

Cluster-internal only — no HTTPRoute, no hostname. Every sender is an in-cluster
app, and the pod holds a Pushover credential. Do not publish it: it has no
inbound token configured (see below).

## Targets

One target, `pushover`, built from the **same 1Password items Alertmanager
already uses**:

| env var              | source                                                   |
| -------------------- | -------------------------------------------------------- |
| `PUSHOVER_APP_TOKEN` | item `alertmanager`, field `ALERTMANAGER_PUSHOVER_TOKEN` |
| `PUSHOVER_USER_KEY`  | item `pushover`, Login `credential` field                |

Consequence worth knowing: notifications sent through chaski appear in Pushover
as the _Alertmanager_ application, because they carry the same application token.
Separate applications (one per source, so Pushover can be filtered per app) need
new tokens minted in Pushover and stored in 1Password — then only the target URL
in the HelmRelease changes:

```yaml
targets:
  pushover:
    apprise:
      url: 'pover://{{ env "PUSHOVER_USER_KEY" }}@{{ env "PUSHOVER_APP_TOKEN" }}'
```

## Routes

Declared in the HelmRelease under `config.routes`, keyed by URL path
(`POST /hooks/{name}`). The four shipped routes are the media-stack notifications
the reference repo relays:

- `sonarr`, `radarr` — fire on `payload.eventType == "Download"`, moderate
  priority, with a deep link back to the item.
- `sonarr-manual`, `radarr-manual` — fire on
  `payload.eventType == "ManualInteractionRequired"` at high priority, pointing at
  the activity queue.

**The routes are inert until something posts to them.** Pointing Sonarr/Radarr at
them is an app-side step in their own configuration (Settings → Connect → Webhook,
URL `http://chaski.default.svc.cluster.local:8080/hooks/sonarr`), not a manifest
change — the same class as adding a library or a root folder.

## Testing a route without sending

Append `?dryRun=1`: chaski reports the matched targets, the rendered fields and
whether the CEL gate passed, and sends nothing. This is the way to check a route
after editing it:

```sh
curl -s -X POST 'http://chaski.default.svc.cluster.local:8080/hooks/radarr?dryRun=1' \
  -H 'Content-Type: application/json' \
  -d '{"eventType":"Download","applicationUrl":"http://radarr","downloadClient":"sabnzbd",
       "movie":{"title":"Example","year":2024,"overview":"…","tmdbId":1},
       "movieFile":{"sceneName":"example.2024.1080p"}}'
```

A payload with an event type the route's `whenExpr` does not match returns
`"fired": false` — that is the answer to "why did nothing happen", not an error.

## Adding a route or target

1. Add the route/target to `config.routes` / `config.targets` in the HelmRelease.
2. Keep credentials as `{{ env "VAR" }}` references resolved from
   `chaski-secret` (the ExternalSecret in the same directory) — never inline.
3. Run the `?dryRun=1` check above against the new route after the merge.

## Authentication

Inbound token auth is **off** (`CHASKI_WEBHOOK_TOKEN` unset). That is deliberate
for an internal-only relay, and it means any pod in the cluster can post to any
route. Two levers exist when that stops being acceptable:

- Set `auth.existingSecret` (plus `existingSecretKey`) to require a bearer token —
  needs a secret rwaltr owns.
- Per-route `verify` (HMAC or shared token over the raw body, with a built-in
  `github` preset) for a sender that can sign.

## Notes

- Config edits roll the pod: the chart stamps a `checksum/config` annotation, and
  `reloader.stakater.com/auto` is set on the Deployment.
- Metrics are on (`/metrics`, port 8081) with a ServiceMonitor, so route volume
  and failures are visible in Prometheus.
