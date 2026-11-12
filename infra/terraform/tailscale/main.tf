terraform {
  cloud {
    organization = "rwaltr"
    hostname     = "app.terraform.io"
    workspaces {
      name = "tailscale-provisioner"
    }
  }
  required_version = ">= 1.8.0"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.29.3"
    }
  }
}

# Credentials come from fnox (1Password-backed) via the provider's native env
# vars (TAILSCALE_OAUTH_CLIENT_ID/TAILSCALE_OAUTH_CLIENT_SECRET), which the tf:*
# mise tasks export explicitly rather than `fnox exec`-ing the whole environment.
# No secrets live in this repo.
#
# The tailnet is deliberately NOT set: omitting it uses the tailnet that owns the
# credential, which is the tailnet we mean and one less value to keep in sync.
provider "tailscale" {}
