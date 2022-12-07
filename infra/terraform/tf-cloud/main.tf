terraform {
  cloud {
    organization = "rwaltr"
    workspaces {
      name = "tfcloud-provision"
    }
  }
  required_providers {
    tfe = {
      version = "~> 0.40.0"
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
