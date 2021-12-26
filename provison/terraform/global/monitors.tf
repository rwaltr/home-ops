# resource "uptimerobot_monitor" "blog" {
#   friendly_name = "Blog"
#   type          = "http"
#   url           = "http://blog.waltr.tech"
#   # pro allows 60 seconds
#   interval = 300
#
# }
# resource "uptimerobot_monitor" "start" {
#   friendly_name = "start"
#   type          = "http"
#   url           = "http://start.waltr.tech"
#   # pro allows 60 seconds
#   interval = 300
#
# }
# resource "uptimerobot_monitor" "jellyfin" {
#   friendly_name = "jellyfin"
#   type          = "http"
#   url           = "http://jellyfin.waltr.tech"
#   # pro allows 60 seconds
#   interval = 300
#
# }
# resource "uptimerobot_monitor" "bin" {
#   friendly_name = "bin"
#   type          = "http"
#   url           = "http://bin.waltr.tech"
#   # pro allows 60 seconds
#   interval = 300
#
# }
# resource "uptimerobot_monitor" "argo" {
#   friendly_name = "argocd"
#   type          = "http"
#   url           = "http://argocd.waltr.tech"
#   # pro allows 60 seconds
#   interval = 300
#
# }
# resource "uptimerobot_monitor" "vault" {
#   friendly_name = "vault"
#   type          = "http"
#   url           = "http://vault.waltr.tech"
#   # pro allows 60 seconds
#   interval = 300
#
# }
#



resource "uptimerobot_monitor" "kyz" {
  friendly_name = "KYZ"
  type          = "ping"
  url           = "8308.waltr.tech"
  interval      = 300

}
