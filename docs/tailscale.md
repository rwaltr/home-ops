# Tailscale (tailnet)

Device-identity access to services that should not be published to the open
internet. VPN only — this is transport and network identity, not application
authentication; there is no AAA here and no app SSO.

The host already ships `tailscaled` (Flatcar sysext 1.102.2, see
`infra/flatcar/butane/base.bu`) and `envoy.yaml` already reserves the external
VIPs for it. What had never been built is the cluster side.

## What Terraform owns

Two workspaces, both running locally (credentials from fnox, state in Terraform
Cloud):

| Workspace   | Directory                    | Owns                                                     |
| ----------- | ---------------------------- | -------------------------------------------------------- |
| `tailscale` | `infra/terraform/tailscale/` | tailnet policy file, MagicDNS, tailnet settings          |
| `bootstrap` | `infra/terraform/bootstrap/` | the operator's OAuth client, and writing it to 1Password |

`bootstrap` is the only project in the repo that holds `OP_SERVICE_ACCOUNT_TOKEN`,
and the only one that writes secrets. Everything else reads them: fnox for local
tooling, External Secrets for the cluster.

## The one manual step

Terraform cannot create the trust credential it authenticates as — creating one
needs the API you need it for. So this exists by hand, once:

1. Tailscale admin console → **Trust credentials** → **+ Credential** (OAuth).
2. Scopes, read and write — exactly the endpoints these two workspaces call:
   **Policy File** (`tailscale_acl` → `POST /tailnet/:tailnet/acl`), **DNS**
   (`tailscale_dns_preferences`), **Networking Settings** (the HTTPS-certificates
   setting, for `https_enabled`) and **OAuth Keys** (where `bootstrap` mints the
   operator's client).

   **Devices: Core is not needed** — nothing here manages devices — and that also
   drops the requirement that such a credential carry a tag. Keep the tag
   `tag:k8s-operator` regardless: the operator's own client has to be created
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
tailscale status                        # on mouse, after joining the tailnet
```

The tailnet policy file is also readable as a whole:

```bash
terraform -chdir=infra/terraform/tailscale plan   # must not want to change policy
```

## Not yet built

- **The Kubernetes operator itself.** It needs a HelmRepository
  (`https://pkgs.tailscale.com/helmcharts`) plus a HelmRelease in a `tailscale`
  namespace, consuming the `tailscale-operator` item via ExternalSecret. It
  creates the `tailscale` IngressClass and the `ProxyClass`/`ProxyGroup`/
  `Connector`/`DNSConfig`/`Tailnet` CRDs.
- **Exposing the gateway on the tailnet.** Two shapes, and the choice depends on
  how Envoy Gateway manages its Service: annotate the generated Service so the
  LAN VIP and a tailnet address both work, or create per-app `Ingress` objects
  with `ingressClassName: tailscale` — more objects, but every one owned in git.
- **Joining mouse to the tailnet**, which is `tailscale up --hostname=mouse`
  followed by approving the device.
