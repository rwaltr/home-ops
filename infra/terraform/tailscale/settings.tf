resource "tailscale_tailnet_settings" "tailnet" {
  # Stops the admin console editing this policy file by hand, and links to where
  # it actually lives. Without this, the console and git quietly diverge and the
  # next apply is a surprise.
  acls_externally_managed_on = true
  acls_external_link         = "https://github.com/rwaltr/home-ops/blob/main/infra/terraform/tailscale/policy.hujson"

  # Certificates for *.<tailnet>.ts.net, which the operator's Tailscale Ingress
  # needs to serve HTTPS to tailnet clients. Tailscale makes you acknowledge the
  # trade: enabling this publishes machine names and the tailnet DNS name on a
  # public Certificate Transparency ledger.
  https_enabled = true
}
