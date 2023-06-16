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
      version = "5.28.0"
    }
  }
}

provider "github" {

}
