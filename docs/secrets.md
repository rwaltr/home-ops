# Secrets (1Password → cluster)

Where cluster secrets live, who is allowed to write them, and how to check that
the cluster can actually get them.

## Flow

1Password vault **`home-ops`** → `ClusterSecretStore` **`onepassword-connect`** →
one Secret per app → the app. The store maps exactly one vault
(`vaults: home-ops: 1` in
`infra/k8s/kyz/apps/external-secrets/onepassword-connect/app/clustersecretstore.yaml`),
and every ExternalSecret in the repo reads from it.

Local and CI tooling reaches the same vault a different way: fnox, with
references in `fnox.toml` and values in 1Password — never in git.

## Who writes what

| Written by                                  | Examples                                                                                                                      |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **You**, by hand in 1Password               | the Cloudflare account token, the OpenRouter key, the Pushover user key, the GitHub App keys, the Reolink and Soulseek logins |
| **Terraform**, `infra/terraform/bootstrap/` | the Tailscale operator's OAuth client, the cluster's Cloudflare DNS tokens                                                    |

`bootstrap` is the only project that holds `OP_SERVICE_ACCOUNT_TOKEN`, and the
only thing in the repo that writes to 1Password. It cannot create the credential
it authenticates as, so that one is hand-made — see `docs/tailscale.md` for the
one-time step.

**That account needs read _and write_ on the vault.** Reading is the everyday case
(`secrets:verify`, `op` lookups) and read-only access satisfies all of it, so a
read-only account fails at the first write and nowhere earlier:

```text
Error creating 1Password item ... you do not have the right permissions to
perform this action: not sufficient permissions for the item update operation
```

Grant it read/write in 1Password (Developer → Service Accounts → the account → the
`home-ops` vault). Terraform cannot repair that from the outside. A failed apply
leaves whatever it managed to create — credentials sitting in state rather than in
1Password — so grant access and re-run; it creates only what is missing.

### Running an apply without a human

`mise run tf:apply` asks for confirmation and Terraform asks again, so a
non-interactive apply (CI, an agent) has to answer both:

```bash
MISE_YES=1 TF_CLI_ARGS_apply=-auto-approve mise run tf:apply <workspace>
```

Without the second, the run aborts before changing anything with
`error asking for approval: EOF`. And never pipe a _running_ `terraform` command
into `head` or anything else that exits early — the SIGPIPE kills it mid-plan and
the cloud backend keeps the state lock, which then blocks every later command.
Redirect to a file and read the file. A lock you own clears with
`terraform force-unlock` given the **workspace path** (`<org>/<workspace>`) as the
id, not the UUID the error also prints.

## Checking it

```bash
mise run secrets:verify
```

Derives every referenced item and field from the ExternalSecret manifests (so it
cannot drift from them) and checks each one against the vault. It prints labels
only, never values, and reports missing items, mistyped or empty fields, and
template references that nothing provides.

It necessarily checks _presence_, not _validity_: an expired or revoked token
passes. Proving a credential still works means calling the API that consumes it.

## The Cloudflare DNS tokens

**What was there:** one _user_-scoped token, never expiring, shared by
external-dns and cert-manager. Nothing could see it (an account token cannot read
user tokens), nothing rotated it, and revoking it would have broken DNS records
and certificate renewal at the same time.

**What `bootstrap` now mints**, as account-owned tokens with an expiry, so they
outlive the person and this workspace can see and replace them:

| Token                   | Zones                     | Item                      |
| ----------------------- | ------------------------- | ------------------------- |
| `home-ops-external-dns` | `waltr.tech`              | `cloudflare-external-dns` |
| `home-ops-cert-manager` | `waltr.tech`, `rwalt.pro` | `cloudflare-cert-manager` |

Zone scope is copied from what each consumer actually asks for — external-dns's
`domainFilters`, cert-manager's `selector.dnsZones` — so the split is least
privilege, not just tidiness. Both use the zone-level **DNS Write** permission
group, so the zone list is the only thing limiting them.

### Switching over (staged, on purpose)

The tokens are minted and stored; **nothing reads them yet**. That is deliberate:
swapping a credential that guards DNS records _and_ Let's Encrypt DNS-01 fails
silently — certificates simply stop renewing — so the flip is a separate step you
can verify and undo.

1. `mise run tf:apply bootstrap` — mints both tokens and writes the two items.
2. Confirm both tokens exist and are active. These are account-owned, so read
   them with the account token instead of revealing the tokens themselves (account
   id: `infra/terraform/bootstrap/cloudflare-tokens.tf`):

   ```bash
   CF=$(fnox get CLOUDFLARE_API_TOKEN)
   curl -s -H "Authorization: Bearer $CF" \
     "https://api.cloudflare.com/client/v4/accounts/<account_id>/tokens?per_page=50" |
     jq -r '.result[] | select(.name | startswith("home-ops-")) |
       "\(.name)  \(.status)  \(.expires_on)  zones: \([.policies[].resources | keys[]] | join(","))"'
   ```

   Expect `home-ops-external-dns` with one zone id and `home-ops-cert-manager`
   with two, both `active`, both expiring together. That proves the scope before
   anything depends on it; step 4 is what proves they work.

3. Flip one service at a time, starting with external-dns. In
   `infra/k8s/kyz/apps/network/external-dns/app/externalsecret.yaml`, the token
   comes from the item's `password` field and its own item:

   ```diff
   -        CF_API_TOKEN: "{{ .CLOUDFLARE_DNS_TOKEN }}"
   +        CF_API_TOKEN: "{{ .password }}"
      dataFrom:
        - extract:
   -        key: cloudflare
   +        key: cloudflare-external-dns
   ```

   and its header comment ("Same Cloudflare token cert-manager uses") is then
   wrong — they are separate tokens.

   Then in
   `infra/k8s/kyz/apps/cert-manager/cert-manager/app/externalsecret.yaml`:

   ```diff
   -        CLOUDFLARE_DNS_TOKEN: "{{ .CLOUDFLARE_DNS_TOKEN }}"
   +        CLOUDFLARE_DNS_TOKEN: "{{ .password }}"
      dataFrom:
        - extract:
   -        key: cloudflare
   +        key: cloudflare-cert-manager
   ```

4. Confirm each Secret synced and the consumer is happy — external-dns's logs for
   record changes, and `kubectl get certificate -A` for cert-manager.

5. Only then revoke the old user-scoped token in the dashboard. Keep it until
   step 4 passes; it is the fallback.

### Rotation

Both tokens expire **2027-11-09** (`local.dns_token_expiry`). The date is
deliberate — the token being replaced never expired, so nothing would ever have
prompted this.

- **Extend**: bump the date, `mise run tf:apply bootstrap`. The value is
  unchanged, so nothing downstream notices.
- **Replace**: `terraform -chdir=infra/terraform/bootstrap apply
-replace=cloudflare_account_token.external_dns`. `create_before_destroy` mints
  the new token first, so the 1Password item only ever moves to a working value;
  External Secrets picks it up on its refresh interval.

## Caution: the account token is the powerful one

The credential `bootstrap` and the `cloudflare` workspace run with
(`CLOUDFLARE_ACCOUNT_TOKEN`, item `cloudflare`, and the account-owned token named
`home-ops-terraform`) carries roughly 200 account-level **Write** permission
groups plus **Zone DNS Write** on every zone. It can mint tokens, rewrite any
zone, and change almost every product in the account.

That is why the leaf credentials it mints are narrow, and why it is the leak that
would matter most. Narrowing it is a real option — the two things it currently
must do are manage DNS records for four zones and mint these tokens.
