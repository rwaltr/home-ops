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
where their restrictions live (currently empty → fall-through back to the
default deny, logged); untrusted's jump exists but is disabled. All sit before
the `any -> any` default deny. Reply traffic rides established/related +
fasttrack.

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
```

Onboarding a restricted zone's service = one accept in the shared chain
(e.g. `add chain=k8s-vips comment="cameras -> frigate vip" action=accept
dst-address=10.10.100.21 in-interface=vlan40-cameras`).

## Verify

```routeros
/routing/bgp/connection print status    # both sessions: established
/ip route print where dst-address~"10.10.100."        # v4 /32s via 10.10.0.10
/ipv6 route print where dst-address~"fdad:207a:f1ab:100"  # v6 /128s via native v6
```

From any mgmt/clients host once peered (ping to a VIP is NOT expected to
answer — Cilium only forwards the service's TCP/UDP port):

```sh
nc -zv 10.10.100.10 6443                          # kube-api v4 VIP
kubectl --server=https://[fdad:207a:f1ab:100::10]:6443 get --raw=/healthz
```
