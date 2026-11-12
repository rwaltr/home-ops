resource "cloudflare_zone" "prof_domain" {
  name = local.my_domains["prof"]
  account = {
    id = cloudflare_account.waltrtech.id
  }
}

resource "cloudflare_dns_record" "prof_root" {
  type    = "CNAME"
  name    = "@"
  content = "rwaltr.github.io"
  zone_id = cloudflare_zone.prof_domain.id
  ttl     = 1
}

moved {
  from = cloudflare_record.prof_root
  to   = cloudflare_dns_record.prof_root
}

resource "cloudflare_dns_record" "prof_www" {
  type    = "CNAME"
  name    = "www"
  content = "rwaltr.github.io"
  zone_id = cloudflare_zone.prof_domain.id
  ttl     = 1
}

moved {
  from = cloudflare_record.prof_www
  to   = cloudflare_dns_record.prof_www
}

resource "cloudflare_dns_record" "prof_githubverify" {
  type    = "TXT"
  name    = "_github-pages-challenge-rwaltr"
  content = "8697f334fc9261ca5d28a65ce0544e"
  zone_id = cloudflare_zone.prof_domain.id

  ttl = 1
}

moved {
  from = cloudflare_record.prof_githubverify
  to   = cloudflare_dns_record.prof_githubverify
}

# Email Records /
resource "cloudflare_dns_record" "prof_MigaduVerify" {
  type    = "TXT"
  name    = "@"
  content = "hosted-email-verify=mtm4pnvs"
  zone_id = cloudflare_zone.prof_domain.id
  ttl     = 1
}

moved {
  from = cloudflare_record.prof_MigaduVerify
  to   = cloudflare_dns_record.prof_MigaduVerify
}

resource "cloudflare_dns_record" "prof_MX1" {
  type     = "MX"
  name     = "@"
  content  = "aspmx1.migadu.com"
  priority = 10
  zone_id  = cloudflare_zone.prof_domain.id
  ttl      = 1
}

moved {
  from = cloudflare_record.prof_MX1
  to   = cloudflare_dns_record.prof_MX1
}

resource "cloudflare_dns_record" "prof_MX2" {
  type     = "MX"
  name     = "@"
  content  = "aspmx2.migadu.com"
  priority = 20
  zone_id  = cloudflare_zone.prof_domain.id
  ttl      = 1
}

moved {
  from = cloudflare_record.prof_MX2
  to   = cloudflare_dns_record.prof_MX2
}

resource "cloudflare_dns_record" "prof_DKIM1" {
  type    = "CNAME"
  name    = "key1._domainkey"
  content = "key1.rwalt.pro._domainkey.migadu.com"
  zone_id = cloudflare_zone.prof_domain.id
  ttl     = 1
}

moved {
  from = cloudflare_record.prof_DKIM1
  to   = cloudflare_dns_record.prof_DKIM1
}

resource "cloudflare_dns_record" "prof_DKIM2" {
  type    = "CNAME"
  name    = "key2._domainkey"
  content = "key2.rwalt.pro._domainkey.migadu.com"
  zone_id = cloudflare_zone.prof_domain.id
  ttl     = 1
}

moved {
  from = cloudflare_record.prof_DKIM2
  to   = cloudflare_dns_record.prof_DKIM2
}

resource "cloudflare_dns_record" "prof_DKIM3" {
  type    = "CNAME"
  name    = "key3._domainkey"
  content = "key3.rwalt.pro._domainkey.migadu.com"
  zone_id = cloudflare_zone.prof_domain.id
  ttl     = 1
}

moved {
  from = cloudflare_record.prof_DKIM3
  to   = cloudflare_dns_record.prof_DKIM3
}

resource "cloudflare_dns_record" "prof_SPF" {
  type    = "TXT"
  name    = "@"
  content = "v=spf1 include:spf.migadu.com -all"
  zone_id = cloudflare_zone.prof_domain.id
  ttl     = 1
}

moved {
  from = cloudflare_record.prof_SPF
  to   = cloudflare_dns_record.prof_SPF
}

resource "cloudflare_dns_record" "prof_DMARC" {
  type    = "TXT"
  name    = "_dmarc"
  content = "v=DMARC1; p=quarantine;"
  zone_id = cloudflare_zone.prof_domain.id

  ttl = 1
}

moved {
  from = cloudflare_record.prof_DMARC
  to   = cloudflare_dns_record.prof_DMARC
}

resource "cloudflare_zone_setting" "prof_domain" {
  for_each   = local.zone_settings
  zone_id    = cloudflare_zone.prof_domain.id
  setting_id = each.key
  value      = each.value
}
