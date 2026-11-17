# Homepage's auth gate needs one generated value, and it has to be generated rather
# than pasted: `HOMEPAGE_AUTH_SECRET` signs and encrypts the session cookie, so it is
# a value nothing upstream issues and nothing human needs to read.
#
# Required as soon as `HOMEPAGE_AUTH_ENABLED` is on, whether or not OIDC is used —
# OIDC replaces the password, not the cookie secret. Upstream's minimum is 32
# characters; `openssl rand -base64 32` is what they suggest.
#
# Rotating it signs every session out. That is the whole blast radius, so unlike the
# HomeBox pepper it is safe to regenerate if it is ever exposed.
#
# Same shape as the other minted values: own item, login category, password field, so
# the ExternalSecret resolves `<item>`/`password` with the two-level reference used
# everywhere else in this repo. `random_password` produces on create only, so a later
# apply leaves it alone.
#
# The OIDC client credentials are NOT here — kaniop mints those from the
# KanidmOAuth2Client resource, so they have no business in Terraform state.

resource "random_password" "homepage_auth_secret" {
  length  = 48
  special = false
}

resource "onepassword_item" "homepage_auth" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "homepage-auth"
  category = "login"
  url      = "https://homepage.waltr.tech"

  # Names what the value is for, not who holds it — the item is Homepage's own.
  username = "homepage"
  password = random_password.homepage_auth_secret.result
}
