# Calendar (Radicale / CalDAV)

One shared calendar for two phones on two different platforms, plus Home Assistant,
plus a read-only feed of the `remind` CLI's reminders.

Radicale is the only new workload. Nothing else was added: iOS Calendar is a
native CalDAV client, Home Assistant has a core CalDAV integration, and Android
needs one app (DAVx⁵).

```
 iPhone (Calendar.app) ─┐
                        ├─ HTTPS → cloudflare tunnel → envoy-external ┐
 Android (DAVx⁵) ───────┘                                             ├→ radicale:5232
 Home Assistant (caldav integration) ─── cluster network ─────────────┘       │
                                                                       radicale-collections PVC
 (workstation) .reminders → rem2ics → scripts/remind-to-caldav.py ────────────┘
```

## Collections and accounts

Four accounts, four collections. Each account is one client credential, so a lost
phone means deleting one htpasswd line rather than rotating a shared password.

| Account          | Used by                       | Collections                       |
| ---------------- | ----------------------------- | --------------------------------- |
| `rwaltr`         | your phone, your desktop      | `rwaltr/calendar` (private)       |
| `sam`            | her iPhone                    | `sam/calendar` (private)          |
| `home-assistant` | the HA CalDAV integration     | `home-assistant/*` (shares)       |
| `remind-export`  | `scripts/remind-to-caldav.py` | `remind-export/remind` (writable) |

Collection layout:

- **`rwaltr/calendar`** — yours alone (`owner_only` rights; nobody else can see it).
- **`sam/calendar`** — hers alone.
- **`rwaltr/family`** — the shared calendar, owned by `rwaltr` and presented inside
  `sam`'s and `home-assistant`'s principals via `map` shares with `rw`.
- **`remind-export/remind`** — the Remind feed. Owned by `remind-export`; shared
  read-only (`r`) to `rwaltr`, `sam` and `home-assistant`.

**Why shares and not a rights file.** Upstream is explicit: any rights backend
other than `owner_only` means collections _outside_ `/USERNAME/` are never
auto-discovered by clients. Since every phone discovers calendars by PROPFIND on
its own principal, a cross-user collection must appear as a child of that
principal. That is what `[sharing] collection_by_map` does (Radicale ≥ 3.7), so
`bootstrap.sh` seeds the sharing database instead of a rights file.

## Cluster side

- `infra/k8s/kyz/apps/default/radicale/` — `ks.yaml` (Flux Kustomization + kopiur
  backup component) and `app/` (OCIRepository, HelmRelease, ExternalSecret,
  kustomization, plus the `config` and `bootstrap.sh` files that become the
  `radicale-config` ConfigMap).
- Pod: `ghcr.io/kozea/radicale:3.8.1`, uid/gid 1000, single listener on 5232,
  `readOnlyRootFilesystem`, config at `/etc/radicale/config`, htpasswd at
  `/etc/radicale-users/users`, storage on the `radicale-collections` PVC
  (openebs-hostpath, 1Gi, backed up nightly by kopiur at `H 5 * * *`).
- Route: `calendar.waltr.tech` on both `envoy-internal` and `envoy-external`
  (public through the cloudflare tunnel — CGNAT, no port forwards). TLS is the
  cert-manager `*.waltr.tech` wildcard; basic auth over TLS is the only gate.
- The **init container** (`bootstrap.sh`) is what makes this declarative: it
  builds the htpasswd file from the 1Password fields (above), pre-creates the four
  collections and seeds the sharing database, so the shares resolve before any
  phone has ever connected. It only ever fills gaps — an existing `.Radicale.props`
  or `sharing.csv` is left untouched, so state written by a phone or the WebUI
  survives every restart. The plaintext `radicale-users` Secret is mounted
  **only** into this container; the app container gets the generated hashes from
  an emptyDir, read-only.

### Provisioning the credentials (owner step — the pod does not start without it)

1Password item **`radicale-secret`**: one **concealed field per account** holding a
_long random password_, named after the account.

| Item field      | htpasswd user     | Used by                        |
| --------------- | ----------------- | ------------------------------ |
| `rwaltr`        | `rwaltr`          | your phone, your desktop       |
| `sam`           | `sam`             | her iPhone                     |
| `ha`            | `home-assistant`  | the HA CalDAV integration      |
| `remind-export` | `remind-export`   | `scripts/remind-to-caldav.py`  |

Those four values are the only credentials in the system, and they are what
`op://home-ops/radicale-secret/<name>` returns. **There is no htpasswd file to
generate.** The `bootstrap.sh` init container bcrypts each field into
`/etc/radicale-users/users` at every pod start, so rotating a password is one
1Password edit: the ExternalSecret picks it up within `refreshInterval` (1h),
reloader rolls the pod, the hash is rebuilt. Nothing is kept in sync by hand.

