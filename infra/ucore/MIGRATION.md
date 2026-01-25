# Production Migration Runbook: NixOS → uCore

**Target Host:** mouse  
**OS Change:** NixOS 24.05 → Universal Blue uCore HCI (stable)  
**Critical Data:** ZFS pool "tank" on separate disks  
**Estimated Downtime:** 1-2 hours

## Pre-Migration Checklist

### 1. Backup Everything (1-2 days before)

```bash
# SSH into current mouse host
ssh rwaltr@mouse

# Create final ZFS snapshots
sudo zfs snapshot -r tank@pre-ucore-migration-$(date +%Y%m%d)

# List all snapshots
zfs list -t snapshot

# Export ZFS pool configuration
sudo zpool status tank > ~/zpool-tank-config.txt
sudo zpool get all tank > ~/zpool-tank-properties.txt

# Backup critical configs
sudo tar -czf ~/mouse-backup-$(date +%Y%m%d).tar.gz \
    /etc/nixos \
    /persist \
    ~/.ssh \
    /var/lib/tailscale

# Copy backup off-host
scp ~/mouse-backup-*.tar.gz ~/zpool-*.txt your-laptop:~/backups/
```

### 2. Document Current State

```bash
# Network configuration
ip addr show > ~/network-config.txt
ip route show >> ~/network-config.txt
cat /etc/resolv.conf >> ~/network-config.txt

# Running services
systemctl list-units --type=service --state=running > ~/services-running.txt

# ZFS datasets and mountpoints
zfs list -o name,mountpoint,used,avail > ~/zfs-datasets.txt

# Firewall rules
sudo iptables -L -n > ~/firewall-rules.txt
```

### 3. Verify Ignition Configs

```bash
# On your workstation
cd ~/src/rwaltr/home-ops

# Build Ignition files
mise run ucore:build

# Validate generated files exist
ls -lh infra/ucore/ignition/
```

### 4. Prepare Installation Media

```bash
# Download uCore ISO
curl -L -o ~/Downloads/ucore-hci-stable.iso \
    https://github.com/ublue-os/ucore/releases/latest/download/ucore-hci-stable.iso

# Create bootable USB (Linux)
sudo dd if=~/Downloads/ucore-hci-stable.iso of=/dev/sdX bs=4M status=progress && sync

# Or use Ventoy, Balena Etcher, etc.
```

### 5. Copy Ignition Config to USB

```bash
# Mount USB (after writing ISO)
# Create a data partition or use Ventoy persistence

# Copy Ignition file
cp infra/ucore/ignition/mouse.ign /path/to/usb/

# You'll need to transfer this to the host during installation
```

## Migration Day

### Phase 1: Pre-Shutdown (15 minutes)

```bash
# SSH into mouse
ssh rwaltr@mouse

# Stop all services gracefully
sudo systemctl stop minio
sudo systemctl stop navidrome  
sudo systemctl stop syncthing
sudo systemctl stop netdata

# Final ZFS snapshot
sudo zfs snapshot -r tank@final-pre-migration-$(date +%Y%m%d-%H%M)

# Export ZFS pool cleanly
sudo zpool export tank

# Verify export
zpool list
# tank should NOT appear

# Shutdown
sudo systemctl poweroff
```

### Phase 2: Installation (30-45 minutes)

1. **Boot from USB**
   - Insert USB with uCore ISO
   - Boot into uCore live environment
   - You'll be at a shell prompt

2. **Transfer Ignition Config**
   ```bash
   # If you have network and can SCP from workstation:
   curl -o /tmp/mouse.ign http://your-laptop-ip:8000/mouse.ign
   
   # Or mount USB data partition and copy:
   mount /dev/sdX2 /mnt
   cp /mnt/mouse.ign /tmp/
   ```

3. **Identify Disks**
   ```bash
   lsblk
   # Identify:
   # - OS disk (nvme0n1 or sda) - will be WIPED
   # - ZFS pool disks - DO NOT TOUCH
   ```

4. **Install uCore**
   ```bash
   # Install to OS disk with Ignition config
   sudo coreos-installer install /dev/nvme0n1 \
       --ignition-file /tmp/mouse.ign \
       --insecure-ignition
   
   # Wait for completion
   # "Install complete" message will appear
   ```

5. **Remove USB and Reboot**
   ```bash
   sudo reboot
   ```

### Phase 3: Post-Boot Setup (30 minutes)

1. **Initial Boot Verification**
   ```bash
   # From workstation, SSH into new system
   ssh rwaltr@mouse
   
   # Check system info
   cat /etc/os-release
   # Should show: Universal Blue uCore
   
   # Check user
   whoami
   id
   ```

2. **Import ZFS Pool**
   ```bash
   # Load ZFS module (should auto-load but verify)
   lsmod | grep zfs
   
   # Import tank pool
   sudo zpool import tank
   
   # Set mountpoint to /var/tank
   sudo zfs set mountpoint=/var/tank tank
   
   # Verify mount
   zfs list
   mount | grep tank
   ls -la /var/tank
   ```

