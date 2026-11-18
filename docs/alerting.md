# Cluster alerting

How alerts travel in this cluster: what raises them, which receiver they land on,
and what happens to a page.

**The agent alert feed (Alertmanager → Teletran) was removed on 2026-11-17** at
rwaltr's request. Routing is notifications-only again; the removal record and the
restore recipe are at the bottom of this file.

## Sources

1. **Prometheus rules → Alertmanager.** Everything in the
   `kube-prometheus-stack` rule set. This is the visible path: it exists as
   `ALERTS` series in Prometheus, so a window can be counted and attributed
   per alert name after the fact.
2. **Flux notification-controller → Alertmanager's v2 API.** The `Alert` CR in
   `flux-system` (any error-severity event) posts straight to the Alertmanager
   API and never appears in `ALERTS` at all. `exclusionList` is in
   `infra/k8s/kyz/apps/flux-system/flux-instance/app/notifications.yaml`.

A review built only from Prometheus therefore under-counts. The
`cluster-alert-review` skill carries the query set and the counting rules; it is
still the method to use for an on-request review, it just no longer runs itself
off the feed.

## Receivers and routing

The live routing table is generated from the `AlertmanagerConfig` CR in
`infra/k8s/kyz/apps/o11y/kube-prometheus-stack/app/alertmanagerconfig.yaml`.
**The loaded config is authoritative, not the manifest** — read it from
`GET /api/v2/status` → `config.original`.

- `pushover` — the human receiver. Everything that pages a phone goes here.
- `blackhole` — deliberately silent, still visible in the Alertmanager UI and in
  Prometheus. Used for `InfoInhibitor`, `Watchdog`, and Unmanic's by-design CPU
  alerts. Blackholing is a routing decision, never a silence or a deleted rule.

Route order matters, because Alertmanager evaluates siblings first-match-wins and
**falls back to the parent receiver only when no child matched**:

- the three blackhole routes come first, so blackholed alerts never dispatch at
  all;
- `pushover` for `severity=critical`;
- an explicit `pushover` catch-all after it — one notification per alert,
  critical or not. The root receiver is also `pushover`, so this child is
  redundant in effect and kept only so the paging path does not depend on the
  root-fallback rule.

## The job

`alert-feed-triage` is a Hermes cron job (id `aa9524f0f633`), not a manifest. It
lives in the Hermes cron store (`/opt/data/cron/jobs.json` on the data PVC),
which is agent state rather than git, and it is **paused**. Its record is kept
rather than deleted so a restore does not have to recreate it — a recreated job
mints a new id, and any URL pointing at the old one gets a `404`. List it with
`cronjob_manage action=list` or `GET /api/jobs` (bearer-authenticated).

Pausing the job alone was not sufficient to stop the triage: the trigger endpoint
(`POST /api/jobs/<id>/run`) un-pauses the job it fires — it writes `enabled:
true, state: scheduled, paused_at: null` — so a single firing alert would have
re-armed it. The route removal below is what makes the disable durable.

## Paging budget

The standing target is **no more than three alerts a day reaching rwaltr**. A page
is a notification dispatched to the human-facing receiver — `pushover` today —
and anything the agent sends unprompted lands on the same phone and counts the
same way. With the feed removed nothing wakes the agent on its own, so the budget
is now exactly the pushover send counter
(`cluster-alert-review` → `references/paging-budget.md`).

## Failure modes

- **A page that never arrives.** Read the Alertmanager log for the failing
  integration and its transport error before touching the receiver config;
  `AlertmanagerFailedToSendAlerts` / `AlertmanagerClusterFailedToSendAlerts` are
  transport failures, not receiver-config failures.
- **Do not** replace a blackhole with a silence or a deleted rule to quieten
  something. Only the notification is unwanted; the condition is real. The
  blackhole already covers that case, permanently and visibly.

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
  declares a condition by-design, a silence is time-bounded.
- **Every silence is dated and disposable.** `spec.endsAt` is required in
  practice; a Silence CR with no end date is a permanent mute that nobody will
  remember to remove. Delete the CR once its window has passed rather than
  leaving expired objects in the tree.
- **The comment is the coordination channel.** A review reads
  `/api/v2/silences`, so a silence whose comment names the work
  ("bjw-s parity deployment series in progress") is how it learns that a firing
  alert is expected churn rather than a new incident. Keep that comment accurate.
- **Temporary silences can also be created over the Alertmanager API**
  (`POST /api/v2/silences`) when a CR cannot land yet — but that state lives
  outside git and must be expired by hand (`DELETE /api/v2/silence/<id>`; the v2
  API has no `PUT` for a silence).

## Removal record: the agent alert feed (2026-11-17)

The feed woke a Hermes cron job for every non-blackholed alert; the job re-derived
state from Prometheus and Alertmanager and reported to the phone. It was not a
webhook route — Alertmanager sends no HMAC header and cannot template one, so a
Hermes route (which refuses an unauthenticated request on a non-loopback bind)
could not be the receiver. It was a bearer-authenticated `POST` to the gateway API
server's `POST /api/jobs/<id>/run`, credentialed from the 1Password field
`hermes` / `api_server_key`.

Removed in git:

- the `hermes` route child (no matchers, `continue: true`) and the `hermes`
  receiver in
  `infra/k8s/kyz/apps/o11y/kube-prometheus-stack/app/alertmanagerconfig.yaml`;
- `externalsecret-hermes-trigger.yaml` and its line in the app
  `kustomization.yaml`.

Because Alertmanager's siblings are first-match-wins and a route's own receiver
is used only when **no child matched**, the bare catch-all `hermes` child was the
reason the explicit `pushover` catch-all existed: a child matching everything
would otherwise have silently stopped warning-grade alerts from paging. That
catch-all is kept.

Two steps git cannot do:

- The External Secrets operator's default `deletionPolicy` is `Retain`, so the
  `hermes-alert-trigger` Secret in `o11y` outlives its ExternalSecret. It holds
  the gateway API key and should be deleted by hand:
  `kubectl -n o11y delete secret hermes-alert-trigger`.
- The Hermes cron job `alert-feed-triage` (`aa9524f0f633`) is paused, not deleted
  (`cronjob_manage action=pause`).

To restore: revert the removal commit, then `cronjob_manage action=resume` the
job. The restored route's `url` must carry the job's id — `aa9524f0f633` while
the existing record is kept.
