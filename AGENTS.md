# 🤖 AI Agent Guidelines for home-ops

Context for AI coding assistants (Cursor, Copilot, Aider, Pi) working on this
homelab infrastructure monorepo.

## 📖 Project Overview

A single-user homelab infrastructure monorepo. The host (**mouse**) runs Flatcar
Container Linux with a single-node k0s + Cilium cluster managed by Flux GitOps;
cloud resources are managed with Terraform.

It manages:

- **Host Configuration**: Flatcar Container Linux (`mouse`) via Butane/Ignition — ZFS storage node + single-node k0s
- **Kubernetes**: k0s v1.36 + Cilium (kube-proxy replacement), Flux GitOps rooted at `infra/k8s/kyz`
- **Cloud Resources**: Terraform for Cloudflare DNS and Terraform Cloud
- **Services**: run **in the k0s cluster**
- **Secrets**: 1Password — fnox for local/CI tooling, Connect + External Secrets in-cluster

> `REFACTOR_PLANS.md` is a historical decision log and lessons file, not an active plan.
> Read it for background, not as a to-do list.

## 🏗️ Repository Structure

```
.
├── REFACTOR_PLANS.md      # Historical decisions log and hard-won lessons
├── README.md              # User-facing overview
├── infra/
│   ├── flatcar/           # Host config: butane/ (base.bu, hosts/*.bu)
│   │   └── ignition/      # generated .ign (gitignored)
│   ├── k0s/               # k0sctl cluster definitions (mouse.yaml, test.yaml)
│   ├── k8s/
│   │   ├── bootstrap/     # helmfile + kustomize bootstrap
│   │   └── kyz/           # Flux GitOps site (apps/, components/, flux/)
│   ├── terraform/         # cloudflare/ (Cloudflare + Porkbun), tf-cloud/
│   ├── routeros/          # MikroTik router notes
│   └── media-tools/       # transcode tooling
├── docs/                  # Per-service runbooks (see index below)
├── .mise/
│   ├── lib/common.sh      # Shared task helpers
│   └── tasks/             # flatcar/, tf/, lint/, fmt/, op/
├── fnox.toml              # project secret refs (1Password-backed)
└── .mise.toml             # Tool versions and tasks
```

## 🎯 Stack

- **Flatcar Container Linux**: immutable OS, ZFS via official systemd-sysext
- **Butane/Ignition**: host configuration (YAML → JSON)
- **k0s + Cilium**: single-node Kubernetes, kube-proxy replacement
- **Flux**: GitOps (`infra/k8s/kyz`); apps grouped under `apps/`
- **Storage**: OpenEBS `openebs-hostpath` (NVMe); the ZFS `tank` pool stays outside the PVC lifecycle
- **Backups**: kopiur + kopia → in-cluster RustFS on `tank/backup/k8s`
- **Secrets**: 1Password Connect + External Secrets in-cluster; fnox (1Password-backed) for local and CI tooling — no secrets in git
- **IaC**: Terraform (Pulumi was abandoned; OpenTofu is the intended direction — no active migration)
- **ZFS**: `tank` pool (raidz1×2, `/var/tank`) — created by hand, imported by Ignition
- **mise**: task runner and dev environment

## ✅ Hard Rules

1. **Secrets**: NEVER commit plaintext secrets. Use fnox / 1Password. If you need
   a credential, remind the user to add it to 1Password rather than pasting it.
2. **Host config → Flatcar**: all host configuration goes in `infra/flatcar/`.
3. **Services in k0s**: do NOT add host-level containers/quadlets; workloads run in the cluster.
4. **Test infrastructure changes in a VM**: `mise run flatcar:bootstrap <host>`.
5. **Use mise tasks**, not raw commands — check `.mise/tasks/` first (`mise tasks`).
6. **IaC**: use the `mise run tf:*` tasks. `plan` before `apply`.
7. **This is a homelab**: single-user, optimize for maintainability over scale.

## 🧭 Project Skills (load on demand)

- **`flatcar-vm`** — build/boot/verify/teardown Flatcar VMs, mise task reference,
  manual Butane compilation, adding a new host.
- **`home-ops-troubleshooting`** — mise, Flatcar/Butane, fnox/1Password, Terraform failures.
- **`verify-change`** — the verification loop to follow before declaring work done.

Ping a skill explicitly with `/skill:verify-change` if the model doesn't auto-load it.

## 📚 Documentation Index

- `REFACTOR_PLANS.md` — historical decisions and lessons
- `docs/jellyfin-metadata.md`, `docs/jellyfin-direct-play.md`, `docs/jellyfin-language-filtering.md`
- `docs/local-llm.md` — LiteLLM gateway: OpenRouter chat + speaches audio (no local LLM)
- `docs/tailscale.md` — Tailnet: Terraform-owned policy/DNS/settings, the Kubernetes operator credential, and the manual bootstrap step
- `docs/logging.md` — decommissioned 2026-11-07 (VictoriaLogs + Fluent Bit removed)
- `docs/alerting.md` — Alertmanager routing + the agent alert feed
- `docs/mosquitto.md` — MQTT broker + HA discovery
- `docs/calendar.md` — Radicale + CalDAV / Remind feed
- `docs/freshrss.md` — FreshRSS
- `docs/navidrome.md` — Navidrome (Subsonic/OpenSubsonic)
- `docs/homebox.md` — HomeBox home inventory
- `docs/kitchenowl.md` — KitchenOwl grocery list + recipes
- `docs/homepage.md` — Homepage service dashboard
- `docs/hermes-agent.md` — Hermes agent
- `docs/comms-demos.md` — Matrix comms-channel demo (internal-only; agent not wired in)
- TODOs: `git grep "TODO:"`

## 🔍 Common Tasks

- **Adding a new service**: add to the Flux GitOps layout under `infra/k8s/kyz/apps/`.
  See the service docs under `docs/`.
- **Adding a new Flatcar host**: see the `flatcar-vm` skill.
- **Adding cloud resources**: add a Terraform workspace/`.tf` under `infra/terraform/`,
  then `mise run tf:plan <workspace>` before `tf:apply`.
- **Finding configuration**: start from `infra/` and `docs/`.
- **Setting up a dev env**: `mise install`, then install the git hooks. On a machine
  you own, do it once globally: `hk install --global --mise` (no-ops in repos without
  an `hk.pkl`). In a container or throwaway clone, use `mise run setup` instead.
  Hooks are defined in `hk.pkl`; `mise run lint` / `mise run fmt` wrap `hk check --all`
  / `hk fix --all`, so there is one place to add a linter.

## ⚠️ Important Considerations

- **Testing**: always exercise Flatcar changes in a VM; run `mise run lint` and
  validate syntax before committing; check for secret leakage.
- **Idempotency & rollback**: changes should be safe to re-apply; consider how to revert.
- **Comments**: explain _why_, not just _what_. Keep commits atomic.

## 💡 Tips for AI Agents

1. Read the relevant docs and existing implementations before proposing new patterns.
2. Suggest `mise run` commands rather than raw commands.
3. Keep Flatcar/Ignition gotchas in mind (`/etc/flatcar/update.conf` can't be
   Ignition-written; sysext units can't be Ignition-enabled).
4. Ask about secrets instead of assuming; never write them in plaintext.
