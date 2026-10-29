data "cloudflare_zones" "public_domain" {
  name = local.my_domains["personal"]
}

#
# resource "cloudflare_record" "public_mx1" {
#   name     = "waltr.tech"
#   value    = "mail.protonmail.ch"
#   type     = "MX"
#   priority = "10"
#   zone_id  = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   ttl      = 1
#   proxied  = false
# }
#
# resource "cloudflare_record" "public_mx2" {
#   name     = "waltr.tech"
#   value    = "mailsec.protonmail.ch"
#   type     = "MX"
#   priority = "20"
#   zone_id  = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   ttl      = 1
#   proxied  = false
# }
#
# resource "cloudflare_record" "public_dmarc" {
#   name    = "_dmarc"
#   value   = "v=DMARC1; p=none"
#   zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   ttl     = 1
#   proxied = false
#   type    = "TXT"
# }
#
# resource "cloudflare_record" "public_spf" {
#   name    = "waltr.tech"
#   value   = "v=spf1 include:_spf.protonmail.ch mx ~all"
#   zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   ttl     = 1
#   proxied = false
#   type    = "TXT"
# }
#
# resource "cloudflare_record" "public_protonmail_verify" {
#   name    = "waltr.tech"
#   value   = "protonmail-verification=49547740ee7975bcce254d09c76c57dbd22ae672"
#   zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   ttl     = 1
#   proxied = false
#   type    = "TXT"
# }
#
# resource "cloudflare_record" "public_protonmail_donainkey1" {
#   name    = "protonmail._domainkey"
#   value   = "protonmail.domainkey.dwigogkdcjwayzy3t2jp74ogrjtrij5a6bnxm3u25aocolxjgtwiq.domains.proton.ch"
#   zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   ttl     = 1
#   proxied = false
#   type    = "CNAME"
# }
#
# resource "cloudflare_record" "public_protonmail_donainkey2" {
#   name    = "protonmail2._domainkey"
#   value   = "protonmail2.domainkey.dwigogkdcjwayzy3t2jp74ogrjtrij5a6bnxm3u25aocolxjgtwiq.domains.proton.ch"
#   zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   ttl     = 1
#   proxied = false
#   type    = "CNAME"
# }
#
# resource "cloudflare_record" "public_protonmail_donainkey3" {
#   name    = "protonmail3._domainkey"
#   value   = "protonmail3.domainkey.dwigogkdcjwayzy3t2jp74ogrjtrij5a6bnxm3u25aocolxjgtwiq.domains.proton.ch"
#   zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   ttl     = 1
#   proxied = false
#   type    = "CNAME"
# }

# Bots and threats

# resource "cloudflare_filter" "bots_and_threats" {
#
#   zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   description = "Expression to block bots and threats determined by CF"
#   expression  = "(cf.client.bot) or (cf.threat_score gt 14)"
# }
#
# resource "cloudflare_firewall_rule" "bots_and_threats" {
#
#
#   zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
#   description = "Firewall rule to block bots and threats determined by CF"
#   filter_id   = cloudflare_filter.bots_and_threats.id
#   action      = "block"
# }

resource "cloudflare_dns_record" "public_githubverify" {
  name    = "_github-pages-challenge-rwaltr"
  type    = "TXT"
  content = "b79e49f4db1fd5edf70c1ccaf4a124"
  zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  ttl     = 1
}

moved {
  from = cloudflare_record.public_githubverify
  to   = cloudflare_dns_record.public_githubverify
}

# Was a hand-made record until now (not owned by external-dns).
resource "cloudflare_dns_record" "public_keybase" {
  name    = "waltr.tech"
  zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  type    = "TXT"
  content = "keybase-site-verification=i3hgyKry6zWhKMMXBj87-yQrHAFfJOWt6sCqmG1slfk"
  ttl     = 3600
}

moved {
  from = cloudflare_record.public_keybase
  to   = cloudflare_dns_record.public_keybase
}

# Email Records /
resource "cloudflare_dns_record" "public_MigaduVerify" {
  type    = "TXT"
  name    = "@"
  content = "hosted-email-verify=ddjnsvhm"
  zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  ttl     = 1
}

moved {
  from = cloudflare_record.public_MigaduVerify
  to   = cloudflare_dns_record.public_MigaduVerify
}

resource "cloudflare_dns_record" "public_mx1" {
  type     = "MX"
  name     = "@"
  content  = "aspmx1.migadu.com"
  priority = 10
  zone_id  = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  ttl      = 1
}

moved {
  from = cloudflare_record.public_mx1
  to   = cloudflare_dns_record.public_mx1
}

resource "cloudflare_dns_record" "public_mx2" {
  type     = "MX"
  name     = "@"
  content  = "aspmx2.migadu.com"
  priority = 20
  zone_id  = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  ttl      = 1
}

moved {
  from = cloudflare_record.public_mx2
  to   = cloudflare_dns_record.public_mx2
}

resource "cloudflare_dns_record" "public_dkim1" {
  type    = "CNAME"
  name    = "key1._domainkey"
  content = "key1.waltr.tech._domainkey.migadu.com"
  zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  ttl     = 1
}

moved {
  from = cloudflare_record.public_dkim1
  to   = cloudflare_dns_record.public_dkim1
}

resource "cloudflare_dns_record" "public_dkim2" {
  type    = "CNAME"
  name    = "key2._domainkey"
  content = "key2.waltr.tech._domainkey.migadu.com"
  zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  ttl     = 1
}

moved {
  from = cloudflare_record.public_dkim2
  to   = cloudflare_dns_record.public_dkim2
}

resource "cloudflare_dns_record" "public_dkim3" {
  type    = "CNAME"
  name    = "key3._domainkey"
  content = "key3.waltr.tech._domainkey.migadu.com"
  zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  ttl     = 1
}

moved {
  from = cloudflare_record.public_dkim3
  to   = cloudflare_dns_record.public_dkim3
}

resource "cloudflare_dns_record" "public_spf" {
  type    = "TXT"
  name    = "@"
  content = "v=spf1 include:spf.migadu.com -all"
  zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  ttl     = 1
}

moved {
  from = cloudflare_record.public_spf
  to   = cloudflare_dns_record.public_spf
}

resource "cloudflare_dns_record" "public_dmarc" {
  type    = "TXT"
  name    = "_dmarc"
  content = "v=DMARC1; p=quarantine;"
  zone_id = lookup(data.cloudflare_zones.public_domain.result[0], "id")
  ttl     = 1
}

moved {
  from = cloudflare_record.public_dmarc
  to   = cloudflare_dns_record.public_dmarc
}

resource "cloudflare_zone_setting" "public_domain" {
  for_each   = local.zone_settings
  zone_id    = data.cloudflare_zones.public_domain.result[0].id
  setting_id = each.key
  value      = each.value
}
