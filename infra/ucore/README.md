# uCore Migration Project

## Quick Start

```bash
# Auto-install uCore VM for 'mouse' host (default)
mise run ucore:vm

# Auto-install for a different host
mise run ucore:vm laptop

# Connect to running VM
mise run ucore:vm-connect mouse
```

## What This Is

Infrastructure-as-code for managing multiple uCore hosts. Currently migrating "mouse" from NixOS to Universal Blue uCore.

**Why uCore?**
- Immutable OS with atomic updates
- Container-first workflow with Podman Quadlet
- ZFS pre-installed (no layering needed)
- Fedora CoreOS base + homebrew tools
- Better suited for long-running homelab services

## Directory Structure

```
infra/ucore/
├── butane/
│   ├── base.bu              # Shared base config (all hosts)
│   ├── storage.bu           # Shared storage config (ZFS hosts)
│   └── hosts/
│       ├── template.bu      # Template for new hosts
│       └── mouse.bu         # Host-specific config (references containers)
├── containers/              # Podman Quadlet definitions
│   ├── minio.container      # Referenced by mouse.bu
│   ├── navidrome.container  # Referenced by mouse.bu
│   ├── syncthing.container  # Referenced by mouse.bu
│   └── netdata.container    # Referenced by mouse.bu
└── ignition/                # Generated Ignition files (gitignored)
```

**Container Integration:**
- Container `.container` files are Podman Quadlet definitions
- Host Butane configs reference them via `contents.local`
- Butane embeds container files into Ignition config
- Ignition deploys to `/etc/containers/systemd/*.container`
- Systemd auto-discovers and manages as services

**Task Management:**
- All build/VM tasks are mise file-based tasks in `.mise/tasks/ucore/`
- Discovered automatically by mise from the project root
```

## Multi-Host Management

### Adding a New Host

1. Create host-specific config:
   ```bash
   cp infra/ucore/butane/hosts/mouse.bu infra/ucore/butane/hosts/newhost.bu
   ```

2. Edit `newhost.bu`:
   - Update hostname
   - Update hostid (for ZFS)
   - Customize services

3. Build and test:
   ```bash
   mise run ucore:vm newhost
   ```

### Host Config Files

- **`butane/base.bu`** - Shared across all hosts (users, SSH, firewall, packages)
- **`butane/storage.bu`** - Shared ZFS configuration
- **`butane/hosts/<hostname>.bu`** - Host-specific (hostname, hostid, uCore rebase service)

## Services Migration Map

| NixOS Service | uCore Implementation |
|--------------|---------------------|
| ZFS | Pre-installed, systemd mount units |
| NFS Server | nfs-utils via rpm-ostree |
| MinIO | Podman container (Quadlet) |
| Navidrome | Podman container (Quadlet) |
| Syncthing | Podman container (Quadlet) |
| Netdata | Podman container (Quadlet) |
| Tailscale | Podman container (Quadlet) |

## Key Changes

### Storage Paths
- **Old:** `/tank/*`
- **New:** `/var/tank/*`
- **Reason:** uCore has immutable root filesystem

All service paths updated:
- `/tank/services/minio` → `/var/tank/services/minio`
- `/tank/nas/library/music` → `/var/tank/nas/library/music`

### Configuration Management
- **Old:** NixOS declarative rebuild
- **New:** Butane → Ignition (provisioning) + rpm-ostree (packages)

### Service Management
- **Old:** systemd units via Nix modules
- **New:** Podman Quadlet + systemd

## Installation Process

The VM automatically:
1. **Downloads Fedora CoreOS ISO** (~1GB, shared across hosts)
2. **Creates custom auto-install ISO** with host-specific Ignition config
3. **Boots VM** and installs Fedora CoreOS to disk (1-2 min)
4. **Reboots** and applies Ignition configuration
5. **Rebases to uCore** from Fedora CoreOS (5-10 min)
6. **Reboots into uCore** with all services running

Zero manual steps required.

## Available Commands

```bash
# Build all Ignition configs
mise run ucore:build

# Build single host config
mise run ucore:build-single mouse

# Create and auto-install VM (default: mouse)
mise run ucore:vm
mise run ucore:vm laptop

# Connect to existing VM
mise run ucore:vm-connect mouse
```

## Testing Workflow

1. `mise run ucore:vm mouse` - Watch the automated installation
2. Wait for system to rebase to uCore and reboot (~10-15 min total)
3. Verify services work
4. Follow production migration: `infra/ucore/MIGRATION.md`

## Documentation

- **[HOSTS.md](HOSTS.md)** - Multi-host management guide
- **[CONTAINERS.md](CONTAINERS.md)** - Container integration architecture
- **[MIGRATION.md](MIGRATION.md)** - Production migration runbook

## Current Hosts

- **mouse** - Primary homelab server (NixOS → uCore migration)

## Current Status

- [x] Multi-host architecture
- [x] Butane configs created
- [x] Container definitions written  
- [x] Automated installation workflow
- [x] Auto-rebase to uCore
- [ ] VM testing validated
- [ ] Production migration scheduled
- [ ] Migration executed
