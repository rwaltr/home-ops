terraform {
  cloud {
    organization = "rwaltr"
    workspaces {
      name = "github-provisioner"
    }
  }
  required_providers {
    github = {
      source = "integrations/github"
      version = "5.27.0"
    }
  }
}

provider "github" {

}