3. **Enable ZFS Services**
   ```bash
   # Enable ZFS import service
   sudo systemctl enable --now zfs-import-tank.service
   
   # Enable weekly scrub
   sudo systemctl enable --now zfs-scrub-weekly@tank.timer
   
   # Verify
   systemctl status zfs-import-tank.service
   systemctl status zfs-scrub-weekly@tank.timer
   ```

4. **Deploy Container Services**
   ```bash
   # Copy Quadlet container definitions
   sudo mkdir -p /etc/containers/systemd
   
   # Transfer from workstation (or they should be in Ignition already)
   # If not in Ignition, SCP them:
   scp infra/ucore/containers/*.container rwaltr@mouse:/tmp/
   sudo mv /tmp/*.container /etc/containers/systemd/
   
   # Reload systemd
   sudo systemctl daemon-reload
   
   # Start services
   sudo systemctl start minio.service
   sudo systemctl start navidrome.service
   sudo systemctl start syncthing.service
   sudo systemctl start netdata.service
   
   # Enable on boot
   sudo systemctl enable minio.service navidrome.service syncthing.service netdata.service
   ```

5. **Configure Tailscale**
   ```bash
   # Start Tailscale container
   sudo systemctl start tailscale.service
   
   # Authenticate (will print URL)
   sudo podman exec tailscale tailscale up
   
   # Follow authentication link
   
   # Verify connection
   sudo podman exec tailscale tailscale status
   ```

6. **Configure Firewall**
   ```bash
   # Verify firewall running
   sudo systemctl status firewalld
   
   # Add homelab service
   sudo firewall-cmd --permanent --add-service=homelab
   sudo firewall-cmd --reload
   
   # List open ports
   sudo firewall-cmd --list-all
   ```

### Phase 4: Verification (15 minutes)

```bash
# Check all services running
systemctl status minio.service
systemctl status navidrome.service
systemctl status syncthing.service
systemctl status netdata.service
systemctl status nfs-server.service
systemctl status tailscale.service

# Check containers
podman ps

# Test MinIO
curl http://localhost:9000

# Test Syncthing
curl http://localhost:8384

# Test Netdata
curl http://localhost:19999

# Test Navidrome
curl http://localhost:4533

# Test NFS exports
showmount -e localhost

# Check ZFS pool health
sudo zpool status

# Check disk space
df -h
zfs list

# Verify data integrity
ls -la /var/tank/nas/library/music
ls -la /var/tank/services/
```

## Rollback Plan

If migration fails and you need to restore NixOS:

1. **Boot from NixOS USB/rescue media**

2. **Import ZFS pool**
   ```bash
   sudo zpool import tank
   ```

3. **Restore from backup**
   ```bash
   # Restore critical configs
   tar -xzf mouse-backup-YYYYMMDD.tar.gz -C /
   
   # Reinstall NixOS if needed
   nixos-install --root /mnt
   ```

## Post-Migration Tasks

### Day 1
- [ ] Monitor service logs for errors
- [ ] Verify Syncthing peers reconnect
- [ ] Test file access via NFS
- [ ] Verify Tailscale connectivity from other devices
- [ ] Check ZFS scrub scheduled

### Week 1
- [ ] Verify automated updates working (rpm-ostree)
- [ ] Test container restarts after reboot
- [ ] Monitor system resources
- [ ] Document any issues or improvements

### Month 1
- [ ] Remove NixOS configurations from repo (if satisfied)
- [ ] Update documentation
- [ ] Share experience with community

## Troubleshooting

### Ignition Didn't Apply
```bash
# Check Ignition logs
journalctl -u ignition-firstboot
journalctl -u ignition-fetch

# Manually apply missing configs
```

### ZFS Pool Won't Import
```bash
# Force import
sudo zpool import -f tank

# Check for errors
sudo zpool status -v tank

# Clear errors
sudo zpool clear tank
```

### Containers Won't Start
```bash
# Check logs
journalctl -u minio.service -n 50
podman logs minio

# Check SELinux (might block mounts)
sudo ausearch -m avc -ts recent

# If needed, relabel volumes
sudo restorecon -Rv /var/tank/services/
```

### Network Issues
```bash
# Check NetworkManager
nmcli device status
nmcli connection show

# Restart network
sudo systemctl restart NetworkManager
```

## Emergency Contacts

- **ZFS Help:** #zfs on Libera.Chat IRC
- **uCore Help:** https://github.com/ublue-os/ucore/discussions
- **Universal Blue Discord:** https://discord.gg/f8MUghG5PB

## Success Criteria

Migration is successful when:
- ✅ All services running and accessible
- ✅ ZFS pool imported and healthy
- ✅ Data accessible and intact
- ✅ Network connectivity restored
- ✅ Tailscale connected
- ✅ Containers survive reboot
- ✅ No critical errors in logs
