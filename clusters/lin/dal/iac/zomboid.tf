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


resource "linode_instance" "zomboid" {
  label = "zomboid"
  image = "linode/fedora34"
  region = "us-central"
  type = "g6-standard-1"
  root_pass = "${data.vault_generic_secret.generic.data["root_pass"]}"

  provisioner "remote-exec" {
    inline = [
      "sudo dnf update -y",
      "sudo dnf install podman -y",
      "mkdir /opt/zomboid/data /opt/zomboid/config -p",
      "podman run --network host -v /opt/zomboid/data:/data -v /opt/zomboid/config:/config registry.gitlab.com/rwaltr/container-images/zomboid-server:0.0.1"
   ]
    connection {
        type = "ssh"
        host = self.ip_address
        user = "root"
        password = "${data.vault_generic_secret.generic.data["root_pass"]}"
    }
  }
}

resource "cloudflare_record" "zomboid-dns" {
    name = "zomboid.games.lin"
    zone_id = "${data.vault_generic_secret.cloudflare.data["zone_id_rwaltrpro"]}"
    type = "A"
    value = linode_instance.zomboid.ip_address
  
}
