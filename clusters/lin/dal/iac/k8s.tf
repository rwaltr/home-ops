terraform {
  required_providers {
      linode = {
          source = "linode/linode"
      }
      vault = {
          source = "hashicorp/vault"
      }
      cloudflare = {
          source = "cloudflare/cloudflare"
      }

  }
}

provider "vault" {
    address = "https://vault.waltr.tech"
}

data "vault_generic_secret" "linode" {
    path = "apikeys/linode"
}

data "vault_generic_secret" "cloudflare" {
    path = "apikeys/cloudflare"
}


data "vault_generic_secret" "generic" {
    path = "apikeys/generic"
}

provider "linode" {
    token = "${data.vault_generic_secret.linode.data["api_token"]}"
}

provider "cloudflare" {
    api_token = "${data.vault_generic_secret.cloudflare.data["api_token"]}"
}


# resource "linode_lke_cluster" "dal" {
#   label = "k8s.dal.waltr.tech"
#   k8s_version = "1.20"
#   region = "us-central"
#   pool {
#     count = 1
#     type = "g6-standard-1"
#   }
# }

# output "kubeconfig" {
#   value = base64decode(linode_lke_cluster.dal.kubeconfig)
#   sensitive = true
# }