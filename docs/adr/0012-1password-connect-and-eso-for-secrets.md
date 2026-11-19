# 1Password Connect + External Secrets, not SOPS

Status: accepted

Cluster secrets come from the 1Password vault `home-ops` through 1Password Connect and
a single `ClusterSecretStore` (`onepassword-connect`); local and CI tooling reaches the
same vault through fnox. SOPS+age, the earlier approach, was dropped: it puts
encrypted secrets in git and a decryption key on every machine that renders manifests,
while Connect keeps values out of git entirely and lets Terraform mint credentials
straight into the vault.

Values nothing outside the cluster reads (session keys, internal crypto keys) are
generated in the cluster by External Secrets generators and never enter 1Password.

## Consequences

- Bootstrap needs one hand-made secret (the Connect credentials) before anything else
  can resolve.
- Only `infra/terraform/bootstrap` writes to the vault; its service account needs read
  **and** write.
- Connect can lag well behind items created from the desktop CLI; restarting the
  Connect pod forces a resync.

Contract: `openspec/specs/secrets-delivery`. Runbook: `docs/secrets.md`.
