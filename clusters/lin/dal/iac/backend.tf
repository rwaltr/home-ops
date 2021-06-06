terraform {
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/22827251/terraform/state/lin-dal/"
    lock_address   = "https://gitlab.com/api/v4/projects/22827251/terraform/state/lin-dal/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/22827251/terraform/state/lin-dal/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}