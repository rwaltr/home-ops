# Flatcar Container Linux replaces uCore

Status: accepted (2026-08-13)

The host `mouse` runs Flatcar, configured only through Butane/Ignition in
`infra/flatcar/`. Flatcar gives A/B updates, a smaller surface, and an official ZFS
systemd-sysext (dm-verity signed, version-locked to the release), which is what makes
an immutable OS viable on a ZFS storage node. The sysext is tagged experimental and is
not for root — acceptable, because ZFS here is a data pool only. uCore and its
quadlets were decommissioned the same day.

## Consequences

- Updates never reboot on their own: `REBOOT_STRATEGY=off` is written by a boot unit,
  because Ignition cannot overwrite `/etc/flatcar/update.conf`. Reboots to apply an
  update are manual while there is one node (ADR 0017).
- Host changes are proven in a VM first (`mise run flatcar:bootstrap`); Ignition fails
  silently to serial, so the VM is the only reliable test.

See `REFACTOR_PLANS.md` → Key decisions, Phase 0 / 0.5, and "Ignition limits found by
full-rebuild bisection".
