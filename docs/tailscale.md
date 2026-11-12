# Tailscale (tailnet)

Device-identity access to services that should not be published to the open
internet. VPN only — this is transport and network identity, not application
authentication; there is no AAA here and no app SSO.

The host ships `tailscaled` (Flatcar sysext 1.102.2, see
`infra/flatcar/butane/base.bu`) and is joined as the device `mouse`. The cluster
side is the operator below: a second device, plus a subnet router that makes the
internal services reachable from anywhere on the tailnet.

## What Terraform owns

Two workspaces, both running locally (credentials from fnox, state in Terraform
Cloud):

| Workspace   | Directory                    | Owns                                                     |
| ----------- | ---------------------------- | -------------------------------------------------------- |
| `tailscale` | `infra/terraform/tailscale/` | tailnet policy file, MagicDNS, settings, split DNS       |
| `bootstrap` | `infra/terraform/bootstrap/` | the operator's OAuth client, and writing it to 1Password |

`bootstrap` is the only project in the repo that holds `OP_SERVICE_ACCOUNT_TOKEN`,
and the only one that writes secrets. Everything else reads them: fnox for local
tooling, External Secrets for the cluster.

## The one manual step

Terraform cannot create the trust credential it authenticates as — creating one
needs the API you need it for. So this exists by hand, once:

1. Tailscale admin console → **Trust credentials** → **+ Credential** (OAuth).
2. Scopes, read and write. Two sets, and both are needed:

   - what these workspaces call: **Policy File** (`tailscale_acl` →
     `POST /tailnet/:tailnet/acl`), **DNS** (`tailscale_dns_preferences`),
     **Networking Settings** (the HTTPS-certificates setting, for `https_enabled`)
     and **OAuth Keys** (where `bootstrap` mints the operator's client);
   - what that minted client is created _with_: **Devices: Core** (write, which
     Tailscale only grants to a credential that carries a tag — hence
     `tag:k8s-operator`) and **Keys: Auth Keys**. A credential cannot grant a
     scope it does not itself hold, so omitting either fails at apply with
     `actor cannot set scopes: [devices:core …]` naming it.

   Keep the tag `tag:k8s-operator`: the operator's own client has to be created
   _carrying_ it, and Tailscale tags limit what a credential may assign. If the tag
   is refused, the apply says so with a 403 naming it and this line is the fix.

3. Put the client ID and secret in the 1Password item **`tailscale-bootstrap`**
   as fields `client_id` and `client_secret`.

Everything after that is `mise run tf:plan <workspace>`. The generated operator
credential never needs pasting: `bootstrap` writes it.

## Import the policy file before the first apply

`tailscale_acl` owns the **entire** policy file — the API replaces it wholesale.
The provider therefore refuses to change an existing policy without an import, so
the first apply fails rather than quietly dropping any rules that live in the
console and not in `policy.hujson`. That guard is deliberate; do not set
`overwrite_existing_content`.

```bash
mise run tf:init
terraform -chdir=infra/terraform/tailscale import tailscale_acl.tailnet acl
```

Then read the plan and confirm `policy.hujson` reproduces the access the tailnet
actually has. `settings.tf` also switches off the console policy editor
(`acls_externally_managed_on`), so after this the repo is the source of truth and
a console edit cannot silently diverge.

## The two 1Password items

| Item                  | Made by               | Fields                                             |
| --------------------- | --------------------- | -------------------------------------------------- |
| `tailscale-bootstrap` | hand, once            | `client_id`, `client_secret`                       |
| `tailscale-operator`  | `bootstrap` workspace | `username` = client ID, `password` = client secret |

The operator item reuses a login's `username`/`password` because the 1Password
provider can only write custom fields inside a section, and External Secrets
resolves the two-level `item/field` form that the rest of this repo uses.

Two things worth knowing about `bootstrap`:

- The operator's client secret is also in Terraform state, via the OAuth client's
  `key` attribute (sensitive, but stored). That is the cost of generating the
  credential rather than pasting it.
- An unknown scope id in `tailscale-operator.tf` is rejected by the API at apply
  time, so a scope mistake fails loudly instead of quietly under-granting.

## Verification

```bash
mise run tf:check                       # fmt, init, validate across all workspaces
tailscale status                        # on mouse: is the host connected
kubectl -n network get pods             # operator, and the connector's proxy
kubectl -n network get connector cluster -o yaml   # routes, and their approval
```

The tailnet policy file is also readable as a whole:

```bash
terraform -chdir=infra/terraform/tailscale plan   # must not want to change policy
```

## The operator

`apps/network/tailscale-operator/` deploys the upstream chart from a
HelmRepository — app-template cannot express the cluster-scoped CRDs it ships
(`Connector`, `ProxyClass`, `ProxyGroup`, `Recorder`, `Tailnet`, `DNSConfig`,
`PeerRelay`) or their RBAC — into the `network` namespace rather than the
`tailscale` namespace its docs use.

Its OAuth credential is the `tailscale-operator` item written by `bootstrap`. The
chart mounts a Secret named `<fullname>-oauth` and reads `client_id` and
`client_secret` out of it as files, so the ExternalSecret's `target.name` and
those two keys are a contract: rename one and the operator installs, runs, and
never authenticates. The chart's own `oauth` block is left empty so no client
secret passes through a HelmRelease.

Credential changes are read once, at startup, so the operator carries
`reloader.stakater.com/auto`.

## Reaching cluster services from the tailnet

A `Connector` (`connector.yaml`, beside the operator) advertises the Cilium
LoadBalancer VIP range — `10.10.100.0/24` and its IPv6 counterpart — so tailnet
clients reach `envoy-internal` and `envoy-external` at the same addresses LAN
clients use. One device and one object, and the 26 HTTPRoutes stay the only
description of what exists.

Split DNS is the other half (`dns.tf`, `waltr.tech` → k8s-gateway at
`10.10.100.53`). Without it a tailnet client cannot resolve the internal
hostnames at all: the public zone carries only what external-dns published
through `envoy-external`. k8s-gateway answers each HTTPRoute with the VIP of the
Gateway serving it, so internal and public hostnames each resolve correctly.

Routes are approved by `autoApprovers.routes` in `policy.hujson` rather than by
clicking them in the console, so the capability stays declarative — and the
Connector has to be created _after_ that policy lands, or its routes sit
unapproved.

The trade, stated plainly: this is network-level access for **every device in the
tailnet**, including the internal apps that have no login of their own. That is
what being on the LAN already means. A per-app `Ingress` with
`ingressClassName: tailscale` inverts it — per-app granularity and ACLs, at the
cost of a proxy pod per app, hostnames that are not `waltr.tech`, and traffic
that bypasses envoy entirely.

## Not yet built

- **API server proxy** (`apiServerProxyConfig`), so `kubectl` works from a
  tailnet device without network access to the API.
- **ACLs.** The policy file is still Tailscale's stock `src: ["*"] dst:
["*:*"] accept`. Fine for one user, and a plain statement of the current
  posture rather than a plan.
- **The host's node key.** `mouse` authenticates as a user device, so its key
  expires after 180 days; tagged devices are exempt.
