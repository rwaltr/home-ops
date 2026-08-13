<!-- Header -->
<div align="center">

<img src="https://raw.githubusercontent.com/rwaltr/branding/master/vector/logo.svg" align="center" width="144px" height="144px"/>

# rwaltr/home-ops

_Universal Blue uCore homelab infrastructure with Terraform/Pulumi cloud management_

</div>

<!-- Shields -->
<div align="center">

[![Discord](https://img.shields.io/discord/673534664354430999?style=for-the-badge&label=discord&logo=discord&logoColor=white)](https://discord.gg/k8s-at-home)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white&style=for-the-badge)](https://github.com/pre-commit/pre-commit)

</div>

<!-- Main Description -->

## 📖 Overview

This is a monorepo to manage my personal homelab infrastructure. Running Universal Blue uCore (Fedora CoreOS-based immutable OS) on the main host ("mouse") with Terraform/Pulumi for cloud resource management. The infrastructure provides object storage (RustFS), monitoring (Netdata), and backup capabilities (Backblaze B2).

## 🔧 Infrastructure Components

### 🔵 uCore

Universal Blue uCore provides immutable, container-first host configuration. Configuration in `infra/ucore/` using Butane → Ignition.

- [uCore Overview](infra/ucore/README.md)
- [Container Architecture](infra/ucore/CONTAINERS.md)
- [Deployment Strategies](infra/ucore/DEPLOYMENT.md)

Entry point: `infra/ucore/butane/`

### 🚗 Flatcar (active experiment)

Flatcar Container Linux test VMs for evaluating a uCore replacement. Raw qemu (no libvirt) VMs with ZFS via systemd-sysext and a k0s + Cilium cluster smoke test. Tasks take a host argument (`test` = scratch VM, `mouse` = mirrors the production host):

```bash
mise run flatcar:vm test      # build ignition, download image, boot VM
mise run flatcar:verify test  # verify ZFS sysext, pool, VLAN over SSH
mise run flatcar:k0s test     # install k0s + Cilium, nginx smoke test
mise run flatcar:vm mouse     # boot the mouse config (import-only ZFS)
mise run flatcar:seed mouse   # hand-create tank like bare metal, then reboot
mise run flatcar:clean test   # destroy VM and disks
```

Entry point: `infra/flatcar/butane/`

### ☸️ Kubernetes (k0s)

Single-node k0s cluster planned for mouse. Configuration managed via k0sctl.

- [Kubernetes on uCore](infra/ucore/KUBERNETES.md)

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

### mouse (uCore)

Primary infrastructure host running:

- **Storage**: ZFS pools
- **Object Storage**: RustFS (S3-compatible, Rust-based)
- **Monitoring**: Netdata for system metrics

Configuration: `infra/ucore/butane/hosts/mouse.bu`

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
| uCore      | Operating System           | ☑️     |
| Flatcar    | Operating System (testing) | 🚧     |
| SOPS       | Secrets Management         | ☑️     |
| Terraform  | Cloud Resource Management  | ☑️     |
| Pulumi     | Cloud Resource Management  | 🚧     |
| ZFS        | Storage & Snapshots        | ☑️     |
| RustFS     | S3-compatible Storage      | ☑️     |
| Netdata    | System Monitoring          | ☑️     |
| k0s        | Kubernetes (single-node)   | 🚧     |
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
