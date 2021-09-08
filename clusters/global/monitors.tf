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


#resource "uptimerobot_monitor" "home" {
#friendly_name = "home"
#type          = "ping"
#url           = "home.waltr.tech"
## pro allows 60 seconds
#interval = 300

#}
