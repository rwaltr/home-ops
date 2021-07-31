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
