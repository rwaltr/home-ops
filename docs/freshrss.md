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

## Authentication

FreshRSS logs in through Kanidm using the OIDC module built into the official Docker
image. That module exists **only in the Debian image**, not Alpine — which is why the
tag here is `ghcr.io/freshrss/freshrss` and not an Alpine variant. Switching the image
would silently disable the login path.

Configuration is entirely environment variables, plus one value that has to be minted:

- `OIDC_CLIENT_CRYPTO_KEY` is the module's own internal encryption key. It is not a
  client credential — the client id and secret come from the `KanidmOAuth2Client` in
  this directory, minted by kaniop. It is **generated in the cluster** rather than
  minted by Terraform: `generator.yaml` declares an External Secrets `Password`
  generator and `externalsecret.yaml` copies its value into `freshrss-oidc`. Nothing
  outside the pod reads it and no human needs to see it, so there is no reason for it
  to pass through 1Password or a Terraform apply.

  `refreshInterval: "0"` on that ExternalSecret is load-bearing — a generator produces
  a fresh value on every reconcile, and a rotating crypto key would invalidate
  in-flight sessions on a schedule. Zero means sync once and leave it alone.

- `OIDC_SCOPES` defaults to `openid` alone, which does **not** carry
  `preferred_username` — the claim used as the FreshRSS username. `profile` is
  required for it.
- `OIDC_X_FORWARDED_HEADERS` is **required** here because FreshRSS sits behind Envoy.
  Without it the module cannot determine the external scheme, host and port, and
  builds a return URL that will not match the registered callback.

The callback registered with Kanidm is the one upstream documents: `/i/oidc/`.

### The step that is not in git

FreshRSS authenticates a user by _claim_, so the FreshRSS account itself has to be
told to trust it. Once, per account:

1. Log in as the account, open **Administration → user → Authentication**.
2. Set the authentication method to **HTTP Authentication**.
3. Confirm the page shows your identity, e.g. `HTTP (for advanced users with HTTPS)
(REMOTE_USER='rwaltr@waltr.tech')`.

The username must match the OIDC identity, or you will lose administrator access to
the instance — upstream warns about this explicitly, and it is the reason to verify
step 3 before closing the tab.

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
