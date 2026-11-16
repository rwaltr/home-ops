# The kubesearch MCP server's inbound bearer token, minted here for the same reason
# as the MikroTik one: nothing upstream issues it, and a token invented in a console
# is a value with no record of what it is for.
#
# Same shape as microtik-mcp — its own item, one login, password field — so the
# ExternalSecret resolves `kubesearch-mcp`/`password` with the same two-level
# reference every other secret in the repo uses.
#
# Without this token kubesearch-mcp's HTTP transport is open by default: it binds
# 0.0.0.0 with CORS `*` and no auth, and logs a warning about it on boot.
#
# Only created when the item does not exist yet; a later apply leaves the token
# alone because `random_password` produces on create only. Consumer: agentgateway,
# which presents it as `Authorization: Bearer <token>`.
resource "random_password" "kubesearch_mcp_token" {
  length  = 48
  special = false
}

resource "onepassword_item" "kubesearch_mcp" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "kubesearch-mcp"
  category = "login"
  url      = "http://kubesearch-mcp.default.svc.cluster.local:3000/mcp"

  username = "agentgateway"
  password = random_password.kubesearch_mcp_token.result
}
