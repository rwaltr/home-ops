# Container memory requests (node `mouse`)

Right-sizing the `requests.memory` of every workload on the single-node cluster.
Tracking issue: [rwaltr/home-ops#896](https://github.com/rwaltr/home-ops/issues/896).
The values live in each app's HelmRelease under
`controllers.<controller>.containers.<container>.resources` (bjw-s `app-template`)
or the chart's own resource key.

## The constraint

|                                           |                                        |
| ----------------------------------------- | -------------------------------------- |
| Node `mouse` memory                       | 32 GiB physical (31.06 GiB `MemTotal`) |
| `kube_node_status_allocatable`            | 30.97 GiB                              |
| Committed **requests** before this change | **28.58 GiB (92%)**                    |
| Actually in use                           | ~15.2 GiB                              |
| Swap                                      | none — only a 4 GiB zram backstop      |

Requests, not actual use, are what the scheduler counts. A node that is 92%
committed on paper while half its memory is idle is a node that refuses new
workloads and forces every scale-up to be argued for. The requests here had
drifted into both directions: 20 pods were holding 13.5 GiB they never touched,
and 35 pods (including 15 with **no request at all**, i.e. BestEffort) were
under-provisioned relative to what they actually run.

## Method

Prometheus is reachable from inside the cluster over service DNS — no
port-forward is available on this node:

```
curl "http://kube-prometheus-stack-prometheus.o11y.svc.cluster.local:9090/api/v1/query?query=<promql>"
```

```promql
# committed request, per container
kube_pod_container_resource_requests{resource="memory", node="mouse"}

# observed working set, per container
quantile_over_time(0.95, container_memory_working_set_bytes{node="mouse", container!="", container!="POD"}[30d])
quantile_over_time(0.99, container_memory_working_set_bytes{node="mouse", container!="", container!="POD"}[30d])
max_over_time(        container_memory_working_set_bytes{node="mouse", container!="", container!="POD"}[30d])
```

Rules applied:

1. **30-day window, percentile not max.** The retention is 30d, so a `[30d]`
   range is the whole Prometheus lifetime (~25 days at the time of the audit).
   7d was explicitly rejected — a single monthly job would otherwise become the
   request.
2. **`request = ceil(p99 × 1.25)`**, rounded to a tidy binary size — 20-30%
   headroom, because a request is not a target.
3. **Bursty batch workloads are sized from p90/p95, not p99.** Where the p99 is
   more than ~2× the p90 (usenet unpack, video re-encode), the request covers
   the bulk of the distribution and the memory **limit** stays the ceiling for
   the spike. Reserving a 5 GiB transient for 100% of the time is how the node
   got into this state.
4. **A request is never set equal to its limit.** `request == limit` forces
   Guaranteed QoS (`oom_score_adj: -997`), which makes the pod the _last_ one
   killed under pressure and removes its ability to burst. Several pods were
   silently Guaranteed-by-default because they declared a limit and no request
   (Kubernetes copies the limit into the request), so this change adds explicit
   requests below the limits.
5. **Request ≤ 75% of the limit.** Where the sized request collided with the
   limit (`litellm` app, `konflate`), the limit moved up too.
6. **Memory only.** No CPU value is touched here; CPU shares and memory are
   different mechanisms with different answers.

Aggregation pitfall: `sum(max_over_time(...))` across series reports a peak no
container reached (restarted containers and cgroup churn leave duplicate
series). Use `max by (namespace, pod, container)(...)`. Per-pod peaks are also
**not simultaneous**, so they must not be summed into a node figure.

## Per-container changes

`request before` is the live value (equal to the limit where Kubernetes
defaulted it). Percentiles are 30d working set.

| pod                                                 | container                   | request before | 30d p95 | 30d p99 | 30d max | request after | limit after |
| --------------------------------------------------- | --------------------------- | -------------- | ------- | ------- | ------- | ------------- | ----------- |
| `cert-manager-55bd95d9c5-45pnr`                     | cert-manager-controller     | -              | 41Mi    | 41Mi    | 42Mi    | **64Mi**      | 256Mi       |
| `cert-manager-cainjector-649f9b85d4-htdc5`          | cert-manager-cainjector     | -              | 82Mi    | 82Mi    | 82Mi    | **128Mi**     | 256Mi       |
| `cert-manager-webhook-55589c7495-2g74t`             | cert-manager-webhook        | -              | 28Mi    | 28Mi    | 29Mi    | **64Mi**      | 256Mi       |
| `cert-manager-webhook-55589c7495-pp7p7`             | cert-manager-webhook        | -              | 26Mi    | 26Mi    | 27Mi    | **64Mi**      | 256Mi       |
| `bazarr-567d68d488-q7lss`                           | app                         | 250Mi          | 310Mi   | 320Mi   | 334Mi   | **448Mi**     | 1024Mi      |
| `degoog-8465cb75bd-d7dp9`                           | app                         | 128Mi          | 230Mi   | 240Mi   | 264Mi   | **320Mi**     | 1024Mi      |
| `esphome-684597479c-85zw4`                          | app                         | 256Mi          | 106Mi   | 106Mi   | 144Mi   | **128Mi**     | 3072Mi      |
| `hermes-c6ccc9bdb-58tt9`                            | app                         | 512Mi          | 710Mi   | 1139Mi  | 1343Mi  | **1536Mi**    | 4096Mi      |
| `hermes-c6ccc9bdb-58tt9`                            | gitcreds                    | -              | 35Mi    | 39Mi    | 50Mi    | **64Mi**      | 256Mi       |
| `home-assistant-67b87677b4-z7wp2`                   | app                         | 2048Mi         | 669Mi   | 685Mi   | 717Mi   | **1024Mi**    | 2048Mi      |
| `immich-postgres-6c9dfd994d-wg9xj`                  | postgres                    | 512Mi          | 245Mi   | 342Mi   | 442Mi   | **448Mi**     | 2048Mi      |
| `immich-server-64597b6fd6-6pndz`                    | app                         | 512Mi          | 1082Mi  | 1396Mi  | 1709Mi  | **1792Mi**    | 4096Mi      |
| `jellyfin-f6777b8c5-8lbzh`                          | app                         | 4096Mi         | 1065Mi  | 1140Mi  | 1518Mi  | **1536Mi**    | 4096Mi      |
| `litellm-597f4c978b-lrjch`                          | app                         | 256Mi          | 496Mi   | 496Mi   | 506Mi   | **640Mi**     | 1024Mi      |
| `litellm-597f4c978b-lrjch`                          | ollama                      | 2500Mi         | 17Mi    | 17Mi    | 30Mi    | **512Mi**     | 4096Mi      |
| `litellm-597f4c978b-lrjch`                          | speaches                    | 1024Mi         | 159Mi   | 159Mi   | 210Mi   | **256Mi**     | 2048Mi      |
| `matter-server-7cddb59bfc-rllzf`                    | app                         | 512Mi          | 99Mi    | 111Mi   | 172Mi   | **192Mi**     | 512Mi       |
| `mosquitto-799c885f9c-zfwv2`                        | app                         | 128Mi          | 6Mi     | 6Mi     | 6Mi     | **32Mi**      | 128Mi       |
| `music-assistant-7db5789d-cn77p`                    | app                         | 2048Mi         | 266Mi   | 286Mi   | 372Mi   | **384Mi**     | 2048Mi      |
| `otbr-5d674d8c6-sw2xk`                              | app                         | 256Mi          | 10Mi    | 10Mi    | 11Mi    | **32Mi**      | 256Mi       |
| `prowlarr-55cbb4b65-zhb4c`                          | app                         | 1024Mi         | 144Mi   | 150Mi   | 157Mi   | **192Mi**     | 1024Mi      |
| `radarr-7bf5bcb966-vvv8f`                           | app                         | 250Mi          | 276Mi   | 315Mi   | 386Mi   | **448Mi**     | 2048Mi      |
| `sabnzbd-b485f9cb5-fx2qs`                           | app                         | 250Mi          | 3449Mi  | 4422Mi  | 4808Mi  | **3072Mi**    | 8192Mi      |
| `seerr-7dd89db669-tpt5n`                            | app                         | 250Mi          | 220Mi   | 221Mi   | 229Mi   | **320Mi**     | 1024Mi      |
| `sonarr-86bf9c95b-s8gqb`                            | app                         | 250Mi          | 567Mi   | 639Mi   | 777Mi   | **896Mi**     | 2048Mi      |
| `tesla-key-6bdb44f9b8-9rzbw`                        | app                         | 128Mi          | 16Mi    | 16Mi    | 16Mi    | **32Mi**      | 128Mi       |
| `unmanic-84b895f4bd-zj7qh`                          | app                         | 1024Mi         | 1836Mi  | 4620Mi  | 5574Mi  | **2048Mi**    | 6144Mi      |
| `wyoming-openwakeword-759f59f5cf-zx7wl`             | app                         | 128Mi          | 39Mi    | 41Mi    | 41Mi    | **64Mi**      | 512Mi       |
| `wyoming-piper-546866d6c7-npbwq`                    | app                         | 256Mi          | 327Mi   | 334Mi   | 334Mi   | **448Mi**     | 1024Mi      |
| `wyoming-whisper-947b65c5f-5mw5b`                   | app                         | 512Mi          | 1577Mi  | 1578Mi  | 1672Mi  | **2048Mi**    | 3072Mi      |
| `zigbee2mqtt-6659644d9b-8twwk`                      | app                         | 512Mi          | 88Mi    | 92Mi    | 94Mi    | **128Mi**     | 512Mi       |
| `zwave-js-ui-86766cb9d8-8hrlt`                      | app                         | 512Mi          | 118Mi   | 123Mi   | 129Mi   | **192Mi**     | 512Mi       |
| `external-secrets-64cc96f478-5t49l`                 | external-secrets            | -              | 54Mi    | 54Mi    | 55Mi    | **96Mi**      | 256Mi       |
| `external-secrets-cert-controller-777d99698d-6xgch` | cert-controller             | -              | 71Mi    | 72Mi    | 73Mi    | **96Mi**      | 256Mi       |
| `external-secrets-webhook-7df4cf9664-9gpfv`         | webhook                     | -              | 44Mi    | 45Mi    | 46Mi    | **64Mi**      | 256Mi       |
| `external-secrets-webhook-7df4cf9664-p9pck`         | webhook                     | -              | 41Mi    | 42Mi    | 43Mi    | **64Mi**      | 256Mi       |
| `flux-operator-55d5b9ff96-rlrff`                    | manager                     | 64Mi           | 159Mi   | 163Mi   | 181Mi   | **256Mi**     | 1024Mi      |
| `helm-controller-9dd7598cc-htbvj`                   | manager                     | 64Mi           | 104Mi   | 127Mi   | 310Mi   | **256Mi**     | 2048Mi      |
| `konflate-6d9b6949f-m2x4m`                          | konflate                    | 256Mi          | 825Mi   | 831Mi   | 832Mi   | **1024Mi**    | 2048Mi      |
| `kustomize-controller-5f5d974686-669rm`             | manager                     | 64Mi           | 124Mi   | 128Mi   | 190Mi   | **256Mi**     | 2048Mi      |
| `source-controller-5ff484c57c-6wwrv`                | manager                     | 64Mi           | 69Mi    | 73Mi    | 98Mi    | **128Mi**     | 2048Mi      |
| `rustfs-6f64dc574d-dffkt`                           | rustfs                      | 256Mi          | 582Mi   | 599Mi   | 667Mi   | **1024Mi**    | 1536Mi      |
| `cilium-7vrgw`                                      | cilium-agent                | 256Mi          | 353Mi   | 357Mi   | 370Mi   | **448Mi**     | 1024Mi      |
| `cilium-operator-5985b8656b-pdskf`                  | cilium-operator             | -              | 112Mi   | 114Mi   | 139Mi   | **192Mi**     | 512Mi       |
| `multus-8snf5`                                      | multus                      | 512Mi          | 43Mi    | 43Mi    | 44Mi    | **64Mi**      | 512Mi       |
| `reloader-5df8568fd8-6vkcs`                         | reloader                    | 32Mi           | 61Mi    | 63Mi    | 64Mi    | **96Mi**      | 128Mi       |
| `cloudflare-tunnel-6fb97d9cdc-rf9k8`                | app                         | 256Mi          | 32Mi    | 33Mi    | 45Mi    | **64Mi**      | 256Mi       |
| `cloudflare-tunnel-6fb97d9cdc-vfpvm`                | app                         | 256Mi          | 31Mi    | 32Mi    | 38Mi    | **64Mi**      | 256Mi       |
| `envoy-external-667945b659-ljxf5`                   | envoy                       | 512Mi          | 54Mi    | 56Mi    | 61Mi    | **128Mi**     | 512Mi       |
| `envoy-gateway-d4db4bdc9-bsgbw`                     | envoy-gateway               | 256Mi          | 134Mi   | 139Mi   | 147Mi   | **192Mi**     | 1024Mi      |
| `envoy-internal-59f594b659-b7ndt`                   | envoy                       | 512Mi          | 69Mi    | 70Mi    | 78Mi    | **128Mi**     | 512Mi       |
| `external-dns-7b6647d646-mxn6f`                     | external-dns                | -              | 34Mi    | 34Mi    | 36Mi    | **64Mi**      | 256Mi       |
| `alertmanager-kube-prometheus-stack-0`              | alertmanager                | 200Mi          | 50Mi    | 52Mi    | 55Mi    | **96Mi**      | 256Mi       |
| `grafana-deployment-6976899bc6-6kv68`               | grafana                     | 256Mi          | 469Mi   | 487Mi   | 509Mi   | **640Mi**     | 1024Mi      |
| `grafana-operator-646f9547c4-m57vv`                 | grafana-operator            | -              | 76Mi    | 78Mi    | 86Mi    | **128Mi**     | 512Mi       |
| `kube-prometheus-stack-operator-649c4dd456-2kmzq`   | kube-prometheus-stack       | -              | 37Mi    | 38Mi    | 41Mi    | **64Mi**      | 256Mi       |
| `kube-state-metrics-6bd5569df8-zctsp`               | kube-state-metrics          | -              | 86Mi    | 87Mi    | 171Mi   | **192Mi**     | 512Mi       |
| `node-exporter-hsr6x`                               | node-exporter               | -              | 30Mi    | 30Mi    | 32Mi    | **64Mi**      | 128Mi       |
| `prometheus-kube-prometheus-stack-0`                | prometheus                  | 4096Mi         | 1010Mi  | 1034Mi  | 1212Mi  | **2048Mi**    | 4096Mi      |
| `openebs-localpv-provisioner-7cdb998b88-hn6ll`      | openebs-localpv-provisioner | -              | 48Mi    | 48Mi    | 54Mi    | **96Mi**      | 256Mi       |

Pod names carry the ReplicaSet suffix and change on every deploy; the manifest
is the stable reference (`infra/k8s/kyz/apps/<group>/<app>/app/helmrelease.yaml`).

## Aggregate: what actually changed

|                                                 |                                    |
| ----------------------------------------------- | ---------------------------------- |
| Requests before                                 | 28.58 GiB (92% of allocatable)     |
| Removed from over-requested pods                | −13.48 GiB across 20 pods          |
| Added to under-requested / never-requested pods | +13.19 GiB across 35 pods          |
| Requests after                                  | **28.28 GiB (91% of allocatable)** |

The headline is not a number that goes down. It is that the 13.5 GiB of sleep-
walking reservation was real, and so was the ~13 GiB of under-provisioning on
the other side: `sabnzbd`, `unmanic`, `wyoming-whisper`, `immich-server`,
`hermes`, `rustfs`, `konflate` and 15 BestEffort system pods were all running
well above their declared requests, which is why they were first in the OOM
queue with a near-zero CPU weight. Making requests honest in both directions
leaves the aggregate roughly where it started — the node genuinely wants ~28 GiB
of requests — but the _distribution_ now matches reality, and the biggest single
offender (`litellm` reserving 3.7 GiB to run 0.5 GiB) is gone.

If real scheduling headroom is the goal, the honest levers are: trim the
headroom factor below 1.25 for the big steady consumers (`jellyfin` 1.5 GiB,
`prometheus` 2 GiB, `immich-server` 1.75 GiB, `wyoming-whisper` 2 GiB), or accept
over-commitment on the bursty batch pods. Both are judgement calls, not
arithmetic.

## Deliberate exceptions

- **`litellm`/`ollama` was sized from an empty window.** It held 2500Mi and never
  left 17Mi for 25 days — no local model load happened at all. The request drops
  to 512Mi and the 4 GiB limit is unchanged, so a load still bursts. If local
  inference comes back, this request must go back up: it is the one number here
  derived from a workload that did not run.
- **`unmanic` (2 GiB) and `sabnzbd` (3 GiB)** are sized from p90, not p99. `unmanic`
  is a deliberately yielding background transcoder (`priorityClass:
unmanic-background`, `preemptionPolicy: Never`); `sabnzbd`'s 4.4 GiB p99 is a
  usenet unpack working set that lasts minutes. Their limits (6 GiB / 8 GiB) are
  the ceilings. Sizing either to p99 would add ~3 GiB of permanent commitment.
- **`unmanic`'s 6 GiB limit is unchanged** (the request-only change keeps the
  memory ceiling the pod already had).
