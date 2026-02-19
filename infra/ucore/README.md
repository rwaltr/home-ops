# uCore Infrastructure

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

Infrastructure-as-code for managing uCore hosts. Running Universal Blue uCore (Fedora CoreOS-based immutable OS) on the primary host "mouse".

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
│   ├── base.bu              # Shared base config (users, SSH, sudo)
│   └── hosts/
│       ├── template.bu      # Template for new hosts
│       └── mouse.bu         # Host-specific config
├── containers/              # Podman Quadlet definitions
│   ├── rustfs.container     # S3-compatible object storage
│   └── netdata.container    # System monitoring
├── ignition/                # Generated Ignition files (gitignored)
│   └── .gitkeep
├── CONTAINERS.md            # Container integration architecture
├── DEPLOYMENT.md            # Deployment strategies
├── HOSTS.md                 # Multi-host management guide
├── KUBERNETES.md            # k0s on uCore
└── SECRETS.md               # Secret management approach
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

## Multi-Host Management

### Adding a New Host

1. Create host-specific config:

   ```bash
   cp infra/ucore/butane/hosts/template.bu infra/ucore/butane/hosts/newhost.bu
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

- **`butane/base.bu`** — Shared across all hosts (users, SSH keys, sudo)
- **`butane/hosts/<hostname>.bu`** — Host-specific (hostname, hostid, uCore rebase, container references)

## Current Containers

| Container | Port(s) | Purpose |
|-----------|---------|---------|
| rustfs | 9000, 9001 | S3-compatible object storage (Rust-based) |
| netdata | 19999 | Real-time system monitoring |

## Service Status

| Service | Implementation | Status |
|---------|---------------|--------|
| ZFS | Pre-installed, systemd mount units | ✅ Active |
| RustFS | Podman container (Quadlet) | ✅ Container defined |
| Netdata | Podman container (Quadlet) | ✅ Container defined |
| NFS Server | nfs-utils via rpm-ostree | 📋 Planned |
| Navidrome | Podman container (Quadlet) | 📋 Planned |
| Syncthing | Podman container (Quadlet) | 📋 Planned |
| Tailscale | Podman container (Quadlet) | 📋 Planned |

## Storage Paths

All service data lives under `/var/tank/` (uCore has an immutable root filesystem):

- `/var/tank/services/rustfs` — RustFS data
- `/var/tank/services/netdata` — Netdata config/cache
- `/var/tank/nas/library/music` — Media library

## Configuration Management

- **Provisioning**: Butane → Ignition
- **Packages**: rpm-ostree
- **Services**: Podman Quadlet + systemd

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

# Clean up VMs and disks
mise run ucore:clean [hostname]
```

## Testing Workflow

1. `mise run ucore:vm mouse` — Watch the automated installation
2. Wait for system to rebase to uCore and reboot (~10-15 min total)
3. `mise run ucore:vm-connect mouse` — SSH in and verify services
4. Verify services and deploy to production (see [DEPLOYMENT.md](DEPLOYMENT.md))

## Documentation

- **[CONTAINERS.md](CONTAINERS.md)** — Container integration architecture
- **[DEPLOYMENT.md](DEPLOYMENT.md)** — Post-provisioning deployment strategies
- **[HOSTS.md](HOSTS.md)** — Multi-host management guide
- **[KUBERNETES.md](KUBERNETES.md)** — k0s single-node cluster on uCore
- **[SECRETS.md](SECRETS.md)** — Secret management with SOPS + age

## Current Hosts

| Hostname | Purpose | Status |
|----------|---------|--------|
| mouse | Primary homelab server | ✅ Running |

## Current Status

- [x] Multi-host architecture
- [x] Base Butane config (users, SSH, sudo)
- [x] Host-specific configs (mouse, template)
- [x] Container definitions (rustfs, netdata)
- [x] Automated VM installation workflow
- [x] Auto-rebase to uCore
- [ ] Additional containers (navidrome, syncthing, tailscale)
- [ ] k0s Kubernetes integration
- [ ] GitOps deployment workflow (see [DEPLOYMENT.md](DEPLOYMENT.md))
