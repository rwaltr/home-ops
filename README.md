<!-- Header -->
<div align="center">

<img src="https://raw.githubusercontent.com/rwaltr/branding/master/vector/logo.svg" align="center" width="144px" height="144px"/>

# rwaltr/home-ops

_Flatcar + k0s + Cilium homelab infrastructure with Terraform/Pulumi cloud management_

</div>

<!-- Shields -->
<div align="center">

[![Discord](https://img.shields.io/discord/673534664354430999?style=for-the-badge&label=discord&logo=discord&logoColor=white)](https://discord.gg/k8s-at-home)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white&style=for-the-badge)](https://github.com/pre-commit/pre-commit)

</div>

<!-- Main Description -->

## 📖 Overview

This is a monorepo to manage my personal homelab infrastructure. Running Flatcar Container Linux (immutable OS) on the main host ("mouse") with a single-node k0s + Cilium cluster, and Terraform/Pulumi for cloud resource management. The infrastructure provides object storage (RustFS), monitoring (Netdata), and backup capabilities (Backblaze B2).

Migration plan and decisions: [REFACTOR_PLANS.md](REFACTOR_PLANS.md)

## 🔧 Infrastructure Components

### 🚗 Flatcar

Flatcar Container Linux provides immutable, container-first host configuration. Configured in `infra/flatcar/` using Butane → Ignition: shared `base.bu` (users, tailscale, mDNS, update policy) merged into per-host configs. ZFS via the official systemd-sysext; the tank pool is created by hand and **imported** by Ignition.

Raw qemu (no libvirt) test VMs validate every config end-to-end. Tasks take a host argument (`test` = scratch VM, `mouse` = mirrors the production host):

```bash
mise run flatcar:bootstrap mouse  # full env: boot → seed tank → verify → k0s + Cilium + nginx
mise run flatcar:vm test          # build ignition, download image, boot VM
mise run flatcar:verify test      # verify ZFS sysext, pool, VLAN over SSH
mise run flatcar:k0s test         # install k0s + Cilium, nginx smoke test
mise run flatcar:seed mouse       # hand-create tank like bare metal, then reboot
mise run flatcar:clean test       # destroy VM and disks
```

Entry point: `infra/flatcar/butane/`

### ☸️ Kubernetes (k0s)

Single-node k0s cluster on mouse (v1.36, Cilium kube-proxy replacement), managed via k0sctl configs in `infra/k0s/`. GitOps layout (Flux + helmfile bootstrap, modeled on onedr0p/home-ops) is the next migration phase — see REFACTOR_PLANS.md.

Entry point: `infra/k0s/`

### 🌐 Terraform

Terraform manages cloud resources (maintenance mode — migrating to Pulumi):

- **Cloudflare**: DNS and domain management (`infra/terraform/cloudflare/`)
- **Backblaze B2**: Backup storage provisioning (`infra/terraform/backblaze/`)
- **Terraform Cloud**: Workspace management (`infra/terraform/tf-cloud/`)

### 🚀 Pulumi

Pulumi stubs created for migrating cloud resources from Terraform (Go-based):

- **Backblaze**: B2 provisioning (`infra/pulumi/backblaze/`) — has initial Go code
- **Cloudflare**: DNS management (`infra/pulumi/cloudflare/`) — stub
- **Terraform Cloud**: Workspace management (`infra/pulumi/tf-cloud/`) — stub

### 🔐 SOPS

Age-based secrets management for encrypting sensitive configuration values inline with repository files.

## 🖥️ Current Host

### mouse (Flatcar)

Primary infrastructure host running:

- **Storage**: ZFS tank pool (raidz1×2, mounted at /var/tank)
- **Kubernetes**: single-node k0s + Cilium
- **Object Storage**: RustFS (S3-compatible, moving in-cluster)
- **Monitoring**: Netdata (moving in-cluster)
- **Access**: Tailscale + mDNS (`mouse.local`)

Configuration: `infra/flatcar/butane/hosts/mouse.bu`

## 🌐 Cloud Integrations

### Cloudflare

DNS and domain management for multiple domains (familylegacy, legacy, prof, public zones)

### Backblaze B2

S3-compatible backup storage for long-term data retention

<!-- TODO items -->

## 🖊️ Finding TODOS

<!-- prosemd: ignore -->

[Uses the `TODO:` format in line](https://github.com/rwaltr/home-ops/search?q=TODO%3A)

---

<!-- Tools -->

## 🧰 Tools

| Tool       | Use                        | Active |
| ---------- | -------------------------- | ------ |
| Flatcar    | Operating System           | ☑️     |
| k0s        | Kubernetes (single-node)   | ☑️     |
| Cilium     | CNI (kube-proxy replacement)| ☑️    |
| SOPS       | Secrets Management         | ☑️     |
| Terraform  | Cloud Resource Management  | ☑️     |
| Pulumi     | Cloud Resource Management  | 🚧     |
| ZFS        | Storage & Snapshots        | ☑️     |
| RustFS     | S3-compatible Storage      | ☑️     |
| Netdata    | System Monitoring          | ☑️     |
| Pre-commit | Code Quality Automation    | ☑️     |
| mise       | Task Runner & Tool Mgmt    | ☑️     |

---

<!-- Thanks -->

## 🤟 Thanks

Thank you to the below for inspiration

- onedr0p
- anthr76
- danmanners

---

<!-- Communities -->

## 🌐 Communities

### K8s-at-Home

[![Discord](https://img.shields.io/discord/673534664354430999?style=for-the-badge&label=discord&logo=discord&logoColor=white)](https://discord.gg/k8s-at-home)

---

<!-- Contact -->

## 📬 Contact Me

- Github Issues
- Email

---

## 📜 Changelog

See [commit history](https://github.com/rwaltr/home-ops/commits/master)

---
