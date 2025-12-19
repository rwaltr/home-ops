<!-- Header -->
<div align="center">

<img src="https://raw.githubusercontent.com/rwaltr/branding/master/vector/logoisolated.png" align="center" width="144px" height="144px"/>

# rwaltr/home-ops

_NixOS-powered homelab infrastructure with Terraform cloud management_

</div>

<!-- Shields -->
<div align="center">

[![Discord](https://img.shields.io/discord/673534664354430999?style=for-the-badge&label=discord&logo=discord&logoColor=white)](https://discord.gg/k8s-at-home)
[![NixOS](https://img.shields.io/badge/NixOS-24.05-blue?style=for-the-badge&logo=nixos&logoColor=white)](https://nixos.org/)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white&style=for-the-badge)](https://github.com/pre-commit/pre-commit)

</div>

<!-- Main Description -->

## 📖 Overview

This is a monorepo to manage my personal homelab infrastructure. Currently running a single NixOS host ("mouse") combined with Terraform for cloud resource management. The infrastructure provides file storage (ZFS, NFS), media services (Navidrome), synchronization (Syncthing), and backup capabilities (MinIO, Backblaze B2).

## 🔧 Infrastructure Components

### ❄️ NixOS

NixOS provides declarative host configuration management. The main host "mouse" is defined in `infra/nix/hosts/mouse/` with configurations for ZFS, MinIO, Syncthing, Navidrome, NFS, and monitoring.

Entry point: `flake.nix`

### 🌐 Terraform

Terraform manages cloud resources through GitOps:
- **Cloudflare**: DNS and domain management (`infra/terraform/cloudflare/`)
- **Backblaze B2**: Backup storage provisioning (`infra/terraform/backblaze/`)

### 🔐 SOPS

Age-based secrets management for encrypting sensitive configuration values inline with repository files.

## 🖥️ Current Host

### mouse (NixOS)

Primary infrastructure host running:
- **Storage**: ZFS pools, NFS server
- **Media**: Navidrome music server
- **Sync**: Syncthing for file synchronization
- **Object Storage**: MinIO for S3-compatible storage
- **Monitoring**: Netdata for system metrics
- **Networking**: Tailscale for VPN mesh

Configuration: `infra/nix/hosts/mouse/`

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

| Tool            | Use                        | Active |
| --------------- | -------------------------- | ------ |
| NixOS           | Operating System           | ☑️     |
| SOPS            | Secrets Management         | ☑️     |
| Terraform       | Cloud Resource Management  | ☑️     |
| Flakes          | Nix Dependency Management  | ☑️     |
| ZFS             | Storage & Snapshots        | ☑️     |
| MinIO           | S3-compatible Storage      | ☑️     |
| Syncthing       | File Synchronization       | ☑️     |
| Navidrome       | Music Streaming Server     | ☑️     |
| Netdata         | System Monitoring          | ☑️     |
| Tailscale       | VPN Mesh Network           | ☑️     |
| Pre-commit      | Code Quality Automation    | ☑️     |

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

## 🔏 License

See [LICENSE](./LICENSE)

---
