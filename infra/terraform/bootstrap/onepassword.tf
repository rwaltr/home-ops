# The operator's credential as a 1Password item, which is how it reaches the
# cluster: External Secrets reads this item and the HelmRelease consumes it.
#
# Note the shape. The 1Password provider can only write custom fields *inside* a
# section, and External Secrets resolves the two-level `item/field` references
# that every other secret in this repo uses. So the pair goes in a login item's
# top-level fields — client ID as the username, client secret as the password —
# rather than as fields conveniently named client_id/client_secret.
#
# Consequence worth knowing: the client secret is also in Terraform state, via
# tailscale_oauth_client.operator.key, which is sensitive but stored. That is the
# price of generating the credential here instead of pasting it by hand.
resource "onepassword_item" "tailscale_operator" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "tailscale-operator"
  category = "login"
  url      = "https://login.tailscale.com/admin/settings/oauth"

  username = tailscale_oauth_client.operator.id  # OAuth client ID
  password = tailscale_oauth_client.operator.key # OAuth client secret
}
