terraform {
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/22827251/terraform/state/lin-dal/"
    lock_address   = "https://gitlab.com/api/v4/projects/22827251/terraform/state/lin-dal/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/22827251/terraform/state/lin-dal/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }

  required_providers {
    linode = {
      source = "linode/linode"
    }
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

provider "linode" {
  token = data.vault_generic_secret.linode.data["api_token"]
}

provider "cloudflare" {
  api_token = data.vault_generic_secret.cloudflare.data["api_token"]
}

