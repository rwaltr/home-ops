# MagicDNS: devices resolve each other by name instead of by 100.x address. It is
# plain VPN plumbing rather than a convenience — it is also what keeps a future
# swap of the control plane (self-hosted, or NetBird) from being a rewrite of
# everything that refers to a peer.
resource "tailscale_dns_preferences" "tailnet" {
  magic_dns = true
}

# Split DNS: tailnet clients resolve the internal hostnames through the cluster's
# own resolver, k8s-gateway (VIP 10.10.100.53), rather than the public zone —
# which only carries the hostnames published through envoy-external. k8s-gateway
# answers each HTTPRoute with the VIP of the Gateway serving it, so both planes
# resolve correctly and the internal hostnames work away from home.
#
# This is the tailnet counterpart of what the router already does for LAN
# clients, and it only works because the operator's Connector advertises
# 10.10.100.0/24 — the resolver address is inside that range.
resource "tailscale_dns_split_nameservers" "waltr_tech" {
  domain      = "waltr.tech"
  nameservers = ["10.10.100.53"]
}
