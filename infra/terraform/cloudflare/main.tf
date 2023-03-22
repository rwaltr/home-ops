terraform {
  cloud {
    organization = "rwaltr"
    workspaces {
      name = "cloudflare-provisioner"
    }
  }
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "4.2.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "0.7.2"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.2.1"
    }
  }
}


data "sops_file" "cloudflare_secrets" {
  source_file = "cloudflare_secrets.sops.yaml"
}

locals {
  cloudflare_secrets = sensitive(yamldecode(nonsensitive(data.sops_file.cloudflare_secrets.raw)))
}

provider "cloudflare" {
  email   = local.cloudflare_secrets["cloudflare_email"]
  api_key = local.cloudflare_secrets["cloudflare_api_key"]
}

resource "cloudflare_account" "waltrtech" {
  name              = "WaltrTech"
  type              = "standard"
  enforce_twofactor = "false"
}
