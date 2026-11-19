# Alert Routing

## Purpose

Where alerts go: which conditions page a human, which wake the agent, which are
deliberately silent, and how temporary quiet is declared. Derived from the
`AlertmanagerConfig`, the Flux `Alert`, and the `Silence` CRs; not a check of the
loaded Alertmanager config. Runbook and the agent feed's mechanics: `docs/alerting.md`.

Policy: **every alert must be actionable, or removed.** An alert that fires and
reaches anyone must have an action someone takes in response. An alert with no
action is a defect in the rule set, fixed by changing or deleting the rule — not
by tolerating the page. Decision record: `docs/adr/0018-every-alert-actionable.md`.

## Requirements

### Requirement: Feed Alertmanager from Prometheus and Flux

Alertmanager SHALL receive both Prometheus rule alerts and Flux error events, with
Flux posting directly to the Alertmanager v2 API.

#### Scenario: A HelmRelease fails to reconcile

- **WHEN** Flux emits an error-severity event for a Kustomization, HelmRelease,
  GitRepository, OCIRepository, or FluxInstance
- **THEN** the `alertmanager` Provider posts it to Alertmanager
- **AND** it does not appear in Prometheus `ALERTS`, so reviews built from Prometheus
  alone under-count

### Requirement: Make every delivered alert actionable

Every alert delivered to `pushover` SHALL have a response action: a
change to make, a runbook step, or a decision to record. An alert for which the
response is "do nothing" SHALL NOT remain deliverable.

#### Scenario: An alert pages and the response is to do nothing

- **WHEN** an alert reaches the phone and the correct response is to ignore it
- **THEN** the alert is treated as a defect in the rule set
- **AND** within the same review, its rule is fixed (threshold, `for:`, or labels) so it
  fires only when action is needed, or the rule is removed

#### Scenario: Triage an alert that fired

- **WHEN** a firing alert is triaged
- **THEN** the outcome is either an action taken, or a change that removes the
  alert's next non-actionable firing

### Requirement: Remove non-actionable alerts at the source

An alert that is never actionable SHALL be removed at its source: the rule deleted, or
disabled in the chart that ships it. Blackhole routing SHALL be reserved for alerts
that must keep firing for a technical reason and SHALL carry a comment stating that
reason. A silence SHALL NOT be used to hide a non-actionable alert.

#### Scenario: A chart ships a rule that is never actionable here

- **WHEN** a rule from `kube-prometheus-stack` (or another chart) has no action on this
  cluster
- **THEN** it is disabled through the chart's values, so it stops firing at all

#### Scenario: An alert must exist but must not notify

- **GIVEN** an alert that other machinery depends on, such as `Watchdog` (dead-man
  heartbeat) or `InfoInhibitor` (used by inhibition)
- **WHEN** it is routed
- **THEN** it goes to `blackhole` with a comment naming what depends on it

### Requirement: Route blackholed alerts before any other receiver

Alerts that must keep firing but are never actionable on their own SHALL be routed
to the `blackhole` receiver before the agent and human routes, so they reach neither.

#### Scenario: Watchdog fires

- **WHEN** `Watchdog` or `InfoInhibitor` fires
- **THEN** it is routed to `blackhole`
- **AND** it does not page the phone, but stays visible in the
  Alertmanager UI and Prometheus

### Requirement: Feed no agent from Alertmanager

Alertmanager SHALL have no agent receiver; `pushover` and `blackhole` SHALL be its only
receivers. Agents read alert state on demand, not from a push feed.

#### Scenario: Read the loaded receivers

- **WHEN** `GET /api/v2/status` → `config.original` is read
- **THEN** only `pushover` and `blackhole` appear as receivers

### Requirement: Page a human for every delivered alert

Every non-blackholed alert SHALL reach `pushover`, regardless of severity. Because
every delivered alert is actionable, severity orders the response; it does not decide
whether a human is told.

#### Scenario: A warning-severity alert fires

- **WHEN** a non-blackholed alert with `severity=warning` fires
- **THEN** no child route matches it, and it reaches `pushover` through the root
  receiver fallback

### Requirement: Suppress a warning when its critical twin fires

A `severity=warning` alert SHALL be inhibited while a `severity=critical` alert with
the same `alertname` and `namespace` is firing.

#### Scenario: Both severities fire

- **WHEN** an alert fires at both critical and warning for one namespace
- **THEN** only the critical one is delivered

### Requirement: Declare temporary quiet as dated Silence objects in git

A temporary mute during planned work SHALL be a `Silence` CR under
`infra/k8s/kyz/apps/o11y/silences/` with an `endsAt` and a comment naming the work.
A silence SHALL NOT be used for an alert that is not actionable; that alert is
removed instead.

#### Scenario: Quiet alerts during a deployment series

- **WHEN** expected churn would page during planned work
- **THEN** a Silence CR with `endsAt` and an explanatory comment is merged
- **AND** the agent reads that comment through `/api/v2/silences` to learn the alert is
  expected

## Baseline Evidence

Traceability pointers, not additional requirements:

- `infra/k8s/kyz/apps/o11y/kube-prometheus-stack/app/alertmanagerconfig.yaml`: route
  order, receivers, inhibit rules.
- `infra/k8s/kyz/apps/flux-system/flux-instance/app/notifications.yaml`: Provider and
  Alert.
- `infra/k8s/kyz/apps/o11y/silences/app/silences.yaml`: one live Silence
  (`bjw-s-parity-deploys`, ends 2026-11-23).
- `docs/alerting.md`.

## Verification Limits

The loaded Alertmanager config is authoritative, not the manifest; this baseline did
not read `/api/v2/status`. The Hermes alert feed was removed on 2026-11-18 (#1146);
the ~245 count below includes the period before that. The paging budget (three a day) is a measure of how well the policy holds, not a
requirement this repo enforces. On 2026-11-19 Prometheus counted ~245 pushover
notifications over 30 days (~8/day), so the current rule set does not yet meet the
policy. No per-rule actionability audit has been done. `InfoInhibitor` is
blackholed, but no loaded inhibit rule uses it, so whether it stays is an open item.
