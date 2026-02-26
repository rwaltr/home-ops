# Kubernetes on uCore: Single-Node k0s Deployment

## Executive Summary

This document covers running a single-node Kubernetes cluster on mouse using **k0s** on uCore. k0s was chosen over k3s for its vanilla upstream Kubernetes experience, lower CPU overhead, and zero-opinion approach (no bundled ingress/LB).

**Stack**: **uCore + k0s (single-node) + OpenEBS ZFS LocalPV + Helm**

**Current State**: ✅ Deployed. k0s v1.35.1+k0s.0 running on mouse (Tailscale: 100.82.231.96). Kubeconfig at `~/.kube/mouse-config`.

---

## Table of Contents

- [Why k0s](#why-k0s)
- [Current Configuration](#current-configuration)
- [Installation](#installation)
- [Storage Integration](#storage-integration)
- [Networking Considerations](#networking-considerations)
- [Coexistence with Quadlet Services](#coexistence-with-quadlet-services)
- [First Workload: RustFS](#first-workload-rustfs)
- [References](#references)

---

## Why k0s

### Decision Rationale

k0s was chosen over k3s and other distributions for this single-node homelab:

| Factor | k0s | k3s |
|--------|-----|-----|
| **Upstream k8s** | Vanilla — no bundled ingress/LB/CNI opinions | Ships Traefik + ServiceLB + Flannel |
| **CPU overhead** | ~12% lower in benchmarks | Slightly higher |
| **Binary** | Single binary, ~240MB | Single binary, ~70MB |
| **RAM idle** | ~650MB | ~500-750MB |
| **Install** | `curl \| sh` + `k0s install` | `curl \| sh` |
| **SELinux** | Works on Fedora CoreOS | Needs `k3s-selinux` package |
| **Expandable** | `--enable-worker --no-taints` retains multi-node option | Always expandable |

**Other distributions considered and rejected:**

- **Talos Linux**: Replaces uCore entirely — incompatible
- **microk8s**: Requires snap — not available on CoreOS
- **kubeadm**: Too heavy for single-node

---

## Current Configuration

A k0sctl cluster definition exists at `infra/k0s/kyz.yaml`:

```yaml
# Key settings from kyz.yaml
apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: k0s-cluster
spec:
  hosts:
    - ssh:
        address: 192.168.122.76  # VM IP — update for production
        user: rwaltr
      role: controller+worker
  k0s:
    config:
      spec:
        network:
          provider: kuberouter
          podCIDR: 10.244.0.0/16
          serviceCIDR: 10.96.0.0/12
        storage:
          type: etcd
```

**Note**: The SSH address (`192.168.122.76`) is a VM address. Update to the production IP or Tailscale address before deploying.

### Repo Structure (Current)

```
home-ops/
├── infra/
│   ├── k0s/
│   │   └── kyz.yaml        # k0sctl cluster definition
│   └── ucore/              # Host config (butane, quadlets)
```

### Planned Repo Structure

```
home-ops/
├── infra/
│   ├── k0s/
│   │   ├── kyz.yaml        # k0sctl cluster definition
│   │   ├── bootstrap/      # k0s install scripts / butane integration
│   │   └── apps/
│   │       └── rustfs/
│   │           ├── values.yaml
│   │           └── secret.sops.yaml
│   └── ucore/              # Host config (butane, quadlets)
```

---

## Installation

### Using k0sctl (Recommended)

```bash
# Install from workstation using k0sctl
k0sctl apply --config infra/k0s/kyz.yaml

# Get kubeconfig
k0sctl kubeconfig --config infra/k0s/kyz.yaml > ~/.kube/mouse-config

# Verify
export KUBECONFIG=~/.kube/mouse-config
kubectl get nodes
```

### Manual Install on Host

```bash
ssh rwaltr@mouse

# Download k0s binary
curl --proto '=https' --tlsv1.2 -sSf https://get.k0s.sh | sudo sh

# Install as single-node (controller + worker)
sudo k0s install controller --single

# Start the service
sudo k0s start

# Verify
sudo k0s status
sudo k0s kubectl get nodes
```

**Data location**: `/var/lib/k0s` (persists across OS updates)

### Remote Access (kubeconfig)

```bash
# On mouse — export kubeconfig
sudo k0s kubeconfig admin > /tmp/k0s-kubeconfig.yaml

# On workstation — copy and adjust
scp rwaltr@mouse:/tmp/k0s-kubeconfig.yaml ~/.kube/mouse-config
# Edit server URL to production/Tailscale IP
export KUBECONFIG=~/.kube/mouse-config
kubectl get nodes
```

### Firewall

Open the k0s API and NodePort range:

```bash
sudo firewall-cmd --permanent --add-port=6443/tcp        # k8s API
sudo firewall-cmd --permanent --add-port=30000-32767/tcp  # NodePorts
sudo firewall-cmd --reload
```

---

## Storage Integration

### Current ZFS Layout

```
tank (raidz1)
└── /var/tank    # Single root dataset
```

**Planned layout:**

```
tank
├── k8s/               # NEW: Kubernetes PVCs (OpenEBS ZFS LocalPV)
│   └── pvc-<uuid>/    # Auto-created per PVC
├── services/           # Quadlet service data
└── nas/                # Media library
```

### Setup ZFS for Kubernetes

```bash
ssh rwaltr@mouse
sudo zfs create tank/k8s
sudo zfs set compression=lz4 tank/k8s
sudo zfs set recordsize=128k tank/k8s
sudo zfs set acltype=posixacl tank/k8s
sudo zfs set xattr=sa tank/k8s
```

### OpenEBS ZFS LocalPV ⭐ RECOMMENDED

Native CSI driver that provisions ZFS datasets as PVs. No network overhead, full ZFS feature set.

```bash
kubectl apply -f https://openebs.github.io/charts/openebs-operator.yaml
kubectl wait --for=condition=ready pod -l app=openebs -n openebs --timeout=300s
```

**Default StorageClass:**

```yaml
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
```

**Snapshot support:**

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: zfs-snapclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
driver: zfs.csi.openebs.io
deletionPolicy: Delete
```

---

## Networking Considerations

### CNI

k0s ships with kube-router as the default CNI. For single-node this is fine — no need to swap in Cilium or Calico unless you want network policy observability later.

### Ports

| Port | Use | Firewall |
|------|-----|----------|
| 6443 | k8s API | Open (or Tailscale only) |
| 30000-32767 | NodePort range | Open as needed |
| 10250 | kubelet metrics | Internal only |

---

## Coexistence with Quadlet Services

k0s uses containerd, Quadlet uses Podman — separate runtimes, separate storage, no conflicts.

```
uCore Host (mouse)
├── Podman + Quadlet
│   ├── Storage: /var/lib/containers/storage
│   └── Services: netdata (host monitoring)
│
└── k0s Cluster
    ├── Runtime: containerd
    ├── Storage: /var/lib/k0s
    ├── PVs: tank/k8s (OpenEBS ZFS)
    └── Workloads: rustfs, future services
```

**Strategy**: New services go into k0s. Netdata stays as a Quadlet (needs privileged host access for monitoring). Infrastructure services requiring direct host access remain Quadlet.

---

## First Workload: RustFS

RustFS is a Rust-based S3-compatible object storage server. It has an official Helm chart with standalone mode support.

### Helm Chart

- **Source**: `https://github.com/rustfs/rustfs/tree/main/helm/rustfs`
- **App version**: 1.0.0-alpha (still alpha — pin versions)

### Standalone Values

```yaml
# values.yaml for single-node RustFS
replicaCount: 1

mode:
  standalone:
    enabled: true
  distributed:
    enabled: false

secret:
  existingSecret: "rustfs-credentials"  # Create separately via SOPS

service:
  type: NodePort
  endpoint:
    port: 9000
    nodePort: 32000
  console:
    port: 9001
    nodePort: 32001

ingress:
  enabled: false  # NodePort access for now

storageclass:
  name: openebs-zfspv
  dataStorageSize: 500Gi
  logStorageSize: 1Gi

resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "1Gi"
    cpu: "2000m"
```

### Secrets (SOPS-encrypted)

Create `infra/k0s/apps/rustfs/secret.sops.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rustfs-credentials
  namespace: rustfs
type: Opaque
stringData:
  RUSTFS_ACCESS_KEY: <real-key>
  RUSTFS_SECRET_KEY: <real-secret>
```

Encrypt: `sops -e -i infra/k0s/apps/rustfs/secret.sops.yaml`

### Deploy

```bash
# Create namespace
kubectl create namespace rustfs

# Apply decrypted secret
sops -d infra/k0s/apps/rustfs/secret.sops.yaml | kubectl apply -f -

# Install chart
helm install rustfs ./helm/rustfs \
  --namespace rustfs \
  -f infra/k0s/apps/rustfs/values.yaml

# Verify
kubectl get pods -n rustfs
curl http://mouse:32000/health
```

Console available at `http://mouse:32001`.

---

## Troubleshooting

### SELinux Denials

k0s generally works with SELinux enforcing on Fedora CoreOS. If pods fail:

```bash
# Check for denials
sudo ausearch -m AVC -ts recent
# Temporary test (not recommended for production)
sudo setenforce 0
```

### Node Taints

With `--single`, k0s doesn't apply control-plane taints. If pods are Pending:

```bash
sudo k0s kubectl describe node | grep Taints
sudo k0s kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### ZFS Volume Permissions

```bash
# Ensure ACL support
sudo zfs get acltype,xattr tank/k8s

# Use fsGroup in pod spec
spec:
  securityContext:
    fsGroup: 10001  # RustFS UID
```

### k0s Service Issues

```bash
sudo k0s status
sudo journalctl -u k0scontroller -f
sudo k0s kubectl get events --all-namespaces --sort-by='.lastTimestamp'
```

---

## References

- [k0s Documentation](https://docs.k0sproject.io/stable/)
- [k0s on Fedora CoreOS](https://docs.k0sproject.io/stable/system-requirements/)
- [k0sctl Documentation](https://github.com/k0sproject/k0sctl)
- [OpenEBS ZFS LocalPV](https://openebs.io/docs/user-guides/local-storage-user-guide/local-pv-zfs/zfs-overview)
- [RustFS Helm Chart](https://github.com/rustfs/rustfs/tree/main/helm/rustfs)
- [Fedora CoreOS Docs](https://docs.fedoraproject.org/en-US/fedora-coreos/)
- [Universal Blue uCore](https://github.com/ublue-os/ucore)
