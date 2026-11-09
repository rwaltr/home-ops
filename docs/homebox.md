# HomeBox (home inventory)

Inventory of everything in the house — items, locations, labels, photos, custom
fields, and the maintenance reminders that ride on them. Written in Go against
SQLite with an embedded UI: the whole thing idles under ~50MB, which is why it
is the cheapest app in the cluster that is actually useful.

## Deploy the fork, not upstream

|                          |                                                                                                            |
| ------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `hay-kot/homebox`        | **archived 2024-06-11.** The repo most search results point at. Dead.                                      |
| `sysadminsmedia/homebox` | Active continuation; serves `homebox.software` and is where 0.26+/0.27 land. **This is what is deployed.** |

Everything below assumes the fork. Version drift between the two is real: the
API-key endpoints and the newer entity model exist only in the fork, and the
older docs still describe the archived layout.

## Shape

```
browser ── HTTPS → k8s-gateway DNS → envoy-internal ──→ homebox:7745
           (homebox.waltr.tech, on-LAN only — NO envoy-external parentRef)

/data/  ← PVC `homebox-data` (5Gi, openebs-hostpath)
  homebox.db      SQLite, WAL      ← the entire application state
  <attachments>   item photos, generated labels
```

`HBOX_STORAGE_CONN_STRING` is `file:///` with
`HBOX_STORAGE_PREFIX_PATH=data`, and `HBOX_DATABASE_SQLITE_PATH` is
`/data/homebox.db` — so both the DB and every attachment resolve under the
`/data` mount. That is what makes `readOnlyRootFilesystem: true` safe here:
nothing outside `/data` is written.

## Manifests

`infra/k8s/kyz/apps/default/homebox/` — `ks.yaml` plus `app/` (HelmRelease,
OCIRepository, ExternalSecret, kustomization). Registered in
`apps/default/kustomization.yaml`.

| Piece    | Value                                                               |
| -------- | ------------------------------------------------------------------- |
| Image    | `ghcr.io/sysadminsmedia/homebox:0.27.1-rootless` (digest pinned)    |
| Chart    | shared `app-template` `5.2.1`                                       |
| Port     | 7745 (`/api/v1/status` — the image's own HEALTHCHECK path, no auth) |
| User     | `65532:65532` — the `homebox` user the `-rootless` tag creates      |
| Root FS  | read-only; only `/data` is writable                                 |
| State    | PVC `homebox-data` (5Gi) → `/data`                                  |
| Backup   | kopiur component, `H 14 * * *`, `KOPIUR_RUNAS=65532`                |
| Exposure | `envoy-internal` only — **not published**                           |

`KOPIUR_RUNAS=65532` is not optional: the mover has to read the SQLite file as
the same uid that owns it. A default-UID mover fails with EACCES, which surfaces
as a failed snapshot rather than a permission error.

## Required secret (blocks first boot)

`HBOX_AUTH_API_KEY_PEPPER` is **required** and the binary refuses to start if it
is shorter than 32 bytes, so until the item exists the pod sits in
CrashLoopBackOff — that is expected, not a broken manifest.

```sh
openssl rand -base64 48   # → paste into the field below
op item create --vault home-ops --category "API Credential" \
  --title homebox api_key_pepper="<value>"
```

**Never rotate it.** The pepper is HMAC'd into every stored API-key hash, so
changing it silently invalidates every issued key with no error to point at.

## Accounts and invitations

The owner account was created through open self-registration, and
`HBOX_OPTIONS_ALLOW_REGISTRATION` is now **`"false"`** — the signup form is no
longer served.

That is not a "no more users" switch, and HomeBox has no admin "add user" form.
What it has is **collection invites**, which sit outside the account system:

> **Collection → Invites** tab → create invite → share the token.

Invite creation is `POST /groups/invitations` (owner-only) and takes two fields:

| Field       | Notes                                                          |
| ----------- | -------------------------------------------------------------- |
| `uses`      | 1–100, enforced by the modal (`invite_create_modal` toast).    |
| `expiresAt` | Defaults to **24h** when unset; expired rows are hidden in UI. |

An already-registered person joins with `POST /groups/invitations/{id}`; a new
person registers **with the invite's group token**. Invites keep working with
signup closed, and that is deliberate rather than a gap in the flag:

```go
// backend/app/api/handlers/v1/v1_ctrl_user.go
if !ctrl.allowRegistration && regData.GroupToken == "" {
```

Registration is refused only when there is _also_ no group token, so the invite
is the intended exception to the closed door.

Group roles: `PUT /groups` and `DELETE /groups/members/{id}` are **owner-only**,
the read endpoints are member-accessible. Everyone in a group shares one
inventory — two groups are two separate inventories, not two views of one.

## API keys are the integration surface

Profile → API Keys issues `hb_…` tokens, one-time visible. That token is how
both AI integrations authenticate:

- **homebox-companion** — photo in, structured item out (vision model extracts
  name, quantity, serial, price). Uses the LiteLLM _library_, so it needs
  `HBC_LLM_API_BASE` pointed at the gateway and a **vision-capable** model in
  `litellm-config`'s `model_list` — the gateway currently has none.
- **homebox-mcp** — inventory Q&A / intake over MCP, for the in-cluster agent.

Both are deliberately **not** deployed here. Also available but unused: the
external label service hook (`HBOX_LABEL_MAKER_LABEL_SERVICE_URL`, an HTTP GET
that returns an image) and Shoutrrr notifiers for maintenance reminders.

## Backup and restore

The kopiur component snapshots the live PVC (`copyMethod: Direct` — there is no
CSI snapshot on openebs-hostpath), so the copy is crash-consistent, not
point-in-time. SQLite is in WAL mode with `busy_timeout`, and the mover runs at
a quiet hour, so restore is a PVC restore plus a pod roll. A restore needs no
schema step: the DB is the app.
