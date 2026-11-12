# The cluster's Cloudflare DNS tokens, minted here rather than pasted from the
# dashboard.
#
# The credential they replace is worth naming, because it explains why this
# exists: a *user*-scoped, never-expiring token, shared by external-dns and
# cert-manager, invisible to automation (an account token cannot read user
# tokens — `/user/tokens` answers "Valid user-level authentication not found"),
# and therefore unrevokable-by-one-consumer. Its loss or expiry would break DNS
# records and certificate renewal together.
#
# These are account-owned tokens instead of user-owned, so they outlive the
# person and this workspace can see and rotate them.
#
# Zone scope mirrors what each consumer actually asks for, read from the
# manifests rather than assumed:
#   external-dns  domainFilters: [waltr.tech]
#   cert-manager  selector.dnsZones: [rwalt.pro, waltr.tech]
#
# Nothing is switched over by applying this: the ExternalSecrets still read the
# old token until the flip described in docs/secrets.md.

data "cloudflare_accounts" "this" {
  name = "WaltrTech"
}

# Zones are looked up, not managed: the cloudflare workspace owns the zones
# themselves, and managing them from two states would fight.
data "cloudflare_zones" "waltr_tech" {
  name = "waltr.tech"
}

data "cloudflare_zones" "rwalt_pro" {
  name = "rwalt.pro"
}

locals {
  cloudflare_account_id = data.cloudflare_accounts.this.result[0].id

  # Filter to the exact name rather than trusting the lookup's match semantics:
  # a name filter that matched something else would quietly mint a token for the
  # wrong zone, and a policy that names a zone which does not exist is rejected
  # by the API at apply time.
  zone_ids = {
    waltr_tech = one([for z in data.cloudflare_zones.waltr_tech.result : z.id if z.name == "waltr.tech"])
    rwalt_pro  = one([for z in data.cloudflare_zones.rwalt_pro.result : z.id if z.name == "rwalt.pro"])
  }

  # Zone-level "DNS Write" (4755a26eedb94da69e1066d98aa820be). The zone scope
  # comes from the resources block, so the same group means "edit DNS in these
  # zones only". Not the account-level DNS group, which would allow editing zone
  # configuration as well.
  dns_write_group = "4755a26eedb94da69e1066d98aa820be"

  # A finite expiry on purpose: the token it replaces never expires, so nothing
  # would ever prompt a rotation. Extending this date is a one-line apply, and
  # the expiry is readable from the Cloudflare API, so it can be monitored.
  dns_token_expiry = "2027-11-09T00:00:00Z"
}

resource "cloudflare_account_token" "external_dns" {
  account_id = local.cloudflare_account_id
  name       = "home-ops-external-dns"

  policies = [{
    effect            = "allow"
    permission_groups = [{ id = local.dns_write_group }]
    resources = jsonencode({
      "com.cloudflare.api.account.zone.${local.zone_ids.waltr_tech}" = "*"
    })
  }]

  expires_on = local.dns_token_expiry

  # Rotation order matters more than it looks: replacing the token while
  # cert-manager is mid-renewal would leave the ClusterIssuer unable to answer
  # DNS-01. create_before_destroy mints the replacement first, so the 1Password
  # item only ever moves to a working value.
  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_account_token" "cert_manager" {
  account_id = local.cloudflare_account_id
  name       = "home-ops-cert-manager"

  policies = [{
    effect            = "allow"
    permission_groups = [{ id = local.dns_write_group }]
    resources = jsonencode({
      "com.cloudflare.api.account.zone.${local.zone_ids.waltr_tech}" = "*"
      "com.cloudflare.api.account.zone.${local.zone_ids.rwalt_pro}"  = "*"
    })
  }]

  expires_on = local.dns_token_expiry

  lifecycle {
    create_before_destroy = true
  }
}
