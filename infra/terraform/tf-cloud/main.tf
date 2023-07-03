terraform {
  cloud {
    organization = "rwaltr"
    workspaces {
      name = "tfcloud-provision"
    }
  }
  required_providers {
    tfe = {
      version = "~> 0.46.0"
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

resource "tfe_workspace" "linode" {
  name           = "linode-provisioner"
  organization   = data.tfe_organization.rwaltr.name
  execution_mode = "local"
}

resource "tfe_workspace" "github-provisioner" {
  name           = "github-provisioner"
  organization   = data.tfe_organization.rwaltr.name
  execution_mode = "local"
}

resource "tfe_workspace" "doppler-provisioner" {
  name           = "doppler-provisioner"
  organization   = data.tfe_organization.rwaltr.name
  execution_mode = "local"
}
