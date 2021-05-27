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


# # Zomboid Server

# resource "linode_instance" "zomboid" {
#   label = "zomboid"
#   image = "linode/ubuntu21.04"
#   region = "us-central"
#   type = "g6-standard-1"
#   root_pass = "${data.vault_generic_secret.generic.data["root_pass"]}"
# }

# resource "cloudflare_record" "zomboid-dns" {
#     name = "zomboid.games.lin"
#     zone_id = "${data.vault_generic_secret.cloudflare.data["zone_id_rwaltrpro"]}"
#     type = "A"
#     value = linode_instance.zomboid.ip_address
  
# }

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