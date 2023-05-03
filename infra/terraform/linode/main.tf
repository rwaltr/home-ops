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
      version = "2.0.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "0.7.2"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "4.5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.3.0"
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

resource "linode_instance" "factorio_server" {
  label           = "FactorioServer"
  image           = "linode/fedora37"
  region          = "us-central"
  type            = "g6-standard-1"
  authorized_keys = compact(split("\n", data.http.github_ssh_keys.response_body))

}


data "cloudflare_zones" "public_domain" {
  filter {
    name = "waltr.tech"
  }
}

resource "cloudflare_record" "factorio_dns" {
  name    = "factorio"
  zone_id = lookup(data.cloudflare_zones.public_domain.zones[0], "id")
  type    = "A"
  ttl     = 1
  proxied = false
  value   = resource.linode_instance.factorio_server.ip_address
}
