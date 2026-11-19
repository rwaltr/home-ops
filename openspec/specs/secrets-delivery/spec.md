# Secrets Delivery

## Purpose

How secret values reach workloads without ever being stored in git: one vault, one
cluster store, a defined set of writers, and in-cluster generation for values nobody
outside the cluster reads. Derived from the manifests, `infra/terraform/bootstrap`, and
`mise run secrets:verify`; not a live check of the vault. Why this design and not
SOPS: `docs/adr/0012-1password-connect-and-eso-for-secrets.md`.

## Requirements

### Requirement: Keep secret values out of git

The repository SHALL NOT contain secret values. A manifest that must carry a secret
before External Secrets exists SHALL hold only a 1Password reference (`op://…`) that is
resolved at apply time.

#### Scenario: Bootstrap the Connect credentials

- **GIVEN** a cluster with no External Secrets operator yet
- **WHEN** `infra/k8s/bootstrap/kustomize/external-secrets/secret.yaml` is applied
- **THEN** its values are `op://home-ops/...` references injected at apply time
- **AND** no plaintext value is present in the committed file

#### Scenario: Commit a manifest with a secret value

- **WHEN** a staged change contains a credential
- **THEN** the `gitleaks-staged` pre-commit step rejects the commit

### Requirement: Read every synced secret through the single cluster store

Every ExternalSecret that pulls from 1Password SHALL reference the
`ClusterSecretStore` named `onepassword-connect`, and that store SHALL map exactly
one vault, `home-ops`.

#### Scenario: Add an ExternalSecret for a new app

- **WHEN** a new ExternalSecret sources a value from 1Password
- **THEN** its `secretStoreRef` is `kind: ClusterSecretStore`, `name: onepassword-connect`
- **AND** the item it names lives in the `home-ops` vault

#### Scenario: Verify the cluster can resolve its secrets

- **WHEN** `mise run secrets:verify` runs
- **THEN** every item and field referenced by an ExternalSecret manifest is checked to
  exist in the vault, by label only
- **AND** a missing item or field fails the task without printing any value

### Requirement: Restrict who writes the vault

Vault items SHALL be written only by a human, by the `infra/terraform/bootstrap`
workspace, or by External Secrets (through a `PushSecret`). No other workload or
controller SHALL write to 1Password.

#### Scenario: Mint a credential nothing upstream issues

- **GIVEN** an app needs a key that a human or another system must also hold
- **WHEN** the key is created
- **THEN** it is minted by a resource in `infra/terraform/bootstrap` and written to the
  `home-ops` vault
- **AND** the app reads it through an ExternalSecret like any other item

#### Scenario: Write an in-cluster value back to the vault

- **GIVEN** a value produced in the cluster that a human or outside system must read
- **WHEN** it is written to 1Password
- **THEN** it is written by External Secrets through a `PushSecret`, not by the app

### Requirement: Generate cluster-only values in the cluster

A value that no human and no system outside the cluster reads SHALL be produced by an
External Secrets generator rather than stored in 1Password. A generated value that must
stay stable SHALL sync once (`refreshInterval: "0"`).

#### Scenario: Add a session signing key

- **GIVEN** an app needs a session or internal encryption key that nothing else reads
- **WHEN** the key is provisioned
- **THEN** an ExternalSecret sources it from a `generators.external-secrets.io` generator
- **AND** that ExternalSecret sets `refreshInterval: "0"`, so the key is not rotated on
  each reconcile and existing sessions or encrypted data survive

#### Scenario: Use a short-lived generated token

- **GIVEN** a generator whose output is meant to expire, such as a GitHub access token
- **WHEN** its ExternalSecret is reconciled
- **THEN** a non-zero `refreshInterval` shorter than the token lifetime is allowed

### Requirement: Fan out shared credentials by namespace label

A credential that many namespaces need SHALL be distributed by a
`ClusterExternalSecret` selecting a namespace label, not copied into each namespace by
hand.

#### Scenario: Enrol a namespace in backups

- **WHEN** a namespace gains the label `kopiur.home-operations.com/repo: cluster-kopia`
- **THEN** the kopia repository credentials appear in that namespace via
  `kopiur-repo/app/clusterexternalsecret.yaml`

## Baseline Evidence

Traceability pointers, not additional requirements:

- `infra/k8s/kyz/apps/external-secrets/onepassword-connect/app/clustersecretstore.yaml`:
  the single store and its one vault.
- `infra/k8s/bootstrap/kustomize/external-secrets/secret.yaml`: the only committed
  `kind: Secret` in `infra/k8s`, holding `op://` references.
- 37 ExternalSecret manifests under `infra/k8s/kyz`, all referencing
  `onepassword-connect` (counted 2026-11-19).
- Generators: `freshrss`, `homepage`, `kritika` (stable, `refreshInterval: "0"`);
  `renovate-operator/jobs` (rotating GitHub token).
- `infra/terraform/bootstrap/*.tf`: `onepassword_item` resources. No `PushSecret`
  exists in the repo yet (counted 2026-11-19), so Terraform is the only vault
  writer today.
- `.mise/tasks/secrets/verify`, `hk.pkl` (`gitleaks-staged`), `docs/secrets.md`.

## Verification Limits

This baseline does not assert that the vault currently holds every referenced item,
that Connect is in sync, or that no secret exists in git history — `mise run
secrets:verify` and the full-history `gitleaks` step are the checks for those, and
were not run while writing this. "No other workload writes the vault" is inferred from
the absence of write-capable 1Password credentials in workload manifests, not from an
audit of each image.
