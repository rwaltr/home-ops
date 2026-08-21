# Bootstrap (Phase 2)

Takes a freshly-installed k0s node to a Flux-managed cluster. Run once per
(re)build; after Flux takes over, this directory is dormant until the next
rebuild.

```sh
export OP_SERVICE_ACCOUNT_TOKEN=ops_...   # 1P service account, scoped to the home-ops vault
mise run k8s:bootstrap mouse
```

## What it does

1. Creates `external-secrets`, `cert-manager`, `flux-system` namespaces
2. Renders `secrets/secret.yaml` through `op inject` (resolves
   `op://home-ops/1password/OP_SESSION_JSON` + `OP_CONNECT_TOKEN`) and applies
   it — this seeds the 1Password Connect server + ESO token. Real values never
   touch git or disk.
3. Runs the helmfile DAG in order:

   | File | Release | Why it's here |
   |---|---|---|
   | `00-cilium.yaml` | cilium (kube-system) | Pod networking; Flux itself needs it |
   | `01-coredns.yaml` | coredns (kube-system) | Cluster DNS |
   | `02-cert-manager.yaml` | cert-manager | CRDs + TLS for webhooks later |
   | `03-external-secrets.yaml` | external-secrets | ESO controller + CRDs |
   | `04-onepassword-connect.yaml` | onepassword-connect | Connect server (bjw-s app-template); postsync hook applies `manifests/clustersecretstore.yaml` |
   | `05-flux-operator.yaml` | flux-operator | Flux operator |
   | `06-flux-instance.yaml` | flux-instance | FluxInstance CR (presync hook waits for the CRD) |

## Prerequisites

- k0s applied: `k0sctl apply --config infra/k0s/<host>.yaml`
- kubeconfig: `k0sctl kubeconfig --config infra/k0s/<host>.yaml > .vm/<host>-prod.kubeconfig`
- `op` CLI authenticated via service account (see AGENTS.md; no desktop-app
  integration — flatpak)
- 1Password vault `home-ops` containing item `1password` with fields
  `OP_SESSION_JSON` (the Connect credentials json) and `OP_CONNECT_TOKEN`

## After bootstrap

Flux starts with no git source wired up (intentional — needs a GitHub
credential). Next steps:

1. GitHub token/SSH deploy key → 1P item
2. `kubernetes/flux/` repo config (GitRepository + root Kustomization,
   ESO-sourced) — committed to git, reconciled by Flux
3. Apps land under `kubernetes/apps/<ns>/<app>/` (onedr0p layout)
