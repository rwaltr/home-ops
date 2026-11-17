# FreshRSS's OIDC module needs one generated value: `OIDC_CLIENT_CRYPTO_KEY`, an
# opaque key the module uses for its own internal encryption. Nothing upstream issues
# it and nothing human needs to read it, so it is minted here rather than pasted.
#
# It is not a client credential — the client id and secret come from the
# KanidmOAuth2Client resource, which kaniop mints, so those stay out of Terraform
# state. This is the one value FreshRSS invents for itself.
#
# Rotating it invalidates in-flight OIDC sessions. That is the whole blast radius.
#
# Same shape as the other minted values: own item, login category, password field, so
# the ExternalSecret resolves `<item>`/`password` with the two-level reference used
# everywhere else in this repo. `random_password` produces on create only, so a later
# apply leaves it alone.

resource "random_password" "freshrss_oidc_crypto_key" {
  length  = 48
  special = false
}

resource "onepassword_item" "freshrss_oidc" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "freshrss-oidc"
  category = "login"
  url      = "https://feeds.waltr.tech"

  username = "freshrss"
  password = random_password.freshrss_oidc_crypto_key.result
}
