resource "cloudflare_zone" "prof_domain" {
  zone       = local.my_domains["prof"]
  account_id = cloudflare_account.waltrtech.id
}

resource "cloudflare_record" "prof_root" {
  type    = "CNAME"
  name    = "@"
  value   = "rwaltr.github.io"
  zone_id = cloudflare_zone.prof_domain.id
}

resource "cloudflare_record" "prof_www" {
  type    = "CNAME"
  name    = "www"
  value   = "rwaltr.github.io"
  zone_id = cloudflare_zone.prof_domain.id
}

resource "cloudflare_record" "prof_githubverify" {
  type    = "TXT"
  name    = "_github-pages-challenge-rwaltr"
  value   = "8697f334fc9261ca5d28a65ce0544e"
  zone_id = cloudflare_zone.prof_domain.id

}
# Email Records /
resource "cloudflare_record" "prof_MigaduVerify" {
  type    = "TXT"
  name    = "@"
  value   = "hosted-email-verify=mtm4pnvs"
  zone_id = cloudflare_zone.prof_domain.id
}

resource "cloudflare_record" "prof_MX1" {
  type     = "MX"
  name     = "@"
  value    = "aspmx1.migadu.com"
  priority = 10
  zone_id  = cloudflare_zone.prof_domain.id
}

resource "cloudflare_record" "prof_MX2" {
  type     = "MX"
  name     = "@"
  value    = "aspmx2.migadu.com"
  priority = 20
  zone_id  = cloudflare_zone.prof_domain.id
}

resource "cloudflare_record" "prof_DKIM1" {
  type    = "CNAME"
  name    = "key1._domainkey"
  value   = "key1.rwalt.pro._domainkey.migadu.com."
  zone_id = cloudflare_zone.prof_domain.id
}

resource "cloudflare_record" "prof_DKIM2" {
  type    = "CNAME"
  name    = "key2._domainkey"
  value   = "key2.rwalt.pro._domainkey.migadu.com."
  zone_id = cloudflare_zone.prof_domain.id
}

resource "cloudflare_record" "prof_DKIM3" {
  type    = "CNAME"
  name    = "key3._domainkey"
  value   = "key3.rwalt.pro._domainkey.migadu.com."
  zone_id = cloudflare_zone.prof_domain.id
}

resource "cloudflare_record" "prof_SPF" {
  type    = "TXT"
  name    = "@"
  value   = "v=spf1 include:spf.migadu.com -all"
  zone_id = cloudflare_zone.prof_domain.id
}

resource "cloudflare_record" "prof_DMARC" {
  type    = "TXT"
  name    = "_dmarc"
  value   = "v=DMARC1; p=quarantine;"
  zone_id = cloudflare_zone.prof_domain.id

}

# / Email Records

resource "cloudflare_zone_settings_override" "prof_domain" {
  zone_id = cloudflare_zone.prof_domain.id
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
