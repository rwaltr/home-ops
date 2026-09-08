# RouterOS hand-managed config (gateway-132l · MikroTik RB5009UG+S+)

Everything here is applied by hand and documented for reproducibility.
The cluster side of this peering lives in
`infra/k8s/kyz/apps/kube-system/cilium/app/networking.yaml`.

## BGP: accept Cilium LB VIPs from mouse

One session, two address families. Cilium (AS 64513, on mouse 10.10.0.10)
announces LoadBalancer VIPs as /32s (v4, from 10.10.100.0/24) and /128s (v6,
from `fdad:207a:f1ab:100::/64`). The router installs them toward mouse, making
VIPs reachable from every VLAN.

```routeros
/routing/bgp/connection
add name=mouse-k8s \
    local.address=10.10.0.1 local.as=64512 local.role=ebgp \
    remote.address=10.10.0.10/32 remote.as=64513 \
    address-families=ip,ipv6 connect=yes \
    router-id=10.10.0.1 \
    comment="Cilium LB VIPs (/32 v4 + /128 v6) from mouse k0s"
```

Notes:

- `address-families=ip,ipv6` — the v6 family sits idle until the cluster
  becomes dual-stack (k0s `dualStack` + Cilium `ipv6.enabled`); negotiating it
  now is harmless.
- BGP runs over TCP 179 — ensure the mgmt-VLAN input chain allows mouse
  → router :179 (and the established/related return).
- Optional hygiene: an input filter limiting what mouse may announce. If
  desired (verify exact filter syntax for your RouterOS version first):

```routeros
/routing/filter/rule
add chain=bgp-in-mouse-k8s rule="if (dst~10.10.100.0/24 || dst~fdad:207a:f1ab:100::/64) {accept} else {reject}"
# then on the connection: input.filter=bgp-in-mouse-k8s
```

## Verify

```routeros
/routing/bgp/connection print status   # want: established, uptime counting
/ip route print where dst-address~"10.10.100."        # want: 10.10.100.10 (kube-api)
/ping 10.10.100.10                                     # from a VLAN 20/30/60 client too
```

From any LAN client once peered:

```sh
nc -zv 10.10.100.10 6443   # kube-api via BGP VIP
```
