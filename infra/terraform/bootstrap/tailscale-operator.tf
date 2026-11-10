# The Kubernetes operator's own trust credential, created here rather than by
# hand so the scopes it runs with are reviewable and reproducible, then written
# into 1Password below for External Secrets to hand to the operator.
#
# Scopes mirror the Tailscale operator install docs, which name them by their
# console labels (Devices > Core, Keys > Auth Keys). An
# unknown scope id is rejected by the API at apply time, so a mistake here fails
# loudly rather than silently granting less than the operator needs.
#
# The bootstrap credential has to hold these same two scopes: Tailscale refuses
# to let a credential grant what it does not have, so without them this fails as
# `actor cannot set scopes: [devices:core auth_keys] (403)`.
#
# Services (Tailscale's VIP "services") is deliberately absent. Only that feature
# needs it, its scope id does not appear in the current trust-credential scope
# list, and asking for a scope the parent credential cannot confer fails the whole
# apply rather than just that field. Add it here and to the credential together if
# Tailscale Services is ever wanted.
#
# tags is not optional: Tailscale requires tags for devices:core and auth_keys,
# and tag:k8s-operator must own tag:k8s in the policy file
# (infra/terraform/tailscale/policy.hujson) or device creation fails later.
resource "tailscale_oauth_client" "operator" {
  # Capped at 50 characters by the provider.
  # Tailscale rejects punctuation here (parentheses and slashes included), so the
  # description stays alphanumeric with spaces and dashes.
  description = "mouse k8s operator - home-ops repo"
  scopes      = ["devices:core", "auth_keys"]
  tags        = ["tag:k8s-operator"]
}
