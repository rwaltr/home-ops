terraform {
  cloud {
    organization = "rwaltr"
    workspaces {
      name = "linode-provisioner"
    }
  }
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "1.29.4"
    }
    sops = {
      source  = "carlpett/sops"
      version = "0.7.1"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "3.30.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.2.1"
    }
  }
}

data "sops_file" "linode_secrets" {
  source_file = "linode_secrets.sops.yaml"
}

data "sops_file" "cloudflare_secrets" {
  source_file = "../cloudflare/cloudflare_secrets.sops.yaml"
}

data "http" "github_ssh_keys" {
  url = "https://github.com./rwaltr.keys"
}

locals {
  linode_secrets     = sensitive(yamldecode(nonsensitive(data.sops_file.linode_secrets.raw)))
  cloudflare_secrets = sensitive(yamldecode(nonsensitive(data.sops_file.cloudflare_secrets.raw)))
}
provider "linode" {
  token = local.linode_secrets["token"]
}

provider "cloudflare" {
  email   = local.cloudflare_secrets["cloudflare_email"]
  api_key = local.cloudflare_secrets["cloudflare_api_key"]
}

resource "linode_sshkey" "rwaltr_gh_key" {
  label = "rwaltr_gh_key"
  ssh_key = chomp(data.http.github_ssh_keys.response_body)
}
