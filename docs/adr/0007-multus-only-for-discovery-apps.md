# Multus/macvlan only for discovery-dependent apps

Status: accepted (2026-09-10)

Only apps that need layer-2 presence on a VLAN — mDNS, SSDP, Matter/Thread discovery;
the Home Assistant class — get a Multus macvlan attachment with a pinned IP and MAC.
Everything else is reached through routed BGP VIPs (ADR 0003). L2 attachments are
expensive here: they need host VLAN subinterfaces, promiscuous parents, a Cilium
`bpf.vlanBypass` list, and per-VLAN app configuration, and they bypass the cluster's
network model.

## Consequences

- Adding a VLAN attachment means touching Butane (subinterface + `Promiscuous=yes`),
  the Cilium `vlanBypass` list, and a NetworkAttachmentDefinition — and restarting the
  pod after the NAD exists.
- The node cannot reach its own macvlan children; verify from the router.

See `REFACTOR_PLANS.md` → the two "Additional decisions (2026-09-10 …)" entries.
