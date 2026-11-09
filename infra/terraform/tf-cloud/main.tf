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
  name         = "cloudflare-provisioner"
  organization = data.tfe_organization.rwaltr.name
}

# The tailnet, and the project that turns cloud credentials into 1Password items.
resource "tfe_workspace" "tailscale" {
  name         = "tailscale-provisioner"
  organization = data.tfe_organization.rwaltr.name
}

resource "tfe_workspace" "bootstrap" {
  name         = "bootstrap-provisioner"
  organization = data.tfe_organization.rwaltr.name
}

# Execution mode and agent pool live here rather than on tfe_workspace, where
# both are deprecated and will be removed. Local for all three: credentials come
# from fnox and never reach Terraform Cloud, while the state still lives there.
#
# Moving the existing cloudflare workspace is safe, and the deprecation warning is
# the only reason it looks otherwise. The provider notes that unsetting
# execution_mode on a workspace "leaves any prior value unmanaged instead of
# reverting to the old default value of remote", so this cannot silently flip a
# workspace to remote execution — the thing that would break it, because the
# credentials it needs are only ever exported locally.
#
# No import needed either: Create reads the workspace's current settings first and
# applies only what is set below, so nothing else gets reset to a default.
resource "tfe_workspace_settings" "cloudflare" {
  workspace_id   = tfe_workspace.cloudflare.id
  execution_mode = "local"
}

resource "tfe_workspace_settings" "tailscale" {
  workspace_id   = tfe_workspace.tailscale.id
  execution_mode = "local"
}

resource "tfe_workspace_settings" "bootstrap" {
  workspace_id   = tfe_workspace.bootstrap.id
  execution_mode = "local"
}
