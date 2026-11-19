# Agent Tool Boundary

## Purpose

What an AI agent can reach through the cluster's MCP servers: read access to cluster,
Flux, router and home state, never secrets and never writes, enforced in more than one
layer and reached through a single gateway. Derived from the MCP server manifests,
their RBAC, and agentgateway's configuration; not a live test of each tool. Covers
`flux-mcp`, `kubectl-mcp`, `kubesearch-mcp`, `home-assistant-mcp`, `mikrotik-mcp`, and
agentgateway's MCP listeners. Hermes's own ServiceAccount is out of scope — see
`docs/hermes-agent.md`.

## Requirements

### Requirement: Run every MCP server read-only in the server itself

Each MCP server SHALL be configured in its own read-only mode, so write tools are not
offered to the caller at all.

#### Scenario: List tools on a cluster-facing server

- **WHEN** a caller lists tools on `flux-mcp` (`--read-only`) or `kubectl-mcp`
  (`MCP_SAFETY_MODE=read-only`)
- **THEN** no tool that creates, patches, or deletes a resource is offered

#### Scenario: Call a router or home server

- **WHEN** a caller uses `mikrotik-mcp` or `home-assistant-mcp`
- **THEN** the identity agentgateway presents is bound to the router role `readonly`,
  and Home Assistant runs with `READ_ONLY_MODE=true`

### Requirement: Back the read-only mode with read-only RBAC

An MCP server with a Kubernetes ServiceAccount SHALL hold only `get`, `list`, and
`watch` verbs, so that a bypass of the server's own mode lands on an API denial.

#### Scenario: A write reaches the API anyway

- **GIVEN** a bug or prompt bypasses the server's read-only mode
- **WHEN** the server sends a create, update, patch, or delete to the API server
- **THEN** the request is denied, because its ClusterRole grants no write verb

### Requirement: Grant no access to Secret objects

No MCP server ServiceAccount SHALL be granted any verb on `secrets`. Masking values in
output SHALL NOT be treated as the boundary.

#### Scenario: Ask for a Secret's contents

- **WHEN** a caller asks `kubectl-mcp` or `flux-mcp` to read a Secret
- **THEN** the API server refuses the read, because `secrets` is absent from the role
- **AND** the value never enters the server process, rather than being redacted after

### Requirement: Keep MCP servers inside the cluster

MCP servers SHALL be ClusterIP-only with no HTTPRoute. A caller outside the cluster
SHALL reach them only through agentgateway, which authenticates the caller and
authorizes each tool.

#### Scenario: Reach an MCP server from the internet

- **WHEN** a client outside the cluster wants a cluster MCP tool
- **THEN** no hostname routes to any MCP server directly
- **AND** the only path is agentgateway's authenticated `/mcp` (API key) or
  `/oauth/mcp` (Kanidm-issued JWT) on `llm.waltr.tech`, subject to its per-client tool
  rules

#### Scenario: Add a new MCP server

- **WHEN** a new MCP server is deployed
- **THEN** it has no HTTPRoute, and it becomes reachable to agents by being added as an
  agentgateway target
- **AND** a server with no working credential is left out of agentgateway's targets
  rather than added unauthenticated

### Requirement: Disable network reach the tool does not need

An MCP server SHALL disable features that fetch arbitrary external content on request
when its purpose does not require them.

#### Scenario: Search the kubesearch index

- **WHEN** `kubesearch-mcp` serves a query
- **THEN** it answers from the released index on its volume
- **AND** repository cloning on request is disabled (`KUBESEARCH_ENABLE_CLONE=false`)

## Baseline Evidence

Traceability pointers, not additional requirements:

- `infra/k8s/kyz/apps/default/{flux-mcp,kubectl-mcp}/app/rbac.yaml`: verbs limited to
  `get`/`list`/`watch`; header comments state `secrets` is absent on purpose.
- `infra/k8s/kyz/apps/default/*-mcp/app/`: no `httproute.yaml` and no `route:` block in
  any of the five (checked 2026-11-19).
- `infra/k8s/kyz/apps/default/mikrotik-mcp/app/helmrelease.yaml`: identity
  `agentgateway` with `role: readonly`.
- `infra/k8s/kyz/apps/default/agentgateway/app/helmrelease.yaml`: MCP targets
  (`flux-mcp`, `kubectl-mcp`, `home-assistant-mcp`, `mikrotik-mcp`), the per-client tool
  rules, and the comment explaining why `kubesearch` is absent.
- `docs/kubectl-mcp.md` → The boundary; `docs/flux-mcp.md`; `docs/agentgateway.md`.

## Verification Limits

This baseline does not assert that any server's read-only mode is free of bugs (that
is why RBAC backs it), that the RouterOS `readonly` group is correctly scoped on the
router, or what the Home Assistant long-lived token itself can do — the HA token
belongs to an HA user, and HA enforces its permissions, not this cluster. No tool was
called against the live cluster while writing it.
