# Refactor Plans: Flatcar + k0s + GitOps

> **Status**: Planning / Phase 0 (Flatcar validation)
> **Reference architecture**: [onedr0p/home-ops](https://github.com/onedr0p/home-ops) (reviewed 2026-08; local clone at `~/src/onedr0p/home-ops`)
> **Owner**: @rwaltr

## Goal

Migrate the homelab from uCore + Quadlets to a GitOps-managed Kubernetes stack:

```
Flatcar (ZFS sysext) → k0sctl/k0s → Cilium (BGP) → Envoy Gateway → Flux
```

Single node (`mouse`) serves **both** ZFS storage and primary compute. Nodes live in
the management VLAN but must directly serve a second VLAN.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Host OS | **Flatcar** (replacing uCore) | A/B updates, smaller surface, official ZFS sysext since 3913.0.0 (dm-verity signed, Secure Boot OK, version-locked to release). Caveat: tagged "experimental", not for root partition (data pools only — fine for us) |
| Cluster | **k0s via k0sctl** | Already deployed on mouse; k0sctl is SSH-based, distro-agnostic. ⚠️ Do NOT use `--profile flatcar` (stale docs — no such worker profile exists; silently wedges the node) |
| CNI | **Cilium** (`provider: custom` in k0s config, kube-proxy replacement) | BGP control plane replaces MetalLB/L2 announcements |
| LB/VIPs | **Cilium BGP** (`CiliumBGPClusterConfig` + `CiliumLoadBalancerIPPool`) | Router supports BGP peering; VIPs live in dedicated service CIDR announced as /32s |
| Ingress | **Envoy Gateway** (Gateway API) | Two Gateways (internal/external) with pinned VIPs via `lbipam.cilium.io/ips`; apps attach via app-template `route:` |
| GitOps | **Flux** (flux-operator + flux-instance) | onedr0p layout: single root ks → `kubernetes/apps`, Kustomize components for cross-cutting concerns |
| Charts | **bjw-s app-template via OCIRepository** for all apps | One values schema, digest-pinned images |
| Storage | **OpenEBS localpv-provisioner hostpath** on OS NVMe (non-default class) | ~~ZFS LocalPV~~ rejected: `poolname` must be a zpool (topology match), and tank stays outside the PVC lifecycle by design |
| Backups | kopiur-style snapshots → **RustFS** (S3) | Our RustFS is the S3 backend, like onedr0p's expanse |
| VLAN L2 needs | Multus + macvlan NAD **only** for discovery-dependent apps (home-assistant class) | BGP/routed VIPs cover everything else |

### Deferred

- **Istio ambient** — revisit only if workload mTLS/SPIFFE identity becomes a concrete
  need. Requires `socketLB.hostNamespaceOnly: true` + `cni.exclusive: false` with
  kube-proxy replacement, and default-deny policies block kubelet probes. Not worth it day one.
- **Secrets**: currently SOPS+age; onedr0p uses 1Password Connect + ESO. Decide before Phase 3.

### Additional decisions (2026-09-10 ~4am, smarthome stack on the SLZB-Ultima3)

- **Full protocol stack in default ns**: mosquitto (anonymous internal broker),
  zigbee2mqtt 2.14.1 (SLZB tcp serial 7638, adapter zstack — the device's own
  template was right), zwave-js-ui 11.23.0 (SLZB z-wave serial **9638**,
  serverEnabled/serverPort seeded into its store PVC), matter-server
  (python-matter-server, HA container's "Matter Server" add-on equivalent).
- **Z2M 2.x owns configuration.yaml** in its data PVC — a read-only configMap
  mount crashloops EROFS (onboarding/migration writes the file). Seed via a
  one-shot pod; the git copy is documentation.
- **HA integrations wired via REST config flows** (long-lived token): mqtt
  (mosquitto), otbr (SLZB OTBR http://10.10.0.101:8080 — remote border
  routers work), zwave_js (ws://zwave-js-ui:3000), matter (reconfigured to
  ws://matter-server:5580/ws). Gotcha: the MQTT flow's
  `other_settings.set_ca_cert` must be **"off"** — "auto" sends a TLS
  ClientHello to the plaintext port = mosquitto "protocol error"; empty-string
  username is also protocol-illegal (omit, don't send "").
- **kopiur mover UID/GID must match the app** — default mover (65532) got
  EACCES on HA's mode-0700 .storage/. Fix: per-policy
  mover.{securityContext:1000:1000, podSecurityContext: fsGroup 1000}.
  Verified with a manual Snapshot CR (source.sourceIndex + target.pvc shape).
- **HACS installed** via exec (custom_components/hacs on the config PVC) for
  custom integrations like adaptive-lighting — not a blueprint, a custom
  integration; blueprint ≠ integration (common confusion).

### Additional decisions (2026-09-10 late, full VLAN + macvlan + cilium saga)

- **THE root cause of the night**: Cilium's tcx BPF (`cil_from_netdev`) on the
  native device (enp88s0) firewalls ALL unknown traffic including 802.1q
  tagged frames; the allowlist is built from vlan devices present at
  AGENT STARTUP only. Our subinterfaces were created at runtime → every
  tagged RX (broadcast ARP/mDNS especially) was silently blackholed by the
  BPF. Fix: `bpf.vlanBypass: [20, 30, 40]` (cilium helmrelease). Symptom
  signature: tagged frames visible on the PHYSICAL (tcpdump) but zero on
  the subinterface; unicast could pass (unknown-dst passthrough) while
  broadcasts always died — stale router ARP made early "successes" lies.
  `bpftool net show dev <phys>` reveals the attachment; `tc filter show`
  does NOT (tcx/bpf-link is invisible to tc).
- **HA now has L2 presence on clients/iot/cameras** (10.20.0.10 /
  10.30.0.10 / 10.40.0.10, pinned MACs a6:30:00:10:<vlan>:0a), verified
  reachable from the router on all three; mDNS (router reflector) observed
  flowing on the subinterfaces. Cross-VLAN discovery rides the router's
  mDNS reflector.
- **networkd file-sort discipline** (cost: one host network outage): the
  master .network uses a MAC match — and vlan subifs INHERIT the parent MAC,
  so the master re-configures its own children unless the per-vlan Name
  matchers sort first (15-* before 20-*). Renaming the master to 30-*
  let 25-primary (DHCP) win on enp88s0 and dropped the host to DHCP —
  recovered via the router's lease table (mouse had picked up 10.10.0.102).
- **macvlan bridge mode needs the parent promiscuous, and networkd re-applies
  .network files on every restart — silently clearing CNI-set promisc**.
  Declarative fix: `[Link] Promiscuous=yes` in each vlan .network.
- **sbr caveat**: pod source-unbound traffic prefers eth0 (cilium) over the
  macvlan attachments; VLAN-IP-bound flows use the right interface. Don't
  trust unbound pings as evidence of macvlan health.
- **ethtool rx-vlan-offload experiments don't bypass the BPF** — the tag is
  checked in metadata form too. Reverted; bypass flag is the fix.

### Additional decisions (2026-09-10, multus/iot VLAN + kopia enrollment)

- **ether4-study is already a trunk** (PVID 10, tagged 10/20/30/40/60) — the
  router side of multus needed zero changes. Host side: `enp88s0.30` via
  systemd-networkd (butane + live hand-delta, router-README pattern).
- **networkd gotcha**: VLAN attachment is `VLAN=` under `[Network]`, NOT a
  `[VLAN]` section (that is .netdev-only). Wrong form parses as "Unknown
  section" and silently does nothing. Also: kernel RA state survives networkd
  restarts (stale `proto ra` routes expire, not disappear) — check
  `accept_ra` before diagnosing.
- **HA on the iot VLAN**: multus + NAD `iot` (macvlan bridge, master
  enp88s0.30) with per-pod static IP (10.30.0.10/23, below DHCP pool
  .100+) and pinned MAC. Pod created before its NAD exists silently skips
  the attach — restart the workload after NAD creation. Cross-VLAN mDNS
  (cast devices on vlan20) still needs a reflector or a second NAD — later.
- **macvlan host isolation**: the node cannot reach its own macvlan children
  (macvlan bridge-mode limitation); the router can. Verify from the router:
  `/tool fetch url="http://10.30.0.10:8123/"`.
- **kopiur enrollment** (first policy in the cluster): ns-scoped
  SnapshotPolicy per app + nightly SnapshotSchedule (`H 3`, runOnCreate
  false); explicit PVC names (app-template persistence has no `labels`
  field for a pvcSelector). Namespace needs the repo tenancy label
  `kopiur.home-operations.com/repo: cluster-kopia`. app-template PVC names
  are `<fullname>-<persistence-name>`.
- **kopiur controller metrics**: ServiceMonitor on
  kopiur-controller-metrics:8081 (chart ships the svc, not the monitor).

### Additional decisions (2026-09-09, home-assistant + apps/default)

- **First homelab app**: HA in the `default` ns (onedr0p convention for
  homelab/media apps), internal-only route `homeassistant.waltr.tech`
  (envoy-internal, k8s-gateway DNS only — no public record). Image:
  ghcr.io/home-operations/home-assistant, digest-pinned.
- **This HA build has no /healthz** (404) — readiness probe uses
  `/manifest.json` (unauthenticated 200). Pod CIDR for proxy trust:
  `10.244.0.0/24` + `fdad:207a:f1ab:244::/117` (Cilium native-routing, /24
  not /16).
- **HA 2026.9 http integration config is store-based, not YAML**: YAML is
  migrated ONCE into `.storage/http` (stable/pending pair with a 5-minute
  trial), then **ignored on every boot**. To change http config after first
  boot: delete `/config/.storage/http` and restart (re-migration), or use the
  UI. YAML http block breaks in HA 2027.2 — after migration remove it from
  configuration.yaml or live with the repair issue.
- Deferred: Multus/macvlan NAD for LAN mDNS/SSDP discovery (the exact
  "discovery-dependent app class" from the original decision).

### Additional decisions (2026-09-09, o11y: grafana + dashboards)

- **Grafana via grafana-operator v5 instance CR** (onedr0p pattern): the
  operator owns Deployment/PVC/HTTPRoute for the CR (spec.httpRoute →
  envoy-internal, `grafana.waltr.tech`); dashboards/datasources are separate
  CRs selected by label `dashboards: grafana`. Admin password from 1P item
  `grafana` (GF_SECURITY_ADMIN_PASSWORD), anonymous viewer enabled.
- **kube-prometheus-stack chart deploys its dashboards as GrafanaDashboard
  CRs already** (`grafana.forceDeployDashboards: true` + `operator.dashboardsConfigMapRefEnabled`).
  Do NOT add a hand-rolled mixin dashboard file — title+folder collisions make
  the operator imports overwrite each other. Chart set wins.
- **CRD shortname collision**: `kubectl get grafana(s)` resolves to the
  External Secrets *Grafana token generator* CRD
  (`grafanas.generators.external-secrets.io`), not the operator's
  `grafanas.grafana.integreatly.org` — always use the fully-qualified name.
- **Grafana-operator needs the instance Ready before dashboards match**:
  dashboards created before the instance was ready sit in
  `NoMatchingInstances` until the operator resyncs/restarts; a pod restart
  requeues everything. Datasources retry on their own, dashboards do not.
- **1Password Connect sync lag**: items created via the desktop-integrated
  CLI can take a long while (observed: indefinitely) to appear in the Connect
  API — a connect pod restart forces a vault re-sync. Symptom: ExternalSecret
  "could not get secret data from provider" although the item exists.
- **grafana.com dashboard ID traps**: 18040-18060-range listings by organic
  search names can be unrelated dashboards (18060 = FluentBit
  "prometheus-cactus"); ESO's official dashboard is **21640**. Envoy Gateway
  official: 24459/24457/24458; cert-manager 20842; cloudflared 17457.
- **Envoy data-plane metrics**: EG already wires a named container port
  `metrics` (:19001 `/stats/prometheus`) + prometheus.io annotations on the
  proxy pods — only a PodMonitor (`app.kubernetes.io/managed-by: envoy-gateway`)
  was needed. Flux controllers: PodMonitor on port `http-prom` by component
  label; flux-operator itself is scraped by its chart ServiceMonitor.
- **Flux PrometheusRule** (gotk_resource_info based) complements the
  Flux→alertmanager Provider/Alert notifications for HelmRelease/Kustomization
  failures.

### Additional decisions (2026-09-09, cloudflare tunnel + waltr.tech ops zone)

- **Universal SSL depth limit is real**: free Cloudflare edge certs cover only
  `<zone>` + `*.<zone>` — one level. `*.*.rwalt.pro` hostnames fail the edge
  TLS handshake outright (`handshake_failure` on ClientHello). Subdomain
  zones are Enterprise-only; CNAME/partial setup is Business-only; ACM ($10/mo)
  and CF-for-SaaS custom hostnames (free, per-app ceremony) were considered
  and rejected.
- **Decision: `waltr.tech` becomes the ops zone.** App names are one level
  (`prometheus.waltr.tech`), covered by Universal SSL. The `kyz` site label
  retired from DNS names. `rwalt.pro` stays personal/mail only. waltr.tech's
  Migadu mail is unaffected by the full-zone internal FWD (mail lookups
  happen at external receiving servers). One CF zone, zero cost, wildcards
  work.
- **cloudflare-tunnel app** (onedr0p pattern, cloudflared 2026.8.3, 2
  replicas, token auth from 1P `cloudflare` item): wildcard ingress
  `*.waltr.tech` → `envoy-external.network.svc.cluster.local:443` over https
  (SNI `external.waltr.tech`, matches the wildcard LE cert). Token-mode
  cloudflared parses local config ingress (verified in current source —
  `prepareTunnelConfig` runs `ParseIngressFromConfigAndCLI` unconditionally).
- **Public record chain**: HTTPRoute attached to `envoy-external` →
  external-dns (gateway filter `--gateway-name=envoy-external` + crd source
  + `--cloudflare-proxied`) publishes the hostname targeting
  `external.waltr.tech` (Gateway `target` annotation) → DNSEndpoint CNAME
  `<tunnel-id>.cfargotunnel.com` → edge → tunnel. Tunnel ID 146ea318-aadd-4efe-97c1-54feac074f1f
  (not a secret — public in every cfargotunnel CNAME).
- **Rename gotcha**: renaming a cert-manager Certificate while keeping the
  secret name wedges issuance ("Secret was issued for <old>" /
  IncorrectCertificate) — delete the secret to re-trigger. ClusterIssuer DNS-01
  solver needed `waltr.tech` added to `dnsZones`.
- **End-to-end verified through the real edge** (from LAN via `--resolve` to
  a CF edge IP): 200 + `cf-ray: …-DFW` on `e2e-http.waltr.tech`.

### Additional decisions (2026-09-09, DNS split + external-dns)

- **Split DNS both ways**: `kyz.rwalt.pro` served by in-cluster k8s-gateway
  (CoreDNS plugin, chart 3.7.2, VIP 10.10.100.53 + v6 twin) answering from
  Gateway/HTTPRoute/Service resources; MikroTik `type=FWD` conditional forward
  with **`match-subdomain=yes`** (the missing knob — without it, subdomains
  NXDOMAIN while the exact name forwards). external-dns (mirror 1.21.1) also
  publishes the same names + internal VIPs to the public Cloudflare zone
  (user accepts internal-IP visibility; CGNAT makes them unreachable).
- **external-dns domain filter is ZONE-scoped**: `--domain-filter kyz.rwalt.pro`
  silently excluded the `rwalt.pro` zone itself ("no hosted zone matching
  record"); must filter on the zone name. Record scoping comes from sources —
  `gateway-httproute` only, so plain Services (incl. kube-api) stay internal.
- **kube-api stays internal-only**: `coredns.io/hostname` annotation on the
  selectorless Service makes k8s-gateway serve `k8s.kyz.rwalt.pro`; no public
  record.
- Tailscale: tailnet gets clients-tier trust via the tailscale operator
  (future phase); no subnet routes advertised today.
- End-to-end verified: plain `curl https://prometheus.kyz.rwalt.pro/` works
  with zero client config and connects over v6 (curl prefers the ULA AAAA).

### Additional decisions (2026-09-09, TLS)

- **TLS path (working end-to-end)**: 1P `cloudflare` item (CLOUDFLARE_DNS_TOKEN,
  scoped DNS-edit on rwalt.pro) → ESO secret → ClusterIssuer
  `letsencrypt-production` (DNS-01, shortlived profile) → `Certificate/kyz-rwalt-pro`
  (`kyz.rwalt.pro` + `*.kyz.rwalt.pro`, ECDSA P-256, 160h, rotation Always) →
  Secret `tls-wildcard` → `envoy-internal` Gateway. Verified: Prometheus served
  over public LE TLS through the Gateway on BOTH VIP families.
- **Pre-existing `rwaltr.pro` typo** was in the ClusterIssuer zone selector —
  domain is `rwalt.pro`. Certificates with the wrong zone would silently fail
  the DNS-01 solver selector.
- **envoy-gateway dual-stack needs THREE fixes** (all found live): 1) generated
  Service is single-stack → StrategicMerge `patch` in EnvoyProxy
  `envoyService` sets `ipFamilyPolicy: PreferDualStack` (no IPv6 EndpointSlice
  → ETP=Local correctly withholds the v6 VIP announcement); 2) Envoy binds
  `0.0.0.0` by default → `EnvoyProxy.spec.ipFamily: DualStack` binds `::` with
  v4-compat (otherwise v6 traffic DNATs to the pod and gets RST at the last
  hop); 3) template `turbo.ac` hostnames/`ceph-block` storageClass in
  konflate + kube-prometheus-stack values → `kyz.rwalt.pro` + `openebs-hostpath`.
- Test recipe until external-dns lands: `curl --resolve
  <host>:443:10.10.100.11 https://<host>/` (v4) and `--resolve
  <host>:443:[fdad:207a:f1ab:100::11]` (v6).

### Additional decisions (2026-09-08, dual-stack + BGP VIPs)

- **Dual-stack over ULA** (no ISP delegation; `fdad:207a:f1ab::/48`): pods in
  `fdad:207a:f1ab:244::/108` (in the :244 block mirroring k0s's 10.244 v4 pod
  CIDR), services in `fdad:207a:f1ab:96::/108`, LB VIPs in
  `fdad:207a:f1ab:100::/64`. mouse got a static v6 (`:10::10`) **alongside**
  SLAAC (both coexist; networkd `IPv6AcceptRA=yes`).
- **k0s gotchas found the hard way**:
  - dual-stack node-IP autodetection does a DNS lookup of the bare hostname —
    needs a static `mouse` A/AAAA in the router's DNS or k0s crash-loops
  - k0s hardcodes `--node-cidr-mask-size-ipv6=117`; kube-controller-manager
    rejects pod CIDRs with a prefix smaller than /101 (117-16) — the VLAN-style
    /64 convention cannot be a pod CIDR; a /108 inside the :244 hextet works
  - nodeipam never *appends* a second family to an existing node — converting
    to dual-stack requires deleting the Node object (pods get garbage-collected
    and recreated by their controllers) so the kubelet re-registers fresh
  - k0s's real pod CIDR is 10.244.0.0/16 (NOT 10.42 — the onedr0p template
    carried k3s values; `ipv4NativeRoutingCIDR` corrected)
- **Cilium BGP needs per-family sessions with this MikroTik**: a v4-transport
  session advertising v6 NLRI gives a `::ffff:` v4-mapped next-hop (6PE
  semantics) that RouterOS won't forward plain-Ethernet v6 via — v6 VIPs
  silently died at the router. Fix: v4 session (10.10.0.1) for v4 /32s,
  v6 session (`fdad:207a:f1ab:10::1`) for v6 /128s, native next-hops.
- **DSR hairpin conntrack trap (same-VLAN clients)**: Cilium LB replies go
  L2-direct to same-VLAN clients, so the router's conntrack sees half a flow
  and v6 `drop invalid` eats client packets until retransmit timeout — every
  fresh same-VLAN v6 connection stalled 6.6s. RouterOS v4 conntrack is loose
  (why v4 was immune); v6 has no loose knob. Fixed with a scoped
  `accept connection-state=invalid` for the mgmt→v6-VIP hairpin (cilium#34972,
  MikroTik t=171177 — the documented "routing triangle" problem). Structural
  fix (dedicated service VLAN) deferred until a second node joins.
- **kube-api via dual VIPs** (10.10.100.10 + `fdad:207a:f1ab:100::10`):
  selectorless Service + manual EndpointSlices (k0s apiserver is host-managed,
  not a pod). ETP=Local needs `nodeName` + `ready: true` on the slices or
  Cilium won't advertise. Router firewall: zone-based default-deny needs the
  VIP blocks in address-lists + mgmt/clients accepts + a shared `k8s-vips`
  chain for iot/cameras (untrusted disabled).

### Additional decisions (2026-09-06)

- **Storage: hostpath only, tank stays out of PVC lifecycle** — ZFS-LocalPV rejected
  after live testing: `poolname` must name a **zpool** (dataset paths like
  `tank/k8s/local` fail topology matching → `no available topology found`), so CSI
  PVs would land as `tank/pvc-*` at the pool root with no way to quarantine them.
  `openebs-hostpath` (NVMe, non-default) is the sole class; durable bulk data is
  hand-managed on tank. Trade-off accepted: hostpath PVs are node-pinned,
  snapshot-less, and on the OS disk — all fine for disposable/scratch-tier data.
- **Backups: kopiur + kopia → in-cluster RustFS on `tank/backup/k8s`** — validated
  end-to-end (seed → Snapshot → wipe PVC → Restore → sha256 match). RustFS runs
  in `kopiur-system`, standalone mode, static hostPath PV to the dataset, pinned to
  mouse until node labels exist (follows the DAS). Plain HTTP in-cluster is safe:
  kopia encrypts client-side (`KOPIA_PASSWORD`) before upload.
- **`copyMethod: Direct` is mandatory on every SnapshotPolicy** — hostpath storage
  has no CSI snapshot stack; kopiur fails closed rather than silently reading live
  volumes. DB workloads get `beforeSnapshot` hooks when they land.
- **Cred fanout pattern** — one 1Password item (`kopia` vault `home-ops`: RUSTFS
  keys + KOPIA_PASSWORD) feeds RustFS itself and, via a ClusterExternalSecret,
  every namespace labeled `kopiur.home-operations.com/repo: cluster-kopia`.
  Onboarding an app = label the ns + SnapshotPolicy/SnapshotSchedule manifests.
  (kopiur's own credentialProjection avoided — no cluster-wide secrets RBAC needed.)
- **RustFS bucket created by hand** (`mc mb`, one-shot) — kopia needs the bucket
  pre-bootstrap; a Git-managed bootstrap Job proved more moving parts than value.
- **Flux lesson: never delete an object mid-health-check** — the kustomize-controller
  assessment goroutine (59m timeout) keeps running against the deleted object and
  overwrites status on the recreated CR; `rollout restart` of kustomize-controller
  is the fix.

### Additional decisions (2026-08-13)

- **k0s over k3s** — k0sctl's declarative YAML + zero bundled components fit this repo;
  k3s's value-adds (Klipper/Traefik/local-path) are all things we replace anyway.
  Revisit if multi-node exposes k0s autopilot issues
- **Sysexts**: adopt **tailscale** (host tailnet access); defer incus/kata/cloud-hypervisor;
  cilium sysext is redundant (CNI runs in-cluster)
- **Bakery sysext delivery**: Flatcar's `systemd-sysupdate` does NOT discover custom
  components (verified 2026-08-13, systemd 257.9 — binary never reads `sysupdate.d`).
  Use pinned, sha256-verified download units instead (see `tailscale-sysext-install.service`
  in test.bu). Revisit sysupdate on newer systemd (`*.transfer` convention)
- **tailscale sysext validated** (2026-08-13): v1.102.2 raw in `/etc/extensions`, hash-checked,
  `tailscaled.service` active, survives reboot **and** cold-boot from Ignition. Auth key via
  SOPS when going real. Caveats found during full-rebuild testing (see lessons below):
  bakery's unit requires `/etc/default/tailscaled` and can't be wired up by Ignition
- **Cilium datapath**: if kata is likely later, set `bpf.datapathMode: veth` from day one
  (netkit is kata-incompatible and the setting is node-wide)
- **Hermes agent** (planned workload): hardened regular pod + Hermes's container terminal
  sandbox backend; kata RuntimeClass as documented upgrade path. Never the default (host)
  terminal backend on the storage node. Needs PVC → lands in backup component

## Phases

- [x] **Phase 0: Validate Flatcar** ✅ 2026-08-12
  - [x] Butane config: ZFS sysext enablement (`/etc/flatcar/enabled-sysext.conf`) — official `flatcar-zfs`, cached in `/etc/extensions`
  - [x] ZFS pool create/import works after boot **and after reboot** (sysext + pool + data all persisted)
  - [x] VLAN subinterface via systemd-networkd units (`vlan40` created, no host IP)
  - [x] k0sctl installs k0s v1.36.3 on Flatcar — ⚠️ **`--profile flatcar` breaks controller+worker**: worker binaries never stage, node never registers, k0s crash-loops every ~5 min with "Lost the controller lease". Dropping the flag fixed it. (Possibly report upstream.)
  - [x] Cilium 1.20 with `provider: custom` + `kubeProxyReplacement: true` — nginx smoke test passed
  - [x] **Full clean→rebuild reproducibility** (2026-08-13): destroyed VM + disks, rebuilt from
    `test.bu` + `infra/k0s/flatcar-test.yaml` alone — same end state (hostname, update.conf,
    tailscale sysext + daemon, ZFS pool, vlan40, k0s Ready, nginx over pod network)
  - Lessons: set `hostname` in Butane (node identity); `k8sServiceHost: 127.0.0.1:7445` in onedr0p's Cilium values is **Talos KubePrism** — k0s needs the direct API address (or `nodeLocalLoadBalancing`) 
- [x] **Phase 0.5: mouse via Ignition + generic VM harness** ✅ 2026-08-13
  - [x] `infra/flatcar/butane/base.bu` (rwaltr+keys+sudoers, tailscale sysext units,
    update-strategy-off, resolved mDNS drop-in) + `hosts/mouse.bu` (hostname, hostid
    1e1719e4, ZFS sysext, **import-only** tank unit, DHCP+mDNS on NIC glob)
  - [x] Live-mouse facts baked in: mgmt on 10.10.0.0/16, igc NIC (i226-LM, MAC
    58:47:ca:74:fb:1c), tank = raidz1×2 6×5.5T at /var/tank; VLANs 30/40 NOT on host
  - [x] Bare-metal addressing: **static 10.10.0.10** via MAC-matched networkd unit
    (20-mouse-static.network); unknown NICs (VMs) fall through to DHCP (25-primary).
    Old uCore DHCP lease .105 dies with uCore — no cutover conflict
  - [x] mDNS: systemd-resolved responder (`MulticastDNS=yes`) — no avahi needed;
    mouse.local verified listening on UDP 5353 v4+v6 (end-to-end LAN test needs bare
    metal — qemu user-net blocks multicast)
  - [x] Generic host-arg'd tasks: `flatcar:{bootstrap,vm,seed,verify,k0s,clean,vm-connect} [host]`
    (default mouse; ports/users in `vm_ports`/`vm_user` in .mise/lib/common.sh).
    **`flatcar:bootstrap mouse` = full env from scratch in one command**
  - [x] Naming normalized for host-arg consistency: `.vm/<host>.*`,
    `infra/k0s/<host>.yaml` (flatcar-test.yaml → test.yaml)
  - [x] `flatcar:seed mouse` hand-creates tank (mirrors bare metal), poweroff → next
    boot exercises the real Ignition import path. Verified: tank ONLINE at /var/tank
  - [x] `infra/k0s/mouse.yaml` prod k0sctl config; task renders VM variant (address→
    127.0.0.1:2224) so the prod spec is what gets tested. k0s+Cilium+nginx ✅
  - Lessons: butane `local:` merge inlines as gzipped data: URL (works fine on Flatcar);
    k0sctl kubeconfig hardcodes :6443 → task rewrites to per-host API port; `#MISE confirm`
    aborts non-interactive chains → vm --force calls the clean script directly;
    konnectivity-agent gets stuck in NetworkNotReady backoff when CNI is out-of-band →
    task bounces it post-Cilium; VM serial upgraded to socket+logfile (interactive debug
    via `socat - UNIX-CONNECT:.vm/<host>-serial.sock`); base.bu carries 4 SSH keys —
    the 3 from uCore base.bu + this workstation (zirconium-bisync)
- [ ] **Phase 1: Bare-metal mouse** — provision real hardware
  - [x] uCore decommissioned (2026-08-13): `infra/ucore/`, `ucore:*` tasks, `kyz-0.yml`,
    FCOS ISO, `check_virsh` all removed; `hosts/template.bu` ported to Flatcar
  - [x] Hardware recon (2026-08-13): MS-01 (i9, 20c/31G), boot = nvme0n1 954GB (OS-only,
    nothing to preserve), pool = sda–sdf whole-disk vdevs (never touched by install),
    UEFI, i226-LM = AMT/vPro port (left 2.5G, carries mgmt), X710 SFP+ ×2 unused

  **Runbook** (console session; ~30 min):
  0. **AMT first** (one-time, pays off forever): BIOS (Del) → ME enabled; MEBx (Ctrl+P,
     default pw `admin`, forced change) → enable AMT + KVM → network **static 10.10.0.106**
     (AMT-over-DHCP is flaky on i226-LM). Then `https://10.10.0.106:16993` + MeshCommander
     KVM/IDE-R = remote console + virtual-media ISO boot for all future reinstalls
  1. Pre-flight: `mise run flatcar:build`; Flatcar stable ISO → USB (or AMT IDE-R);
     confirm backups (6.7T pool isn't touched, but disk-selection mistakes are final)
  2. Boot live env → DHCP → `scp infra/flatcar/ignition/mouse.ign core@<ip>:`
  3. `lsblk` — target is **nvme0n1 ONLY** (954GB; the six 5.5T are the pool)
  4. `sudo flatcar-install -d /dev/nvme0n1 -i mouse.ign` → reboot, remove media
  5. First boot applies Ignition (hostname, hostid, keys, tailscale, mDNS, update-off,
     zfs sysext) → `zfs-import-tank` imports the existing pool to /var/tank
  6. Verify from workstation: `ssh rwaltr@10.10.0.10` — zpool status (6/6 ONLINE),
     df /var/tank, tailscaled active; `sudo tailscale up` (NEW tailnet identity —
     delete the old mouse node); mouse.local via mDNS
  7. `k0sctl apply --config infra/k0s/mouse.yaml`; Cilium helm with
     `k8sServiceHost=10.10.0.10` (NOT the VM's 10.0.2.15); then Phase 2 owns cluster state
  8. Rollback: reinstall uCore from git history the same way; pool imports identically

  **How the install ACTUALLY went down (2026-08-16)** — none of the designed paths
  survived contact; what worked was disassembly:
  1. kexec into the PXE live env boots fine, but it's hostile unattended: no autologin
     on the generic path (`flatcar.autologin` didn't take), and Ignition's URL fetch
     needs BOTH the right arg (`ignition.config.url`, not `flatcar.ignition.config.url`)
     AND `ip=dhcp` (dracut skips initramfs networking otherwise) — never got a fetch
  2. `flatcar-install` from running uCore (RAM-resident fedora container) **completed
     the full image dd** before failing on `rereadpt`/`wipefs` — kernel won't reload
     the partition table of the disk the OS runs from. KEY INSIGHT: dd happens BEFORE
     those steps; the "failure" left a complete Flatcar disk missing only `config.ign`
  3. Winning move: write `config.ign` into the OEM partition via **loop device at
     absolute sector offset** (`losetup -o $((sector*512)) --sizelimit ... -f /dev/nvme0n1`)
     — bypasses the stale in-memory partition table entirely. Then `sysrq b` reboot
  4. First boot: Ignition read config.ign from the OEM partition (no URL fetch!),
     applied mouse.ign, came up at static 10.10.0.10. ✅

  **Lessons:**
  - **Export the pool BEFORE pulling disks** — a suspended pool wedges any sync()-caller
    (incl. kexec's pre-load sync) in zil_commit forever
  - flatcar-install order of ops: dd image → rereadpt → wipefs → mount OEM → cp config.ign.
    A failure late in that list may still leave a fully-imaged disk — read the script
    before assuming failure
  - `losetup --offset/--sizelimit` edits partitions on busy disks (kernel table be damned)
  - The PXE live env is for PXE. Via kexec it's a login wall with extra steps
  - AMT KVM + IDE-R + stunnel bridge = the insurance that made all risk-taking free
  - Corrupted /etc/containers/policy.json (NUL padding) = interrupted write during a
    power-cycle; only image pulls notice

  **AMT access from Linux** (validated 2026-08-16): AMT = static 10.10.0.9 on the
  i226-LM port (left 2.5G), TLS-only (16992 plain is filtered; 16993/16995 open).
  Gotcha: its TLS stack needs **legacy renegotiation** (pre-RFC5746) which OpenSSL 3
  refuses — and node.js (MeshCommander) ignores OPENSSL_CONF, so it can't be fixed
  client-side. Solution: **stunnel TLS bridge** on localhost, MeshCommander talks plain:

  ```
  # /tmp/amt-stunnel.conf — bridges BOTH port pairs (WS-Man + KVM/IDE-R)
  foreground = yes
  pid =
  [amt-wsman]
  client = yes
  accept = 127.0.0.1:16992
  connect = 10.10.0.9:16993
  options = ALLOW_UNSAFE_LEGACY_RENEGOTIATION
  [amt-redir]
  client = yes
  accept = 127.0.0.1:16994
  connect = 10.10.0.9:16995
  options = ALLOW_UNSAFE_LEGACY_RENEGOTIATION
  ```

  ```bash
  podman run -d --name amt-bridge --rm --network host \
    -v /tmp/amt-stunnel.conf:/etc/stunnel/stunnel.conf:ro,Z \
    docker.io/library/debian:trixie-slim bash -c \
    "apt-get update -qq && apt-get install -y -qq stunnel4 >/dev/null 2>&1 && stunnel /etc/stunnel/stunnel.conf"

  # MeshCommander web UI (node): host networking so its 127.0.0.1 bind is reachable
  podman run -d --name meshcommander --rm --network host \
    docker.io/library/node:22-slim bash -c \
    "cd /tmp && npm install meshcommander --no-audit --no-fund --loglevel=error && node node_modules/meshcommander"
  # → http://localhost:3000, Add Computer = 127.0.0.1, admin + MEBx pw, TLS OFF
  ```

  Direct curl works with an OPENSSL_CONF allowing UnsafeLegacyRenegotiation (SECLEVEL=1).
  AMT DHCP mode = shared host IP (snoops host's DHCP) — host is static, so AMT must be static.

  **SOL (Serial-over-LAN)** — documented, NOT yet enabled in mouse.bu:
  the ME exposes a virtual UART as ttyS0; AMT side is already live (16995 open).
  To use it later: add to the host .bu (flatcar variant supports kernel_arguments,
  verified 2026-08-16):
  ```yaml
  kernel_arguments:
    should_exist:
      - console=ttyS0,115200n8
  ```
  systemd auto-spawns serial-getty on console= ports, so that's the whole OS side.
  Client: `amtterm -h 127.0.0.1 -u admin -p <MEBx pw>` (amtterm pkg) through the
  stunnel bridge's plain 16994 side. Bonus: enable BIOS "Serial Console Redirection"
  for POST/GRUB visibility too. Use case: text-only remote console in tmux,
  loggable/scriptable, no KVM protocol needed.

  **PXE (researched, NOT chosen for n=1)**: Flatcar publishes PXE kernel+initrd
  (`flatcar_production_pxe.vmlinuz` / `_image.cpio.gz`); iPXE script boots it with
  `flatcar.ignition.config.url=http://<server>/mouse.ign` (http/https/tftp). Needs DHCP
  next-server+bootfile (router-dependent) or ProxyDHCP dnsmasq on an always-on device —
  mouse is the only server, so that's the workstation (chicken-egg). Middle ground:
  flash tiny iPXE USB → chainload HTTP script, no DHCP changes. But AMT IDE-R covers
  the same remote-boot need with zero infrastructure → **AMT > PXE for a single node**.
  Revisit PXE if a second node appears.
- [ ] **Phase 2: Bootstrap** — BUILT at `k8s/kyz/bootstrap/helmfile/` (rendered against live cluster, not yet applied). DAG: cilium → coredns → cert-manager → external-secrets → onepassword-connect → flux-operator/instance. Secrets: 1Password Connect + ESO — `op inject` seeds the Connect creds at bootstrap (`OP_SERVICE_ACCOUNT_TOKEN` env, prompted; no SOPS for k8s). Layout decision: `k8s/<site>/` (kyz = this site; future sites sit beside it). Run: `mise run k8s:bootstrap mouse` — needs 1P item `1password` in vault `home-ops` with OP_SESSION_JSON + OP_CONNECT_TOKEN. Model: `~/src/onedr0p/home-ops/bootstrap/helmfile/`
- [ ] **Phase 3: GitOps layout** — `kubernetes/{apps,components,flux}`; root ks with HelmRelease default patches; components: alerts, backup, zeroscale
- [ ] **Phase 4: Networking** — Cilium BGP resources, Envoy Gateway internal/external, cert-manager, external-dns (Cloudflare)
- [ ] **Phase 5: Workloads** — migrate rustfs/netdata quadlets into cluster; remaining apps
- [ ] **Phase 6: Automation** — Renovate (home-operations presets, tiered automerge), CI (butane validate, image pull check)

## Lessons from onedr0p/home-ops review

1. **Uniformity beats cleverness** — every app: `ks.yaml` + `app/{kustomization,ocirepository,helmrelease}.yaml`
2. **Push defaults to platform layer** — root Flux ks patches HelmRelease defaults (CRD handling, remediation) into every child
3. **Kustomize components** with `${VAR:=default}` for backup/alerts/zeroscale — one line per app
4. **Bootstrap as explicit DAG** (helmfile `needs:`), CRDs applied out-of-band to kill dependsOn chains
5. **Zero secrets in git** — resolved at render/apply time
6. **Renovate does the heavy lifting** — shared presets, digest automerge, min release age
7. **CI pulls images on PR** to catch dead registries before merge
8. Webhook `Receiver` for push-to-reconcile (seconds, not the 1h interval)

## Lessons from knuckle (`~/src/knuckle`, projectbluefin Flatcar installer)

Knuckle is a TUI/headless Butane generator — everything it produces is Butane, so
hand-written Butane stays our source of truth. Steal these:

1. **update-engine auto-reboots by default** → pin `REBOOT_STRATEGY=off` in
   `/etc/flatcar/update.conf`; reboots become deliberate (kured or manual).
   ⚠️ Exception to "everything is Butane": see Ignition limits below — this file
   can't be Ignition-written, needs a boot unit

## Ignition limits found by full-rebuild bisection (2026-08-13)

Failure mode for all three: `ignition-files` fails silently to serial, VM black-box
reboot-loops every ~5 min. Found by diffing against last-known-good config one change
at a time (console log only shows `res=failed`; detail stays in the journal).

1. **Ignition cannot overwrite `/etc/flatcar/update.conf`** — it exists in the base
   image (empty). `ignition-files` fails on overwrite. Fix: `update-strategy-off.service`
   oneshot writes `REBOOT_STRATEGY=off` post-boot
2. **Ignition cannot enable sysext-provided units** — `enabled: true` on
   `tailscaled.service` fails the same way (unit doesn't exist until merge). Fix: the
   install unit runs `systemctl enable --now tailscaled.service` after `systemd-sysext refresh`
3. **Bakery `tailscaled.service` has a mandatory `EnvironmentFile=/etc/default/tailscaled`**
   (upstream tailscale marks it optional with `-`). Unit crash-loops without it. Fix: ship
   `PORT="41641"`/`FLAGS=""` via Butane. Knuckle's "auto-starts at boot" claim needs this too
4. **systemd unit quoting**: `ExecStartPost=/bin/sh -c "echo '$${VAR}  file' | sha256sum -c"`
   — single quotes block systemd var expansion → bogus hash line, unit fails. Use escaped
   double quotes
5. **k0sctl honors the real `known_hosts`** — recreated VM = new host key = apply fails
   with "host key mismatch". The `flatcar:k0s` task auto-clears the per-host entry now
2. **Flatcar ships no swap** — fine for k8s (kubelet default), deliberate choice
3. **Bakery sysext catalog** (extensions.flatcar.org): `tailscale` (Integrated
   tier — host tailnet access), `bird` (redundant — Cilium BGP in-cluster),
   `nvidia-drivers`. Bakery sysexts update via `systemd-sysupdate` separately
   from OS updates; official sysexts ride the release
4. Knuckle headless mode may be useful later for bare-metal installer media
   for mouse instead of hand-rolling flatcar-install

## Session log

### 2026-09-11 — Tesla key host, Matter VLAN presence, VIP firewall fix, Frigate

- **Tesla Fleet integration live**: keypair (EC P-256) in 1P `tesla-fleet` +
  `/config/tesla_fleet.key` in HA PVC; public key served by new `tesla-key`
  nginx app at the exact Tesla path (`/.well-known/appspecific/…`, no
  redirects) — `tesla.waltr.tech`, envoy-external ONLY (Tesla's verifier is
  the sole consumer). 2026 Model Y → command signing required; user pairs
  vehicle key at tesla.com/_ak/tesla.waltr.tech.
- **matter-server got IoT VLAN macvlan** (`10.30.0.11/23`, MAC a6:30:00:10:30:0b,
  annotation lives in `defaultPodOptions.annotations` — app-template 5.x
  schema REJECTS `podAnnotations` under controllers): Matter mDNS is IPv6
  link-local `ff02::fb`, unrouteable — co-VLAN presence is the only fix, no
  router reflection possible. Verified `_matterc` discovery from the pod.
- **Leviton WiFi Matter switch**: BLE provisioning requires phone-side GMS;
  matter-server has no BLE (`commission_with_code: Bluetooth commissioning
  is not available`). Commission via My Leviton app + share, or GMS phone.
- **GrapheneOS finding**: Matter/Thread commissioning on Android is mediated
  by sandboxed GMS; Thread credential handoff is unreliable there. mouse
  HAS a MediaTek WiFi/BT combo (0e8d:c616) — server-side BLE via
  matter-server is the future fix; user deferred (old-phone fallback).
- **k8s-vips / k8s-vips6 chains populated** (TCP 80/443 + UDP 443): they were
  designed empty (fall-through deny) which ZONEDENY'd phones on IoT reaching
  homeassistant.waltr.tech. Keep v4/v6 chains symmetric (routeros README).
- **Router mDNS repeater**: `/ip dns mdns-repeat-ifaces` now covers
  vlan20-clients + vlan30-iot + vlan10-mgmt (IPv4 mDNS only — v6 LL cannot
  be reflected by design).
- **Frigate 0.16.2 (in flight)**: go2rtc embedded (route go2rtc.waltr.tech :1984),
  cameras VLAN macvlan `10.40.0.11/24` MAC a6:30:00:10:40:0b, config PVC
  (kopia @H5, 30m jitter), recordings on `/var/tank/nas/nvr` (NOT backed up),
  CPU detector, anonymous internal mosquitto for HA discovery. RTSP creds
  via 1P `frigate` item (frigate_rtsp_user/frigate_rtsp_pass) →
  `frigate-secret` → go2rtc `{ENV}` substitution.

#### Frigate follow-up (same day)
- **Deployed + running non-root** (1/1): went through the full s6-overlay
  gauntlet — see `frigate/app/helmrelease.yaml` comments. Key learnings:
  - app-template 5.x REJECTS `podAnnotations` under controllers → use
    `defaultPodOptions.annotations`
  - emptyDir persistence uses `sizeLimit` (not `size`)
  - s6 non-root needs the full recipe: `/run` emptyDir (Memory),
    `HOME=/tmp/home`, `S6_CATCHALL_USER`, `S6_YES_I_WANT_A_WORLD_WRITABLE_RUN…`,
    CAP_SETGID (applyuidgid sets supplementary groups), a chown-free
    `log-prepare/run` override (configmap, defaultMode 493), and the nginx
    copy init container via HelmRelease `postRenderers` (NOT values —
    chart applies globalMounts to values-inits, shadowing the image dir)
  - `postRenderers` on HelmRelease v2 is a LIST of maps, not a map
- **RTSP URL gotcha**: the Reolink password contains `@` — secret template
  renders a percent-encoded copy via sprig `urlquery`
  (`FRIGATE_RTSP_PASS_ENC`).
- **reolink camera (10.40.0.199) REMOVED**: its firmware doesn't support
  generic RTSP output (port 554 refused); nursery (10.40.0.198) streams fine.
- **2-way talk wired**: RTSP `#backchannel=1` + `*_talk` opus streams +
  go2rtc WebRTC listener `:8555` with candidate `10.40.0.11:8555` — rides
  the router's existing `clients → cameras: UDP only` accept. HA-side:
  frigate integration (MQTT auto-discovery, URL
  `http://frigate.default.svc.cluster.local:5000`) + frigate-card with
  `live_provider: go2rtc, modes: [webrtc]` + `menu.buttons.microphone`.
- **k8s-gateway upstream migration** (was broken ~2 days unnoticed — chart
  + pod kept running, only the helmrepo refresh 404'd):
  - `k8s-gateway.github.io` index → 404; true new home is the
    `k8s-gateway/k8s_gateway` fork (GitHub read-only mirror + codeberg),
    Helm repo `https://k8s-gateway.kryptonian.kapsi.fi/`, chart 3.7.3,
    image `codeberg.org/k8s-gateway/k8s_gateway:1.8.3` (public).
  - intermediate detour through `ori-edge.github.io` was a dead end:
    chart 2.4.0 defaults to `quay.io/oriedge/k8s_gateway` which went
    **private** (401) — do NOT pin that.
  - debugging notes: a wedged kustomization reconcile survived `--force`;
    clearing required deleting the ks object + restarting
    kustomize-controller. Helm upgrade loops showed "release is in a
    failed state" while waiting on the crashlooping deployment.
  - split-DNS verified restored (v4+v6 records for envoy VIPs).
  - backlog idea (user): replace k8s-gateway with
    `mirceanton/external-dns-provider-mikrotik` (records written into
    RouterOS DNS — survives cluster outages; cost: router-side state).

### 2026-09-11 (evening) — Frigate lag root cause: VLAN routing + s6 caps

- **Symptom**: frigate UI/API lagging badly. Chain of causes, all fixed:
  1. **s6 log services crashloop**: `logutil-service` runs
     `s6-applyuidgid -U` (drop logs to nobody) — the runtime does NOT honor
     `caps.add: [SETGID]` for non-root containers (CapPrm=0 despite add),
     so setgroups always EPERMs. Fix: shim configmap mounted over
     `/package/admin/s6/command/s6-applyuidgid` that strips uid/gid flags
     and execs as container uid (frigate/s6/s6-applyuidgid). Watch the
     quoting: a case pattern `-g')` needs quoting or it's a syntax error.
  2. **ffmpeg lost its camera feed**: go2rtc dials the camera with an
     UNBOUND socket → dst route lookup hits the main table → eth0 →
     firewall timeout. sbr only routes SOURCE-bound traffic. Fix: add the
     on-link subnet route to each VLAN NAD (`{"dst": "10.40.0.0/24"}` etc.)
     so unbound dials ride the macvlan. NO YAML comments inside the CNI
     JSON string — multus fails to parse and EVERY pod with an attachment
     fails its sandbox (caught after all 3 NADs were broken together).
  3. Post-fix: camera_fps 4.2, detect 2.8, detector ~25ms, frames flowing.
- **Restarted frigate/matter-server/home-assistant** to pick up the NAD
  change (attachments apply at pod (re)creation only).
- `kubectl top` unusable on this cluster (no metrics-server) — debug via
  in-pod `/proc` + app /api/stats.

### 2026-09-11 (night) — Frigate REMOVED, go2rtc stands in

- **Frigate torn out entirely** (HR/pods/PVC/routes pruned). Why: the E1 Pro
  is a WiFi camera — Frigate's persistent dual-RTSP pulls (main for record +
  sub for detect, 24/7) choked its radio until it dropped off the network
  and rebooted. User verdict: too much load for WiFi cameras; future is
  either a second node or ethernet cameras. The go2rtc non-root/s6 work
  above remains valid reference material.
- **Standalone go2rtc deployed** (apps/default/go2rtc, alexxit/go2rtc
  1.9.9 pinned): streams are LAZY — producers dial the camera only while a
  consumer is viewing, so the camera gets zero idle load.
  - cameras VLAN macvlan 10.40.0.11 (same IP frigate used) + NAD on-link
    route handles unbound dials; webrtc candidate `10.40.0.11:8555` rides
    the router's clients->cameras UDP accept.
  - streams: `nursery` (main, plain) + `nursery_talk` (backchannel,
    only while talking). Ports 1984 API/UI, 8554 RTSP restream for HA's
    generic camera stream, 8555 WebRTC UDP.
  - creds: same 1P `reolink local admin` item → `go2rtc-secret` (with the
    urlquery-encoded copy). Route: `go2rtc.waltr.tech` (internal).
  - HA viewing: AlexxIT WebRTC card / frigate-card style config pointing
    at `go2rtc.waltr.tech:1984` (webrtc+mse), or generic camera entity on
    `rtsp://go2rtc.default.svc.cluster.local:8554/nursery`.

## Open questions

- [ ] Controlled reboot mechanism for OS updates: kured vs manual?

- [ ] SOPS+age (keep) vs 1Password Connect + ESO (adopt)?
- [ ] Dedicated service CIDR for BGP pool: `192.168.x.0/24` — pick one
- [ ] Router ASN / node ASN assignment
- [x] ~~Which VLAN ID is the "served" VLAN?~~ → **30 (iot) + 40 (cameras), both reached
  via k8s (home-assistant/macvlan or BGP), NOT configured on the host** (2026-08-13)
- [x] ~~`infra/k0s/kyz-0.yml` superseded by `mouse.yaml`~~ → deleted with uCore decom (2026-08-13)
- [x] ~~Do other hosts stay on uCore, or does everything move to Flatcar?~~ → everything moves; uCore decommissioned 2026-08-13
