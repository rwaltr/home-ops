# SQLite by default for single-user apps

Status: accepted (2026-10-08, FreshRSS; reapplied per app since)

When an app supports SQLite, it uses SQLite on its PVC rather than a database service:
FreshRSS, Paperless, Forgejo, HomeBox and Navidrome. One user and low write rates do not need a server, and every database
service is another workload to keep, back up and reconcile on a single node.

Postgres arrives only when an app requires it — kritika, through CloudNativePG.

## Consequences

- Backups are crash-consistent file copies (kopiur `Direct` mover) of a WAL-mode
  database; a write landing mid-copy is the accepted trade-off.
- Switching an app to Postgres later is an export/import per the app's own tooling
  (Paperless documents its path), not a cluster change.

Kanidm also runs on SQLite, but that is its only backend, not a choice made here.

See `docs/paperless.md` → Why SQLite and the
2026-10-08 FreshRSS entry in `REFACTOR_PLANS.md`.
