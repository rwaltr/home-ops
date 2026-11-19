# Cluster alerting

How alerts travel in this cluster: what raises them, and which receiver they land
on. Nothing is fed to the agent: Teletran is not woken by alerts, and its
alert-triage job is gone (2026-11-18, see `REFACTOR_PLANS.md`).

## Sources

Contract: `openspec/specs/alert-routing`. Policy: every alert must be actionable, or
removed (`docs/adr/0018-every-alert-actionable.md`).

1. **Prometheus rules → Alertmanager.** Everything in the
   `kube-prometheus-stack` rule set. This is the visible path: it exists as
   `ALERTS` series in Prometheus, so a window can be counted and attributed
   per alert name after the fact.
2. **Flux notification-controller → Alertmanager's v2 API.** The `Alert` CR in
   `flux-system` (any error-severity event) posts straight to the Alertmanager
   API and never appears in `ALERTS` at all. `exclusionList` is in
   `infra/k8s/kyz/apps/flux-system/flux-instance/app/notifications.yaml`.

A review built only from Prometheus therefore under-counts. The
`cluster-alert-review` skill carries the query set and the counting rules.

## Receivers and routing

The live routing table is generated from the `AlertmanagerConfig` CR in
`infra/k8s/kyz/apps/o11y/kube-prometheus-stack/app/alertmanagerconfig.yaml`.
**The loaded config is authoritative, not the manifest** — read it from
`GET /api/v2/status` → `config.original`.

- `pushover` — the human receiver. Everything that pages a phone goes here.
- `blackhole` — deliberately silent, still visible in the Alertmanager UI and in
  Prometheus. Used only for alerts that must keep firing but are never actionable
  alone: `InfoInhibitor` and `Watchdog`. A non-actionable alert is not blackholed;
  its rule is fixed or removed.

There is no agent receiver. Route order only decides which blackholes win
(Alertmanager evaluates siblings first-match-wins and falls back to the root
`pushover` when no child matched):

- the two blackhole routes come first;
- `pushover` for `severity=critical`, then the root `pushover` fallback for
  everything else — one notification per alert, critical or not.

## Verifying routing

1. `flux get ks -n o11y` — the app reconciled to the merge commit.
2. `GET /api/v2/status` → `config.original`: only `pushover` and `blackhole`
   remain as receivers, and no route names anything else.
3. `GET /api/v2/alerts/groups` — a firing group's `receiver` field names the
   receiver it actually dispatches to. This is the end-to-end check; the config
   can be right while an existing group still points at the old receiver.

## Paging budget

The standing target is **no more than three alerts a day reaching rwaltr**. A page
is a notification dispatched to the human-facing receiver, `pushover` today, and
the budget is measured against the pushover send counter
(`cluster-alert-review` → `references/paging-budget.md`).

## Failure modes

- **An alert fires and nothing pages.** Check `GET /api/v2/alerts/groups` for the
  receiver the group dispatches to, then the Alertmanager pod log: a failing
  notification is logged there and raises `AlertmanagerFailedToSendAlerts`.
- **Do not** quieten a noisy alert with a silence or a new blackhole route. If the
  page has no action, fix the rule's threshold or `for:` so it fires only when
  action is needed, or remove the rule (for chart rules, disable it in the
  chart's values).

## Silences

Silences are declared in git as `Silence` resources
(`observability.giantswarm.io/v1alpha2`, namespaced in `o11y`) under
`infra/k8s/kyz/apps/o11y/silences/`, reconciled onto Alertmanager by
`silence-operator` (`infra/k8s/kyz/apps/o11y/silence-operator/`). The CRs live in
their own Flux Kustomization that `dependsOn` the operator, because the CRD comes
from the operator's HelmRelease and cannot be in the same apply.

- **A silence is a notification decision, not a fix.** It suppresses delivery;
  the alert keeps firing and stays visible in the Alertmanager UI and Prometheus.
  The distinction from `blackhole` routing matters: blackhole is permanent and
  only for alerts something depends on, a silence is time-bounded and only for
  planned work.
- **Every silence is dated and disposable.** `spec.endsAt` is required in
  practice; a Silence CR with no end date is a permanent mute that nobody will
  remember to remove. Delete the CR once its window has passed rather than
  leaving expired objects in the tree.
- **The comment is the coordination channel.** The alert-triage agent reads
  `/api/v2/silences` when it triages, so a silence whose comment names the work
  ("bjw-s parity deployment series in progress") is how it learns that a firing
  alert is expected churn rather than a new incident. Keep that comment accurate.
- **Temporary silences can also be created over the Alertmanager API**
  (`POST /api/v2/silences`) when a CR cannot land yet — but that state lives
  outside git and must be expired by hand (`PUT /api/v2/silence/<id>` with an
  `endsAt` in the past).
