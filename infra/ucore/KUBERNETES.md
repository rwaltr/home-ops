# Kubernetes on uCore: Single-Node Deployment Analysis

## Executive Summary

This document analyzes the feasibility, approaches, and considerations for deploying a single-node Kubernetes cluster on mouse running uCore, as an alternative to Podman Quadlet deployments.

**TL;DR**: Running k3s on uCore is technically feasible and well-suited for homelab environments, especially if you value Kubernetes experience and GitOps workflows. However, it adds operational complexity compared to Podman Quadlets. The recommended stack is: **uCore + k3s + OpenEBS ZFS LocalPV + Flux**.

---

## Table of Contents

- [Why Consider Kubernetes?](#why-consider-kubernetes)
- [Kubernetes Distribution Comparison](#kubernetes-distribution-comparison)
- [Installation Approaches](#installation-approaches)
- [Storage Integration](#storage-integration)
- [Networking Considerations](#networking-considerations)
- [Coexistence with Quadlet Services](#coexistence-with-quadlet-services)
- [Migration Path from Current Setup](#migration-path-from-current-setup)
- [Recommended Implementation](#recommended-implementation)
- [Kubernetes vs Podman Quadlet Decision Matrix](#kubernetes-vs-podman-quadlet-decision-matrix)
- [References](#references)

---

## Why Consider Kubernetes?

### Advantages for Your Use Case

1. **Familiar Tooling**: You know k8s well, reducing learning curve
2. **GitOps Native**: Flux/ArgoCD provide declarative, Git-backed deployments
3. **Rich Ecosystem**: Access to Helm charts, Operators, and community resources
4. **Advanced Storage**: Native CSI integration with ZFS (snapshots, clones, resize)
5. **Future-Proof**: Easy migration to multi-node if requirements change
6. **Declarative Everything**: Ingress, secrets, config maps - all Kubernetes-native

### Trade-offs vs Podman Quadlet

| Factor | Kubernetes (k3s) | Podman Quadlet |
|--------|------------------|----------------|
| **Resource Overhead** | ~500MB RAM baseline | ~50MB RAM baseline |
| **Complexity** | Medium-High | Low |
| **Learning Curve** | Steep (mitigated for you) | Gentle |
| **Declarative Config** | Full YAML manifests | `.container` INI files |
| **Storage Options** | CSI drivers (rich) | Host bind mounts |
| **Networking** | CNI plugins | Podman networks |
| **Auto-updates** | Renovate + Flux | podman-auto-update |
| **Best For** | Multi-service orchestration | Simple container hosting |

---

## Kubernetes Distribution Comparison

### Evaluated Options

#### 1. **k3s** ⭐ RECOMMENDED

**Overview**: Lightweight Kubernetes distribution by Rancher/SUSE
- **Binary Size**: ~70MB single binary
- **Memory Footprint**: ~500-750MB idle
- **Database**: Embedded SQLite (perfect for single-node)
- **Included**: Local-path storage, Traefik ingress, ServiceLB

**Pros**:
- ✅ Best community support for homelab/edge use cases
- ✅ Built-in Tailscale integration (`--vpn-auth` since v1.26)
- ✅ Single binary installation (no rpm-ostree layering needed)
- ✅ Extensive documentation for immutable systems
- ✅ Active development and security updates

**Cons**:
- ⚠️ Slightly higher resource usage than k0s
- ⚠️ Uses bash installation script (not fully declarative)
- ⚠️ Some SELinux issues on RHEL/Fedora (requires `k3s-selinux` package)

**Installation on uCore**:
```bash
# Install to /usr/local/bin (writable on uCore)
curl -sfL https://get.k3s.io | sh -s - server \
  --disable=traefik \
  --write-kubeconfig-mode=644 \
  --node-taint=''

# Verify
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```

**Data Location**: `/var/lib/rancher/k3s` (persists across OS updates)

---

#### 2. **k0s**

**Overview**: Pure upstream Kubernetes, single binary
- **Binary Size**: ~240MB (includes more components)
- **Memory Footprint**: ~650MB idle (12% less CPU than k3s in benchmarks)
- **Database**: Embedded etcd or SQLite

**Pros**:
- ✅ True upstream Kubernetes (vanilla experience)
- ✅ Lower CPU usage than k3s
- ✅ No external dependencies
- ✅ Good for learning standard Kubernetes

**Cons**:
- ⚠️ Smaller community than k3s
- ⚠️ Less homelab-specific documentation
- ⚠️ No Tailscale integration out of the box

**Installation on uCore**:
```bash
curl -sSLf https://get.k0s.sh | sudo sh
sudo k0s install controller --single
sudo k0s start
```

**Use k0s if**: You want pure upstream Kubernetes experience without k3s customizations.

---

#### 3. **Talos Linux** ⚠️ NOT COMPATIBLE

**Overview**: Immutable, API-managed Kubernetes OS
- **Key Difference**: **Replaces uCore entirely** - it's a complete OS, not a k8s distribution

**Why NOT Recommended**:
- ❌ Cannot run on uCore (requires bare metal install)
- ❌ No ZFS support (uses ext4/xfs only)
- ❌ Cannot run Podman Quadlet services alongside k8s
- ❌ Steeper learning curve (API-only management, no SSH)
- ✅ **Better choice**: If starting fresh and want pure Kubernetes focus

**When to Consider Talos**: If you decide to abandon uCore and go all-in on Kubernetes with a purpose-built OS.

---

#### 4. **microk8s / kubeadm** ❌ NOT RECOMMENDED

- **microk8s**: Requires snap packages (not available on CoreOS/uCore)
- **kubeadm**: Too heavy for single-node, requires manual component management

---

## Installation Approaches

### Three Methods for Installing k3s on uCore

#### Method 1: Static Binary (RECOMMENDED) ✅

**How it Works**:
- k3s installer downloads binary to `/usr/local/bin` (writable on uCore)
- Creates systemd service at `/etc/systemd/system/k3s.service`
- No rpm-ostree layering required
- No OS reboot needed

**Installation**:
```bash
# SSH to mouse
ssh rwaltr@mouse

# Install k3s
curl -sfL https://get.k3s.io | sh -s - server \
  --disable=traefik \
  --disable=servicelb \
  --write-kubeconfig-mode=644 \
  --node-taint='' \
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16

# Verify installation
systemctl status k3s
kubectl get nodes
```

**Pros**:
- ✅ Fastest method
- ✅ No OS modifications
- ✅ Easy to update (`k3s-killall.sh && curl ... | sh`)

**Cons**:
- ⚠️ Not declarative (requires manual steps)
- ⚠️ Bash script dependency

---

#### Method 2: Butane/Ignition Bootstrap ⚠️

**How it Works**:
- Include k3s installation in Butane config
- Provision-time setup via systemd oneshot unit

**Example Butane Snippet**:
```yaml
systemd:
  units:
    - name: k3s-install.service
      enabled: true
      contents: |
        [Unit]
        Description=Install k3s
        ConditionPathExists=!/usr/local/bin/k3s
        After=network-online.target
        Wants=network-online.target
        
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/bin/curl -sfL https://get.k3s.io | sh -s - server --disable=traefik
        
        [Install]
        WantedBy=multi-user.target
```

**Pros**:
- ✅ Declarative provisioning
- ✅ Repeatable across VMs

**Cons**:
- ⚠️ Ignition runs once (updates require manual intervention)
- ⚠️ More complex for single-node homelab
- ⚠️ k3s version pinning difficult

---

#### Method 3: rpm-ostree Layering ❌ NOT RECOMMENDED

**Why Avoid**:
- k3s is not packaged for Fedora/RHEL repositories
- Requires custom RPM builds or third-party repos
- Conflicts with `k3s-selinux` package during re-runs
- Breaks uCore immutability principles
- Slow updates (requires OS reboot)

**Only use if**: Corporate requirement for RPM-based deployments.

---

## Storage Integration

### Your Current Setup (NixOS/uCore)

**Existing ZFS Pool**:
```bash
# From zfs.nix
networking.hostId = "1e1719e4";
boot.zfs.extraPools = [ "tank" ];

# Current paths:
/var/tank/services/rustfs/
/var/tank/services/navidrome/
/var/tank/services/syncthing/
/var/tank/nas/library/music/
```

### Kubernetes Storage Options

#### Option 1: OpenEBS ZFS LocalPV ⭐ RECOMMENDED

**Why Best for Your Setup**:
- ✅ Uses existing `tank` ZFS pool
- ✅ Lightweight (pure control-plane CSI driver)
- ✅ Native ZFS features (snapshots, clones, compression)
- ✅ No network overhead (local storage)
- ✅ CNCF Sandbox project (enterprise-backed)

**Installation**:
```bash
# 1. Install OpenEBS operator
kubectl apply -f https://openebs.github.io/charts/openebs-operator.yaml

# Wait for pods to be ready
kubectl get pods -n openebs -w

# 2. Create StorageClass for ZFS
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-zfspv
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
allowVolumeExpansion: true
parameters:
  recordsize: "128k"
  compression: "lz4"
  dedup: "off"
  fstype: "zfs"
  poolname: "tank/k8s"  # Uses child dataset, doesn't touch /var/tank/services
provisioner: zfs.csi.openebs.io
volumeBindingMode: WaitForFirstConsumer
EOF
```

**How it Integrates**:
```
tank (ZFS pool)
├── services/          # Existing Quadlet service data
│   ├── rustfs/
│   ├── navidrome/
│   └── syncthing/
├── nas/               # Existing media library
│   └── library/music/
└── k8s/               # NEW: Kubernetes volumes
    └── pvc-<uuid>/    # Auto-created by OpenEBS
```

**StorageClass Features**:
```yaml
# For database workloads
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: zfs-db
parameters:
  recordsize: "16k"       # Optimized for databases
  compression: "lz4"
  fstype: "zfs"
  poolname: "tank/k8s/db"

---
# For media workloads
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: zfs-media
parameters:
  recordsize: "1M"        # Optimized for large files
  compression: "off"      # Save CPU for media files
  fstype: "zfs"
  poolname: "tank/k8s/media"
```

**Snapshot Support**:
```yaml
# Create VolumeSnapshotClass
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: zfs-snapclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
driver: zfs.csi.openebs.io
deletionPolicy: Delete

---
# Take snapshot
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-snapshot
spec:
  volumeSnapshotClassName: zfs-snapclass
  source:
    persistentVolumeClaimName: my-pvc
```

**Performance**: Native ZFS performance (no network layer)

---

#### Option 2: democratic-csi (For TrueNAS Users)

**When to Use**:
- You plan to add a TrueNAS/FreeNAS server
- You want centralized storage management
- You need NFS/iSCSI multi-node access later

**Cons for Single-Node**:
- Network overhead (+1-5ms latency)
- More complex setup (SSH keys, NFS server config)
- Overkill for local storage

**Skip this unless**: You already have or plan to deploy TrueNAS.

---

#### Option 3: k3s local-path-provisioner (Simplest)

**Included by Default**: k3s ships with local-path-provisioner

**Pros**:
- ✅ Zero configuration
- ✅ Works out of the box
- ✅ Good for testing

**Cons**:
- ❌ No ZFS features (no snapshots, compression, etc.)
- ❌ Just bind mounts to `/var/lib/rancher/k3s/storage`
- ❌ No volume resize support

**Use for**: Non-critical workloads, config maps, temp storage

---

### Storage Recommendation

**Use Hybrid Approach**:
1. **OpenEBS ZFS LocalPV** (default) → Databases, stateful apps
2. **local-path** → Logs, caches, non-critical data

```yaml
# Database deployment
spec:
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: postgres-data
---
# PVC using ZFS
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
spec:
  storageClassName: openebs-zfspv
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
```

---

## Networking Considerations

### Current Setup (NixOS/uCore)

**Existing Network Services**:
- Tailscale VPN mesh
- NFS server (port 2049)
- Service ports: 19999 (Netdata), 8384 (Syncthing), 22000 (Syncthing sync)

### Kubernetes Networking Integration

#### CNI Plugin Choice

**k3s Default: Flannel VXLAN**
- Pros: Simple, works out of the box
- Cons: MTU issues with Tailscale (both use 1280 MTU)

**Recommended: Flannel WireGuard Backend**
```bash
# Install k3s with Flannel WireGuard
curl -sfL https://get.k3s.io | sh -s - server \
  --flannel-backend=wireguard-native \
  --disable=traefik
```

**Why WireGuard**:
- ✅ Better Tailscale compatibility (avoids MTU mismatch)
- ✅ Encrypted pod-to-pod traffic
- ✅ Native Linux kernel support (fast)

**Alternative: Cilium**
```bash
# Install k3s without CNI
curl -sfL https://get.k3s.io | sh -s - server \
  --flannel-backend=none \
  --disable-network-policy

# Install Cilium
helm install cilium cilium/cilium --namespace kube-system \
  --set tunnel=vxlan \
  --set ipam.mode=kubernetes
```

**Cilium Benefits**:
- eBPF-based networking
- Hubble observability UI
- Advanced network policies

**Cilium Cons**:
- Higher resource usage (~200MB extra)
- More complex for single-node

---

#### Tailscale Integration

**Option A: Tailscale for External Access Only** ⭐ RECOMMENDED

```bash
# Bind k3s API server to Tailscale IP
TAILSCALE_IP=$(tailscale ip -4)

curl -sfL https://get.k3s.io | sh -s - server \
  --bind-address ${TAILSCALE_IP} \
  --advertise-address ${TAILSCALE_IP} \
  --tls-san ${TAILSCALE_IP}
```

**Access cluster remotely**:
```bash
# From laptop
scp rwaltr@mouse:/etc/rancher/k3s/k3s.yaml ~/.kube/config
# Edit server URL to use Tailscale IP
kubectl get nodes
```

**Option B: k3s Native Tailscale Integration**

```bash
# Requires Tailscale OAuth client
curl -sfL https://get.k3s.io | sh -s - server \
  --vpn-auth="name=tailscale,joinKey=${TS_AUTHKEY}"
```

**Known Issues**:
- MTU mismatch with Flannel VXLAN (use WireGuard backend)
- Requires pre-installed Tailscale on host

---

#### Port Conflicts

**Potential Conflicts**:
- k3s API: 6443 (new, no conflict)
- k3s Metrics: 10250 (new, no conflict)
- Ingress Controller: 80, 443 (may conflict with future services)

**Resolution**:
```bash
# Use NodePort services or custom ports
# Or use Traefik as reverse proxy for both k8s and Quadlet services
```

---

## Coexistence with Quadlet Services

### Can k8s and Quadlet Run Together? YES ✅

**How They Coexist**:

```
uCore Host (mouse)
├── Podman (rootless + rootful)
│   ├── Container Storage: /var/lib/containers/storage
│   ├── Quadlet Services:
│   │   ├── rustfs.service (port 9000-9001)
│   │   ├── navidrome.service (port 4533)
│   │   └── syncthing.service (port 8384, 22000)
│   └── Network: Podman CNI
│
└── k3s Cluster
    ├── Container Runtime: containerd (separate from Podman)
    ├── Container Storage: /var/lib/rancher/k3s
    ├── Kubernetes Pods: (new workloads)
    └── Network: Flannel CNI
```

**Key Points**:
1. **Separate Runtimes**: Podman and containerd don't conflict
2. **Separate Storage**: Different backing stores
3. **Shared Network**: Both can use host network or bridge
4. **Shared ZFS**: Both can access `/var/tank` datasets

### Migration Strategy

**Phase 1: Run Both** (Recommended Starting Point)
```
Quadlet Services:          k8s Workloads:
- RustFS (stable)          (none yet)
- Navidrome (stable)
- Syncthing (stable)
- Netdata (monitoring)
```

**Phase 2: Migrate Non-Critical**
```
Quadlet Services:          k8s Workloads:
- RustFS (stable)          - Test app (learning)
- Navidrome (stable)       - Monitoring (Prometheus)
- Syncthing (stable)
```

**Phase 3: Migrate by Preference**
```
Quadlet Services:          k8s Workloads:
- RustFS (if staying)      - Navidrome (if migrated)
                           - New services
```

**Never Migrate** (Good candidates to stay on Quadlet):
- Critical infrastructure (reverse proxy, DNS)
- Services requiring host hardware access
- Long-running stable services you don't want to touch

---

## Migration Path from Current Setup

### Your Current Services

| Service | Current Deployment | Complexity | k8s Migration Priority |
|---------|-------------------|------------|------------------------|
| **RustFS** | Quadlet | Medium | Low (stable, S3 compatible) |
| **Navidrome** | Quadlet | Low | Medium (good k8s learning project) |
| **Syncthing** | Quadlet | Low | Low (works fine as container) |
| **Netdata** | Quadlet | Low | High (replace with Prometheus/Grafana) |
| **MinIO** (future) | NixOS service | Medium | High (excellent k8s Operator available) |

### Migration Example: Navidrome

**Current (Quadlet)**:
```ini
# /etc/containers/systemd/navidrome.container
[Container]
Image=docker.io/deluan/navidrome:latest
PublishPort=4533:4533
Volume=/var/tank/nas/library/music:/music:ro,Z
Volume=/var/tank/services/navidrome/data:/data:Z
Environment=ND_MUSICFOLDER=/music
```

**Migrated (Kubernetes)**:
```yaml
# navidrome-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: navidrome
spec:
  replicas: 1
  selector:
    matchLabels:
      app: navidrome
  template:
    metadata:
      labels:
        app: navidrome
    spec:
      containers:
      - name: navidrome
        image: deluan/navidrome:latest
        ports:
        - containerPort: 4533
        env:
        - name: ND_MUSICFOLDER
          value: /music
        volumeMounts:
        - name: music
          mountPath: /music
          readOnly: true
        - name: data
          mountPath: /data
      volumes:
      - name: music
        hostPath:
          path: /var/tank/nas/library/music  # Shared with Quadlet
          type: Directory
      - name: data
        persistentVolumeClaim:
          claimName: navidrome-data

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: navidrome-data
spec:
  storageClassName: openebs-zfspv
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi

---
apiVersion: v1
kind: Service
metadata:
  name: navidrome
spec:
  type: NodePort
  ports:
  - port: 4533
    targetPort: 4533
    nodePort: 30533  # Or use Ingress
  selector:
    app: navidrome
```

**Benefits of k8s Version**:
- ✅ Declarative YAML (GitOps ready)
- ✅ PVC backed by ZFS (snapshots available)
- ✅ Easy rollback (`kubectl rollout undo`)
- ✅ Ingress integration (HTTPS with cert-manager)

**Cons**:
- ⚠️ More verbose configuration
- ⚠️ Requires understanding of k8s concepts

---

## Recommended Implementation

### Full Stack Recommendation

```
┌─────────────────────────────────────────────┐
│           OS: uCore (stable)                │
│  - ZFS kernel module (pre-installed)        │
│  - Podman + Quadlet (for infra services)    │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│       k3s (single-node cluster)             │
│  - CNI: Flannel WireGuard                   │
│  - Ingress: nginx-ingress                   │
│  - Cert-manager: Let's Encrypt              │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│    Storage: OpenEBS ZFS LocalPV             │
│  - Pool: tank/k8s                           │
│  - Features: Snapshots, compression, resize │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│         GitOps: Flux CD                     │
│  - Git repo: rwaltr/home-ops                │
│  - Auto-sync: kubernetes/ directory         │
│  - Auto-update: Renovate bot                │
└─────────────────────────────────────────────┘
```

### Step-by-Step Setup

#### 1. Install k3s

```bash
# SSH to mouse
ssh rwaltr@mouse

# Install k3s with optimized settings
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" sh -s - server \
  --disable=traefik \
  --disable=servicelb \
  --flannel-backend=wireguard-native \
  --write-kubeconfig-mode=644 \
  --node-taint='' \
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16

# Verify
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```

#### 2. Install OpenEBS ZFS CSI

```bash
# Create ZFS dataset for k8s
zfs create tank/k8s

# Install OpenEBS
kubectl apply -f https://openebs.github.io/charts/openebs-operator.yaml

# Wait for pods
kubectl wait --for=condition=ready pod -l app=openebs -n openebs --timeout=300s

# Create default StorageClass
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-zfspv
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
allowVolumeExpansion: true
parameters:
  recordsize: "128k"
  compression: "lz4"
  dedup: "off"
  fstype: "zfs"
  poolname: "tank/k8s"
provisioner: zfs.csi.openebs.io
volumeBindingMode: WaitForFirstConsumer
EOF
```

#### 3. Install nginx-ingress

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/baremetal/deploy.yaml

# Expose on host ports 80/443
kubectl patch service ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":80,"nodePort":30080,"protocol":"TCP"},{"name":"https","port":443,"targetPort":443,"nodePort":30443,"protocol":"TCP"}]}}'
```

#### 4. Install cert-manager (Optional, for Let's Encrypt)

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
```

#### 5. Install Flux (GitOps)

```bash
# From your laptop (not mouse)
flux bootstrap github \
  --owner=rwaltr \
  --repository=home-ops \
  --branch=main \
  --path=kubernetes/clusters/mouse \
  --personal
```

**Directory Structure** (create in your repo):
```
home-ops/
├── infra/
│   ├── nix/          # Existing NixOS configs
│   └── ucore/        # Existing uCore configs
└── kubernetes/       # NEW
    ├── clusters/
    │   └── mouse/
    │       ├── flux-system/
    │       └── infrastructure.yaml
    └── apps/
        ├── media/
        │   └── navidrome/
        │       ├── deployment.yaml
        │       ├── service.yaml
        │       └── kustomization.yaml
        └── monitoring/
            └── prometheus/
```

#### 6. Deploy First App

```bash
# Create namespace
kubectl create namespace media

# Deploy Navidrome
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: navidrome-data
  namespace: media
spec:
  storageClassName: openebs-zfspv
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: navidrome
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: navidrome
  template:
    metadata:
      labels:
        app: navidrome
    spec:
      containers:
      - name: navidrome
        image: deluan/navidrome:latest
        ports:
        - containerPort: 4533
        env:
        - name: ND_MUSICFOLDER
          value: /music
        - name: ND_DATADIR
          value: /data
        volumeMounts:
        - name: music
          mountPath: /music
          readOnly: true
        - name: data
          mountPath: /data
      volumes:
      - name: music
        hostPath:
          path: /var/tank/nas/library/music
          type: Directory
      - name: data
        persistentVolumeClaim:
          claimName: navidrome-data
---
apiVersion: v1
kind: Service
metadata:
  name: navidrome
  namespace: media
spec:
  type: NodePort
  ports:
  - port: 4533
    targetPort: 4533
    nodePort: 30533
  selector:
    app: navidrome
EOF

# Access at http://mouse:30533
```

---

## Kubernetes vs Podman Quadlet Decision Matrix

### When to Choose Kubernetes

✅ **Use k8s if you...**
- Want to learn/practice Kubernetes skills
- Value GitOps workflows (Flux/ArgoCD)
- Plan to run 10+ microservices
- Need advanced storage (snapshots, clones, resize)
- Might scale to multi-node later
- Want to use Helm charts and Operators
- Appreciate declarative infrastructure

### When to Choose Podman Quadlet

✅ **Use Quadlet if you...**
- Run 5 or fewer services
- Value simplicity over features
- Are comfortable with systemd
- Don't need Kubernetes-specific features
- Want minimal resource overhead
- Prefer simple `.container` files over YAML manifests
- Don't need multi-replica deployments

### Hybrid Approach (RECOMMENDED)

✅ **Best of Both Worlds**:
- **Quadlet**: Infrastructure services (Traefik, Pi-hole, backup)
- **k8s**: Application workloads (databases, web apps, cron jobs)

**Example Split**:
```
Quadlet Services:
- Traefik (reverse proxy for everything)
- Tailscale (VPN mesh)
- Backup tools (restic, rclone)

k8s Workloads:
- Navidrome (media streaming)
- PostgreSQL (databases)
- Web apps (wiki, dashboard, etc.)
- Monitoring (Prometheus/Grafana)
```

---

## Common Pitfalls & Solutions

### 1. SELinux Denials

**Problem**: Pods fail to start with permission errors
**Solution**:
```bash
# Install k3s-selinux (only needed on first install)
curl -sfL https://get.k3s.io | sh -s - server --selinux

# Or disable SELinux (not recommended)
setenforce 0
```

### 2. Node Taints (Single-Node)

**Problem**: Pods stuck in Pending (control-plane taint prevents scheduling)
**Solution**:
```bash
# Install without taints
curl -sfL https://get.k3s.io | sh -s - server --node-taint=''

# Or remove taint after install
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### 3. Resource Starvation

**Problem**: Host runs out of memory with k8s + Quadlet services
**Solution**:
```yaml
# Set resource limits on k8s pods
resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "500m"

# Reserve resources for system in kubelet config
# /etc/rancher/k3s/kubelet.config
systemReserved:
  memory: 1Gi
  cpu: 500m
```

### 4. ZFS Dataset Permissions

**Problem**: Pods can't write to ZFS volumes
**Solution**:
```bash
# Set correct permissions on parent dataset
zfs set acltype=posixacl tank/k8s
zfs set xattr=sa tank/k8s

# Or use fsGroup in pod spec
spec:
  securityContext:
    fsGroup: 1000
```

### 5. Automatic Updates Breaking k8s

**Problem**: uCore OS update changes k3s compatibility
**Solution**:
```bash
# Pin k3s version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.30.0+k3s1" sh -

# Or use k3s auto-upgrade controller
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml
```

---

## Monitoring & Management

### Recommended Tools

1. **k9s**: Terminal UI for Kubernetes
```bash
# Install on laptop
brew install k9s
# Or on mouse
curl -sS https://webi.sh/k9s | sh

# Use
k9s
```

2. **Lens Desktop**: GUI for k8s
```bash
# Install on laptop
brew install --cask lens
```

3. **Prometheus + Grafana**: Monitoring stack
```bash
# Install kube-prometheus-stack via Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

---

## Next Steps

### Immediate Actions

1. **Test in VM first**:
   ```bash
   mise run ucore:vm mouse-k8s-test
   # Follow installation steps above in VM
   ```

2. **Read Official Docs**:
   - [k3s Documentation](https://docs.k3s.io/)
   - [OpenEBS ZFS LocalPV](https://openebs.io/docs/user-guides/local-storage-user-guide/local-pv-zfs/zfs-overview)
   - [Flux Getting Started](https://fluxcd.io/flux/get-started/)

3. **Join Communities**:
   - [k8s-at-home Discord](https://discord.gg/k8s-at-home)
   - [r/selfhosted](https://reddit.com/r/selfhosted)
   - [Home Operations Discord](https://discord.gg/home-operations)

### Long-Term Considerations

- **Backup Strategy**: Use Velero for k8s-native backups
- **Secrets Management**: Consider external-secrets-operator + sops
- **Multi-Node**: If adding nodes, switch to distributed storage (Rook-Ceph, Longhorn)
- **High Availability**: Consider 3-node control plane for production

---

## References

### Official Documentation
- [k3s Documentation](https://docs.k3s.io/)
- [Fedora CoreOS](https://docs.fedoraproject.org/en-US/fedora-coreos/)
- [Universal Blue uCore](https://github.com/ublue-os/ucore)
- [OpenEBS ZFS LocalPV](https://openebs.io/docs/user-guides/local-storage-user-guide/local-pv-zfs/zfs-overview)
- [Kubernetes CSI](https://kubernetes-csi.github.io/docs/)

### Community Resources
- [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template) - Popular Talos + k3s template
- [k8s-at-home Search](https://nanne.dev/k8s-at-home-search/) - Helm chart search
- [awesome-home-kubernetes](https://github.com/k8s-at-home/awesome-home-kubernetes)

### Related Blog Posts
- [Lawrence Gripper: Zero Toil Homelab](http://blog.gripdev.xyz/2024/03/16/in-search-of-a-zero-toil-homelab-with-immutable-linux/)
- [Major Hayden: Podman Quadlet Auto-Updates](https://major.io/p/podman-quadlet-automatic-updates/)
- [Daniel Melzak: uCore Server Setup](https://daniel.melzaks.com/guides/ucore-server-setup/)

---

## Conclusion

**For your specific use case (single-node homelab on uCore with ZFS and Tailscale):**

**Recommended Path**: Start with **Podman Quadlet** for simplicity, add **k3s** when you want to learn k8s or need advanced features.

**Optimal Hybrid Stack**:
```
uCore + Podman Quadlet (infrastructure)
         +
uCore + k3s + OpenEBS ZFS (applications)
```

This gives you the best of both worlds: simple, reliable infrastructure services via Quadlet, and flexible, powerful application orchestration via Kubernetes.

**Time Investment Estimate**:
- Quadlet-only approach: 2-4 hours setup
- k3s + GitOps approach: 8-16 hours initial setup + learning curve
- Hybrid approach: Start Quadlet (2-4h), add k3s later (4-8h)

Choose based on your goals: **learning k8s** (go k3s) vs **getting services running** (go Quadlet).
