# The Kubernetes operator's own trust credential, created here rather than by
# hand so the scopes it runs with are reviewable and reproducible, then written
# into 1Password below for External Secrets to hand to the operator.
#
# Scopes mirror the Tailscale operator install docs, which name them by their
# console labels (General > Services, Devices > Core, Keys > Auth Keys). An
# unknown scope id is rejected by the API at apply time, so a mistake here fails
# loudly rather than silently granting less than the operator needs.
#
# tags is not optional: Tailscale requires tags for devices:core and auth_keys,
# and tag:k8s-operator must own tag:k8s in the policy file
# (infra/terraform/tailscale/policy.hujson) or device creation fails later.
resource "tailscale_oauth_client" "operator" {
  # Capped at 50 characters by the provider.
  description = "mouse k8s operator (infra/terraform/bootstrap)"
  scopes      = ["devices:core", "auth_keys", "services"]
  tags        = ["tag:k8s-operator"]
}
