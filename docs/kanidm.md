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

The realm is **`waltr.tech`** — the apex, not `idm.waltr.tech`. Principal names are
built from it (`rwaltr@waltr.tech`), and the identity namespace for everything in
this house should not be named after one of the services that speaks it.

The realm is also the **WebAuthn RP ID**, and that is the load-bearing reason for
the apex rather than a tidiness preference: an RP ID of `waltr.tech` covers
`idm.waltr.tech`, so passkeys work from the subdomain and survive the UI moving.

`domain` is immutable after first initialisation and is baked into WebAuthn and
every principal name, so changing it means a fresh volume. `origin` is the URL the
server is reached at — the login page and the links the server mints — and it must
match the domain **or descend from it**:

> This must match or be a descendent of the domain name you configure above. If
> these two items are not consistent, the server WILL refuse to start.

So the realm is the apex and the server is at `idm.waltr.tech`. Those two are the
same constraint read in both directions, not two independent settings: `idm.waltr.tech`
descends from `waltr.tech`, which is why the split is allowed at all.

## Running it

Internal only: `https://idm.waltr.tech/ui/login` on `envoy-internal`, with a
Let's Encrypt certificate and a 5Gi PVC on `openebs-hostpath`. external-dns
publishes only routes attached to `envoy-external`, so nothing about this is
reachable from the internet until a second route is added on purpose.

The apex itself stays free — the login page is on the subdomain, so nothing about
this layout claims `waltr.tech` for the IdP.

The gateway-to-server hop has its own trap. Kaniop generates a `BackendTLSPolicy`
whose `validation.hostname` defaults to `spec.domain` — the **realm** — so with the
realm at the apex and the server at the subdomain it asks envoy to validate a
certificate issued for `idm.waltr.tech` against the name `waltr.tech`. The
handshake fails and the route answers **503** while reporting `Accepted=True`,
`ResolvedRefs=True` and a ready backend pod; only Kanidm's log admits it
(`Failed to create TLS stream ... AlertReceived(CertificateUnknown)`). The CR names
`validation.hostname` explicitly to keep the two in agreement.

The gateway-to-server hop has its own trap. Kaniop generates a `BackendTLSPolicy`
whose `validation.hostname` defaults to `spec.domain` — the **realm** — so with the
realm at the apex and the server at the subdomain it asks envoy to validate a
certificate issued for `idm.waltr.tech` against the name `waltr.tech`. The
handshake fails and the route answers **503** while reporting `Accepted=True`,
`ResolvedRefs=True` and a ready backend pod; only Kanidm's log admits it
(`Failed to create TLS stream ... AlertReceived(CertificateUnknown)`). The CR names
`validation.hostname` explicitly to keep the two in agreement.

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
upstream issue. Keep the pin and bump it deliberately, with the SDK version
checked against it.

Do not trust the operator's own compatibility field after a bump — it reported
the 1.12.1 image as `compatible / upgrade-check passed` while `kanidmd domain
upgrade-check` was failing to exec inside the pod. The check that exists to catch
exactly this mismatch degrades to a pass. Compare the image tag against kaniop's
`kanidm_client` version by hand.

A version mismatch is _not_ what produced the `403 AccessDenied` loop this cluster
spent an evening in — that was the group resource described under Accounts. Worth
keeping straight, because the symptom is identical and the fix is unrelated.

**Kanidm cannot be downgraded once its database has migrated**, so moving server
lines means starting from a fresh volume. The recipe has two steps that are easy
to get wrong:

1. **Delete the PVC explicitly.** Deleting the `Kanidm` resource does _not_ delete
   the volume: a StatefulSet's default PVC policy is `Retain`, so a fresh-looking
   cluster comes up on the old database and reproduces the exact failure you were
   trying to clear. Delete the pod first — `kubectl delete pvc` blocks until the
   volume is released, so a `pvc && pod` chain never reaches the second command —
   and let the StatefulSet build a new PVC from the template.