That last point is the whole design: the first version of this app stored a
hand-made bcrypt blob in the item's **notes** and read it with `{{ .notesPlain }}`.
The blob drifted from these fields, and every client got a 401 with no obvious
cause. If you ever do want the hash parked in 1Password instead, it has to be
regenerated from *these* fields (`htpasswd -nB`) whenever one changes — so don't.

The plaintext passwords do land in the `radicale-users` Secret, but it is mounted
**only into the init container**; the app container mounts just the generated
hashes. That is the price of not hand-maintaining a hash blob, and it is the same
Secret-read trust boundary as the 1Password Connect token already in the cluster.

## Client setup

**iPhone (Sam).** Settings → Apps → Calendar → Accounts → Add Account → Other →
**Add CalDAV Account**: server `calendar.waltr.tech`, username `sam`, password
from 1Password. Calendar.app discovers `Sam`, `Family` and `Remind (read-only)`
and shows them as separate calendars. No app to install.

**Android (rwaltr).** Install **DAVx⁵** (F-Droid `davx5-ose` is free; the Play
version is paid) and add a CalDAV account with the base URL
`https://calendar.waltr.tech` plus the `rwaltr` credentials. DAVx⁵ then offers
`Rwaltr`, `Family` and `Remind (read-only)` to sync. For a calendar UI use
Fossify Calendar or Etar; the Google Calendar app also works but **does not** show
DAVx⁵ calendars until the DAVx⁵ account is enabled under its
Settings → Manage Accounts (DAVx⁵'s own FAQ).

**Home Assistant.** Settings → Devices & services → Add integration → **CalDAV**:
URL `https://calendar.waltr.tech`, username `home-assistant`. It creates a
calendar entity per collection with `CREATE_EVENT` support, so automations can
both trigger on events and add them (`calendar.create_event`).

Config entries live in `/config/.storage` on the HA PVC — the `config/` directory
in this repo is a mirror, not a mounted source — so this is a UI step, not a Git
change. If it should be reproducible from Git instead, use the YAML form
(`calendar: platform: caldav`) with the password in HA's `secrets.yaml`.

## Remind as a read-only feed (workstation side)

The `.reminders` file never leaves your machine, and it is deliberately not in
Git (it contains real dates). Only the rendered events are uploaded, by an
account that can write to nothing else. Nothing in this path runs in the
cluster.

```bash
# once: rem2ics (the converter) and the remind CLI it shells out to
uv tool install remind          # provides rem2ics; requires `remind` >= 04.00.00 on PATH

# nightly (cron / systemd timer), password read from 1Password rather than argv
op run --env-file ~/.config/remind-caldav.env -- \
  python3 scripts/remind-to-caldav.py --reminders ~/.reminders --months 24
```

with `~/.config/remind-caldav.env` holding:

```
REMIND_CALDAV_URL=https://calendar.waltr.tech
REMIND_CALDAV_USER=remind-export
REMIND_CALDAV_PASSWORD=op://home-ops/radicale-secret/remind-export
```

Useful flags: `--dry-run` (print the plan, change nothing), `--reset` (delete
everything in the feed first — the recovery path if a resource is ever written
into that collection by hand), `--collection` and `--months` (default 24 months
forward from rem2ics' start date, 12 weeks back).

Behaviour worth knowing before trusting it:

- **One resource per event.** RFC 4791 §4.1 requires every `VEVENT` in a calendar
  object resource to share a UID, and Radicale enforces it (a multi-event `.ics`
  is rejected with HTTP 400, `Multiple VEVENT components with different UIDs`).
  So the script splits rem2ics' output, names each resource after its UID, copies
  the `VTIMEZONE` blocks into each one, and deletes resources the current export
  no longer produces — removing a line from `.reminders` removes the event.
- **`--startdate` takes an absolute date, not an offset.** rem2ics parses it with
  dateutil (so `-4w` fails): `--startdate=$(date -d '-4 weeks' +%F)`. Plain
  `--months 24` is usually what you want.
- **Lossy on purpose.** The conversion renders reminders in their evaluated form:
  `OMIT` / `TRIGGER` / `BEFORE` / `SKIP` / `PUSH-OMIT-CONTEXT` are flattened, the
  `%"summary%description"` MSG form is passed through as literal text rather than
  parsed into summary+description, recurrence rules survive only for daily and
  weekly events, and the feed is a snapshot of the requested window (a birthday
  reminder more than 24 months out is simply not there yet).

## Not done, and why

- **mTLS** — technically possible at Cloudflare's edge (Cloudflare-managed CA,
  mTLS header forwarding to origin via Transform Rules), but iOS Calendar.app
  cannot present a client certificate: Apple's CalDAV payload has exactly seven
  fields and none of them is one, and there is no cert picker in the account UI.
  DAVx⁵ supports client certs, so Android alone would have worked. The only
  Radicale-side bridge would be `http_x_remote_user`, which _disables_ Radicale's
  own authentication and trusts a header — with a second (in-cluster) route to
  the same pod, anything on the LAN could forge it.
- **CardDAV / contacts** — not configured. Radicale can render birthdays from a
  CardDAV address book's `BDAY` fields (sharing conversion `bday`), but the Remind
  feed already covers birthdays, and nobody asked for contact sync.
- **OAuth/LDAP/IMAP/PAM auth** — needs an identity provider this cluster does not
  run; upstream also notes OAuth2 is not usable by CalDAV clients directly.
- **Tailscale-only exposure** — the host already runs tailscaled, and a
  tailnet-only endpoint would give device-identity auth that works on iOS. Not
  chosen: a public hostname with per-account passwords was acceptable, and it
  keeps the phones free of a VPN client.

## Verification (what was actually tested, 2026-09-29)

Against **radicale 3.8.1** — the pinned digest — running the committed `config`
and `bootstrap.sh` locally, seeded exactly as the init container seeds it:

- store seeded by hand, no management-API calls: `sam` discovers `Sam`, `Family`
  and `Remind (read-only)`; `PROPFIND` on `rwaltr/calendar` as `sam` → 403;
- `sam` PUTs an event into `Family`, `rwaltr` reads it back through his own path;
  the `home-assistant` account does the same; `calendar-query` REPORT returns both;
- `sam` PUT into the read-only feed → 403 (the seed's permission column is what
  enforces this), while `remind-export` can write and both humans can read;
- `.well-known/caldav` redirects to the principal;
- `.Radicale.props` JSON and the `sharing.csv` rows in `bootstrap.sh` are
  byte-for-byte what `MKCOL` / `POST /.sharing/v1/map/create` write;
- `scripts/remind-to-caldav.py` end to end against a live server: reset, publish
  (one resource per event), idempotent re-run (no spurious deletes), stale event
  removed, feed enforced read-only for the other account. Remind 05.x was built
  from source for the test; rem2ics' output is a single multi-event `.ics`, which
  is why the splitter exists.
- `helm template` renders the Deployment/Service/HTTPRoute/PVC from the committed
  values and the probes resolve to `/.web/` (200 unauthenticated; `/` is a 302).

Not tested: a real phone client over the tunnel, and the HA CalDAV config flow
(both need the environment, not the manifests).

### Verified live in the cluster (2026-09-30)

Deployed end to end on `mouse` — the pinned digest, the committed values and the
real 1Password item — covering what the local run could not:

- init container logged `generated 4 htpasswd entries: home-assistant,
  remind-export, rwaltr, sam`, and the app container has no
  `/etc/radicale-passwords` at all: the plaintext Secret never reaches it;
- all four accounts authenticate (`PROPFIND` → 207, wrong password → 401);
- discovery by PROPFIND `Depth: 1` matches the collections table for every
  principal — `rwaltr` → `Rwaltr`/`Family`/`Remind (read-only)`, `sam` →
  `Sam`/`Family`/`Remind (read-only)`, `home-assistant` →
  `Family`/`Remind (read-only)`;
- `sam` PUT into `Family` → 201, `rwaltr` GET through his own path → 200 with the
  body intact, `home-assistant` → 200; `sam` PROPFIND on `rwaltr/calendar` → 403;
- read-only feed: `rwaltr` PUT → 403, `remind-export` PUT → 201, `sam` GET → 200;
- through `envoy-internal` over TLS: `/.web/` → 200, authenticated `/` → 302,
  PROPFIND `/sam/` → 207; the public `https://calendar.waltr.tech/.web/` → 200
  through the cloudflare tunnel.

This deploy is also what exposed the credential drift: the item's note held a
bcrypt blob that matched none of its four password fields, so every client got a
401. That failure is the reason the file is generated rather than stored.

## Cautions for whoever touches this next

- **Re-verify the seed before bumping the image tag.** `bootstrap.sh` writes
  Radicale's own storage formats (`.Radicale.props`, `sharing.csv` column order and
  `True`/`False` spelling). A wrong byte here does not crash — the share silently
  never appears.
- **The four passwords live in the `radicale-users` Secret in cleartext.** That is
  the price of generating the htpasswd instead of hand-maintaining it. Mount it
  nowhere but the init container (the `advancedMounts` in `helmrelease.yaml`), and
  never copy one into a manifest — `git grep` for the passwords should stay empty.
- **The PVC name is pinned with `forceRename` on purpose.** app-template names a
  _lone_ PVC plainly `<fullname>` and only suffixes the key once a second PVC
  exists; without the pin, a chart refactor could rename it and orphan the data.
- **`permit_create_map: true`** lets any authenticated account create shares of
  its own collections (from the WebUI). Turn it off if the shares should be
  seed-only.
- **Passwords are the only gate on a public hostname.** No rate limiting is
  configured beyond Radicale's `delay_on_error`; anyone can reach the login page.
  The accounts are what matter, so keep them long and random.
- A restored PVC only needs the init container to fill in whatever is missing —
  it never rewrites existing collections, so a restore cannot be clobbered by a
  later deploy.
