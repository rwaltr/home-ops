# Cloudflare zone settings. v4 had one `cloudflare_zone_settings_override` per
# zone with three identical copies of the same block; v5 models every setting as
# its own `cloudflare_zone_setting` resource, so they live in one map here and
# each zone iterates it.
#
# Notes carried over from the tf-migrate run: `minify` is gone (Cloudflare
# removed Auto Minify on 2024-08-05 and forces it off), `universal_ssl` is gone
# (Cloudflare no longer exposes that toggle), and the Zero RTT setting id is
# `0rtt`, not `zero_rtt`.
locals {
  zone_settings = {
    "0rtt"                   = "on"
    always_online            = "off"
    always_use_https         = "on"
    automatic_https_rewrites = "on"
    brotli                   = "on"
    browser_check            = "on"
    challenge_ttl            = 1800
    development_mode         = "off"
    email_obfuscation        = "on"
    hotlink_protection       = "off"
    http3                    = "on"
    ip_geolocation           = "on"
    ipv6                     = "on"
    min_tls_version          = "1.2"
    opportunistic_encryption = "on"
    opportunistic_onion      = "on"
    privacy_pass             = "on"
    pseudo_ipv4              = "off"
    rocket_loader            = "off"
    # The API rejects a security_header payload without an integer max_age, even
    # when HSTS is disabled, so every field is spelled out to match the live value.
    security_header = {
      strict_transport_security = {
        enabled            = false
        max_age            = 0
        include_subdomains = false
        preload            = false
        nosniff            = false
      }
    }
    security_level      = "medium"
    server_side_exclude = "on"
    ssl                 = "strict"
    tls_1_3             = "zrt"
    websockets          = "on"
  }
}
