data "cloudflare_zones" "legacy_domain" {
  filter {
    name = local.my_domains["personallegacy"]
  }
}

# Email Records /
resource "cloudflare_record" "legacy_MigaduVerify" {
  type    = "TXT"
  name    = "@"
  value   = "hosted-email-verify=gkkczxli"
  zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_mx1" {
  type     = "MX"
  name     = "@"
  value    = "aspmx1.migadu.com"
  priority = 10
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_mx2" {
  type     = "MX"
  name     = "@"
  value    = "aspmx2.migadu.com"
  priority = 20
  zone_id  = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_dkim1" {
  type    = "CNAME"
  name    = "key1._domainkey"
  value   = "key1.blackphidora.com._domainkey.migadu.com."
  zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_dkim2" {
  type    = "CNAME"
  name    = "key2._domainkey"
  value   = "key2.blackphidora.com._domainkey.migadu.com."
  zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_dkim3" {
  type    = "CNAME"
  name    = "key3._domainkey"
  value   = "key3.blackphidora.com._domainkey.migadu.com."
  zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_spf" {
  type    = "TXT"
  name    = "@"
  value   = "v=spf1 include:spf.migadu.com -all"
  zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}

resource "cloudflare_record" "legacy_dmarc" {
  type    = "TXT"
  name    = "_dmarc"
  value   = "v=DMARC1; p=quarantine;"
  zone_id = lookup(data.cloudflare_zones.legacy_domain.zones[0], "id")
}
