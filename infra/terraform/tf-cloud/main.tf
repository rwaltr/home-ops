terraform {
  cloud {
    organization = "rwaltr"
    hostname     = "app.terraform.io"
    workspaces {
      name = "tfcloud-provision"
    }
  }
  required_version = ">= 1.8.0"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.81.0"
    }
  }
}

data "tfe_organization" "rwaltr" {
  name = "rwaltr"
}

resource "tfe_workspace" "cloudflare" {
  name           = "cloudflare-provisioner"
  organization   = data.tfe_organization.rwaltr.name
  execution_mode = "local"
}

# The tailnet, and the project that turns cloud credentials into 1Password items.
# Both run locally too: credentials come from fnox, state stays in Terraform
# Cloud.
resource "tfe_workspace" "tailscale" {
  name           = "tailscale-provisioner"
  organization   = data.tfe_organization.rwaltr.name
  execution_mode = "local"
}

resource "tfe_workspace" "bootstrap" {
  name           = "bootstrap-provisioner"
  organization   = data.tfe_organization.rwaltr.name
  execution_mode = "local"
}
