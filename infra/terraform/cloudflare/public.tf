data "cloudflare_zones" "public_domain" {
  filter {
    name = local.my_domains["personal"]
  }
}


resource "cloudflare_record" "public_githubverify" {
  name = "_github-pages-challenge-rwaltr"
  type = "TXT"
  value = "b79e49f4db1fd5edf70c1ccaf4a124"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
}

resource "cloudflare_record" "public_blog" {
  name    = "blog"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  type    = "CNAME"
  ttl     = "1"
  value   = "rwaltr.github.io"
  proxied = true
}

resource "cloudflare_record" "public_kyz" {
  name    = "kyz"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  type    = "CNAME"
  ttl     = "1"
  value   = "gw.kyz.waltr.tech"
  proxied = true

}


resource "cloudflare_record" "public_mx1" {
  name     = "waltr.tech"
  value    = "mail.protonmail.ch"
  type     = "MX"
  priority = "10"
  zone_id  = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  ttl      = 1
  proxied  = false
}

resource "cloudflare_record" "public_mx2" {
  name     = "waltr.tech"
  value    = "mailsec.protonmail.ch"
  type     = "MX"
  priority = "20"
  zone_id  = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  ttl      = 1
  proxied  = false
}

resource "cloudflare_record" "public_dmarc" {
  name    = "_dmarc"
  value   = "v=DMARC1; p=none"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  ttl     = 1
  proxied = false
  type    = "TXT"
}

resource "cloudflare_record" "public_spf" {
  name    = "waltr.tech"
  value   = "v=spf1 include:_spf.protonmail.ch mx ~all"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  ttl     = 1
  proxied = false
  type    = "TXT"
}

resource "cloudflare_record" "public_protonmail_verify" {
  name    = "waltr.tech"
  value   = "protonmail-verification=49547740ee7975bcce254d09c76c57dbd22ae672"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  ttl     = 1
  proxied = false
  type    = "TXT"
}

resource "cloudflare_record" "public_protonmail_donainkey1" {
  name    = "protonmail._domainkey"
  value   = "protonmail.domainkey.dwigogkdcjwayzy3t2jp74ogrjtrij5a6bnxm3u25aocolxjgtwiq.domains.proton.ch"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  ttl     = 1
  proxied = false
  type    = "CNAME"
}

resource "cloudflare_record" "public_protonmail_donainkey2" {
  name    = "protonmail2._domainkey"
  value   = "protonmail2.domainkey.dwigogkdcjwayzy3t2jp74ogrjtrij5a6bnxm3u25aocolxjgtwiq.domains.proton.ch"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  ttl     = 1
  proxied = false
  type    = "CNAME"
}

resource "cloudflare_record" "public_protonmail_donainkey3" {
  name    = "protonmail3._domainkey"
  value   = "protonmail3.domainkey.dwigogkdcjwayzy3t2jp74ogrjtrij5a6bnxm3u25aocolxjgtwiq.domains.proton.ch"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  ttl     = 1
  proxied = false
  type    = "CNAME"
}

resource "cloudflare_zone_settings_override" "public_domain_settings" {
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
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

# Bots and threats

# resource "cloudflare_filter" "bots_and_threats" {
#
#   zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
#   description = "Expression to block bots and threats determined by CF"
#   expression  = "(cf.client.bot) or (cf.threat_score gt 14)"
# }
#
# resource "cloudflare_firewall_rule" "bots_and_threats" {
#
#
#   zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
#   description = "Firewall rule to block bots and threats determined by CF"
#   filter_id   = cloudflare_filter.bots_and_threats.id
#   action      = "block"
# }
