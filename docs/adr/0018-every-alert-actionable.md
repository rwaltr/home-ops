# Every alert must be actionable, or removed

Status: accepted (2026-11-19)

An alert that reaches rwaltr's phone must have an action someone takes in response. If the right response is to do nothing, the alert is a defect: its rule
is fixed (threshold, `for:`, labels) so it fires only when action is needed, or the
rule is removed — chart rules are disabled in the chart's values. Blackhole routing is
reserved for alerts that must keep firing because something depends on them, each
with a comment naming that dependency. Silences are only for planned work. This
replaces the earlier rule that blackholing is a routing decision and a rule is never
deleted: blackholing a noisy alert kept the noise in the system without anyone
acting on it.

## Consequences

- On 2026-11-19 Prometheus counted ~245 pushover notifications over 30 days (~8 a
  day) against the three-a-day budget (part of that window predates the Hermes feed's
  removal, which did not change pushover's sends). Meeting the policy means auditing the
  rules that fired, starting with the warning-severity `Kaniop*`, `Kube*` and
  `Node*` rules.
- The Unmanic CPU blackhole was removed. It had been dead since the CPU limit was
  dropped (#895).
- `InfoInhibitor` stays blackholed for now, but no loaded inhibit rule uses it. The
  inhibit rule needs wiring, or the alert should be disabled.
- Severity still does not decide whether a page goes out. Every delivered alert
  pages; severity only orders the response.
