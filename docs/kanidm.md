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

## Layout

- `infra/k8s/kyz/apps/identity/kaniop` — the operator
- `infra/k8s/kyz/apps/identity/kanidm` — the cluster, its certificate, and its
  HTTPRoute
