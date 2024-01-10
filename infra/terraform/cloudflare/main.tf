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
      version = "4.22.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "1.0.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.4.0"
    }
  }
}


data "sops_file" "cloudflare_secrets" {
  source_file = "cloudflare_secrets.sops.yaml"
}

data "sops_file" "my_domains"{
  source_file = "../../shared/domains.sops.yaml"
}

locals {
  cloudflare_secrets = sensitive(yamldecode(nonsensitive(data.sops_file.cloudflare_secrets.raw)))
  my_domains = sensitive(yamldecode(nonsensitive(data.sops_file.my_domains.raw)))
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
