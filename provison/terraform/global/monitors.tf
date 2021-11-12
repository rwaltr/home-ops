resource "uptimerobot_monitor" "blog" {
  friendly_name = "Blog"
  type          = "http"
  url           = "http://blog.waltr.tech"
  # pro allows 60 seconds
  interval = 300

}
resource "uptimerobot_monitor" "start" {
  friendly_name = "start"
  type          = "http"
  url           = "http://start.waltr.tech"
  # pro allows 60 seconds
  interval = 300

}


resource "uptimerobot_monitor" "kyz" {
  friendly_name = "KYZ"
  type          = "ping"
  url           = "8308.waltr.tech"
  interval      = 300

}
