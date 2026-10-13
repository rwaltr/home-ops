# Terraform pipeline (agent-authored infrastructure)

Tofu Controller ([flux-iac](https://github.com/flux-iac/tofu-controller)) reconciles
`Terraform` objects against a Flux source. HCL lives in this repo, a `Terraform` object
points at a path in it, and the controller runs plan/apply on its own — instead of a human
running `terraform` on a workstation. It is the engine that lets the agent author
infrastructure through the normal branch + PR loop.

Installed at `infra/k8s/kyz/apps/flux-system/tofu-controller/` (chart `0.16.5`, pinned by
digest). The decision record and the comparison against Crossplane and Pulumi is issue
[#913](https://github.com/rwaltr/home-ops/issues/913).

## Why this engine

- It is a Flux controller, so it adds one component to a GitOps loop that already runs
  here rather than a second control plane.
- It persists state in a Kubernetes Secret by default, so no external state backend is
  required. (Crossplane's `provider-opentofu` explicitly does not persist state.)
- `approvePlan` is a first-class workflow: `auto`, manual (gated on a plan hash), or
  `disable`. Crossplane has no equivalent plan/approve step.
- HCL is the same language as the existing `infra/terraform/`, and it is constrained and
  declarative — which matters more, not less, when an agent is the author.

## The state question, and why the DNS workspace is safe to adopt

The Cloudflare workspace runs against **Terraform Cloud**:

```hcl
terraform {
  cloud {
    organization = "rwaltr"
    hostname     = "app.terraform.io"
    workspaces { name = "cloudflare-provisioner" }
  }
}
```

Tofu Controller speaks TFC natively: `spec.cloud` plus a `cliConfigSecretRef` pointing at
a Secret holding a `terraform.tfrc`, and **state stays in the Terraform Cloud workspace**.
Nothing is migrated and nothing is imported.

This is the whole reason the adoption is safe. A controller pointed at 39 live DNS records
with an empty state would try to create a second copy of every record. Pointed at the
existing TFC workspace, it sees the state that is already there and the first plan it
produces is a comparison against reality, not a create-everything.

## Day-one configuration

Any `Terraform` object starts with:

```yaml
spec:
  approvePlan: disable
```

`disable` means the controller **detects drift only and skips both the plan and the apply
stages**. It cannot change anything. The first object is promoted only after its drift
output has been read and understood.

## Blockers, stated plainly

Two things must exist before any `Terraform` object can run. Both are open.

### 1. Terraform Cloud API token (owner step)

Create a TFC user or team API token and store it in 1Password as item `terraform-cloud`,
field `TFC_TOKEN`. Scope it to the `cloudflare-provisioner` workspace if TFC allows — the
controller only needs to start runs there. Until the item exists the ExternalSecret
reports `SecretSyncedError` and no `Terraform` object can run. That is fail-closed, and it
is intended.

### 2. The SOPS age key — the real design question

The Cloudflare workspace does not read credentials from environment variables. It decrypts
them from SOPS files at plan time:

```hcl
data "sops_file" "cloudflare_secrets" {
  source_file = "cloudflare_secrets.sops.yaml"
}
provider "cloudflare" {
  email   = local.cloudflare_secrets["cloudflare_email"]
  api_key = local.cloudflare_secrets["cloudflare_api_key"]
}
```

`carlpett/sops` decrypts with the age private key, which today lives on the workstation at
`~/.config/sops/age/keys.txt`. A controller running in-cluster (or a TFC remote runner)
does not have it, so **the workspace as written cannot run anywhere but rwaltr's machine**.

Two ways out:

- **(a) Refactor the workspace to take credentials from the environment.** Replace the
  `sops_file` lookups with variables fed by `TF_VAR_*` from a Secret, supplied by ESO from
  1Password. The age key never enters the cluster. This also removes the `sops` provider
  from a workspace that only used it for credentials.
- **(b) Give the runner the age key.** Cheaper to write, but that one key decrypts _every_
  SOPS file in this repo, so it is a strictly larger grant than the Cloudflare credential
  itself.

**(a) is recommended**, and it is worth doing regardless of this project: the same change
is an opportunity to replace `cloudflare_api_key` — a **global Cloudflare API key** — with
a scoped API token, which is what `external-dns` and `cert-manager` already use from the
`cloudflare` 1Password item.

Either option is a change to a live DNS workspace, so it is deliberately not bundled with
the controller install. It lands as its own PR, planned against TFC first, where the
expected result is **no resource changes** — which is what proves the credential swap is
sound before anything can apply.

## Sequence

1. **Shipped:** tofu-controller installed, no `Terraform` objects. Nothing can act on DNS.
2. **Next, needs (1) above:** the `Terraform` object for the Cloudflare workspace with
   `approvePlan: disable`, so the first output is drift information only.
3. **Then, needs a decision on (2):** the credential refactor, planned against TFC, with
   the plan expected to be empty.
4. **Only then:** promote to manual approval, and `auto` for a named non-destructive class.

## Operating notes

- Read a plan out of the object, not the repo:
  `kubectl -n flux-system get terraform <name> -o yaml` — the plan and drift live in
  status.
- State backup, if the Kubernetes backend is ever used:
  `kubectl get secret tfstate-<workspace>-<name> -o jsonpath='{.data.tfstate}' | base64 -d | gzip -d`
- To stop the controller acting on everything at once:
  `kubectl -n flux-system suspend kustomization tofu-controller` — or remove the
  `./tofu-controller/ks.yaml` entry from the group kustomization and let Flux prune it.
- A stuck workspace lock is released with `tfctl unlock`, not by deleting objects.
