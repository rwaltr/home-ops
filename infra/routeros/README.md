# RouterOS hand-managed config (gateway-132l · MikroTik RB5009UG+S+)

Everything here is applied by hand and documented for reproducibility.
The cluster side of this peering lives in
`infra/k8s/kyz/apps/kube-system/cilium/app/networking.yaml`.

## BGP: accept Cilium LB VIPs from mouse

One session, two address families. Cilium (AS 64513, on mouse 10.10.0.10)
announces LoadBalancer VIPs as /32s (v4, from 10.10.100.0/24) and /128s (v6,
from `fdad:207a:f1ab:100::/64`). The router installs them toward mouse, making
VIPs reachable from every VLAN.

As-built on the router (note: the connection carries its own AS override; the
auto-created `kyz-k8s` instance still shows as=64513 but the connection's
`as=64512` governs the session):

```routeros
/routing/bgp/connection
add afi=ip,ipv6 as=64512 connect=yes local.address=10.10.0.1 local.role=ebgp \
    name=mouse-k8s remote.address=10.10.0.10/32 remote.as=64513 \
    routing-table=main instance=kyz-k8s
```

Notes:

- The v6 family sits idle until the cluster becomes dual-stack (k0s
  `dualStack` + Cilium `ipv6.enabled`); negotiating it now is harmless.
- BGP runs over TCP 179 — ensure the mgmt-VLAN input chain allows mouse
  → router :179 (mgmt has full router access already).

## VIP address list

The VIP block is held in an address-list (convention: `v4-*` names) so new
blocks are list edits, not rule edits:

```routeros
/ip firewall address-list
add address=10.10.100.0/24 comment="Cilium LB VIPs (BGP)" list=v4-k8s-vips
```

Related pre-existing lists (planned 2026-07-31, currently unused):
`v4-k8s-pods` (10.90.0.0/16), `v4-k8s-services` (10.91.0.0/16),
`v4-k8s-lb` (10.92.0.0/16). **TODO(align):** decide whether the live VIP pool
(10.10.100.0/24) should migrate to the planned `v4-k8s-lb` space — would
change the Cilium pool + kube-api VIP + these rules together.

## Firewall: zone access to the VIP space

Model: mgmt + clients get full access as direct accepts; iot/cameras jump
into one shared `k8s-vips` chain where their restrictions will live (currently
empty → fall-through back to `ZONEDENY`, logged); untrusted's jump exists but
is disabled until a decision is made. All sit before the `ZONEDENY` default
deny. Reply traffic rides the established/related accept + fasttrack.

```routeros
/ip firewall filter
add action=accept chain=forward comment="mgmt -> k8s vips: full access" \
    dst-address-list=v4-k8s-vips in-interface-list=MGMT out-interface=vlan10-mgmt
add action=accept chain=forward comment="clients -> k8s vips: full access" \
    dst-address-list=v4-k8s-vips in-interface=vlan20-clients out-interface=vlan10-mgmt
add action=jump chain=forward comment="iot -> k8s vips: jump" \
    dst-address-list=v4-k8s-vips in-interface=vlan30-iot jump-target=k8s-vips \
    out-interface=vlan10-mgmt
add action=jump chain=forward comment="cameras -> k8s vips: jump" \
    dst-address-list=v4-k8s-vips in-interface=vlan40-cameras jump-target=k8s-vips \
    out-interface=vlan10-mgmt
add action=jump chain=forward comment="untrusted -> k8s vips: jump" disabled=yes \
    dst-address-list=v4-k8s-vips in-interface=vlan60-untrusted jump-target=k8s-vips \
    out-interface=vlan10-mgmt
```

Onboarding a restricted zone's service = one accept in the `k8s-vips` chain
(e.g. `add chain=k8s-vips comment="cameras -> frigate vip" action=accept
dst-address=10.10.100.21 in-interface=vlan40-cameras`).

The `/ipv6 firewall filter` twin (`fdad:207a:f1ab:100::/64`) lands with the
dual-stack phase.

## Verify

```routeros
/routing/bgp/connection print status   # want: established, uptime counting
/ip route print where dst-address~"10.10.100."        # want: 10.10.100.10 (kube-api)
```

From any mgmt/clients host once peered (ping to a VIP is NOT expected to
answer — Cilium only forwards the service's TCP/UDP port):

```sh
nc -zv 10.10.100.10 6443   # kube-api via BGP VIP
kubectl --server=https://10.10.100.10:6443 get --raw=/healthz
```
