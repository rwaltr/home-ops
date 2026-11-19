# OS-update reboots are manual while there is one node

Status: accepted (2026-11-19)

Flatcar stages updates but never reboots on its own (`REBOOT_STRATEGY=off`). Applying a
staged update is a reboot rwaltr starts by hand, at a time he chooses. kured was
considered and rejected for now: with a single node, a kured reboot is a full outage
of every workload, with nowhere to drain to. That trade only changes when a second
node exists. Revisit kured (or Flatcar's own lock-coordinated strategies) then.

## Consequences

- Staged updates can sit unapplied indefinitely. Nothing pages on a pending
  reboot today. The update is applied only when someone remembers or has another
  reason to reboot.
- A reboot is a planned outage: silence the alerts it will cause for the window
  (`Silence` CR, see `docs/alerting.md`), then reboot.