- **`konnectivity-agent`** is the only pod on the node with no request that
  cannot be fixed here — k0s manages it, it is not in Git.
- **`kopiur` controller** keeps the chart's 128Mi request (p99 65Mi, −64Mi delta,
  immaterial) and still has **no memory limit** — worth a separate change, not
  bundled into a requests-only PR.
- **`alertmanager`'s and `prometheus`'s `config-reloader` containers stay
  BestEffort.** The pinned prometheus-operator's CRDs have no
  `configReloaderResources` field (`kubectl explain alertmanager.spec
.configReloaderResources` → field does not exist), so there is nowhere to put
  a request without a chart/CRD change.
- **CronJobs and one-shot pods** (`recyclarr`, `zfs-vdev-exporter`, the
  `*-nightly-*` snapshot movers, the `op-*` probes) are excluded: a Job's
  7-day peak is one run, not a working set.
- **`immich-valkey`, `smartctl-exporter`, `radicale`, `k8s-gateway`,
  `intel-gpu-resource-driver`, `coredns`, `notification-controller`** were left
  alone: within 20% / 32Mi of their measured working set, or (in `coredns`'s
  case) owned by k0s rather than Git.

## Re-running it

The PromQL above plus `kubectl get pods -A -o json` for the current requests is
the whole audit. The issue suggested a VPA in recommendation-only mode to keep
the numbers honest; that is not in this change — a VPA writes to status only, but
it still needs to be watched, and on a node this close to its request ceiling a
mis-read recommendation is worse than no recommendation.
