resource "cloudflare_zone" "legacyfamily" {
  name = local.my_domains["familylegacy"]
  account = {
    id = cloudflare_account.waltrtech.id
  }
}

# Email Records /
resource "cloudflare_dns_record" "familylegacy_MigaduVerify" {
  type    = "TXT"
  name    = "@"
  content = "hosted-email-verify=gl6knkig"
  zone_id = cloudflare_zone.legacyfamily.id
  ttl     = 1
}

moved {
  from = cloudflare_record.familylegacy_MigaduVerify
  to   = cloudflare_dns_record.familylegacy_MigaduVerify
}

resource "cloudflare_dns_record" "familylegacy_MX1" {
  type     = "MX"
  name     = "@"
  content  = "aspmx1.migadu.com"
  priority = 10
  zone_id  = cloudflare_zone.legacyfamily.id
  ttl      = 1
}

moved {
  from = cloudflare_record.familylegacy_MX1
  to   = cloudflare_dns_record.familylegacy_MX1
}

resource "cloudflare_dns_record" "familylegacy_MX2" {
  type     = "MX"
  name     = "@"
  content  = "aspmx2.migadu.com"
  priority = 20
  zone_id  = cloudflare_zone.legacyfamily.id
  ttl      = 1
}

moved {
  from = cloudflare_record.familylegacy_MX2
  to   = cloudflare_dns_record.familylegacy_MX2
}

resource "cloudflare_dns_record" "familylegacy_DKIM1" {
  type    = "CNAME"
  name    = "key1._domainkey"
  content = "key1.rwwalter.com._domainkey.migadu.com"
  zone_id = cloudflare_zone.legacyfamily.id
  ttl     = 1
}

moved {
  from = cloudflare_record.familylegacy_DKIM1
  to   = cloudflare_dns_record.familylegacy_DKIM1
}

resource "cloudflare_dns_record" "familylegacy_DKIM2" {
  type    = "CNAME"
  name    = "key2._domainkey"
  content = "key2.rwwalter.com._domainkey.migadu.com"
  zone_id = cloudflare_zone.legacyfamily.id
  ttl     = 1
}

moved {
  from = cloudflare_record.familylegacy_DKIM2
  to   = cloudflare_dns_record.familylegacy_DKIM2
}

resource "cloudflare_dns_record" "familylegacy_DKIM3" {
  type    = "CNAME"
  name    = "key3._domainkey"
  content = "key3.rwwalter.com._domainkey.migadu.com"
  zone_id = cloudflare_zone.legacyfamily.id
  ttl     = 1
}

moved {
  from = cloudflare_record.familylegacy_DKIM3
  to   = cloudflare_dns_record.familylegacy_DKIM3
}

resource "cloudflare_dns_record" "familylegacy_SPF" {
  type    = "TXT"
  name    = "@"
  content = "v=spf1 include:spf.migadu.com -all"
  zone_id = cloudflare_zone.legacyfamily.id
  ttl     = 1
}

moved {
  from = cloudflare_record.familylegacy_SPF
  to   = cloudflare_dns_record.familylegacy_SPF
}

resource "cloudflare_dns_record" "familylegacy_DMARC" {
  type    = "TXT"
  name    = "_dmarc"
  content = "v=DMARC1; p=quarantine;"
  zone_id = cloudflare_zone.legacyfamily.id

  ttl = 1
}

moved {
  from = cloudflare_record.familylegacy_DMARC
  to   = cloudflare_dns_record.familylegacy_DMARC
}

resource "cloudflare_dns_record" "familylegacy_autoconfig" {
  type    = "CNAME"
  name    = "autoconfig"
  content = "autoconfig.migadu.com"
  zone_id = cloudflare_zone.legacyfamily.id
  ttl     = 1
}

moved {
  from = cloudflare_record.familylegacy_autoconfig
  to   = cloudflare_dns_record.familylegacy_autoconfig
}

resource "cloudflare_zone_setting" "legacyfamily" {
  for_each   = local.zone_settings
  zone_id    = cloudflare_zone.legacyfamily.id
  setting_id = each.key
  value      = each.value
}
