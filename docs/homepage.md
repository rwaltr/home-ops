# Homepage (service dashboard)

One page for everything in the cluster, plus the few things that are not. It
replaces nothing directly — there was no dashboard before this — and it sits
alongside Grafana, which answers "is it healthy" rather than "where is it".

```
browser ── HTTPS → k8s-gateway DNS → envoy-internal ──→ homepage:3000
           (homepage.waltr.tech, on-LAN only — NO envoy-external parentRef)
                              │
                              └── GET/LIST via the pod's service account token
                                    ├─ gateway.networking.k8s.io/httproutes   ← the app list
                                    ├─ ""/pods, ""/nodes + metrics.k8s.io     ← the CPU/RAM widgets
                                    └─ apiextensions.k8s.io/customresourcedefinitions (get only)
```

## Discovery is opt-in, not automatic

This is the thing to understand before adding a service. Homepage does **not**
list every HTTPRoute in the cluster. It lists HTTPRoutes carrying
`gethomepage.dev/enabled: "true"`:

```yaml
route:
  app:
    annotations:
      gethomepage.dev/enabled: "true"
      gethomepage.dev/name: Jellyfin
      gethomepage.dev/description: Movies & TV
      gethomepage.dev/group: Media
      gethomepage.dev/icon: jellyfin.png
    hostnames:
      - jellyfin.waltr.tech
```

| Annotation            | Notes                                                                 |
| --------------------- | --------------------------------------------------------------------- |
| `enabled`             | Required. Without it the route is invisible.                          |
| `name`                | Display name.                                                         |
| `group`               | Section heading; discovered groups render above `services.yaml` ones. |
| `description`, `icon` | Cosmetic. Icons come from the bundled set or a URL.                   |
| `weight`              | Optional ordering within a group.                                     |
| `href`                | **Omitted** for HTTPRoutes — the hostname is used.                    |
| `widget.*`            | Optional widget, e.g. `gethomepage.dev/widget.type: "jellyfin"`.      |

Annotating in git next to the route is the whole point: a service cannot appear
on the dashboard without someone deciding it should, and the review happens in
the same commit as the service.

**Currently annotated:** Jellyfin, Navidrome, FreshRSS, HomeBox, KitchenOwl.
Everything else is one annotation block away — `services.yaml` is the wrong place
for a cluster service.

## The RBAC prerequisite upstream does not mention

Homepage probes for the HTTPRoute CRD before enabling Gateway discovery
(`src/utils/config/kubernetes.js` → `checkCRD` →
`readCustomResourceDefinitionStatus`). A 403 there is caught, logged, and treated
as "CRD absent" — Gateway discovery then silently switches itself off and the
dashboard comes up with only the static `services.yaml` entries.

The ClusterRole published upstream does **not** grant `apiextensions.k8s.io`, so
`rbac.yaml` adds exactly one rule beyond upstream:

```yaml
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get"]
```

If the dashboard ever goes empty after a change, check for
`Error checking if CRD httproutes.gateway.networking.k8s.io exists` in the logs
before suspecting the annotations.

## Manifests

`infra/k8s/kyz/apps/default/homepage/` — `ks.yaml` plus `app/` (HelmRelease,
OCIRepository, ConfigMap, ClusterRole/Binding, kustomization). Registered in
`apps/default/kustomization.yaml`. **No PVC and no kopiur component**: every
config file is a ConfigMap and the only writable path is an emptyDir for logs.

