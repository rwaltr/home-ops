# FreshRSS (feeds.waltr.tech)

Self-hosted feed aggregator for rwaltr's reading. Defined in
`infra/k8s/kyz/apps/default/freshrss/`.

|             |                                                                                                    |
| ----------- | -------------------------------------------------------------------------------------------------- |
| Web UI      | `https://feeds.waltr.tech` (envoy-internal **and** envoy-external)                                 |
| Mobile APIs | Google Reader API (`/api/greader.php`), Fever API (`/api/fever.php`) — off until enabled in the UI |
| Image       | `ghcr.io/freshrss/freshrss:1.30.1`, index digest-pinned                                            |
| Storage     | `freshrss-data` (5Gi, SQLite + config) · `freshrss-extensions` (1Gi)                               |
| Backups     | kopiur policy `freshrss`, nightly `H 5 * * *`, mover uid/gid 33                                    |

## Why FreshRSS

Chosen over Miniflux and CommaFeed (2026-10-08) because it is the only one of
the three that needs **no database service**: SQLite is the default backend, so
the app is one container plus two PVCs on a single-node cluster. Miniflux
requires PostgreSQL; CommaFeed's Google Reader UI is closer to the original but
its client ecosystem is thinner. FreshRSS also implements the Google Reader API
plus Fever, which is what native clients (Reeder, NetNewsWire, FeedMe, Readrops,
Capy Reader) sync against.

## First run (one-time, in a browser)

The manifests deliberately do **not** pre-install the instance. The image's
headless hooks (`FRESHRSS_INSTALL`, `FRESHRSS_USER`) can install FreshRSS but
create no account, and self-registration is off by default — so a headless
install would leave the instance unreachable without an in-pod
`cli/create-user.php`. Instead the first boot serves the web installer:

1. Open `https://feeds.waltr.tech`.
2. The installer runs at `/i/`. Choose **SQLite** (no DB fields needed), set the
   admin username and password, and confirm the base URL
   `https://feeds.waltr.tech` (it drives WebSub, favicons and API URLs).
3. Log in. Done — nothing to provision in 1Password.

Consequence: the install is a browser step, not a declared manifest. The result
(config.php + SQLite DB) lives on the `freshrss-data` PVC and is in the nightly
kopiur snapshot set.

## Mobile clients

The web installer does not touch the API switch, and FreshRSS defaults
`api_enabled` to **false** (`config.default.php`) — so it must be turned on
before a client can sync:

1. _Settings → Administration → Authentication_ → tick **Allow API access**
   (this is the `api_enabled` system setting).
2. _Settings → Profile_ → set an **API password** for your user. It is a
   separate credential from the login password.

Then point the client at `https://feeds.waltr.tech/api/greader.php`.

## Downstream consumers

Nothing consumes this yet. If an automation ever wants the article list, prefer
the Google Reader API with a dedicated user over scraping the UI.

## Operational notes

- **Runs as root.** The upstream entrypoint rewrites `/etc/localtime`,
  php.ini and the Apache vhost in place, then chowns `data/` and `extensions/`
  to `www-data` (uid 33) before exec'ing Apache on port 80. `readOnlyRootFilesystem`
  must stay `false` or the pod crashloops before Apache starts. Capabilities are
  narrowed to CHOWN/SETGID/SETUID/DAC_OVERRIDE/FOWNER.
- **Backups.** kopiur's mover runs as 33:33, not the default 65532: `data/users/<user>/`
  is mode 0700 owned by www-data, so a default-UID mover fails with EACCES.
  `copyMethod: Direct` (no CSI snapshots on openebs-hostpath) means snapshots are
  crash-consistent — a SQLite write landing mid-copy is the accepted tradeoff,
  same as HA's recorder DB.
- **Feed refresh.** `CRON_MIN: "11,41"` schedules the in-container cron, so feeds
  refresh every 30 minutes even with nobody reading. Drop it and feeds only pull
  when a client opens the UI/API.
- **Extension installs** write to the `freshrss-extensions` PVC. Without that PVC
  they would land on the container filesystem and disappear on the next pod roll.
- **Proxy.** Apache's `mod_remoteip` trusts `10.0.0.0/8` by default and Cilium's
  pod CIDR is `10.244.0.0/24`, so client IPs survive Envoy without setting
  `TRUSTED_PROXY`. If the pod CIDR ever moves outside those ranges, set it.
- **Public exposure** is via the cloudflare tunnel (`envoy-external`). The service
  is internet-reachable; FreshRSS has no built-in per-IP rate limit, so the
  login form is the only gate. Kernel-level protection is whatever Cloudflare
  provides.

## Verification

```bash
kubectl -n default get helmrelease,pvc,pod -l app.kubernetes.io/name=freshrss
kubectl -n default get snapshotpolicy,snapshotschedule freshrss
curl -sS -o /dev/null -w '%{http_code}\n' https://feeds.waltr.tech/i/   # 200
```
