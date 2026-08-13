<div align="center">

<img src="https://raw.githubusercontent.com/rwaltr/branding/master/vector/logo.svg" width="144px" height="144px"/>

# home-ops

### _Flatcar · k0s · Cilium — GitOps homelab, cloud-managed with Terraform/Pulumi_

[![Discord](https://img.shields.io/discord/673534664354430999?style=for-the-badge&label=discord&logo=discord&logoColor=white)](https://discord.gg/k8s-at-home)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white&style=for-the-badge)](https://github.com/pre-commit/pre-commit)
[![last-commit](https://img.shields.io/github/last-commit/rwaltr/home-ops?style=for-the-badge&logo=git&logoColor=white)](https://github.com/rwaltr/home-ops/commits/master)
[![stars](https://img.shields.io/github/stars/rwaltr/home-ops?style=for-the-badge&logo=github)](https://github.com/rwaltr/home-ops/stargazers)
[![k0s](https://img.shields.io/badge/k0s-v1.36-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)](https://k0sproject.io/)

</div>

## 📖 Overview

Monorepo for my personal homelab. The main host (**mouse**) runs Flatcar Container Linux (immutable OS) with a single-node k0s + Cilium cluster; cloud resources are managed with Terraform (migrating to Pulumi). Services include object storage (RustFS), monitoring (Netdata), and backups (Backblaze B2).

> 🗺️ Migration plan, decisions log, and lessons: **[REFACTOR_PLANS.md](REFACTOR_PLANS.md)**

```
Flatcar (ZFS sysext) → k0sctl/k0s → Cilium (BGP) → Envoy Gateway → Flux
```

## 🗂️ Repository Structure

| Path               | Purpose                                                      |
| ------------------ | ------------------------------------------------------------ |
| `infra/flatcar/`   | Butane → Ignition host configs (`base.bu` + per-host)        |
| `infra/k0s/`       | k0sctl cluster definitions                                   |
| `infra/terraform/` | Cloudflare, Backblaze B2, Terraform Cloud (maintenance mode) |
| `infra/shared/`    | Shared SOPS-encrypted config                                 |
| `.mise/tasks/`     | Task automation (flatcar VM lifecycle, terraform)            |

## 🔧 Infrastructure

### 🚗 Flatcar

Immutable, container-first host OS configured in `infra/flatcar/` via Butane → Ignition. A shared `base.bu` (users, Tailscale, mDNS, update policy) merges into per-host configs. ZFS comes from the official systemd-sysext; the tank pool is created by hand and **imported** by Ignition.

Raw qemu test VMs (no libvirt) validate every config end-to-end. Tasks take a host argument (`test` = scratch VM, `mouse` = mirrors production):

```bash
mise run flatcar:bootstrap mouse  # full env: boot → seed tank → verify → k0s + Cilium + nginx
mise run flatcar:vm test          # build ignition, download image, boot VM
mise run flatcar:verify test      # verify ZFS sysext, pool, VLAN over SSH
mise run flatcar:k0s test         # install k0s + Cilium, nginx smoke test
mise run flatcar:seed mouse       # hand-create tank like bare metal, then reboot
mise run flatcar:clean test       # destroy VM and disks
```

### ☸️ Kubernetes (k0s)

Single-node k0s cluster on mouse (v1.36, Cilium as kube-proxy replacement), managed via k0sctl configs in `infra/k0s/`. GitOps layout (Flux + helmfile bootstrap, modeled on [onedr0p/home-ops](https://github.com/onedr0p/home-ops)) is the next migration phase.

### 🌐 Terraform

Cloud resources in maintenance mode — migrating to Pulumi:

- **Cloudflare** — DNS and domain management (`infra/terraform/cloudflare/`)
- **Backblaze B2** — backup storage provisioning (`infra/terraform/backblaze/`)
- **Terraform Cloud** — workspace management (`infra/terraform/tf-cloud/`)

### 🚀 Pulumi

Planned migration target for cloud resources (Go). Early stubs were pruned; `infra/pulumi/` will be recreated when this migration becomes active.

### 🔐 SOPS

Age-based secrets management — sensitive values are encrypted inline alongside repository files.

## 🖥️ Current Host

**mouse** (Flatcar) — primary infrastructure host:

| Role           | Details                                   |
| -------------- | ----------------------------------------- |
| Storage        | ZFS tank pool (raidz1×2, `/var/tank`)     |
| Kubernetes     | single-node k0s + Cilium                  |
| Object Storage | RustFS (S3-compatible, moving in-cluster) |
| Monitoring     | Netdata (moving in-cluster)               |
| Access         | Tailscale + mDNS (`mouse.local`)          |

Config: `infra/flatcar/butane/hosts/mouse.bu`

## ☁️ Cloud Integrations

- **Cloudflare** — DNS and domain management (familylegacy, legacy, prof, public zones)
- **Backblaze B2** — S3-compatible backup storage for long-term retention

## 🧰 Tools

| Tool       | Use                          | Status           |
| ---------- | ---------------------------- | ---------------- |
| Flatcar    | Operating System             | ✅               |
| k0s        | Kubernetes (single-node)     | ✅               |
| Cilium     | CNI (kube-proxy replacement) | ✅               |
| ZFS        | Storage & Snapshots          | ✅               |
| SOPS       | Secrets Management           | ✅               |
| Terraform  | Cloud Resource Management    | ✅ (maintenance) |
| Pulumi     | Cloud Resource Management    | 🚧 planned       |
| RustFS     | S3-compatible Storage        | ✅               |
| Netdata    | System Monitoring            | ✅               |
| mise       | Task Runner & Tool Mgmt      | ✅               |
| Pre-commit | Code Quality Automation      | ✅               |

## 🖊️ TODOs

In-code TODOs use the `TODO:` format — [search the repo](https://github.com/rwaltr/home-ops/search?q=TODO%3A).

---

<div align="center">

**🤟 Thanks** — [onedr0p](https://github.com/onedr0p) · [anthr76](https://github.com/anthr76) · [danmanners](https://github.com/danmanners) for inspiration
**🌐 Community** — [k8s-at-home Discord](https://discord.gg/k8s-at-home)
**📬 Contact** — GitHub Issues · Email
**📜 Changelog** — [commit history](https://github.com/rwaltr/home-ops/commits/master)

</div>
