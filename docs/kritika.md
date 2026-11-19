# kritika (AI pull request reviews)

[kritika](https://kritika.home-operations.com/) reviews pull requests on
`git.waltr.tech`. It posts a summary and inline findings as the Forgejo user
`kritika`. It is defined in `infra/k8s/kyz/apps/kritika/` (the app) and
`infra/k8s/kyz/apps/cnpg-system/` (its Postgres operator).

|            |                                                                               |
| ---------- | ----------------------------------------------------------------------------- |
| Dashboard  | `https://kritika.waltr.tech` (envoy-internal), user `admin`                   |
| Webhook    | `https://kritika.waltr.tech/hooks/forgejo`, on the `rwaltr` user              |
| Forge user | `kritika` (Forgejo id 3), repo **admin** collaborator on each repo            |
| Model      | `claude-sonnet-5-5` (Claude subscription) via agentgateway; deepseek fallback |
| Embeddings | `voyage-code-4` (1024 dims) via agentgateway → OpenRouter                     |
| Database   | CNPG `kritika-postgres`, Postgres 18 + VectorChord, 1 instance                |
| Secrets    | 1Password item `kritika`; agentgateway holds the model keys                   |

## How Forgejo and kritika authenticate

No long-lived Forgejo token exists. kritika signs short-lived JWTs with an RSA
key (`kritika` / `forgejo_private_key`) and serves the public half at
`https://kritika.waltr.tech/forgejo/.well-known/keys`. The `kritika` user has two
**Authorized Integrations** (Forgejo 16+, the reason Forgejo runs 17 rather than
15 LTS) that trust tokens from that issuer:

- **write**: `read:user`, `write:repository`, `write:issue`. Its audience is
  `audience` in the HelmRelease.
- **read-only**: `read:repository`. Runner pods use it to fetch the repo, so
  the pod that reads untrusted PR content cannot write. Its audience is
  `runnerAudience`.

Audiences are not secret. Forgejo only shows them after an integration is
saved, and it fetches kritika's keys while saving. So a fresh install takes two
steps: deploy without audiences, then create the integrations and commit the
audiences.

```sh
P=$(kubectl -n default get pod -l app.kubernetes.io/name=forgejo -o name)
for spec in "kritika:read:user,write:repository,write:issue" "kritika-runner:read:repository"; do
  name=${spec%%:*} scopes=${spec#*:}
  kubectl -n default exec "$P" -c forgejo -- forgejo admin user create-authorized-integration \
    -u kritika --name "$name" --issuer https://kritika.waltr.tech/forgejo \
    --claim-eq sub=kritika $(printf -- '--scope %s ' ${scopes//,/ })
done # each prints its audience
```

The repo admin role is what kritika's docs require. Without it, kritika can't
read a commenter's permission, so it won't answer `@kritika` mentions, and it
can't dismiss its own stale approvals. It also lets the bot change repo
settings, so the write integration's scopes are the actual limit on what it can
do.

## Forgejo settings this needs

`kritika.waltr.tech` resolves to the envoy-internal VIP, which is a private
address. Forgejo refuses private addresses for both of these by default, so
the Forgejo HelmRelease names the host explicitly:

- `webhook.ALLOWED_HOST_LIST: external,kritika.waltr.tech`
- `authorized_integration.ALLOWED_DOMAINS: kritika.waltr.tech`

Never widen these to `*` or `private`. Any repo admin, including this bot, can
point a webhook at anything the list allows.

kritika's egress gateway also refuses private addresses, so
`egress.allow` lists the envoy-internal VIP (`10.10.100.11`,
`fdad:207a:f1ab:100::11`). Without it, every runner clone fails with
`resolves to a private address no allow entry covers`.

## Network policy

Plain NetworkPolicies (`networkPolicy.type: default`) confine runner pods to
DNS and kritika's gateway. The chart's `cilium` flavor would also filter DNS
names, but Cilium's L7 DNS proxy on mouse accepts the queries and never
answers. Every runner then timed out on `waiting for the gateway`, so that
flavor is off.
The serve pods may reach port 443 anywhere, but Cilium matches traffic **after**
the Service/VIP translation. The serve pods actually hit the envoy-internal
pods on 10443 and agentgateway's internal listener on 8082, so both appear in
`networkPolicy.extraEgress`. If reviews hang on connect, check the Cilium
drops with `hubble observe -n kritika --verdict DROPPED` before anything else.

## Signing in

Open `https://kritika.waltr.tech` from the LAN or tailnet and choose
**Kanidm**. Members of the Kanidm group `kritika_admins`
(`identity/resources/app/group-kritika-admins.yaml`) sign in as admins. Everyone
else is refused. To add someone, add them to that group.

How it fits together:

- `app/oauth2client.yaml` is the Kanidm client. kaniop mints
  `kritika-kanidm-oauth2-credentials`.
- The `kritika` namespace is listed in Kanidm's
  `oauth2ClientNamespaceSelector`.
- `auth.oidc.roleMappingExpr` maps the group to the admin role.

Kanidm was chosen over "Sign in with Forgejo" because Forgejo signs in through
Kanidm anyway, and this keeps roles on Kanidm groups.

Break-glass: the local `admin` user, with the password in 1Password item
`kritika`, field `password`:

```sh
op item get kritika --vault home-ops --fields password --reveal
```

## Models

Reviews use `claude-sonnet-5-5` on the Claude subscription, through
agentgateway's unauthenticated in-cluster listener (8082). If that fails, they
fall back to `deepseek-v4.1-flash` on OpenRouter. deepseek alone was not good
enough: it sometimes finished a review without submitting it. Prices in
`providers.agentgateway.pricing` are list prices. The subscription is not
billed per call, so the dashboard's spend shows how much of the plan reviews
use. kritika sends a placeholder key, which the gateway replaces with each
upstream's own.

## Day-2

- **Enable a repo**: open the dashboard, then Accounts → rwaltr →
  Repositories. Newly discovered repos start off.
- **Ask for a review**: comment `@kritika review` on a PR.
- **Rotate the signing key**:
  1. Add the new key as `previousKey`.
  2. Wait 10 minutes for Forgejo's key cache.
  3. Swap `privateKey` and `previousKey`.
  4. After another hour, drop `previousKey`.
     Replacing the 1Password field in one step breaks every call until Forgejo's
     cache turns over.
- **Database passwords** come from an External Secrets `Password` generator
  with `refreshInterval: "0"`. Deleting a `kritika-postgres-*` Secret mints a
  new password. CNPG applies it to the role, and Reloader does not watch those
  Secrets, so restart kritika afterwards.

## Known gaps

- **Database backups** go to RustFS through the Barman Cloud plugin: nightly
  base backup plus continuous WAL, 30 days (`s3://cnpg/kritika-postgres-pg18`).
  The cluster still bootstraps with `initdb`. Restoring is the manual swap in
  [docs/postgres.md](postgres.md#kritika).
- **No sandboxed runtime.** mouse has no gVisor or Kata. Runner pods are still
  non-root, read-only, capability-free and network-fenced.
- **Forgejo off LTS.** 17 is supported until 2027-01-28. Bump Forgejo every
  quarter until 19 LTS (2027-04).
