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

## Verify

```routeros
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
