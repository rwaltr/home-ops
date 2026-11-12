# The tailnet policy file (tags, grants, autoApprovers) lives in policy.hujson so
# that a change to access control arrives as a reviewable diff next to everything
# else, instead of as a click in the admin console.
#
# This resource owns the WHOLE policy file: the API replaces it wholesale. The
# provider guards against that — without an import it refuses to change an
# existing policy, so the first apply fails with a message rather than quietly
# dropping any rules that live in the console and not here. Import once:
#
#   terraform import tailscale_acl.tailnet acl
#
# Do not add overwrite_existing_content: the guard is the point.
resource "tailscale_acl" "tailnet" {
  acl = file("${path.module}/policy.hujson")
}