2. **Delete the `-admin-passwords` Secret.** The operator defines its `Initialized`
   condition as `AdminSecretExists` and only runs `recover-account` when that
   condition is false. A surviving Secret therefore means the operator keeps
   authenticating with the dead database's credentials and every reconcile fails
   with `AuthenticationFailed`. Deleting it is the trigger, not a cleanup detail.

Both are disposable — the Secret is regenerated and identity resources are
re-created from git.

Two settings are load-bearing rather than stylistic: `storage.volumeClaimTemplate`
(the operator's default is an **EmptyDir**, so omitting it puts the identity
database in a scratch directory) and `tlsSecretName` (the server terminates TLS
itself and will not start without a usable secret).

## Accounts

Identity resources live in `infra/k8s/kyz/apps/identity/resources` as kaniop
custom resources — persons, groups, and later OAuth2 clients. Each is reviewed and
merged like anything else; there is no separate identity database to edit by hand.

**Do not declare `members` on a built-in group.** A `KanidmGroup` is authoritative
over the member list it declares, and the built-in groups are load-bearing: the
operator's own account (`idm_admin`) is a member of `idm_admins`, and every
permission it needs — creating persons, creating groups, issuing OAuth2 clients —
hangs off `idm_admins` through `idm_people_admins`, `idm_group_admins` and friends.
Declaring `members: [rwaltr]` on `idm_admins` therefore does not _add_ a member, it
**replaces** the list, deletes `idm_admin`, and strips the operator of every right it
has. The operator then fails its own reconciles with `403 AccessDenied` and
`allowed: {}` — having locked itself out with its own write.

If a built-in group must be managed, list the built-in members explicitly
(`members: [idm_admin, rwaltr]`) and treat that list as load-bearing. The safer
answer is not to manage built-ins at all: administration belongs to the `idm_admin`
account, and Kanidm's own guidance is to keep a separate administration account
rather than granting administration to a daily-use person.

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

Administration is the `idm_admin` account, whose password the operator generates
into the `kanidm-admin-passwords` Secret. The `admin` account is recovery only and
should not be anyone's daily login. Neither belongs to a person resource — see the
warning above about built-in groups.

## OAuth2 clients

Each application that logs users in through Kanidm gets a `KanidmOAuth2Client`
resource, and it lives in the _application's_ namespace so that the credentials the
operator mints land next to the app consuming them (`CLIENT_ID` and
`CLIENT_SECRET`).

That only works because the `Kanidm` resource names the namespaces to watch:

- unset — only the Kanidm resource's own namespace;
- `{}` — every namespace in the cluster;
- a label selector — matching namespaces.

We list namespaces explicitly. An empty selector would let any namespace in the
cluster mint an identity provider client, and the list costs one line per namespace
when a new one is needed.

A client in an unwatched namespace does not fail loudly. It sits with no status, no
log line, and no error — the only clue is an event on the object itself:

```
Warning  ResourceNotWatched  configure `oauth2ClientNamespaceSelector` on Kanidm resource to watch this namespace
```

Scopes are granted per group: a client cannot request a scope that no group holds,
so each `scopeMap` names a group — usually `idm_all_persons`, which is dynamic and
therefore needs no membership list — and the scopes it may ask for. `groups` is
only released when that scope is granted, so anything that maps roles from group
membership has to ask for it.

`redirectUrl` is an **array** in the CRD despite the singular name, and redirect
URLs are matched exactly, so it has to be the URL the application actually calls
back on.

## Not done yet

The OAuth2 client and the gateway's `jwtAuth` policy, which is what Grok needs.
That is also when `llm.waltr.tech` gets republished, since the flow needs both
the authorization server and the MCP endpoint reachable from outside.

Publishing the IdP is a route move and nothing else: `idm.waltr.tech` is already
covered by the tunnel's `*.waltr.tech` rule, so no tunnel change is needed. (This
was two changes while the login page sat on the apex, because a wildcard does not
match the apex — moving it to the subdomain removed that whole class of problem.)

## Layout

- `infra/k8s/kyz/apps/identity/kaniop` — the operator
- `infra/k8s/kyz/apps/identity/kanidm` — the cluster, its certificate, and the
  HTTPRoute the CR generates
