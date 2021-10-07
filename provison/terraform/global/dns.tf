resource "cloudflare_record" "blog" {
  name    = "blog"
  zone_id = data.vault_generic_secret.cloudflare.data["zone_id_waltrtech"]
  value   = "rwaltr.github.io"
  type    = "CNAME"
  ttl     = 3600
}


resource "cloudflare_record" "startpage" {
  name    = "start"
  zone_id = data.vault_generic_secret.cloudflare.data["zone_id_waltrtech"]
  value   = "waltrtech.gitlab.io"
  type    = "CNAME"
  ttl     = 3600
}

# resource "cloudflare_record" "root" {
#   name    = "waltr.tech"
#   zone_id = data.vault_generic_secret.cloudflare.data["zone_id_waltrtech"]
#   value   = ""
#   type    = "A"
#   ttl     = 3600
# }

resource "cloudflare_record" "keybase" {
  name    = "waltr.tech"
  zone_id = data.vault_generic_secret.cloudflare.data["zone_id_waltrtech"]
  value   = "keybase-site-verification=i3hgyKry6zWhKMMXBj87-yQrHAFfJOWt6sCqmG1slfk"
  type    = "TXT"
  ttl     = 3600
}


resource "cloudflare_record" "ghpages-start" {
  name    = "_gitlab-pages-verification-code.start"
  zone_id = data.vault_generic_secret.cloudflare.data["zone_id_waltrtech"]
  value   = "gitlab-pages-verification-code=3c1ebbe2b62c977b83a689feb7f6a5bf"
  type    = "TXT"
  ttl     = 3600
}

resource "cloudflare_record" "ghpages-verify" {
  name    = "_gitlab-pages-verification-code"
  zone_id = data.vault_generic_secret.cloudflare.data["zone_id_waltrtech"]
  value   = "gitlab-pages-verification-code=7a51f29ce7ca59cdb6fa056b502e450f"
  type    = "TXT"
  ttl     = 3600
}

resource "cloudflare_record" "factorio" {
  name    = "factorio"
  zone_id = data.vault_generic_secret.cloudflare.data["zone_id_waltrtech"]
  value   = "home.waltr.tech"
  type    = "CNAME"
  ttl     = 3600
}
## SPFs?