| Piece    | Value                                                                |
| -------- | -------------------------------------------------------------------- |
| Image    | `ghcr.io/gethomepage/homepage:v2.7.0` (digest pinned)                |
| Chart    | shared `app-template` `5.2.1` — Homepage only ships community charts |
| Port     | 3000 (`/api/healthcheck` = the image's own HEALTHCHECK target)       |
| User     | `1000:1000`, read-only root FS, logs to emptyDir + stdout            |
| RBAC     | read-only ClusterRole (no write verbs anywhere)                      |
| Backup   | none needed — state is the git repo                                  |
| Exposure | `envoy-internal` only — **not published**                            |

Two non-obvious requirements, both commented inline:

- **`automountServiceAccountToken: true`.** Every other app here sets `false`.
  `mode: cluster` reads that token; without it Homepage cannot list anything.
- **The pod IP must be in `HOMEPAGE_ALLOWED_HOSTS`.** The kubelet probe reaches
  `:3000` by pod IP and the Host check runs on every request, so the value is
  `"$(MY_POD_IP):3000,homepage.waltr.tech"`. That `$(...)` reference needs
  `dependsOn: MY_POD_IP` on the same env entry, and the reason is not obvious:
  app-template renders an env **map** in alphabetical order, so
  `HOMEPAGE_ALLOWED_HOSTS` (H) renders before `MY_POD_IP` (M), the reference never
  expands, and the probe fails host validation with a 400 while the site itself
  works perfectly in a browser. `dependsOn` triggers the chart's Kahn sort.

  The symptom is worth memorising, because it is easy to misread as a routing
  fault: `Startup probe failed: HTTP probe failed with statuscode: 400` in the
  events, `Host validation failed for: 10.244.x.x:3000` in the logs, and
  `curl https://homepage.waltr.tech` returning a healthy 200 the whole time.

## Adding things that are not in the cluster

`services.yaml` in the ConfigMap is for exactly this — the router, Cloudflare,
SaaS dashboards. Two mechanisms beyond a plain link:

```yaml
- RouterOS:
    icon: mikrotik.png
    href: http://10.10.0.1/
    description: Edge router
    siteMonitor: http://10.10.0.1/ # HTTP HEAD→GET, shows latency
    ping: 10.10.0.1 # real ICMP, IPv4 only
```

`siteMonitor` does **not** authenticate, so for anything behind a login it
reports the login page's status, not the service's health. `bookmarks.yaml` is
the lighter list for links that need neither widgets nor a status check.

For an external thing with an API, `customapi` maps dotted JSON paths to fields:

```yaml
widget:
  type: customapi
  url: https://app.terraform.io/api/v2/account/details
  headers:
    Authorization: Bearer {{HOMEPAGE_VAR_TF_CLOUD_TOKEN}}
  mappings:
    - field: data.attributes.username
      label: Account
```

## Secrets

Never put a widget API key in the ConfigMap. Env vars prefixed `HOMEPAGE_VAR_`
substitute into any config file as `{{HOMEPAGE_VAR_XXX}}`:

1. Add an `ExternalSecret` mapping the 1Password field to a secret key named
   `HOMEPAGE_VAR_TF_CLOUD_TOKEN`.
2. `envFrom` that Secret in the HelmRelease.
3. Reference `{{HOMEPAGE_VAR_TF_CLOUD_TOKEN}}` in the widget.

`HOMEPAGE_FILE_XXX` does the same with a mounted file's _contents_, which suits
docker-style secret files.

## MCP endpoint

Homepage ships one, and it is **off**. Turning it on
(`HOMEPAGE_MCP_ENABLED: "true"`) exposes `/api/mcp` so an assistant can inspect
and — with writes allowed — edit these config files.

Think before enabling it: the token grants read access to **every configured
service credential** and, with writes enabled, control of `custom.js`, which runs
in every browser that loads the dashboard. It requires `HOMEPAGE_MCP_TOKEN` of at
least 32 characters whenever Homepage auth is off, which it currently is.

## Gotchas

- **A missing ConfigMap key is a startup error, not a blank page.** Homepage
  copies a default into place for any config file it cannot find, and
  `/app/config` is read-only, so the copy fails with
  `EROFS: read-only file system, copyfile '/app/src/skeleton/<file>'`.

  The file list is not something to reason about — it is upstream's
  `src/skeleton` directory, and it is **nine** files: `kubernetes.yaml`,
  `services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `settings.yaml`,
  `docker.yaml`, `proxmox.yaml`, `custom.css`, `custom.js`. Each one must be
  both a ConfigMap key _and_ a mount. `proxmox.yaml` is the easy one to miss
  because nothing here uses Proxmox.

- **Discovered services render above `services.yaml` ones**, with no rigid
  ordering between discovered groups. `weight` is the only lever.
- **One widget per discovered service.** Multiple widgets are documented as
  unsupported with annotation-based discovery, so anything wanting several
  widgets needs a static `services.yaml` entry instead.
- **`settings.yaml` is deliberately empty** — it is validated, so inventing keys
  risks an error banner. Theme and layout belong there when wanted.
