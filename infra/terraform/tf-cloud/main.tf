terraform {
  cloud {
    organization = "rwaltr"
    hostname     = "app.terraform.io"
    workspaces {
      name = "tfcloud-provision"
    }
  }
  required_providers {
    tfe = {
      version = "~> 0.50.0"
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

# resource "tfe_workspace" "linode" {
#   name           = "linode-provisioner"
#   organization   = data.tfe_organization.rwaltr.name
#   execution_mode = "local"
# }

resource "tfe_workspace" "backblaze" {
  name           = "backblaze-provisioner"
  organization   = data.tfe_organization.rwaltr.name
  execution_mode = "local"
}
