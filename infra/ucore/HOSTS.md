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
│   ├── base.bu              # Shared: users, SSH, firewall, packages
│   ├── storage.bu           # Shared: ZFS config
│   └── hosts/
│       ├── template.bu      # Template for new hosts
│       └── <hostname>.bu    # Per-host config
├── containers/              # Shared container definitions
└── ignition/                # Generated files (gitignored)

.mise/tasks/ucore/           # Mise task files
├── build                    # Build all Ignition configs
├── build-single             # Build single host config
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
- Add host-specific services/configuration

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
# Get VM IP
virsh --connect qemu:///system domifaddr ucore-newhost-test

# SSH into VM
ssh rwaltr@<ip>

# Verify uCore
rpm-ostree status
```

## Host Configuration Files

### base.bu (Shared)
- User accounts and SSH keys
- Firewall rules
- System packages (rpm-ostree)
- Common system settings

### storage.bu (Shared - ZFS hosts only)
- ZFS kernel module loading
- ZFS pool import service
- NFS server configuration
- ZFS scrub timer

### hosts/<hostname>.bu (Per-Host)
- Hostname
- ZFS hostid (unique per host)
- uCore rebase service
- **Container definitions** (references to `containers/*.container`)
- Host-specific services
- Host-specific network configuration

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

# Delete VM
virsh --connect qemu:///system destroy ucore-<hostname>-test
virsh --connect qemu:///system undefine ucore-<hostname>-test --nvram

# Delete VM disks
rm .vm/ucore-<hostname>*.qcow2
rm .vm/fedora-coreos-<hostname>-autoinstall.iso
```

## Deployment to Production

### Option 1: USB Boot (Recommended)

1. Write custom ISO to USB:
   ```bash
   # Build Ignition
   mise run ucore:build
   
   # Create custom ISO
   podman run --rm --privileged \
     -v .vm:/data \
     -v infra/ucore/ignition:/ignition:ro \
     quay.io/coreos/coreos-installer:release \
     iso customize \
     --dest-device /dev/sda \
     --dest-ignition /ignition/<hostname>.ign \
     -o /data/<hostname>-install.iso \
     /data/fedora-coreos-stable.iso
   
   # Write to USB
   sudo dd if=.vm/<hostname>-install.iso of=/dev/sdX bs=4M status=progress
   ```

2. Boot target machine from USB
3. Installation happens automatically
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
| mouse    | In Progress | 1e1719e4 | Primary homelab server |

## Resources

- [Fedora CoreOS Docs](https://docs.fedoraproject.org/en-US/fedora-coreos/)
- [Universal Blue uCore](https://github.com/ublue-os/ucore)
- [Butane Config Spec](https://coreos.github.io/butane/config-fcos-v1_5/)
