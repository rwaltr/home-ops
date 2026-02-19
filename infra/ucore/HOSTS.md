# Multi-Host Management Guide

## Quick Reference

```bash
# Add new host
cp infra/ucore/butane/hosts/template.bu infra/ucore/butane/hosts/newhost.bu
# Edit newhost.bu and customize

# Build and test
mise run ucore:vm newhost

# Connect to VM
mise run ucore:vm-connect newhost
```

## Directory Layout

```
infra/ucore/
├── butane/
│   ├── base.bu              # Shared: users, SSH keys, sudo
│   └── hosts/
│       ├── template.bu      # Template for new hosts
│       └── <hostname>.bu    # Per-host config
├── containers/              # Shared container definitions
│   ├── rustfs.container
│   └── netdata.container
└── ignition/                # Generated files (gitignored)

.mise/tasks/ucore/           # Mise task files
├── build                    # Build all Ignition configs
├── build-single             # Build single host config
├── clean                    # Clean up VMs and disks
├── customize-iso            # Create custom install ISO
├── download-iso             # Download Fedora CoreOS ISO
├── vm                       # Create and install VM
└── vm-connect               # Connect to existing VM
```

## Adding a New Host

### 1. Create Host Config

```bash
# Copy template
cp infra/ucore/butane/hosts/template.bu infra/ucore/butane/hosts/newhost.bu

# Generate unique hostid for ZFS
printf '%08x\n' $(date +%s)
# Example output: 679f3a2c

# Edit the file
vim infra/ucore/butane/hosts/newhost.bu
```

### 2. Customize Host Config

Required changes in `newhost.bu`:

- Replace `CHANGEME_HOSTNAME` with actual hostname
- Replace `CHANGEME_HOSTID` with generated hostid
- Add container references as needed (see mouse.bu for examples)

### 3. Build and Test

```bash
# Build Ignition config
mise run ucore:build

# Test in VM
mise run ucore:vm newhost
```

### 4. Verify Installation

Watch the VM console for:

1. Fedora CoreOS installation (1-2 min)
2. First reboot
3. uCore rebase (5-10 min)
4. Second reboot into uCore
5. Services starting

```bash
# Connect to VM
mise run ucore:vm-connect newhost

# Verify uCore
rpm-ostree status
```

## Host Configuration Files

### base.bu (Shared)

- User accounts (`rwaltr`) and SSH authorized keys
- Passwordless sudo via `nopasswd` group
- Applied to all hosts via Ignition `merge`

### hosts/template.bu (Template)

Starting point for new hosts. Includes:

- Placeholder hostname and hostid
- Merges `base.ign` and `storage.ign`
- Rebase to uCore service
- Avahi, smartd, firewalld systemd units
- Commented container reference examples

### hosts/mouse.bu (Production Host)

Mouse-specific configuration:

- Hostname: `mouse`
- ZFS hostid: `1e1719e4`
- Merges `base.ign` and `storage.ign`
- Rebase to uCore service
- Avahi (mDNS) and smartd (disk monitoring)
- **Note**: Container references not yet added to mouse.bu (containers are defined in `containers/` but not referenced in Butane yet)

## Adding Containers to a Host

Containers are managed via Podman Quadlet. The workflow:

1. **Create container definition** in `containers/myapp.container`:

   ```ini
   [Unit]
   Description=My Application
   After=network-online.target

   [Container]
   Image=docker.io/myapp:latest
   ContainerName=myapp
   PublishPort=8080:8080
   Volume=/var/tank/services/myapp:/data:Z

   [Install]
   WantedBy=multi-user.target
   ```

2. **Reference in host Butane config** (`butane/hosts/<hostname>.bu`):

   ```yaml
   storage:
     files:
       - path: /etc/containers/systemd/myapp.container
         mode: 0644
         contents:
           local: infra/ucore/containers/myapp.container
   ```

3. **Build and deploy**:

   ```bash
   mise run ucore:build
   # Container is now embedded in Ignition config
   ```

4. **On boot**, systemd automatically:
   - Discovers `*.container` files in `/etc/containers/systemd/`
   - Creates systemd services (e.g., `myapp.service`)
   - Starts containers according to dependencies

See [CONTAINERS.md](CONTAINERS.md) for full architecture details.

### Container Management Commands

```bash
# List containers
systemctl list-units '*.service' --type=service | grep container

# Status
systemctl status rustfs.service

# Logs
journalctl -u rustfs.service -f

# Restart
systemctl restart rustfs.service

# Disable
systemctl disable --now rustfs.service
```

## VM Management

```bash
# List all VMs
virsh --connect qemu:///system list --all

# Start VM
virsh --connect qemu:///system start ucore-<hostname>-test

# Stop VM
virsh --connect qemu:///system shutdown ucore-<hostname>-test

# Delete VM and disks
mise run ucore:clean <hostname>

# Or manually:
virsh --connect qemu:///system destroy ucore-<hostname>-test
virsh --connect qemu:///system undefine ucore-<hostname>-test --nvram
rm .vm/ucore-<hostname>*.qcow2
rm .vm/fedora-coreos-<hostname>-*-autoinstall.iso
```

## Deployment to Production

### Option 1: USB Boot (Recommended)

1. Build Ignition and create custom ISO:

   ```bash
   mise run ucore:build
   mise run ucore:customize-iso <hostname>
   ```

2. Write to USB:

   ```bash
   sudo dd if=.vm/fedora-coreos-<hostname>-vda-autoinstall.iso of=/dev/sdX bs=4M status=progress
   ```

3. Boot target machine from USB — installation happens automatically

4. System reboots into uCore

### Option 2: PXE Boot

See Fedora CoreOS docs for PXE setup with custom Ignition configs.

## Troubleshooting

### Build fails

```bash
# Check Butane syntax
butane --strict < infra/ucore/butane/hosts/<hostname>.bu

# Build single config with verbose output
mise run ucore:build-single <hostname>
```

### VM won't boot

```bash
# Check VM console
virsh --connect qemu:///system console ucore-<hostname>-test

# Check Ignition was applied
journalctl -u ignition-*
```

### Rebase to uCore fails

```bash
# Check rebase service
systemctl status rebase-to-ucore.service
journalctl -u rebase-to-ucore.service

# Manual rebase
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/ucore-hci:stable
sudo systemctl reboot
```

## Current Hosts

| Hostname | Status | ZFS Hostid | Purpose |
|----------|--------|------------|---------|
| mouse    | ✅ Running | 1e1719e4 | Primary homelab server |

## Resources

- [Fedora CoreOS Docs](https://docs.fedoraproject.org/en-US/fedora-coreos/)
- [Universal Blue uCore](https://github.com/ublue-os/ucore)
- [Butane Config Spec](https://coreos.github.io/butane/config-fcos-v1_5/)
