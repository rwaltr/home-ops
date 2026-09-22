# RouterOS hand-managed config (gateway-132l · MikroTik RB5009UG+S+)

Everything here is applied by hand and documented for reproducibility.
The cluster side of this peering lives in
`infra/k8s/kyz/apps/kube-system/cilium/app/networking.yaml`.

## BGP: accept Cilium LB VIPs from mouse

**Two sessions, one per family.** A v4-transport session advertising v6 NLRI
yields a v4-mapped next-hop (`::ffff:10.10.0.10` — 6PE/MPLS semantics), which
RouterOS cannot use for plain-Ethernet v6 forwarding. Splitting the families
gives each session a native next-hop.

- v4 transport (10.10.0.1 ↔ 10.10.0.10): v4 VIP /32s from `10.10.100.0/24`
- v6 transport (`fdad:207a:f1ab:10::1` ↔ `fdad:207a:f1ab:10::10`): v6 VIP
  /128s from `fdad:207a:f1ab:100::/64`

ASNs: Cilium 64513 (mouse), router 64512.

```routeros
/routing/bgp/connection
add afi=ip as=64512 connect=yes local.address=10.10.0.1 local.role=ebgp \
    name=mouse-k8s remote.address=10.10.0.10/32 remote.as=64513 \
    routing-table=main instance=kyz-k8s comment="Cilium LB VIPs v4"
add afi=ipv6 as=64512 connect=yes local.address=fdad:207a:f1ab:10::1 \
    local.role=ebgp name=mouse-k8s-v6 \
    remote.address=fdad:207a:f1ab:10::10/128 remote.as=64513 \
    routing-table=main instance=kyz-k8s comment="Cilium LB VIPs v6 (v6 transport)"
```

