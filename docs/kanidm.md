# Kanidm

Identity provider for the cluster, deployed with **kaniop**, the third-party
Kubernetes operator for Kanidm. It serves `idm.waltr.tech` on both gateways and
is the OIDC/OAuth2 issuer for Forgejo, FreshRSS, HomeBox, Homepage, Paperless,
kritika, renovate-operator, Grafana, and agentgateway's `/oauth/mcp` door — each
holds a `KanidmOAuth2Client` in its own `app/oauth2client.yaml`.

## Why it exists

Grok's consumer MCP connector will not accept a static header from a server that
answers `401`. It probes the URL, sees the challenge, and demands an OAuth client:
authorization endpoint, token endpoint, PKCE. agentgateway authenticates with
`apiKey`, which no header configuration satisfies. Something has to issue tokens,
and the same requirement applies to any other client that only speaks OAuth.

That was why `llm.waltr.tech` was unpublished until Kanidm existed: the gateway
was fine, but the door had nothing that could authenticate an OAuth-only client.
It is published again with a JWT-verified `/oauth/mcp` path — see
`docs/agentgateway.md`. Once the issuer was there, the other apps' logins moved
onto it too.

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

## Exposure: internal and public

`idm.waltr.tech` is served on **both** gateways, and the two parentRefs sit on the
one HTTPRoute kaniop generates:

- `envoy-internal` — the house. This is the split-horizon answer the cluster's DNS
  gives every dual-homed hostname: `idm.waltr.tech` resolves to the internal VIP
  inside, and to the Cloudflare tunnel outside.
- `envoy-external` — the internet, via the Cloudflare tunnel. **This parentRef is
  also what publishes the DNS record**, because external-dns runs with
  `--gateway-name=envoy-external` and ignores every other gateway. Removing it
  unpublishes the hostname.

**Public is not a choice, and there is no partial version of it.** An OAuth2
authorization server has to be reachable by the client's _browser_ — the
authorization endpoint and the login page that follows it — and by the client's
_servers_ — the token endpoint, the discovery document, the signing keys. A
non-cluster client therefore needs the whole surface, and the only thing a
path-based split would protect is the admin UI, at the cost of a rule that breaks
the next time the UI moves a route.

The certificate was already the public answer: `certificate.yaml` gets
`idm.waltr.tech` from `letsencrypt-production` over DNS-01, so nothing about TLS
changed when the route became public. `backendTlsPolicy` names the origin host
explicitly for both listeners — see the trap above.

### The limit in front of the credential endpoint

`ratelimit.yaml` is a `BackendTrafficPolicy` on the generated route:

- `/v1/auth` — **Exact**, 20 requests/minute. This is where the password is
  actually POSTed. It is not `/ui/login`: that path serves the page, and the login
  UI is a wasm app that would have been throttled while the credential endpoint sat
  untouched. The match is Exact rather than a prefix so `/v1/auth/valid` — the
  session check the UI and the operator both poll — is unaffected.
- everything else — 600 requests/minute, a flood guard rather than a login shaper.
  Envoy applies the strictest matching rule, so it cannot loosen the one above.

The limit is here rather than in Kanidm because Kanidm documents no rate-limit or
lockout setting at all: its `server.toml` option list is `bindaddress`, `db_path`,
`domain`, `origin`, `path`, `schedule`, `sidebar`, `tls_chain`, `tls_key`,
`version`. The counters are per Route, and they are **not** per client — a burst
from one source consumes the budget for everyone, which is the intent for credential
stuffing and the reason the number is generous for a human. Raise it here if it ever
gets in the way; nothing else depends on the value.

What the limit does not do: it does not stop an attacker from reaching the login
page, the discovery document or the admin UI. What protects the accounts is the
credential itself — a generated password for `idm_admin`, and a passkey or password
for `rwaltr` — plus this limit on attempts. Anyone administering Kanidm should
understand that the admin surface is internet-reachable by design.

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

**Give the account a mail address.** Kanidm only emits the `email` claim when the
account has a primary mail attribute set, and clients key their users on it. HomeBox
refuses the login outright (`no email found in token claims`), and both
django-allauth (Paperless) and Grafana use the address to match or create the local
account. `personAttributes.mail` is a list and the first entry is the primary:

```yaml
personAttributes:
  displayname: rwaltr
  mail:
    - rwaltr@waltr.tech
```

The address does not have to be deliverable — nothing sends mail to it — but the
claim is only populated when it exists.

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

**Kaniop enforces PKCE by default**, and Kanidm refuses an authorization request
without a code challenge:

```
ERROR  No PKCE code challenge was provided with client in enforced PKCE mode
       o2rs.name: "<client>"
ERROR  Unable to authorise - error: invalid_request
```

The client-side symptom is generic (`invalid_request`, or an `invalidstate`-flavoured
error page served by the identity provider itself) and everything at the app looks
correct, so this is worth checking in Kanidm's log first. Turn PKCE on in the
application (`use_pkce` for Grafana) rather than relaxing the client — the
enforcement is the safer default, and every client we have supports PKCE.

**A public client cannot disable the consent prompt.** Kanidm requires both PKCE and
the consent prompt on public clients, so `disableConsentPrompt: true` alongside
`public: true` is a contradiction the operator cannot resolve: it retries
`PATCH /v1/oauth2/<client>` and gets

```
ERROR  requested_pres is not a subset of allowed
       requested_pres: {OAuth2ConsentPromptEnable}
```

forever, with the client otherwise fully reconciled and working. Public clients are
only for applications that cannot keep a secret — such as one whose configuration is
a single JSON blob that cannot be assembled from two Secret keys (Paperless). The
consent screen is the cost.

## Not done yet

Grok's OAuth2 client (`apps/default/agentgateway/app/oauth2client.yaml`) and the
gateway's `jwtAuth` policy are deployed, but the client's `origin` and
`redirectUrl` are still `.invalid` placeholders: xAI does not publish its
callback. Until they are replaced, every authorization attempt is refused —
deliberately. See the comment at the top of that file for where the real values
come from.

Publishing the IdP was a route move and nothing else: `idm.waltr.tech` is already
covered by the tunnel's `*.waltr.tech` rule, so no tunnel change is needed. (This
was two changes while the login page sat on the apex, because a wildcard does not
match the apex — moving it to the subdomain removed that whole class of problem.)

## Layout

- `infra/k8s/kyz/apps/identity/kaniop` — the operator
- `infra/k8s/kyz/apps/identity/kanidm` — the cluster, its certificate, and the
  HTTPRoute the CR generates
