# Host Provisioning

## Purpose

How the host `mouse` gets its configuration: entirely from Butane/Ignition, tested in
a VM, never mutating the storage pool. Derived from `infra/flatcar/`, the
`flatcar:*` tasks and the `flatcar-vm` skill; not a check of the running host. Why
Flatcar: `docs/adr/0001-flatcar-host-os.md`.

## Requirements

### Requirement: Configure the host only through Butane

Host configuration SHALL live in `infra/flatcar/butane/` — a shared `base.bu` merged
into per-host files — and SHALL reach the host only through Ignition.

#### Scenario: Change a host setting

- **WHEN** a host setting changes
- **THEN** the change is a Butane edit compiled by `mise run flatcar:build`
- **AND** a hand edit on the live host is a stopgap that must be mirrored into Butane in
  the same session, or the next reprovision loses it

### Requirement: Import the storage pool, never create it

Ignition SHALL import existing ZFS pools and SHALL NOT create or modify one. The
production host's Butane SHALL contain no `zpool create`.

#### Scenario: Reprovision mouse

- **WHEN** mouse is reinstalled from Ignition
- **THEN** `zfs-import-tank.service` runs `zpool import -a` and `zfs mount -a` after the
  sysext merge
- **AND** the existing `tank` pool and its data are untouched

#### Scenario: Test pool handling in a VM

- **WHEN** `mise run flatcar:seed mouse` runs
- **THEN** it creates the pool by hand outside Ignition, mirroring bare metal, so the next
  boot exercises the real import path

### Requirement: Never reboot for updates on its own

The host SHALL NOT reboot automatically to apply OS updates.

#### Scenario: A Flatcar update is downloaded

- **WHEN** update-engine stages a new release
- **THEN** `/etc/flatcar/update.conf` holds `REBOOT_STRATEGY=off`, written by
  `update-strategy-off.service`, and the host waits for a deliberate reboot

### Requirement: Apply OS updates by manual reboot while single-node

While the cluster has one node, a staged OS update SHALL be applied only by a reboot
that rwaltr starts by hand. No automated reboot controller (kured or similar) SHALL
be installed until there is more than one node (ADR 0017).

#### Scenario: An update is staged on the single node

- **WHEN** update-engine has staged a release on `mouse`
- **THEN** it stays staged until rwaltr reboots the host at a chosen time
- **AND** no in-cluster controller reboots it

#### Scenario: A second node joins

- **WHEN** the cluster gains a second node
- **THEN** the manual-reboot decision is revisited (ADR 0017), not carried over by
  default

### Requirement: Rebuild reproducibly from the repo alone

A host built from its Butane and k0sctl files alone SHALL reach the same state as the
running host.

#### Scenario: Rebuild a VM from scratch

- **WHEN** `mise run flatcar:bootstrap mouse` runs against a fresh VM
- **THEN** it boots from Ignition, seeds and imports the pool, passes
  `mise run flatcar:verify`, and runs k0s with Cilium and an nginx smoke test

### Requirement: Prove host changes in a VM before applying them

A change to Butane or k0sctl configuration SHALL pass a VM build and
`mise run flatcar:verify` before it is applied to mouse.

#### Scenario: Ignition rejects a change silently

- **GIVEN** a Butane change that `ignition-files` cannot apply
- **WHEN** it is tested in a VM
- **THEN** the VM fails visibly (reboot loop, `res=failed` on serial) instead of the
  production host

## Baseline Evidence

Traceability pointers, not additional requirements:

- `infra/flatcar/butane/{base.bu,hosts/mouse.bu}`: `update-strategy-off.service`,
  `zfs-import-tank.service`, hostid, sysext config; no `zpool create` (the one in
  `test.bu` is the scratch host).
- `.mise/tasks/flatcar/{bootstrap,seed,verify}`, `.pi/skills/flatcar-vm/SKILL.md`.
- `REFACTOR_PLANS.md` → Phase 0 / 0.5 and "Ignition limits found by full-rebuild
  bisection".

## Verification Limits

This baseline was not exercised in a VM while it was written, and says nothing about
whether the running host has drifted from Butane. At least two changes were applied
live and mirrored into Butane afterwards (the VLAN subinterface on 2026-09-10; zram
and the ARC cap on 2026-09-23); whether every such delta was mirrored is not
verified here. Nothing reports a staged-but-unapplied update, so how far the host lags
the Flatcar channel is not known from the repo.
