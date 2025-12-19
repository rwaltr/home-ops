terraform {
  cloud {
    organization = "rwaltr"
    hostname     = "app.terraform.io"
    workspaces {
      name = "backblaze-provisioner"
    }
  }
  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "0.12.0"
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


data "sops_file" "backblaze_secrets" {
  source_file = "backblaze_secrets.sops.yaml"
}

locals {
  backblaze_secrets = sensitive(yamldecode(nonsensitive(data.sops_file.backblaze_secrets.raw)))
}

provider "b2" {
  application_key    = local.backblaze_secrets["applicationKey"]
  application_key_id = local.backblaze_secrets["keyid"]
}

resource "b2_bucket" "example_bucket" {
  bucket_name = "rwaltr-backup-test"
  bucket_type = "allPrivate"
}
