---
name: flatcar-vm
description: Build, boot, verify, and tear down Flatcar k0s test VMs in the home-ops repo using mise tasks, plus manual Butane compilation. Use when changing Flatcar/Ignition host config, k0s, Cilium, or the ZFS tank pool and you need VM validation.
---

# Flatcar VM workflow

All commands run from the repo root. Every task takes a host argument
(`test` = scratch config, `mouse` = mirrors the production host; default `mouse`).

## Locations

- Butane configs: `infra/flatcar/butane/base.bu` (shared: users, tailscale, mDNS,
  update-strategy), `butane/test.bu` (scratch), `butane/hosts/*.bu` (per-host, merge base.ign)
- Compiled to Ignition: `infra/flatcar/ignition/*.ign` (JSON, gitignored) via `mise run flatcar:build`
- ZFS: pool created by hand, **imported** by Ignition (`zpool import -a`) — never create in Butane
- k0sctl configs: `infra/k0s/<host>.yaml`

## Common tasks

```bash
# Full env from scratch: boot → seed tank → verify → k0s + Cilium + nginx
mise run flatcar:bootstrap mouse

# Build ignition, download image, boot VM (test: SSH on 127.0.0.1:2223, mouse: 2224)
mise run flatcar:vm test

# Verify sysext, ZFS pool, network + host-specific checks over SSH
mise run flatcar:verify test

# Install k0s + Cilium and smoke-test with nginx
mise run flatcar:k0s test

# mouse only: hand-create the tank pool (mirrors bare metal), then reboot
mise run flatcar:seed mouse

# SSH into a VM
mise run flatcar:vm-connect test

# Destroy VM and disks (prompts for confirmation)
mise run flatcar:clean test
```

## Notes

- Destructive tasks (`flatcar:clean`, `tf:apply`) prompt for confirmation before running.
- `[hostname]` args default to `mouse` (`FLATCAR_HOST` env var overrides).
- `tf:plan`/`tf:apply` take a workspace (`cloudflare|backblaze|tf-cloud`) and pass extra
  args through to terraform: `mise run tf:plan cloudflare -target=x`.
- Shared shell helpers live in `.mise/lib/common.sh` — includes `log`/`die` and
  `download_artifact <url> <sha256|sha512|https-checksum-url> <dest>`
  (checksum-verified atomic downloads; use it for all artifact downloads instead of
  relying on mise `outputs` caching).

## Manual Butane compilation (if needed)

```bash
butane --pretty --strict --files-dir . < infra/flatcar/butane/hosts/mouse.bu > infra/flatcar/ignition/mouse.ign
```

## Adding a new Flatcar host

1. Create `infra/flatcar/butane/hosts/<host>.bu` (merge `infra/flatcar/ignition/base.ign`).
2. Create `infra/k0s/<host>.yaml` (copy `mouse.yaml`).
3. Register ports/user in `vm_ports`/`vm_user` in `.mise/lib/common.sh`.
4. Test: `mise run flatcar:bootstrap <host>`.
