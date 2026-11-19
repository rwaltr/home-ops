# Service Exposure

## Purpose

How a cluster service becomes reachable, and from where: internal by default, public
only by attaching to one gateway, with DNS and TLS following from that attachment
rather than from separate edits. Derived from the gateway, external-dns, k8s-gateway,
cert-manager and cloudflared manifests; not a live reachability test. Why the shape
is this one: `docs/adr/0006-waltr-tech-ops-zone.md` and
`docs/adr/0016-cgnat-cloudflare-tunnel-only-inbound.md`.

## Requirements

### Requirement: Keep services internal unless attached to the external gateway

An HTTP route SHALL be internal-only unless it names `envoy-external` in
`parentRefs`. Attaching to `envoy-external` SHALL be the single act that publishes a
service.

#### Scenario: Add a route on the internal gateway only

- **WHEN** an app's route names only `envoy-internal`
- **THEN** in-house clients resolve its hostname through k8s-gateway to the internal VIP
- **AND** external-dns creates no public record for it

#### Scenario: Publish a service

- **WHEN** an app's route adds `envoy-external` to its `parentRefs`
- **THEN** external-dns publishes the hostname in the `waltr.tech` Cloudflare zone,
  targeting `external.waltr.tech`
- **AND** no Terraform, router, or tunnel change is needed

#### Scenario: Unpublish a service

- **WHEN** `envoy-external` is removed from the route
- **THEN** external-dns deletes the public record on its next sync (`policy: sync`)

### Requirement: Accept public traffic only through the Cloudflare tunnel

Public requests SHALL enter the cluster only through the `cloudflared` tunnel, whose
ingress forwards `*.waltr.tech` to `envoy-external` and refuses everything else.

#### Scenario: Reach a published hostname from the internet

- **WHEN** a client outside the house requests `<app>.waltr.tech`
- **THEN** Cloudflare's edge serves it through the tunnel to `envoy-external`
- **AND** the public record is a proxied CNAME chain ending at the tunnel, never the
  site's own address

#### Scenario: Request a hostname outside the wildcard

- **WHEN** the tunnel receives a request that does not match `*.waltr.tech`
- **THEN** it answers `404` (`http_status:404` catch-all) and nothing reaches a gateway

### Requirement: Use one label below the ops zone

Every published hostname SHALL be exactly one label below `waltr.tech`, so the free
Universal SSL edge certificate covers it.

#### Scenario: Pick a hostname for a new public app

- **WHEN** a new public hostname is chosen
- **THEN** it has the form `<app>.waltr.tech`
- **AND** a name like `<a>.<b>.waltr.tech` is rejected, because Cloudflare's edge has no
  certificate for it

### Requirement: Serve both gateways with the cluster's wildcard certificate

Both gateways SHALL terminate TLS with the cert-manager wildcard certificate for
`waltr.tech` and `*.waltr.tech`, issued through DNS-01.

#### Scenario: Add an HTTPS route

- **WHEN** a route attaches to either gateway
- **THEN** it is served with the `tls-wildcard` certificate without a per-app
  Certificate

### Requirement: Answer in-house names from the cluster

The router SHALL forward `waltr.tech` lookups to k8s-gateway, which answers from the
cluster's Gateways, HTTPRoutes and Services, so in-house clients reach internal VIPs
without hairpinning through Cloudflare.

#### Scenario: Resolve a dual-homed name at home

- **WHEN** an in-house client resolves a hostname that is on both gateways
- **THEN** it receives the internal VIP from k8s-gateway, not the Cloudflare record

## Baseline Evidence

Traceability pointers, not additional requirements:

- `infra/k8s/kyz/apps/network/external-dns/app/helmrelease.yaml`: sources
  `gateway-httproute` + `crd`, `--gateway-name=envoy-external`, `--cloudflare-proxied`,
  `policy: sync`, domain filter `waltr.tech`.
- `infra/k8s/kyz/apps/network/envoy-gateway/app/envoy.yaml`: the two Gateways, their
  VIPs, the `external.waltr.tech` target annotation, and `tls-wildcard`.
- `infra/k8s/kyz/apps/network/cloudflare-tunnel/app/{helmrelease,dnsendpoint}.yaml`:
  wildcard ingress, 404 catch-all, and the `external.waltr.tech` CNAME.
- `infra/k8s/kyz/apps/network/certificates/app/certificate.yaml`: wildcard names.
- `infra/k8s/kyz/apps/network/k8s-gateway/app/helmrelease.yaml`, `infra/routeros/README.md`
  → Split DNS.
- Routes parsed 2026-11-19: 12 apps attach to `envoy-external`, 30 are internal-only.
  Three are external-only by design: `tesla-key` (Tesla's verifier is the only
  consumer), `flux-instance` (`flux-receiver` webhook), `agentgateway` (`llm.waltr.tech`).

## Verification Limits

Nothing here was tested through the real edge. This baseline does not assert that each
public app is safe to be public — that is per-app authentication, documented in its
runbook. Tailscale reachability is a separate path and is not covered here
(`docs/tailscale.md`).
