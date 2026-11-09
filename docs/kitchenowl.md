# KitchenOwl (groceries + recipes)

Shared shopping list and recipe manager for the household: real-time sync across
phones, meal plans, expense tracking, and web-recipe import. One image — the
Flutter web build, the Flask API, and a Celery worker all live in
`tombursch/kitchenowl`.

## Why it is the cheapest AI win in the cluster

KitchenOwl calls the **LiteLLM Python library directly**, so it needs no adapter
and no sidecar to use the cluster's gateway:

```
recipe URL → uwsgi [web] :8080 → Flask :5000
                                     │
                     LLM_MODEL=openai/deepseek-v4.1-flash
                     LLM_API_URL=http://litellm.default.svc.cluster.local:4000/v1
                                     │
                                     └─→ litellm :4000 ──→ OpenRouter
                                     ↑ OPENAI_API_KEY ← 1P item `litellm`/`master_key`
```

The `openai/` prefix is a **client-side routing hint**: the library strips it and
POSTs `{"model": "deepseek-v4.1-flash"}` to `LLM_API_URL`, where
`deepseek-v4.1-flash` is a LiteLLM _alias_ from the `litellm-config`
ConfigMap — not an OpenAI model. The library then picks the credential from the
provider prefix, which is why the `openai/…` model needs `OPENAI_API_KEY` set
to the LiteLLM master key (same value hermes uses as `LITELLM_API_KEY`).

Two features turn on together: LLM ingredient parsing (better than the bundled
English-trained NLP parser, and it translates ingredient names into the
household language) and the AI recipe generator
(`LLM_RECIPE_GENERATION=false` disables the second).

**Failure is safe.** `parseIngredientsStream` wraps the LLM call in
`try/except` and falls through to the local `ingredient-parser` model, so a
gateway outage degrades the feature instead of breaking recipe import. That is
the whole reason wiring it is low-risk.

`KITCHENOWL_MCP_ENABLED=true` exposes the built-in MCP endpoint at `/mcp`
(uwsgi's `[web]` route excludes `/mcp` from the SPA static-map, so it reaches
Flask). It is available for an agent to add/read list items; nothing consumes it
yet.

## Manifests

`infra/k8s/kyz/apps/default/kitchenowl/` — `ks.yaml` plus `app/`
(HelmRelease, OCIRepository, ExternalSecret, kustomization). Registered in
`apps/default/kustomization.yaml`.

| Piece    | Value                                                                    |
| -------- | ------------------------------------------------------------------------ |
| Image    | `docker.io/tombursch/kitchenowl:v0.8.1` (digest pinned)                  |
| Chart    | shared `app-template` `5.2.1`                                            |
| Port     | 8080 (uwsgi `[web]`; `:5000` is the internal socket, not on the Service) |
| User     | `1000:1000` — the `kitchenowl` user the image creates                    |
| Root FS  | **writable** (see below)                                                 |
| State    | PVC `kitchenowl-data` (5Gi) → `/data`                                    |
| Backup   | kopiur component, `H 15 * * *`                                           |
| Exposure | `envoy-internal` only — **not published**                                |

### Two deviations from the house defaults, both deliberate

- **`readOnlyRootFilesystem: false`.** `entrypoint.sh` does `sed -i` on
  `wsgi.ini` when `/proc/net/if_inet6` is missing (the sockets bind `[::]`),
  and uwsgi's `smart-attach-daemon` writes `/tmp/celery.pid` for Celery. Under
  `set -e` a failed sed exits the container before uwsgi starts. Same call as
  freshrss, whose entrypoint is also self-modifying.
- **Probes hit `/api/health/<token>`, not `/`.** uwsgi's static-map serves
  `index.html` for any extensionless path, so a probe on `/` returns 200 even
  with Flask down — it would report healthy forever while the API was dead.

## Required secret

```sh
openssl rand -base64 48
op item create --vault home-ops --category "API Credential" \
  --title kitchenowl jwt_secret_key="<value>"
```

The image ships `JWT_SECRET_KEY` as the literal `PLEASE_CHANGE_ME` — a signing
key every deployment in the world shares. Refresh tokens are valid 30 days
(`JWT_REFRESH_TOKEN_EXPIRES`), so that is a session-forgery path, not a
formality. The ExternalSecret also maps the LiteLLM master key to
`OPENAI_API_KEY`.

## First run — the registration flip

KitchenOwl gates signup at the **route-registration** level, not with a flag
inside the handler:

```python
if OPEN_REGISTRATION and not DISABLE_USERNAME_PASSWORD_LOGIN:
    @auth.route("/signup", ...)
```

With `OPEN_REGISTRATION=false` the endpoint does not exist, and there is no
management command that creates a user (`manage.py` only does jobs and mail). So:

1. `OPEN_REGISTRATION` ships as `"true"`. Open
   `https://kitchenowl.waltr.tech`, sign up, and create the household.
2. Flip it to `"false"` in the HelmRelease and commit. The pod rolls itself and
   the signup route disappears again.

Until step 2 the signup form is reachable by anyone on the LAN.

## Backup and restore

Same shape as HomeBox: `/data/database.db` plus `/data/upload`. The kopiur
mover reads the live PVC, so the SQLite copy is crash-consistent — restore is a
PVC restore and a pod roll. Note the Celery worker shares the container and the
DB; there is no separate queue to restore.
