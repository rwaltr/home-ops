# MagicDNS: devices resolve each other by name instead of by 100.x address. It is
# plain VPN plumbing rather than a convenience — it is also what keeps a future
# swap of the control plane (self-hosted, or NetBird) from being a rewrite of
# everything that refers to a peer.
resource "tailscale_dns_preferences" "tailnet" {
  magic_dns = true
}
