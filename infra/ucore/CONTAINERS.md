# Container Integration Architecture

## Overview

Containers are managed using **Podman Quadlet**, which integrates container definitions directly into systemd.

## File Flow

```
containers/rustfs.container (Quadlet definition)
         ↓
butane/hosts/mouse.bu (references via contents.local)
         ↓
ignition/mouse.ign (embeds container file)
         ↓
/etc/containers/systemd/rustfs.container (deployed on boot)
         ↓
systemd discovers and creates rustfs.service
         ↓
Container runs as systemd service
```

## Current Containers

| Container | Port(s) | Volume(s) | Purpose |
|-----------|---------|-----------|---------|
| rustfs | 9000, 9001 | `/var/tank/services/rustfs/data` | S3-compatible object storage (Rust-based) |
| netdata | 19999 | `/var/tank/services/netdata/*`, host system mounts | Real-time system monitoring |

**Planned (not yet created):**

| Container | Purpose | Status |
|-----------|---------|--------|
| navidrome | Music streaming server | 📋 Planned |
| syncthing | File synchronization | 📋 Planned |
| tailscale | VPN mesh network | 📋 Planned |

## How It Works

### 1. Container Definition (Quadlet)

File: `containers/rustfs.container`

```ini
[Unit]
Description=RustFS S3-compatible object storage
After=network-online.target zfs-import-tank.service
Wants=network-online.target

[Container]
Image=docker.io/rustfs/rustfs:latest
ContainerName=rustfs
PublishPort=9000:9000
PublishPort=9001:9001
Volume=/var/tank/services/rustfs/data:/data:Z
Environment=RUSTFS_ACCESS_KEY=admin
Environment=RUSTFS_SECRET_KEY=changeme
Environment=RUSTFS_CONSOLE_ENABLE=true
Exec=/data

[Service]
TimeoutStartSec=900
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

### 2. Host Butane Config

File: `butane/hosts/mouse.bu`

```yaml
storage:
  files:
    - path: /etc/containers/systemd/rustfs.container
      mode: 0644
      contents:
        local: infra/ucore/containers/rustfs.container
```

**What happens:**

- Butane reads `containers/rustfs.container` from filesystem
- Embeds content (compressed) into Ignition JSON
- Ignition deploys to `/etc/containers/systemd/` on target

### 3. Systemd Integration

On boot, systemd's **quadlet generator** (`/usr/lib/systemd/system-generators/podman-system-generator`):

1. Scans `/etc/containers/systemd/*.container`
2. Generates systemd service units in `/run/systemd/system/`
3. Enables and starts services per `[Install]` directive

Result: `rustfs.service` runs like any systemd service.

## Adding a New Container

### Step 1: Create Quadlet Definition

```bash
# Create container definition
cat > infra/ucore/containers/myapp.container << 'EOF'
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
EOF
```

### Step 2: Reference in Host Config

Edit `butane/hosts/mouse.bu`:

```yaml
storage:
  files:
    # ... existing containers ...

    - path: /etc/containers/systemd/myapp.container
      mode: 0644
      contents:
        local: infra/ucore/containers/myapp.container
```

### Step 3: Build and Deploy

```bash
# Rebuild Ignition
mise run ucore:build

# Test in VM
mise run ucore:vm mouse

# Or deploy to production (see DEPLOYMENT.md)
```

## Container Lifecycle Management

### Managing Services

```bash
# Status
systemctl status rustfs.service

# Start/Stop
systemctl start rustfs.service
systemctl stop rustfs.service

# Enable/Disable
systemctl enable rustfs.service
systemctl disable rustfs.service

# Restart
systemctl restart rustfs.service

# Logs
journalctl -u rustfs.service -f
```

### Updating Container Images

Since containers use `:latest` tags, update by:

```bash
# Pull new image
podman pull docker.io/rustfs/rustfs:latest

# Restart service
systemctl restart rustfs.service
```

For pinned versions, edit the `.container` file, rebuild Ignition, and redeploy.

### Persistent Storage

All containers use ZFS volumes under `/var/tank/services/<name>/`:

- Survives container recreation
- Benefits from ZFS snapshots/replication
- Mounted with `:Z` for SELinux relabeling

## Troubleshooting

### Container won't start

```bash
# Check systemd status
systemctl status myapp.service

# Check container logs
journalctl -u myapp.service -n 50

# Check Quadlet file syntax
cat /etc/containers/systemd/myapp.container

# Manually test container
podman run --rm -it docker.io/myapp:latest
```

### Quadlet file not generating service

```bash
# Force systemd to regenerate
systemctl daemon-reload

# Check quadlet generator ran
ls /run/systemd/system/*.service | grep myapp

# Check for errors
journalctl -u systemd-generator
```

### Volume mount permissions

```bash
# SELinux context issues
ls -lZ /var/tank/services/myapp

# Fix SELinux labels
restorecon -R /var/tank/services/myapp

# Or use :z instead of :Z in Volume= directive
```

## Best Practices

1. **Dependencies**: Use `After=` to ensure ZFS pool is mounted first
2. **Restart Policy**: Always set `Restart=on-failure` in `[Service]`
3. **Volume Mounts**: Use `:Z` for SELinux relabeling
4. **Image Tags**: Use specific versions in production, `:latest` for testing
5. **Secrets**: Use environment files or systemd credentials, not inline
6. **Resource Limits**: Add memory/CPU limits via `[Service]` section

## References

- [Podman Quadlet Documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [Butane Config Spec](https://coreos.github.io/butane/config-fcos-v1_5/)
- [Fedora CoreOS Storage](https://docs.fedoraproject.org/en-US/fedora-coreos/storage/)
