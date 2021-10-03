
# Zomboid Server
resource "linode_instance" "sshcatest" {
  label     = "sshcatset"
  image     = "linode/fedora34"
  region    = "us-central"
  type      = "g6-standard-2"
  root_pass = data.vault_generic_secret.generic.data["root_pass"]

  provisioner "remote-exec" {
    inline = [
      #"sudo dnf update -y",
      "sudo curl https://vault.waltr.tech/v1/sshca/public_key > /etc/ssh/cakey.pem",
      "echo 'TrustedUserCAKeys /etc/ssh/cakey.pem' | sudo tee -a /etc/ssh/sshd_config",
      "useradd blackphidora",
      "usermod -aG sudo blackphidora",
      "sudo systemctl restart sshd"

    ]
    connection {
      type     = "ssh"
      host     = self.ip_address
      user     = "root"
      password = data.vault_generic_secret.generic.data["root_pass"]
    }
  }
}

# resource "cloudflare_record" "zomboid-dns" {
#   name    = "zomboid."
#   zone_id = data.vault_generic_secret.cloudflare.data["zone_id_rwaltrpro"]
#   type    = "A"
#   value   = linode_instance.zomboid.ip_address

# }
