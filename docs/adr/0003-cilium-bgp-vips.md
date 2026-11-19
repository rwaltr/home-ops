# LoadBalancer VIPs announced over BGP, one session per address family

Status: accepted (2026-09-08)

Cilium (kube-proxy replacement) announces LoadBalancer VIPs from
`10.10.100.0/24` and `fdad:207a:f1ab:100::/64` to the MikroTik over BGP as /32s and
/128s (mouse AS 64513, router AS 64512). This replaces MetalLB and L2 announcements:
the router speaks BGP, and routed VIPs need no ARP/NDP tricks on a single node.

There are **two BGP sessions, one per family**, not one multiprotocol session. A
v4-transport session carrying v6 NLRI produces a `::ffff:`-mapped next-hop (6PE
semantics) that RouterOS will not forward plain v6 through, so v6 VIPs silently died
at the router. Native next-hops per family fixed it.

## Consequences

- Same-VLAN clients hit a DSR hairpin: replies go L2-direct, the router sees half a
  flow, and v6 conntrack drops it as invalid. A scoped accept rule on the router
  (`infra/routeros/README.md`) covers it; a dedicated service VLAN is the structural fix,
  deferred until a second node.

See `REFACTOR_PLANS.md` → "Additional decisions (2026-09-08, dual-stack + BGP VIPs)"
and `infra/k8s/kyz/apps/kube-system/cilium/app/networking.yaml`.
