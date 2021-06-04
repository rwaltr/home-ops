
# Zomboid Server
# resource "linode_instance" "zomboid" {
#   label = "zomboid"
#   image = "linode/fedora34"
#   region = "us-central"
#   type = "g6-standard-2"
#   root_pass = "${data.vault_generic_secret.generic.data["root_pass"]}"

#   provisioner "remote-exec" {
#     inline = [
#       "sudo dnf update -y",
#       "sudo dnf install podman -y",
#       "setenforce 0",
#       "mkdir /opt/zomboid/data /opt/zomboid/config -p",
#       "podman run -d --network host -v /opt/zomboid/data:/data -v /opt/zomboid/config:/config registry.gitlab.com/rwaltr/container-images/zomboid-server:0.0.1",
#       "systemctl stop firewalld"
#    ]
#     connection { 
#         type = "ssh"
#         host = self.ip_address
#         user = "root"
#         password = "${data.vault_generic_secret.generic.data["root_pass"]}"
#     }
#   }
# }

# resource "cloudflare_record" "zomboid-dns" {
#     name = "zomboid."
#     zone_id = "${data.vault_generic_secret.cloudflare.data["zone_id_rwaltrpro"]}"
#     type = "A"
#     value = linode_instance.zomboid.ip_address
  
# }
