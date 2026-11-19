# GitOps Reconciliation

## Purpose

The repository-defined reconciliation contract for cluster applications: which
source Flux reads, which commit it may deploy, and how a manifest in this repo
becomes a running workload. This baseline is derived from the checked-out
manifests plus operator-confirmed intent; it is not a live-cluster verification.
Host provisioning (`infra/flatcar`), cloud resources (`infra/terraform`), and
individual application behaviour are out of scope.

## Requirements

### Requirement: Retrieve manifests from outside the cluster

Flux SHALL retrieve manifests from the GitHub mirror at
`github.com/rwaltr/home-ops`, not from the in-cluster Forgejo at
`git.waltr.tech`, so that manifest retrieval does not depend on a service the
cluster itself runs.

#### Scenario: Recover a cluster whose Forgejo is gone

- **GIVEN** the merged history is present on the GitHub mirror
- **WHEN** Flux starts against an empty or rebuilt cluster
- **THEN** its configured manifest source is the GitHub mirror
- **AND** no part of reconciliation requires in-cluster Forgejo

#### Scenario: Land an authoritative Forgejo commit

- **GIVEN** a commit is merged to `master` on Forgejo
- **WHEN** the change is expected on the cluster
- **THEN** verification establishes the commit reached the GitHub mirror at the
  revision Flux consumes before treating a missing rollout as a manifest bug

### Requirement: Deploy only from the default branch

The configured sync source SHALL track `refs/heads/master`, so a branch or pull
request cannot change cluster state without being merged.

#### Scenario: Push an unmerged branch

- **GIVEN** a branch with manifest edits exists on the remote
- **WHEN** Flux reconciles on its interval
- **THEN** it reads `refs/heads/master`
- **AND** the branch contents are not applied

### Requirement: Reach applications through an explicit registration chain

A workload SHALL be reachable only through the full chain: the root
Kustomization at `infra/k8s/kyz` → a namespace directory under `apps/` → an
app's `ks.yaml` (a Flux Kustomization) → the app's `app/` Kustomize build.
Removing a link is the mechanism for disabling an app.

#### Scenario: Reconcile a registered application

- **WHEN** the root Kustomization is built
- **THEN** it includes the namespace directory that lists the app's `ks.yaml`
- **AND** that Flux Kustomization selects the app's `app` path with `prune: true`

#### Scenario: Disable an application

- **GIVEN** an app whose `ks.yaml` is commented out of its namespace
  `kustomization.yaml`
- **WHEN** Flux reconciles that namespace
- **THEN** the app's Flux Kustomization is absent from the build
- **AND** its workloads and pruned resources are removed, so disabling is stated
  in the comment with the reason and the date

### Requirement: Separate the Flux namespace from the workload namespace

The namespace directory SHALL assign the Flux resource's namespace through
Kustomize `namespace:`, and each Flux Kustomization SHALL set
`spec.targetNamespace` to the namespace its resources are deployed into.

#### Scenario: Deploy into a namespaced app

- **WHEN** an app's `ks.yaml` is built inside its namespace directory
- **THEN** the Flux Kustomization object itself carries that namespace
- **AND** `spec.targetNamespace` names the same namespace for the deployed
  resources, rather than relying on a namespace set on each manifest

### Requirement: Declare chart sources explicitly

An application SHALL name its chart source in its own `app/kustomization.yaml`,
with the chart pulled from a pinned `OCIRepository` and selected by the
HelmRelease through `spec.chartRef`.

#### Scenario: Build a Helm-managed application

- **WHEN** an app's `app` path is built
- **THEN** the build includes both `helmrelease.yaml` and `ocirepository.yaml`
- **AND** the HelmRelease selects that repository through `spec.chartRef`

## Baseline Evidence

Traceability pointers, not additional requirements:

- `infra/k8s/kyz/apps/flux-system/flux-instance/app/helmrelease.yaml`: sync kind,
  URL, revision, path, interval.
- `infra/k8s/kyz/kustomization.yaml`: root resources (namespace directories).
- `infra/k8s/kyz/apps/default/kustomization.yaml`: namespace assignment, app
  registration, and commented-out app intent.
- `infra/k8s/kyz/apps/default/it-tools/{ks.yaml,app/kustomization.yaml}`:
  representative Flux Kustomization, `targetNamespace`, and chart source pair.
- `docs/forgejo.md`: operator-confirmed reason the mirror is the Flux source.

## Verification Limits

This baseline asserts nothing about live cluster health, whether every app
follows the representative pattern, or current push-mirror lag. Forgejo-to-GitHub
delivery and the revision live Flux has actually observed were not verified while
writing it.
