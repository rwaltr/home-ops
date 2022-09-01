<!-- Header -->
<div align="center">

<img src="https://raw.githubusercontent.com/rwaltr/branding/master/vector/logoisolated.png" align="center" width="144px" height="144px"/>

# rwaltr/home-ops

</div>

<!-- Shields -->
<div align="center">

[![Discord](https://img.shields.io/discord/673534664354430999?style=for-the-badge&label=discord&logo=discord&logoColor=white)](https://discord.gg/k8s-at-home)
[![talos](https://img.shields.io/badge/talos-installed-brightgreen?style=for-the-badge)](https://www.talos.dev/)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white&style=for-the-badge)](https://github.com/pre-commit/pre-commit)
[![Lines of code](https://img.shields.io/tokei/lines/github/rwaltr/home-ops?style=for-the-badge&color=brightgreen&label=lines&logo=codefactor&logoColor=white)](https://github.com/rwaltr/home-ops/graphs/contributors)
[![100DaysofHomelab](https://img.shields.io/badge/100DaysOf-Homelab-blue?style=for-the-badge)](<https://twitter.com/search?f=top&q=(%23100DaysOfHomelab)%20(from%3Arwaltrtech)>)

</div>

<!-- Main Description -->

## 📖 Overview

This is a Monorepo to manage my personal environment. A combination of Talos, Terraform, and Argo allow this repo to provide most of the configuration required to manage this environment across regions/clouds.

### ⛵ Kubernetes

My homelab is Kubernetes based, meaning that I have a cluster of nodes running OCI (AKA. Docker) containers. Since my lab is mostly Kubernetes, I can use tools that focus on text manipulation and formatting, then use ArgoCD to actually feed these configs into my cluster.

The result is that the text files here turn into actual running applications.

I use a toolset called `Talos Linux` to help abstract the hardware management of Kubernetes.

#### 🐦 Talos

Talos is a OS that is configured by a YAML manifest. You can see this in `:/cluster`

### 🐧 Gitops

Gitops generally means that your git repo is the state of your environment.

Here it is done with Argo and Terraform

### Networking

#### KYZ

In the site `KYZ` The cluster communicates with the edge gateway with BGP. Ports 80 and 443 are forwarded to the Ingress manager

<!-- TODO items -->

## 🖊️ Finding TODOS

[Uses the `TODO:` format in line](https://github.com/rwaltr/home-ops/search?q=TODO%3A)

---

<!-- Tools -->

## 🧰 Tools!

| Tool         | Use                    | Active |
| ------------ | ---------------------- | ------ |
| Argo         | Gitops Operator        | ☑️     |
| Talos        | Operating System       | ☑️     |
| Traefik      | Ingress Management     | ☑️     |
| Cert-manager | X509 Secrets manager   | ☑️     |
| HashiVault   | Secrets store          | ⚠️     |
| External-dns | Public DNS operator    | ☑️     |
| SOPS         | inline secrets-manager | ☑️     |
| pre-commit   | Commit checking        | ☑️     |
| Cilium       | CNI                    | ☑️     |

---

<!-- Thanks -->

## 🤟 Thanks

Thank you to the below for inspiration

- onedr0p
- anthr76
- dirtycajunrice
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
- Twitter DMs
- Email

---

## 📜 Changelog

See [commit history](https://github.com/rwaltr/home-ops/commits/master)

---

## 🔏 License

See [LICENSE](./LICENSE)

---
