# Nameserver delegation for the domains registered at Porkbun. The nameservers
# are read back from Cloudflare rather than hardcoded, so a Cloudflare
# reassignment (or a zone re-add) propagates to the registrar on the next apply.
# Register another domain at Porkbun -> add it here and nothing else.
locals {
  porkbun_domains = toset([
    "waltr.tech",
    "blackphidora.com",
    "rwwalter.com",
    "rwalt.pro",
  ])
}

# Singular data source: it exposes name_servers, the plural cloudflare_zones does not.
data "cloudflare_zone" "porkbun" {
  for_each = local.porkbun_domains
  filter = {
    name = each.value
    account = {
      id = cloudflare_account.waltrtech.id
    }
  }
}

resource "porkbun_domain_nameservers" "domain" {
  for_each    = data.cloudflare_zone.porkbun
  domain      = each.key
  nameservers = each.value.name_servers
}

