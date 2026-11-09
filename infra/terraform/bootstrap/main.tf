# The "cloud bootstrap" project: the single place where a cloud credential is
# turned into a 1Password item.
#
# Everything else in this repo *reads* secrets — fnox (1Password-backed) for
# local tooling, External Secrets for the cluster. Nothing else writes them. That
# keeps this the one project that needs OP_SERVICE_ACCOUNT_TOKEN, which matches
# the discipline in the tf:* mise tasks, where each workspace is handed only the
# credentials it actually uses.
#
# The one credential Terraform cannot make for itself is the trust credential it
# logs in with: creating it needs the API you need it for. So that is made by
# hand once, in the Tailscale admin console, and pasted into the
# `tailscale-bootstrap` 1Password item. Everything produced from here on is code.
terraform {
  cloud {
    organization = "rwaltr"
    hostname     = "app.terraform.io"
    workspaces {
      name = "bootstrap-provisioner"
    }
  }
  required_version = ">= 1.8.0"

  required_providers {
    # Tailscale, because the operator's OAuth client is a cloud resource that
    # happens to be a credential.
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.29.3"
    }
    # 1Password, because the output of this project is an item, not a URL.
    onepassword = {
      source  = "1password/onepassword"
      version = "3.4.1"
    }
  }
}

# Credentials come from fnox via the tf:* mise tasks:
#   TAILSCALE_OAUTH_CLIENT_ID / _SECRET  the hand-made trust credential above
#   OP_SERVICE_ACCOUNT_TOKEN             from the OS keychain (fnox's keychain
#     provider), so writing to 1Password needs no 1Password item to exist first
provider "tailscale" {}

provider "onepassword" {}

variable "onepassword_vault" {
  description = "1Password vault holding this cluster's secrets. Same vault fnox's `op` provider reads."
  type        = string
  default     = "home-ops"
}

data "onepassword_vault" "secrets" {
  name = var.onepassword_vault
}
