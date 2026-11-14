# The MikroTik MCP server's inbound bearer token, minted here rather than pasted
# into 1Password by hand.
#
# Why it is *produced* rather than consumed: MikroMCP's HTTP transport refuses to
# start without an identity, whose token is the thing a client presents. Nothing
# upstream issues that token, so it has to be invented — and a value invented in
# a vendor console is a value that exists in one place, unrotated, with no record
# of what it is for. The other half of the reason is repetition: "add a field to
# this item" had already come up twice for the same deployment.
#
# Why its own item, not a field on the hand-made `microtik` item (router
# username/password/confirmsecret):
#   1. The 1Password provider can only write custom fields *inside* a section, and
#      External Secrets resolves the two-level `item/field` reference every other
#      secret in this repo uses — a top-level login field is the shape that works.
#   2. Adopting that item would put fields nobody reviewed (rwaltr's router
#      password among them) under Terraform's control, the same reason
#      onepassword.tf declines to adopt the existing `cloudflare` item.
# So the token lives alone in `microtik-mcp`, and the MCP's ExternalSecret reads
# both items: router credentials from `microtik`, this token from here.
#
# The generated value is in Terraform state (sensitive, but stored) — the price
# of generating rather than pasting, as noted in onepassword.tf. The provider
# regenerates nothing once the item exists: `random_password` only produces on
# create, so a later apply leaves the token alone.
#
# Consumer: the client that talks to http://mikrotik-mcp.default.svc.cluster.local:3000
# (agentgateway), which presents it as `Authorization: Bearer`.
resource "random_password" "mikrotik_mcp_token" {
  length  = 48
  special = false
}

resource "onepassword_item" "mikrotik_mcp" {
  vault    = data.onepassword_vault.secrets.uuid
  title    = "microtik-mcp"
  category = "login"
  url      = "http://10.10.0.1"

  # Names the consumer rather than the field: in the UI this reads as
  # "agentgateway's credential for the MikroTik MCP server".
  username = "agentgateway"
  password = random_password.mikrotik_mcp_token.result
}
