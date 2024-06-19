<!-- Header -->
<div align="center">

# 🚧 Please pardon the dust 🚧

The homelab is currently undergoing operation "Honey I Shrunk The Homelab". See Issues for progress

## <img src="https://external-content.duckduckgo.com/iu/?u=http%3A%2F%2Fvignette3.wikia.nocookie.net%2Ffossils-archeology%2Fimages%2Fd%2Fdf%2FPatrick_star.png%2Frevision%2Flatest%3Fcb%3D20160401153603&f=1&nofb=1&ipt=41964821b231f453e9d0e60b9af655c8566587350449513761e03ff04ab50e66&ipo=images" align="center" width="244px" height="244px"/>

<img src="https://raw.githubusercontent.com/rwaltr/branding/master/vector/logoisolated.png" align="center" width="144px" height="144px"/>

# rwaltr/home-ops

</div>

<!-- Shields -->
<div align="center">

[![Discord](https://img.shields.io/discord/673534664354430999?style=for-the-badge&label=discord&logo=discord&logoColor=white)](https://discord.gg/k8s-at-home)
[![talos](https://img.shields.io/badge/talos-installed-brightgreen?style=for-the-badge)](https://www.talos.dev/)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white&style=for-the-badge)](https://github.com/pre-commit/pre-commit)

</div>

<!-- Main Description -->

## 📖 Overview

This is a Monorepo to manage my personal environment. A combination of Talos, NixOS, Terraform, and Flux allow this repo to provide most of the configuration required to manage this environment across regions/clouds.

## 🔧 Orchestration tools

### KCL

Yaml is old school, KCL is a DSL that provides the power of full type safety while rendering yaml at the end of the day.

### ⛵ Kubernetes

My homelab is Kubernetes based, meaning that I have a cluster of nodes running OCI (AKA. Docker) containers. Since my lab is mostly Kubernetes, I can use tools that focus on text manipulation and formatting, then use Flux to actually feed these configs into my cluster.

The result is that the text files here turn into actual running applications.

I use a toolset called `Talos Linux` to help abstract the hardware management of Kubernetes.

### 🌐 Terraform/OpenTofu

Terraform does one-shot api calls. Things I wont want managed by a controller but should be gitops.

### 🍭 Crossplane

Crossplane is the platform behind my operator focused management.

### ❄️ Nix

Nix is used for hosts that do not run Kubernetes directly. This is a declarative configuration management system that allows me to manage my hosts in a gitops fashion.

## Nodes types

### 🐦 Talos

Talos is a kubernetes focused OS that is configured by a YAML manifest. You can see this in `:/infra/talos`

I use `talhelper` to further abstract Talos's config for easy config file expandability

### ❄️ NixOS

NixOS is used in hosts that are not meant to run Kubernetes directly.

`:/infra/nix` is where I store this but the entry point is `:/flake.nix`

## 🏘️ Sites

### 🏢 KYZ

KYZ acts as the management and as a workload site.

<!-- TODO items -->

## 🖊️ Finding TODOS

<!-- prosemd: ignore -->

[Uses the `TODO:` format in line](https://github.com/rwaltr/home-ops/search?q=TODO%3A)

---

<!-- Tools -->

## 🧰 Tools

| Tool       | Use                    | Active |
| ---------- | ---------------------- | ------ |
| NixOS      | Operating System       | ☑️     |
| SOPS       | inline secrets-manager |        |
| KCL        | DSL                    |        |
| Talos      | Operating System       |        |
| Flux       | Gitops Operator        |        |
| Crossplane | API platform           |        |

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
