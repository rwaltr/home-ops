# Kanidm

Identity provider for the cluster, deployed with **kaniop**, the third-party
Kubernetes operator for Kanidm. Not yet serving anything — this records the
decisions so far and what it is for.

## Why it exists

Grok's consumer MCP connector will not accept a static header from a server that
answers `401`. It probes the URL, sees the challenge, and demands an OAuth client:
authorization endpoint, token endpoint, PKCE. agentgateway authenticates with
`apiKey`, which no header configuration satisfies. Something has to issue tokens,
and the same requirement applies to any other client that only speaks OAuth.

That is why `llm.waltr.tech` is unpublished. The gateway is fine; the door has
nothing that can authenticate an OAuth-only client.

## Why kaniop, and why not PostgreSQL

Kaniop runs Kanidm with its own default store (SQLite) on the StatefulSet's
persistent volume. Searched the whole kaniop repository for Postgres support:
zero hits. There is no database to configure, so the parked
"kaniop versus the Postgres operator" question answers itself:

- **kaniop ⇒ SQLite.** One operator, one PVC, and `KanidmOAuth2Client` /
  `KanidmPersonAccount` as custom resources.
- **PostgreSQL would mean running Kanidm by hand** outside the operator, which
  gives up exactly those CRDs — the part that lets identity changes be submitted
  as pull requests. That fails the bar we hold everything else to.
- CloudNativePG therefore stays a separate decision, for workloads that need
  Postgres for their own reasons. It should not be coupled to the IdP.

## Who maintains it

`pando85/kaniop` — Alexander Gil Casas, an individual, not the Kanidm project and
not a company. AGPL-3.0, first commit September 2024, 140 stars. Very actively
maintained: v0.23.0 was released the day this was written. Of 14 contributors,
the top three are bots (`renovate`, `forkline-bot`) and the operator author; the
human contributors outside the author have between one and four commits each. It
is effectively a single-maintainer project, and Kanidm upstream does not mention
it anywhere.

The alternative — Kanidm's own container image in a hand-written StatefulSet,
with OAuth2 clients created through the `kanidm` CLI — trades that dependency for
manual identity management. Kaniop is the option that keeps identity declarative.

## Domain

`idm.waltr.tech`. Kanidm's `domain` is immutable after creation and is baked into
WebAuthn and every principal name (`rwaltr@idm.waltr.tech`), and `origin` must
match or descend from it or the server refuses to start. Choose it once.

## Running it

Internal only: `https://idm.waltr.tech/ui/login` on `envoy-internal`, with a
Let's Encrypt certificate and a 5Gi PVC on `openebs-hostpath`. external-dns
publishes only routes attached to `envoy-external`, so nothing about this is
reachable from the internet until a second route is added on purpose.

The operator recovers the built-in `admin` and `idm_admin` accounts on first
initialisation and writes the generated passwords to the `kanidm-admin-passwords`
Secret in the `identity` namespace. They are Secrets, so the agent cannot read
them — which is the point:

```sh
kubectl -n identity get secret kanidm-admin-passwords \
  -o go-template='{{range $k,$v := .data}}{{$k}} = {{$v | base64decode}}{{"\n"}}{{end}}'
```

`idm_admin` administers the directory; `admin` is the recovery account. Log in at
the UI, then change the passwords there.

The server image is **pinned** (`kanidm/server:1.11.2`) because the operator's
default is `:latest`, and `latest` is one minor version ahead of what kaniop
0.23.0 can drive. Kaniop's client SDK is 1.11.2; Kanidm 1.12 support is an open
upstream issue. The mismatch is quiet and ugly rather than loud: the operator
could *create* an entry but not *read it back*, so it decided every object was
missing and retried the create, which the server then refused with 403.

Do not trust the operator's own compatibility field after a bump — it reported
the 1.12.1 image as `compatible / upgrade-check passed` while `kanidmd domain
upgrade-check` was failing to exec inside the pod. The check that exists to catch
exactly this mismatch degrades to a pass. Compare the image tag against kaniop's
`kanidm_client` version by hand.

**Kanidm cannot be downgraded once its database has migrated.** Moving to a newer
server line therefore means starting from a fresh volume: delete the PVC and the
`-admin-passwords` Secret, then let the operator re-initialise. Both are
disposable — the Secret is regenerated and identity resources are re-created from
git.

Two settings are load-bearing rather than stylistic: `storage.volumeClaimTemplate`
(the operator's default is an **EmptyDir**, so omitting it puts the identity
database in a scratch directory) and `tlsSecretName` (the server terminates TLS
itself and will not start without a usable secret).

## Accounts

Identity resources live in `infra/k8s/kyz/apps/identity/resources` as kaniop
custom resources — persons, groups, and later OAuth2 clients. Each is reviewed and
merged like anything else; there is no separate identity database to edit by hand.

A new person account gets its one-time credential link through a Kubernetes Event,
which is the operator's default delivery. Email would require `spec.mailSender` on
the Kanidm cluster, which is not configured, and is not worth standing up a mail
path just to read one link:

```sh
kubectl -n identity get events --field-selector involvedObject.name=rwaltr
```

The link is valid for `credentialsTokenTtl` (a day here). If it lapses before it is
used, bump the resend annotation on the person resource rather than deleting and
recreating it — the account keeps its identifier.

`idm-admins` is a `KanidmGroup` naming Kanidm's built-in `idm_admins` group with
`rwaltr` as a member, which is what grants identity administration in the UI. The
`admin` account is recovery only, and should not be the account anyone logs in as
day to day.

## Not done yet

The OAuth2 client and the gateway's `jwtAuth` policy, which is what Grok needs.
That is also when `llm.waltr.tech` gets republished, since the flow needs both
the authorization server and the MCP endpoint reachable from outside.

## Layout

- `infra/k8s/kyz/apps/identity/kaniop` — the operator
- `infra/k8s/kyz/apps/identity/kanidm` — the cluster, its certificate, and the
  HTTPRoute the CR generates
