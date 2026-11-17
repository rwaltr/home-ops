# Cluster alerting and the agent alert feed

How alerts travel in this cluster: what raises them, which receiver they land on,
and how Teletran is woken by the same feed that reaches rwaltr's phone.

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
`cluster-alert-review` skill carries the query set and the counting rules.

## Receivers and routing

The live routing table is generated from the `AlertmanagerConfig` CR in
`infra/k8s/kyz/apps/o11y/kube-prometheus-stack/app/alertmanagerconfig.yaml`.
**The loaded config is authoritative, not the manifest** — read it from
`GET /api/v2/status` → `config.original`.

- `pushover` — the human receiver. Everything that pages a phone goes here.
- `blackhole` — deliberately silent, still visible in the Alertmanager UI and in
  Prometheus. Used for `InfoInhibitor`, `Watchdog`, and Unmanic's by-design CPU
  alerts. Blackholing is a routing decision, never a silence or a deleted rule.
- `hermes` — the agent feed (below).

Route order matters, because Alertmanager evaluates siblings first-match-wins and
**falls back to the parent receiver only when no child matched**:

- the three blackhole routes come first, so blackholed alerts never reach the
  agent;
- `hermes` (no matchers, `continue: true`) then wakes Teletran for every
  non-blackholed alert and keeps matching;
- `pushover` for `severity=critical`, then an explicit `pushover` catch-all —
  the pair reproduces exactly the paging behaviour that predates the agent feed
  (one notification per alert, critical or not). The catch-all is required:
  without it the `hermes` child would match first and the root receiver's
  fallback would never run, silently removing warning-grade pages.

## The agent feed

Alertmanager cannot sign a Hermes webhook route — it sends no HMAC header, and a
Hermes route refuses an unauthenticated request on a non-loopback bind — so the
feed is not a webhook route. It is a **bearer-authenticated trigger into the
gateway API server**:

    POST http://hermes.default.svc.cluster.local:8642/api/jobs/aa9524f0f633/run
    Authorization: Bearer <API_SERVER_KEY>

- The token comes from `externalsecret-hermes-trigger.yaml` in the same app
  directory, which reads the **same 1Password field the Hermes pod itself
  authenticates against** (`hermes` / `api_server_key`). No new credential is
  minted and no owner step is involved.
- `sendResolved: false`: one wake-up per firing group; the resolved follow-up
  would only re-run the triage to report that something stopped.
- The Alertmanager webhook body is deliberately ignored. The endpoint's optional
  `prompt` field is the only thing it would read, and Alertmanager cannot
  template its webhook body — so the job re-derives the state from Prometheus and
  Alertmanager instead, which is the method `cluster-alert-review` already uses
  and which sees a cascade as one incident rather than one payload at a time.

### The job

`alert-feed-triage` is a Hermes cron job, not a manifest:

- fired on demand by the route above (the normal path), or by its own weekly
  schedule (Monday 09:00) as a fallback sweep;
- loads the `cluster-alert-review` skill, reports to the Discord DM;
- continuity is on, so a run can see what the previous run already reported;
- the Hermes scheduler claims each job at most once at a time, so a burst of
  alert groups collapses into one run instead of a queue of them.

**The job id in the URL is the coupling.** The job lives in the Hermes cron
store (`/opt/data/cron/jobs.json` on the data PVC), which is agent state rather
than git. Recreating the job mints a new id, and the Alertmanager URL then points
at nothing: the trigger gets a `404`, Alertmanager logs a failed notification, and
the feed goes quiet. Update the `url` line in `alertmanagerconfig.yaml` in the
same session the job is recreated. List it with `cronjob_manage action=list` or
`GET /api/jobs` (bearer-authenticated).

## Verifying the feed

1. `flux get ks -n o11y` — the app reconciled to the merge commit.
2. `GET /api/v2/status` → `config.original`: the `hermes` route and receiver
   present, with the bearer credentials resolved.
3. `GET /api/v2/alerts/groups` — a firing group's `receiver` field names the
   receiver it actually dispatches to. This is the end-to-end check; the config
   can be right while an existing group still points at the old receiver.
4. Alertmanager pod log — a trigger that landed shows the job POST; the failure
   modes below show up here first.
5. The job's own record: `/opt/data/cron/executions.db` and
   `/opt/data/cron/output/aa9524f0f633/`.

## Paging budget

The standing target is **no more than three alerts a day reaching rwaltr**. A page
is a notification dispatched to the human-facing receiver — `pushover` today, and
Teletran's own reports count the same way, because they land on the same phone.
This integration is therefore additive by design: Teletran is woken by the feed
and decides what is worth saying, but it does not replace or mute the pushover
path, and the budget is still measured against the pushover send counter
(`cluster-alert-review` → `references/paging-budget.md`).

## Failure modes

- **Feed silent, alerts still firing.** Job id mismatch (404), the Hermes pod
  mid-roll (`POST` refused), or the API server unreachable from `o11y`. In every
  case Alertmanager logs a failed notification and raises
  `AlertmanagerFailedToSendAlerts`; that alert itself routes to `hermes`, so it
  wakes the agent rather than hiding the gap.
- **A trigger during a run is refused, not queued.** That is the at-most-once
  claim doing natural coalescing on a cascade.
- **Do not** replace a blackhole with a silence or a deleted rule to quieten the
  agent feed. Only the notification is unwanted; the condition is real.

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
- **The comment is the coordination channel.** The alert-triage agent reads
  `/api/v2/silences` when it triages, so a silence whose comment names the work
  ("bjw-s parity deployment series in progress") is how it learns that a firing
  alert is expected churn rather than a new incident. Keep that comment accurate.
- **Match the label the alert actually carries, not the app it is about.** A
  silence on `pod=<app>-.*` covers only the alerts that name the app in `pod`
  (`KubePodNotReady`, `KubePodCrashLooping`, `TargetDown`). The
  kube-state-metrics-derived alerts about the same app do not: `pod` is
  `kube-state-metrics-<hash>` and the app appears as `deployment` (or `name` on a
  `HelmRelease`), with `namespace` being the exporter's (`o11y`) and the real one
  in `exported_namespace`. Those escape the silence and page. When a series
  silence is written, write the companion CRs for those shapes in the same
  commit — the parity series carries `bjw-s-parity-deploys` for `pod`,
  `bjw-s-parity-deployment-scoped` for `deployment` and
  `bjw-s-parity-helmreleases` for `name` + `customresource_kind`.
- **Temporary silences can also be created over the Alertmanager API**
  (`POST /api/v2/silences`) when a CR cannot land yet — but that state lives
  outside git and is retired with `DELETE /api/v2/silence/<id>`. The v2 API has
  no `PUT` for a silence: it answers `405` and leaves the silence active, so the
  documented "expire it by PUTting a past `endsAt`" is not a thing that works.
