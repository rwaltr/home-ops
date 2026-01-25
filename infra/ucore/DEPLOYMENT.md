# uCore Deployment Strategies

## Overview

This document outlines approaches for deploying configuration changes to running uCore systems after initial provisioning. Since Ignition is provision-time only, ongoing management requires different tools.

## Deployment Layers

uCore deployments have three distinct layers, each with different update mechanisms:

```
┌─────────────────────────────────────────┐
│ Layer 1: OS Image (Immutable Base)     │ → bootc/rpm-ostree
├─────────────────────────────────────────┤
│ Layer 2: Configuration (/etc)          │ → Git-based sync / Ansible
├─────────────────────────────────────────┤
│ Layer 3: Containers (Applications)     │ → Quadlet + auto-update
└─────────────────────────────────────────┘
```

## Recommended Approach: GitOps Pattern

### Inspiration

Based on [deuill/coreos-home-server](https://github.com/deuill/coreos-home-server) - a production homelab using Git-based automatic configuration sync.

**Key Concept**: Git repository is the source of truth. Systems pull configuration updates periodically via systemd timer.

### Implementation

#### 1. Git Sync Service

Create `/etc/systemd/system/home-ops-sync.service`:

```ini
[Unit]
Description=Sync home-ops configuration from Git
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=GIT_REPO=https://github.com/rwaltr/home-ops.git
Environment=GIT_BRANCH=main
ExecStartPre=/usr/bin/rm -rf /tmp/home-ops-sync
ExecStartPre=/usr/bin/git clone --depth=1 --branch=${GIT_BRANCH} ${GIT_REPO} /tmp/home-ops-sync
ExecStart=/usr/bin/bash /tmp/home-ops-sync/infra/ucore/scripts/apply-config.sh

[Install]
WantedBy=multi-user.target
```

Create `/etc/systemd/system/home-ops-sync.timer`:

```ini
[Unit]
Description=Sync home-ops configuration hourly

[Timer]
OnCalendar=hourly
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
```

#### 2. Deployment Script

Create `infra/ucore/scripts/apply-config.sh`:

```bash
#!/bin/bash
set -euo pipefail

REPO_ROOT="/tmp/home-ops-sync"
QUADLET_DIR="/etc/containers/systemd"

echo "Deploying configuration updates..."

# Sync Quadlet container definitions
rsync -av --delete "${REPO_ROOT}/infra/ucore/containers/" "${QUADLET_DIR}/"

# Reload systemd to pick up changes
systemctl daemon-reload

# Restart changed services (optional - may cause brief downtime)
for container in "${REPO_ROOT}/infra/ucore/containers/"*.container; do
    service_name=$(basename "$container" .container)
    if systemctl is-active "${service_name}.service" >/dev/null 2>&1; then
        echo "Restarting ${service_name}.service"
        systemctl restart "${service_name}.service"
    fi
done

echo "Configuration deployed successfully"
```

#### 3. Enable on Host

```bash
# Copy units to /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now home-ops-sync.timer

# Verify
systemctl status home-ops-sync.timer
```

### Daily Workflow

```bash
# 1. Edit configuration locally
vim infra/ucore/containers/navidrome.container

# 2. Commit and push
git add infra/ucore/containers/navidrome.container
git commit -m "Update Navidrome configuration"
git push

# 3. Wait for automatic sync (within 1 hour)
# OR trigger manually:
ssh rwaltr@mouse "sudo systemctl start home-ops-sync.service"

# 4. Verify deployment
ssh rwaltr@mouse "systemctl status navidrome.service"
```

---

## OS Updates

### Automatic Staging (Recommended)

Configure automatic downloads with manual reboot control:

```bash
# Enable automatic staging
sudo sed -i 's/^#AutomaticUpdatePolicy=.*/AutomaticUpdatePolicy=stage/' /etc/rpm-ostreed.conf
sudo systemctl enable rpm-ostreed-automatic.timer --now
```

**How it works:**
- Updates download and stage automatically
- No automatic reboots
- You control when to apply via `systemctl reboot`

**Check for staged updates:**
```bash
rpm-ostree status
```

**Apply staged update:**
```bash
sudo systemctl reboot
```

### Manual Updates

```bash
# Check for updates
rpm-ostree upgrade --check

# Download and stage
rpm-ostree upgrade

# Reboot to apply
sudo systemctl reboot
```

### Modern Alternative: bootc

Container-native OS management (available in newer uCore versions):

```bash
# One-time switch to bootc
sudo bootc switch ghcr.io/ublue-os/ucore:stable

# Future updates
sudo bootc upgrade
sudo systemctl reboot
```

---

## Container Updates

### Automatic Updates (Recommended)

Enable Podman's built-in auto-update timer:

```bash
sudo systemctl enable --now podman-auto-update.timer
```

**Configure containers for auto-update:**

```ini
# infra/ucore/containers/navidrome.container
[Container]
Image=docker.io/deluan/navidrome:latest
Label=io.containers.autoupdate=registry
PublishPort=4533:4533
Volume=/var/tank/nas/library/music:/music:ro
Volume=/var/tank/services/navidrome:/data:Z

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

**How it works:**
- Timer runs daily
- Checks registry for new image digest
- Pulls updated images
- Restarts systemd services

**Manual trigger:**
```bash
podman auto-update --dry-run  # Check for updates
podman auto-update            # Apply updates
```

### Manual Container Updates

```bash
# Update single container
sudo podman pull docker.io/deluan/navidrome:latest
sudo systemctl restart navidrome.service

# Update all containers
sudo podman auto-update
```

---

## Rollback Procedures

### OS Rollback

```bash
# List deployments
rpm-ostree status

# Rollback to previous deployment
sudo rpm-ostree rollback
sudo systemctl reboot
```

### Container Rollback

```bash
# Pull specific version
sudo podman pull docker.io/deluan/navidrome:0.52.0

# Update container file to pin version
vim infra/ucore/containers/navidrome.container
# Change: Image=docker.io/deluan/navidrome:0.52.0

# Commit and push
git commit -am "Rollback Navidrome to 0.52.0"
git push

# Wait for sync or trigger manually
ssh rwaltr@mouse "sudo systemctl start home-ops-sync.service"
```

### Configuration Rollback

```bash
# Revert Git commit
git revert HEAD
git push

# Trigger sync
ssh rwaltr@mouse "sudo systemctl start home-ops-sync.service"
```

---

## Monitoring & Verification

### System Status

```bash
# OS deployment status
rpm-ostree status

# Check for staged updates
rpm-ostree upgrade --check

# Container auto-update status
systemctl status podman-auto-update.timer
journalctl -u podman-auto-update.service

# Config sync status
systemctl status home-ops-sync.timer
journalctl -u home-ops-sync.service
```

### Service Health

```bash
# List all Quadlet services
systemctl list-units '*.service' | grep -E '(rustfs|navidrome|syncthing|netdata)'

# View service logs
journalctl -u navidrome.service -f

# Check container status
podman ps -a
```

---

## Alternative Approaches

### Ansible-Based Management

For multi-host fleets, consider Ansible:

```yaml
# playbook.yml
- hosts: coreos
  tasks:
    - name: Layer packages
      ansible.builtin.command: rpm-ostree install htop
      
    - name: Deploy container configs
      ansible.builtin.copy:
        src: containers/
        dest: /etc/containers/systemd/
        
    - name: Reload systemd
      ansible.builtin.systemd:
        daemon_reload: yes
```

**References:**
- [zjpeterson/ansible-edge-management](https://github.com/zjpeterson/ansible-edge-management)
- [RedHat Edge API templates](https://github.com/RedHatInsights/edge-api/tree/main/templates)

### Custom OCI Images

Build custom OS images with baked-in packages:

```dockerfile
# Containerfile
FROM quay.io/fedora/fedora-coreos:stable
RUN rpm-ostree install htop tmux vim && \
    rpm-ostree cleanup -m && \
    ostree container commit
```

```bash
# Build and push
podman build -t ghcr.io/rwaltr/custom-ucore:latest .
podman push ghcr.io/rwaltr/custom-ucore:latest

# Rebase host
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/rwaltr/custom-ucore:latest
sudo systemctl reboot
```

---

## Best Practices

1. **Git as Source of Truth**: All configuration changes go through Git
2. **Automatic Staging**: Updates download automatically, apply manually
3. **Pin Critical Versions**: Use specific tags for production services
4. **Test in VM First**: Validate changes in `mise run ucore:vm` before production
5. **Enable Rollback**: Keep previous deployment available (`ostree admin pin 0`)
6. **Monitor Logs**: Use `journalctl` to track service health
7. **Immutability Matters**: Never manually edit files - always update via Git

---

## Implementation Checklist

- [ ] Create `infra/ucore/scripts/apply-config.sh`
- [ ] Add systemd units to Butane config or manually deploy
- [ ] Enable `home-ops-sync.timer` on host
- [ ] Enable `rpm-ostreed-automatic.timer` for OS updates
- [ ] Enable `podman-auto-update.timer` for container updates
- [ ] Add `io.containers.autoupdate=registry` label to containers
- [ ] Test deployment workflow in VM
- [ ] Document rollback procedure for team

---

## References

- [deuill/coreos-home-server](https://github.com/deuill/coreos-home-server) - GitOps pattern inspiration
- [Fedora CoreOS FAQ](https://docs.fedoraproject.org/en-US/fedora-coreos/faq/) - Official guidance
- [Podman Auto-Update](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html) - Container updates
- [bootc Getting Started](https://docs.fedoraproject.org/en-US/bootc/getting-started/) - Modern OS updates
- [Major Hayden: Podman Quadlet Auto-Updates](https://major.io/p/podman-quadlet-automatic-updates/) - Tutorial
