# The client key that consumers present to CLIProxyAPI, minted here for the same
# reason as the MikroTik MCP token: nothing upstream issues it, so a hand-pasted
# value would exist in one place with no record of its purpose and no rotation.
#
# This is *not* the provider credential. Codex/ChatGPT, Claude and Gemini sessions
# are OAuth logins a human authorises in a browser; the proxy receives the token
# pairs, refreshes them, and rewrites them on its PVC. No vault can hold those,
# and it should not try — a stale copy breaks the account rather than failing
# loudly. This item is only the front-door key.
resource "random_password" "cliproxyapi_key" {
  length  = 48
  special = false
}

resource "onepassword_item" "cliproxyapi" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "cliproxyapi"
  category = "login"
  url      = "http://cliproxyapi.default.svc.cluster.local:8317"

  # Names the consumer rather than the field.
  username = "agentgateway"
  password = random_password.cliproxyapi_key.result
}