BGP runs over TCP 179. v4: mgmt has full router access already. v6 needed an
explicit input allow (LAN's v6 router chain only opens DHCP/DNS/NTP):

```routeros
/ipv6/firewall/filter
add action=accept chain=input comment="mouse -> router: BGP v6 (k8s)" \
    protocol=tcp dst-port=179 src-address=fdad:207a:f1ab:10::10
```

## Static DNS: mouse

k0s dual-stack node-IP autodetection resolves its own hostname via DNS —
without these, the controller crash-loops (`lookup mouse: no such host`).
Also the natural home for LAN-wide names:

```routeros
/ip/dns/static
add address=10.10.0.10 comment="mouse · Flatcar host" name=mouse
add address=fdad:207a:f1ab:10::10 comment="mouse · v6" name=mouse
```

## Split DNS: waltr.tech (ops zone) → in-cluster resolver

`waltr.tech` is the k8s ops zone — served internally by the in-cluster
k8s-gateway (CoreDNS plugin) at VIP `10.10.100.53` /
`fdad:207a:f1ab:100::53`; it answers from Gateway/HTTPRoute/Service
resources. Conditional forward on the router — **`match-subdomain=yes` is
required** (without it only the exact name forwards, subdomains NXDOMAIN):

```routeros
/ip/dns/static
add type=FWD name=waltr.tech forward-to=10.10.100.53 match-subdomain=yes comment="k8s internal DNS (waltr.tech ops zone)"
add type=FWD name=waltr.tech forward-to=fdad:207a:f1ab:100::53 match-subdomain=yes comment="k8s internal DNS (waltr.tech ops zone, v6)"
```

Public records for the same names are published by external-dns to the
Cloudflare `waltr.tech` zone; publicly-exposed services route through the
cloudflare tunnel (attach the HTTPRoute to `envoy-external`, the record then
targets `external.waltr.tech` → tunnel CNAME). Internal VIPs in public DNS
(CGNAAT makes them unreachable from outside) is accepted. `k8s.waltr.tech`
(kube-api) is internal-only: annotated `coredns.io/hostname` on the Service
serves it via k8s-gateway, and external-dns's source (`gateway-httproute`)
never publishes plain Services. Mail on waltr.tech (Migadu) is unaffected:
MX/DKIM/SPF lookups happen at external receiving servers, never on LAN
clients. Tailscale clients get the same view via the tailscale operator
(future phase).

## VIP address lists

Convention: `v4-*` / `v6-*` names. VIP blocks are list edits, not rule edits.

```routeros
/ip/firewall/address-list
add address=10.10.100.0/24 comment="Cilium LB VIPs (BGP)" list=v4-k8s-vips
add address=10.42.0.0/16 comment="Cilium pods (k0s pod CIDR)" list=v4-k8s-pods
add address=10.96.0.0/12 comment="Cilium services (k0s service CIDR)" list=v4-k8s-services
/ipv6/firewall/address-list
add address=fdad:207a:f1ab:100::/64 comment="Cilium LB VIPs v6 (BGP)" list=v6-k8s-vips
```

## Firewall: zone access to the VIP space

Model (v4 and v6 twins): mgmt + clients get full access as direct accepts;
iot/cameras jump into one shared chain per family (`k8s-vips` / `k8s-vips6`)
where their restrictions live: web ports (TCP 80/443 + UDP 443 for HTTP/3)
are accepted, everything else falls through to the default deny, logged;
untrusted's jump exists but is disabled. All sit before the `any -> any`
default deny. Reply traffic rides established/related + fasttrack.

> 2026-09-11: chains populated with the web allows (v4+v6) — phones on IoT
> couldn't reach `homeassistant.waltr.tech` (envoy VIPs) while the chain was
> empty; every SYN logged as ZONEDENY. Keep the v4/v6 chains symmetric.

```routeros
/ip/firewall/filter
add action=accept chain=forward comment="mgmt -> k8s vips: full access" \
    dst-address-list=v4-k8s-vips in-interface-list=MGMT out-interface=vlan10-mgmt
add action=accept chain=forward comment="clients -> k8s vips: full access" \
    dst-address-list=v4-k8s-vips in-interface=vlan20-clients out-interface=vlan10-mgmt
add action=jump chain=forward comment="iot -> k8s vips: jump" \
    dst-address-list=v4-k8s-vips in-interface=vlan30-iot jump-target=k8s-vips out-interface=vlan10-mgmt
add action=jump chain=forward comment="cameras -> k8s vips: jump" \
    dst-address-list=v4-k8s-vips in-interface=vlan40-cameras jump-target=k8s-vips out-interface=vlan10-mgmt
add action=jump chain=forward comment="untrusted -> k8s vips: jump" disabled=yes \
    dst-address-list=v4-k8s-vips in-interface=vlan60-untrusted jump-target=k8s-vips out-interface=vlan10-mgmt

add action=accept chain=k8s-vips comment="k8s vips: web (HTTP/HTTPS)" \
    protocol=tcp dst-port=80,443
add action=accept chain=k8s-vips comment="k8s vips: HTTP/3 (QUIC)" \
    protocol=udp dst-port=443

/ipv6/firewall/filter
add action=accept chain=forward comment="mgmt -> k8s vips: full access" \
    dst-address-list=v6-k8s-vips in-interface-list=MGMT out-interface=vlan10-mgmt
add action=accept chain=forward comment="clients -> k8s vips: full access" \
    dst-address-list=v6-k8s-vips in-interface=vlan20-clients out-interface=vlan10-mgmt
add action=jump chain=forward comment="iot -> k8s vips: jump" \
    dst-address-list=v6-k8s-vips in-interface=vlan30-iot jump-target=k8s-vips6 out-interface=vlan10-mgmt
add action=jump chain=forward comment="cameras -> k8s vips: jump" \
    dst-address-list=v6-k8s-vips in-interface=vlan40-cameras jump-target=k8s-vips6 out-interface=vlan10-mgmt
add action=jump chain=forward comment="untrusted -> k8s vips: jump" disabled=yes \
    dst-address-list=v6-k8s-vips in-interface=vlan60-untrusted jump-target=k8s-vips6 out-interface=vlan10-mgmt

add action=accept chain=k8s-vips6 comment="k8s vips6: web (HTTP/HTTPS)" \
    protocol=tcp dst-port=80,443
add action=accept chain=k8s-vips6 comment="k8s vips6: HTTP/3 (QUIC)" \
    protocol=udp dst-port=443
```

Onboarding a restricted zone's service = one accept in the shared chain
(e.g. `add chain=k8s-vips comment="cameras -> frigate vip" action=accept
dst-address=10.10.100.21 in-interface=vlan40-cameras`).

### Same-VLAN v6 hairpin: the conntrack exception

Cilium LB uses DSR: replies leave the node **directly at L2** to the client.
When client and node share a VLAN (mgmt here), the router forwards the SYN but
never sees the SYN-ACK — its conntrack marks the client's follow-up packets
`invalid` and `defconf: drop invalid` eats them until retransmit timeout
(≈6.6s on every new connection). Cross-VLAN clients are symmetric and immune.
v4 is immune only because RouterOS v4 conntrack tracks loosely; v6 does not.

This is the documented "routing triangle" problem — cilium/cilium#34972
(MikroTik users, same signature), MikroTik forum t=171177, r/kubernetes BGP
VIP threads. Chosen fix (Option A below): a scoped `accept invalid` for the
mgmt hairpin to the v6 VIP list only:

```routeros
/ipv6/firewall/filter
add action=accept chain=forward \
    comment="mgmt hairpin -> k8s v6 vips: DSR replies bypass router (asymmetric in conntrack) - see cilium#34972" \
    connection-state=invalid dst-address-list=v6-k8s-vips \
    in-interface=vlan10-mgmt out-interface=vlan10-mgmt
```

(placed before `defconf: drop invalid`). Alternatives considered:

- **B — router src-NAT on the hairpin**: fully symmetric flows, no invalid
  packets, but services lose real client IPs and replies take an extra hop
- **C — per-client static routes**: works but unmanageable for phones/IoT
- **D — dedicated service VLAN for cluster + VIPs**: the structurally correct
  fix; revisit when a second node joins

Verified: 6.6s → ~3ms first-byte on fresh v6 connections from same-VLAN
clients. The exception is safe-to-spoof only in a narrow sense: a packet must
already have been routed by this router toward a Cilium LB service port on the
VIP list to reach this rule at all.

## Matter over Thread across VLANs

**2026-09-22 — the OTBR moved off the SLZB and into the cluster.** The
SLZB-Ultima3 now runs Mode "Thread to remote OTBR": a Thread RCP (radio only)
exposing Serial-over-IP on `tcp/6638`, still on `vlan10-mgmt` (its web UI is
unauthenticated and must not sit on the iot VLAN). `otbr-agent` runs as a pod
(`default/otbr`, `bnutzer/otbr-tcp`) with a multus macvlan interface on
`vlan30-iot` (`10.30.0.13`), so the border agent, mDNS and SRP advertising
proxy share L2 with the Thread devices **and** matter-server. That removed the
cross-VLAN mDNS problem and is what makes OTA-provider discovery work.

Consequences worth remembering:

- Thread traffic no longer touches the router: matter-server learns the OMR
  from the OTBR's RA and the OTBR forwards `net1` <-> `wpan0`.
- The OTBR pod needs `net.ipv6.conf.all.forwarding=1` **and**
  `net.ipv6.conf.net1.accept_ra=2`. Enabling forwarding makes the kernel ignore
  RAs (`accept_ra=1` accepts only while not forwarding), which strips `net1`'s
  global addresses and the routes to the infra prefixes. k0s allows no unsafe
  sysctls, so both are set by a privileged init container, not
  `securityContext.sysctls` (kubelet: `SysctlForbidden`).
- OpenThread advertises the OMR as an **RFC 4191 Route Information Option**,
  which Linux ignores unless `accept_ra_rt_info_max_plen > 0`; matter-server
  sets that on `net1` via an init container. RouterOS ignores RIOs entirely,
  so the router keeps a **static** route to the OMR.
- The OMR prefix is minted by the border routing manager (`fd85:2657:315b:1::/64`
  now, not the old `fdde:c7ce:397e:1::/64`) and persists in the OTBR's
  `/var/lib/thread` PVC, so it is stable across restarts but changes if that
  PVC is lost. Check with `wrap-ot-ctl br omrprefix`.
- HA's `otbr` integration URL must be repointed at the pod Service
  (`http://otbr:8081`), not the old SLZB REST (`http://10.10.0.101:8080`).

**2026-09-20 — before the move, the SLZB-Ultima3 OTBR lived on `vlan10-mgmt` (`10.10.0.101`,
ULA `fdad:207a:f1ab:10:d405:92ff:fe6f:fe78`), while the controller pods have
L2 presence on `vlan30-iot` and the commissioning phone is on
`vlan20-clients`.** Commissioning "worked" but the phone's post-pairing
"confirm connectivity" step failed. Root cause was two separate gaps, both on
the router side:

1. **The router never learned the Thread route.** RouterOS only accepts RA by
   default when forwarding is off (`accept-router-advertisements` defaults to
   `yes-if-forwarding-disabled`, and `ipv6 forward=yes` here), so the OTBR's RA
   did no good. The k8s node `mouse` _is_ a host and kept a `proto ra` route
   `fdde:c7ce:397e:1::/64 via fe80::d405:92ff:fe6f:fe78`, which is why HA /
   matter-server could reach Thread devices straight over the OTBR's link-local
   — and why the breakage only showed up on the phone.
2. **The ULA catch-all black-holed it.** `fc00::/7 → blackhole` (the "ula
   catch-all" route) silently drops any ULA prefix without a more-specific
   route, including the Thread OMR prefix. Router ping to a Thread address was
   100% loss until the route below existed; the pod ping was 0% loss the whole
   time (different path — see #1).

```routeros
# Static route is deliberate: RouterOS ignores the OTBR's RFC 4191 RIO, so the
# OMR route is pinned. Gateway is the OTBR pod's net1 link-local on vlan30.
/ipv6/route
add dst-address=fd85:2657:315b:1::/64 \
    gateway=fe80::a430:ff:fe10:300d%vlan30-iot distance=1 \
    comment="Thread OMR -> k8s OTBR (vlan30)"

# clients zone -> OTBR / Thread devices, before the any->any default deny
/ipv6/firewall/filter
add action=accept chain=forward comment="clients -> OTBR iot ULA (Border Agent)" \
    in-interface=vlan20-clients out-interface=vlan30-iot \
    dst-address=fdad:207a:f1ab:30:a430:ff:fe10:300d
add action=accept chain=forward comment="clients -> Thread OMR (k8s OTBR, vlan30)" \
    in-interface=vlan20-clients out-interface=vlan30-iot \
    dst-address=fd85:2657:315b:1::/64
```

The v4 rule (`clients -> 10.10.0.101`) was tried and removed — the actual
confirm hit the v6 OMR allow and nothing used the v4/REST path. Verified:
phone confirm now increments the OMR rule (244 B/pkt), and the `any -> any`
default deny does not move.

### Findings: why Thread is painful with many VLANs

- **Thread is its own L2; the border router is the only L3 door.** All Thread
  device traffic arrives as the OMR prefix (`fdde:c7ce:397e:1::/64` here,
  chosen at commissioning time) on the OTBR's LAN segment. Every router that
  sits between a client and the OTBR needs a route for it — hosts that consume
  RAs get it free, forwarding routers do not. The prefix is not static: a new
  dataset/commission can change it and silently break everything until the route
  is updated.
- **mDNS gives false confidence.** `_meshcop._udp` is link-local multicast
  (`ff02::fb`). The router's mDNS repeater (`/ip/dns/mdns-repeat-ifaces`, here
  vlan10 + vlan20 + vlan30) reflects **IPv4 mDNS only** — v6 link-local cannot
  be repeated by design. So the phone _discovers_ the OTBR across VLANs, but the
  addresses it then needs (ULA/OMR, and the Thread border agent) still require
  L3 routing and a firewall allow. Discovery working ≠ connectivity working.
- **The controller and border router should share a VLAN.** Matter/Thread's
  mDNS service records (`_matter._tcp`, `_matterc._udp`, `_meshcop._udp`) and
  Thread itself are link-local-first. Co-locating HA/matter-server with the
  OTBR (or the OTBR with them) avoids the route + allow entirely. The earlier
  "put matter-server on the iot VLAN" fix followed this reasoning; the OTBR
  staying on mgmt is what created the split.
- **Server-side vs phone-side paths diverge.** In-cluster pods reached Thread
  via `mouse`'s RA route while the router black-holed it, so the server "worked"
  and only the phone failed. Debugging this needs to start from _where the
  packet enters the router_, not from whether HA "sees" the border router.
- **IPv6 default-deny was silent.** The v6 `any -> any` drop had no `log=yes`
  (unlike v4's `ZONEDENY`), so cross-zone v6 failures were invisible. If you're
  debugging Thread/Matter, enable logging on it first (`log=yes
log-prefix=ZONEDENY6`), or you'll stare at an empty log while packets vanish.
- **BLE commissioning is out of band.** `commission_with_code: Bluetooth
commissioning is not available` comes from matter-server, which needs a real
  adapter (D-Bus + `/dev/hci*`). ESPHome Bluetooth proxies only extend HA's
  `bluetooth` integration — they cannot serve matter-server. Thread credential
  sync to the phone is likewise separate from this IP path.
- **Zone model reminder:** there is no generic `clients -> mgmt` (or `iot ->
mgmt`) allow — only the k8s VIP block. The OTBR is a plain mgmt host, so every
  controller-to-OTBR flow needs an explicit, narrowly-scoped accept like the
  ones above.

## Verify

```routeros
/ipv6 route print where comment~"Thread OMR"   # As, via OTBR pod LL on vlan30-iot
/ipv6 firewall filter print stats where comment~"Thread OMR"  # increments on phone confirm
/routing/bgp/connection print status    # both sessions: established
/ip route print where dst-address~"10.10.100."        # v4 /32s via 10.10.0.10
/ipv6 route print where dst-address~"fdad:207a:f1ab:100"  # v6 /128s via native v6
```

From any mgmt/clients host once peered (ping to a VIP is NOT expected to
answer — Cilium only forwards the service's TCP/UDP port):

```sh
nc -zv 10.10.100.20 80                                  # e2e-http v4 VIP
curl "http://[fdad:207a:f1ab:100::20]/"                # e2e-http v6 VIP
nc -zv 10.10.100.10 6443                               # kube-api v4 VIP
kubectl --server=https://[fdad:207a:f1ab:100::10]:6443 get --raw=/healthz
```
