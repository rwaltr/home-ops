terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
    }

  }
}

provider "vault" {
  address = "https://vault.waltr.tech"
}

data "vault_generic_secret" "linode" {
  path = "apikeys/linode"
}

data "vault_generic_secret" "cloudflare" {
  path = "apikeys/cloudflare"
}


data "vault_generic_secret" "generic" {
  path = "apikeys/generic"
}

provider "cloudflare" {
  api_token = data.vault_generic_secret.cloudflare.data["api_token"]
}
