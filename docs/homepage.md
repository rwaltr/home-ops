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

**Currently annotated:** everything user-facing, grouped by what the thing is
rather than where it runs — Media (Jellyfin, Navidrome, Seerr), Media Ops (Radarr,
Sonarr, Prowlarr, Bazarr, SABnzbd, Unmanic, slskd), Smart Home (Home Assistant,
Zigbee2MQTT, Z-Wave JS UI, ESPHome, go2rtc), Household (HomeBox, KitchenOwl,
Radicale), Photos (Immich), Reading (FreshRSS), AI (LiteLLM, Hermes), Comms
(Matrix, Element), Monitoring (Grafana, Prometheus, Alertmanager), Tools
(degoog).

Three of those are annotated in git but **inert**, because their apps are
commented out of `apps/default/kustomization.yaml` and so have no HTTPRoute to be
discovered: `slskd`, `go2rtc`, and `music-assistant` (off since 2026-10-11). They
appear the moment those `ks.yaml` lines are uncommented. Three others are
deliberately **not** annotated and should not be: `tesla.waltr.tech` (a static
`.well-known` key file for Tesla's Fleet verifier), `flux-receiver.waltr.tech`
(a webhook POST endpoint) and `konflate`. Homepage does not list itself.

### Verifying what was actually discovered

Do not trust the manifest — ask Homepage what it resolved, from inside the pod:

```bash
kubectl exec -n default deploy/homepage -c app -- \
  wget -qO- http://localhost:3000/api/services | jq -r '.[] | "\(.name): \([.services[].name] | join(", "))"'
```

It returns **groups**, not services — `.[]` is a group. Two failure modes look
perfectly fine in git and only show up here:

- **A route something else generates for you.** Grafana's HTTPRoute is created by
  the Grafana operator, and the CRD embeds the route's _spec_ but not its metadata.
  The annotations therefore live somewhere else, and putting them beside the spec
  is rejected outright:

  ```yaml
  httpRoute:
    metadata: # NOT spec.annotations — the CRD declares no such field
      annotations:
        gethomepage.dev/enabled: "true"
    spec:
      hostnames:
        - grafana.waltr.tech
  ```

  This surfaces as a server-side dry-run failure on the `grafana-instance`
  Kustomization — which is a _separate_ Kustomization from `grafana-operator`, so
  most of o11y keeps reporting Ready while that one is stuck, and the existing
  Grafana object stays up because a failed apply never prunes.

- **An app that is disabled.** Annotating a route in git accomplishes nothing if
  the app is commented out of the parent `kustomization.yaml`; there is no
  HTTPRoute in the cluster to discover. `slskd`, `go2rtc` and `music-assistant`
  are in exactly this state, so their groups will look thinner than the git diff
  suggests.

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

## The top strip comes from Prometheus, not from Kubernetes

Homepage's built-in `kubernetes` and `resources` info widgets read the
`metrics.k8s.io` API. **This cluster has no metrics-server** — the only metrics
workload is `kube-state-metrics`, which feeds Prometheus, not that API — so those
widgets rendered `API Error` on every refresh: three failing blocks, ~14 log
lines per 45 seconds, while `kubectl top nodes` failed for the same reason.

Rather than add a metrics-server for a dashboard ornament, the strip queries the
Prometheus that is already here (the same source Grafana reads):

```yaml
- customapi:
    url: http://kube-prometheus-stack-prometheus.o11y.svc.cluster.local:9090/api/v1/query
    method: POST
    headers:
      Content-Type: application/x-www-form-urlencoded
    requestBody: 'query=1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))'
    mappings:
      - field: data.result.0.value.1
        label: used
        format: percent
```

Three details make this work, and all three are easy to get wrong:

- **POST with a form body.** PromQL in a GET query string has to be
  percent-encoded and stops being reviewable in git. The generic proxy sends a
  _string_ `requestBody` verbatim — but an **object** `requestBody` is
  `JSON.stringify`'d, which Prometheus rejects. It has to be a string.
- **`data.result.0.value.1`.** shvl splits on `[.[\]]+`, so numeric path segments
  index the Prometheus response's arrays. That is the only reason a vector
  response is readable at all.
- **`format: percent` multiplies by 100** (Intl percent style), so the queries
  return a 0–1 ratio and must _not_ include `* 100`. Adding it renders 1080%.

A third widget does the same for disk IOPS:

```promql
sum(rate(node_disk_reads_completed_total[5m]) + rate(node_disk_writes_completed_total[5m]))
```

It sums every block device, to match the cluster-wide CPU and RAM above, and uses
`format: number` because IOPS is a count rather than a ratio. Knowing the split
matters before reading anything into the number: the Kingston NVMe behind
`openebs-hostpath` does ~150 IOPS where the entire 6-disk `tank` pool does ~24, so
"cluster" IOPS is mostly an NVMe number. For the pool alone, filter the devices:
`{device=~"sd[a-f]"}`.

Adding a fourth is one more `customapi` entry with a new `requestBody`; per-pod
memory would mean querying cadvisor metrics, which kube-prometheus-stack already
scrapes from the kubelet.

### The same missing API also breaks per-service stats

The other half of this problem is not in `widgets.yaml` and cannot be fixed there.
Kubernetes discovery sets `app` and `namespace` on **every** service it finds
(`constructedServiceFromResource()` in `resource-helpers.js`), and a service card
renders a Kubernetes stats block whenever `service.app` is set. There is nothing
to configure and no annotation to opt out:

- `app` falls back to the HTTPRoute's name when the annotation is empty, so it
  cannot be blanked — `gethomepage.dev/app: ""` is falsy and gets replaced.
- The block is collapsed and **not rendered** until the stats button on a card is
  clicked, so it is silent by default. Clicking a discovered service's stats
  button will show the metrics-server error.
- Setting `showStats: true` in `settings.yaml` would expand it for every service
  and make that error permanent.

So the choices for per-service stats are a metrics-server, or replacing discovery
with static `services.yaml` entries (which carry no `app`/`namespace` and so
request nothing). Neither is worth doing for a CPU number on a homelab card.

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
