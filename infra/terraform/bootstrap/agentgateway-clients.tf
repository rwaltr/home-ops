# Inbound credentials for the gateway's public door: one key per client, minted
# rather than pasted.
#
# Why these are generated here: a client key is a value nothing upstream issues and
# nothing human needs to read. What matters is that each client holds its own, so
# revoking one does not disturb the others — the Grok key in a phone and the ring's
# key in another phone are independent failures, not one shared password.
#
# The keys are consumed as `keys[].key` in the agentgateway config, which arrives by
# environment substitution, so nothing plaintext is committed. Metadata in the config
# maps each key to a client identity (`apiKey.client`), and that identity is what the
# per-client model allow-lists and MCP authorization rules are written against.
#
# Same shape as the other minted tokens: own item, login category, password field, so
# the ExternalSecret resolves `<item>`/`password` with the two-level reference used
# everywhere else in this repo.
#
# Values live in Terraform state (sensitive, stored) — the documented price of
# generating rather than pasting. `random_password` produces on create only, so a
# later apply leaves existing keys alone and does not break a configured client.

resource "random_password" "grok_key" {
  length  = 48
  special = false
}

resource "onepassword_item" "grok" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "grok"
  category = "login"
  url      = "https://llm.waltr.tech"

  # Names the consumer: this key authenticates the client to the gateway.
  username = "agentgateway"
  password = random_password.grok_key.result
}

resource "random_password" "pebble_index_key" {
  length  = 48
  special = false
}

resource "onepassword_item" "pebble_index" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "pebble-index"
  category = "login"
  url      = "https://llm.waltr.tech"

  username = "agentgateway"
  password = random_password.pebble_index_key.result
}

# pi, the operator's own agent client. Its own key for the same reason as the
# others: revoking it must not disturb the phone clients. It is the only client
# allowed to reach `claude`, the paid subscription behind cliproxyapi.
resource "random_password" "pi_key" {
  length  = 48
  special = false
}

resource "onepassword_item" "pi" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "pi"
  category = "login"
  url      = "https://llm.waltr.tech"

  username = "agentgateway"
  password = random_password.pi_key.result
}

# Not a client credential: the key that encrypts MCP session IDs.
#
# Without it the gateway logs "no session key configured; MCP session IDs are not
# encrypted" and emits session IDs that are base64 only — a client can decode the
# multiplexed target names and upstream session IDs out of them. That is tolerable on
# a cluster-internal listener and not on a public one, so it is set before the public
# route exists.
#
# 32 bytes as 64 hex characters, which is what the gateway expects.
resource "random_bytes" "session_key" {
  length = 32
}

resource "onepassword_item" "agentgateway_session" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "agentgateway-session"
  category = "login"

  username = "agentgateway"
  password = random_bytes.session_key.hex
}
