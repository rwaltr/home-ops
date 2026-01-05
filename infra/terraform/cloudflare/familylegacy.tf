resource "cloudflare_zone" "legacyfamily" {
  zone       = local.my_domains["familylegacy"]
  account_id = cloudflare_account.waltrtech.id
}


# Email Records /
resource "cloudflare_record" "familylegacy_MigaduVerify" {
  type    = "TXT"
  name    = "@"
  value   = "hosted-email-verify=gl6knkig"
  zone_id = cloudflare_zone.legacyfamily.id
}

resource "cloudflare_record" "familylegacy_MX1" {
  type     = "MX"
  name     = "@"
  value    = "aspmx1.migadu.com"
  priority = 10
  zone_id  = cloudflare_zone.legacyfamily.id
}

resource "cloudflare_record" "familylegacy_MX2" {
  type     = "MX"
  name     = "@"
  value    = "aspmx2.migadu.com"
  priority = 20
  zone_id  = cloudflare_zone.legacyfamily.id
}

resource "cloudflare_record" "familylegacy_DKIM1" {
  type    = "CNAME"
  name    = "key1._domainkey"
  value   = "key1.rwwalter.com._domainkey.migadu.com."
  zone_id = cloudflare_zone.legacyfamily.id
}

resource "cloudflare_record" "familylegacy_DKIM2" {
  type    = "CNAME"
  name    = "key2._domainkey"
  value   = "key2.rwwalter.com._domainkey.migadu.com."
  zone_id = cloudflare_zone.legacyfamily.id
}

resource "cloudflare_record" "familylegacy_DKIM3" {
  type    = "CNAME"
  name    = "key3._domainkey"
  value   = "key3.rwwalter.com._domainkey.migadu.com."
  zone_id = cloudflare_zone.legacyfamily.id
}

resource "cloudflare_record" "familylegacy_SPF" {
  type    = "TXT"
  name    = "@"
  value   = "v=spf1 include:spf.migadu.com -all"
  zone_id = cloudflare_zone.legacyfamily.id
}

resource "cloudflare_record" "familylegacy_DMARC" {
  type    = "TXT"
  name    = "_dmarc"
  value   = "v=DMARC1; p=quarantine;"
  zone_id = cloudflare_zone.legacyfamily.id

}

resource "cloudflare_record" "familylegacy_autoconfig" {
  type    = "CNAME"
  name    = "autoconfig"
  value   = "autoconfig.migadu.com."
  zone_id = cloudflare_zone.legacyfamily.id
}

# / Email Records

resource "cloudflare_zone_settings_override" "legacyfamily_domain_settings" {
  zone_id = cloudflare_zone.legacyfamily.id
  settings {
    ssl                      = "strict"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    opportunistic_encryption = "on"
    tls_1_3                  = "zrt"
    automatic_https_rewrites = "on"
    universal_ssl            = "on"
    browser_check            = "on"
    challenge_ttl            = 1800
    privacy_pass             = "on"
    security_level           = "medium"
    brotli                   = "on"
    minify {
      css  = "on"
      js   = "on"
      html = "on"
    }
    rocket_loader       = "off"
    always_online       = "off"
    development_mode    = "off"
    http3               = "on"
    zero_rtt            = "on"
    ipv6                = "on"
    websockets          = "on"
    opportunistic_onion = "on"
    pseudo_ipv4         = "off"
    ip_geolocation      = "on"
    email_obfuscation   = "on"
    server_side_exclude = "on"
    hotlink_protection  = "off"
    security_header {
      enabled = false
    }
  }
}
