data "cloudflare_zones" "legacy_domain" {
  filter {
    name = local.my_domains["personallegacy"]
  }
}

# Email Records /
resource "cloudflare_record" "legacy_MigaduVerify" {
  type = "TXT"
  name = "@"
  value = "hosted-email-verify=xr7ptjnw"
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_mx1" {
  type = "MX"
  name = "@"
  value = "aspmx1.migadu.com"
  priority = 10
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_mx2" {
  type = "MX"
  name = "@"
  value = "aspmx2.migadu.com"
  priority = 20
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_dkim1" {
  type = "CNAME"
  name = "key1._domainkey"
  value = "key1.blackphidora.com._domainkey.migadu.com."
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_dkim2" {
  type = "CNAME"
  name = "key2._domainkey"
  value = "key2.blackphidora.com._domainkey.migadu.com."
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_dkim3" {
  type = "CNAME"
  name = "key3._domainkey"
  value = "key3.blackphidora.com._domainkey.migadu.com."
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_spf" {
  type = "TXT"
  name = "@"
  value = "v=spf1 include:spf.migadu.com -all"
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_dmarc" {
  type = "TXT"
  name = "_dmarc"
  value = "v=DMARC1; p=quarantine;"
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

# / Email Records

# Old records

# resource "cloudflare_record" "legacy_mx1" {
#   name     = "blackphidora.com"
  # zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
#   value    = "mail.protonmail.ch"
#   proxied  = false
#   type     = "MX"
#   ttl      = 1
#   priority = 10
# }
#
# resource "cloudflare_record" "legacy_mx2" {
#   name     = "blackphidora.com"
#   zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
#   value    = "mailsec.protonmail.ch"
#   proxied  = false
#   type     = "MX"
#   ttl      = 1
#   priority = 20
# }
#
# resource "cloudflare_record" "legacy_spf" {
#   name    = "blackphidora.com"
#   zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
#   value   = "v=spf1 include:_spf.protonmail.ch mx ~all"
#   proxied = false
#   type    = "TXT"
#   ttl     = 1
# }
#
# resource "cloudflare_record" "legacy_dmarc" {
#   name    = "_dmarc"
#   zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
#   value   = "v=DMARC1; p=quarantine"
#   proxied = false
#   type    = "TXT"
#   ttl     = 1
# }
#
# resource "cloudflare_record" "legacy_protonmail_verify" {
#   name    = "blackphidora.com"
#   zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
#   value   = "protonmail-verification=76ef6e985c19106f5d161e541cf9aa11956f4abe"
#   proxied = false
#   type    = "TXT"
#   ttl     = 1
# }
#
#
# resource "cloudflare_record" "legacy_protonmail_domainkey1" {
#   name    = "protonmail._domainkey"
#   zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
#   value   = "protonmail.domainkey.du4z6xo4ilxoxjbq6yqjpanjc25vcvijosketmsajtsr7ecrshn3a.domains.proton.ch"
#   proxied = false
#   type    = "CNAME"
#   ttl     = 1
# }
#
#
# resource "cloudflare_record" "legacy_protonmail_domainkey2" {
#   name    = "protonmail2._domainkey"
#   zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
#   value   = "protonmail2.domainkey.du4z6xo4ilxoxjbq6yqjpanjc25vcvijosketmsajtsr7ecrshn3a.domains.proton.ch"
#   proxied = false
#   type    = "CNAME"
#   ttl     = 1
# }
#
# resource "cloudflare_record" "legacy_protonmail_domainkey3" {
#   name    = "protonmail3._domainkey"
#   zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
#   value   = "protonmail3.domainkey.du4z6xo4ilxoxjbq6yqjpanjc25vcvijosketmsajtsr7ecrshn3a.domains.proton.ch"
#   proxied = false
#   type    = "CNAME"
#   ttl     = 1
# }
