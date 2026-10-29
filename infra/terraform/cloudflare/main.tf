terraform {
  cloud {
    organization = "rwaltr"
    hostname     = "app.terraform.io"
    workspaces {
      name = "cloudflare-provisioner"
    }
  }
  required_version = ">= 1.8.0" // moved/import blocks are used by the provider v5 migration

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "4.52.10"
    }
    porkbun = {
      source  = "icco/porkbun"
      version = "1.1.4"
    }
  }
}


# Credentials come from fnox (1Password-backed) via each provider's native env
# vars (CLOUDFLARE_API_TOKEN, PORKBUN_API_KEY/PORKBUN_SECRET_KEY): the tf:* mise
# tasks wrap terraform in `fnox exec`. No secrets live in this repo.
provider "cloudflare" {}

# Registry-side nameserver delegation only; zones stay on Cloudflare.
provider "porkbun" {}

locals {
  # Zone names. Previously decrypted from ../../shared/domains.sops.yaml, but the
  # same names already appear unencrypted across the repo, so SOPS hid nothing.
  my_domains = {
    personal       = "waltr.tech"
    personallegacy = "blackphidora.com"
    familylegacy   = "rwwalter.com"
    prof           = "rwalt.pro"
  }
}

resource "cloudflare_account" "waltrtech" {
  name              = "WaltrTech"
  type              = "standard"
  enforce_twofactor = "false"
}
