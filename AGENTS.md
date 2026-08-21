# 🤖 AI Agent Guidelines for home-ops

This document provides context and guidelines for AI coding assistants (like Cursor, Copilot, Aider, or Pi) working on this homelab infrastructure repository.

## 📖 Project Overview

This is a homelab infrastructure monorepo with **two active migrations**:

1. **Host Migration**: uCore → **Flatcar + k0s + Cilium** (GitOps, modeled on onedr0p/home-ops)
2. **IaC Migration**: Terraform → Pulumi

It manages:

- **Host Configuration**: Flatcar Container Linux (mouse) via Butane/Ignition — ZFS storage node + single-node k0s
- **Kubernetes**: k0s v1.36 + Cilium (kube-proxy replacement) — validated in VM
- **Cloud Resources**: Terraform for Cloudflare DNS and Backblaze B2 storage (migrating to Pulumi)
- **Services**: RustFS (S3-compatible storage), Netdata (monitoring) — moving in-cluster
- **Secrets**: SOPS with age encryption

**Read `REFACTOR_PLANS.md` first** — it tracks the Flatcar migration phases, decisions, and lessons.

## 🏗️ Repository Structure

```
.
├── REFACTOR_PLANS.md      # 🗺️ Flatcar migration plan, decisions log, lessons
├── infra/
│   ├── flatcar/           # 🔵 Primary host configuration (uCore replacement)
│   │   ├── butane/        # Butane configs (YAML → Ignition)
│   │   │   ├── base.bu    # Shared base (users, SSH keys, tailscale, mDNS, update-strategy)
│   │   │   ├── test.bu    # Scratch validation config
│   │   │   └── hosts/     # Per-host configs (mouse.bu)
│   │   └── ignition/      # Generated .ign files (gitignored)
│   ├── k0s/               # ☸️ k0sctl cluster definitions
│   │   ├── mouse.yaml     # Production single-node cluster (10.10.0.10)
│   │   └── test.yaml      # Scratch VM cluster
│   ├── terraform/         # 🔄 Current IaC (maintenance mode)
│   │   ├── cloudflare/    # DNS & domain management
│   │   ├── backblaze/     # B2 backup storage
│   │   └── tf-cloud/      # Terraform Cloud config
│   └── shared/            # Shared config (domains.sops.yaml)
├── .mise/
│   ├── lib/common.sh      # Shared task helpers (log/die/download_artifact/vm_ports/vm_user)
│   └── tasks/             # File-based tasks: flatcar/, tf/
├── .sops.yaml             # SOPS configuration
├── fnox.toml              # Alternative SOPS config (age provider)
└── .mise.toml             # Development environment & tool versions
```

## 🎯 Key Technologies

### Current Stack

- **Flatcar Container Linux**: Immutable OS, ZFS via official systemd-sysext
- **Butane/Ignition**: Host configuration (YAML → JSON)
- **k0s + Cilium**: Single-node Kubernetes, kube-proxy replacement (validated)
- **Terraform**: Infrastructure as Code (🔄 **Migrating to Pulumi**)
- **SOPS + age**: Secrets encryption
- **ZFS**: tank pool (raidz1×2, /var/tank) — created by hand, imported by Ignition
- **Pre-commit**: Code quality hooks
- **mise**: Task runner and development environment manager

### In-Progress

- **Flatcar migration**: Phases 0–0.5 done (validation + mouse config); see REFACTOR_PLANS.md
- **Pulumi**: Modern IaC with Go — no code yet (early stubs pruned); create `infra/pulumi/` when starting
- **GitOps layout**: Flux + helmfile bootstrap modeled on onedr0p/home-ops (Phase 2+)

## 📝 Working with This Repository

### Before Making Changes

1. **Consider Pulumi for new IaC**: When adding new cloud resources, prefer Pulumi over Terraform when possible

2. **Use mise tasks**: Most operations have mise task wrappers — check `.mise/tasks/` before running commands manually

3. **Read `REFACTOR_PLANS.md`** before working on host configuration or Kubernetes —
   it has the migration phases, the decisions log (k0s vs k3s, sysext delivery, Cilium
   BGP), and hard-won Ignition lessons (e.g. `/etc/flatcar/update.conf` can't be
   Ignition-written; sysext units can't be Ignition-enabled)

4. **Check for TODOs**: Search for `TODO:` comments in relevant files

5. **Review existing patterns**: Look at similar implementations before creating new ones

### Flatcar Configuration (Primary Development Target)

**Location**: `infra/flatcar/`

- Butane configs: `butane/base.bu` (shared: users, tailscale, mDNS, update-strategy),
  `butane/test.bu` (scratch), `butane/hosts/*.bu` (per-host, merge base.ign)
- Compiled to Ignition: `ignition/*.ign` (JSON, gitignored) via `mise run flatcar:build`
- ZFS: pool created by hand, **imported** by Ignition (`zpool import -a`) — never create in butane
- k0sctl configs: `infra/k0s/<host>.yaml`

**Use mise tasks** for common operations: `mise tasks` lists everything.

**Flatcar test VMs** (raw qemu, no libvirt). All tasks take a host argument
(`test` = scratch config, `mouse` = mirrors the production host; default `mouse`):

```bash
# Full env from scratch: boot → seed tank → verify → k0s + Cilium + nginx
mise run flatcar:bootstrap mouse

# Build ignition, download image, boot VM (test: SSH on 127.0.0.1:2223, mouse: 2224)
mise run flatcar:vm test

# Verify sysext, ZFS pool, network + host-specific checks over SSH
mise run flatcar:verify test

# Install k0s + Cilium and smoke-test with nginx
mise run flatcar:k0s test

# mouse only: hand-create the tank pool (mirrors bare metal), then reboot
mise run flatcar:seed mouse

# SSH into a VM
mise run flatcar:vm-connect test

# Destroy VM and disks (prompts for confirmation)
mise run flatcar:clean test
```

Notes:

- Destructive tasks (`flatcar:clean`, `tf:apply`) prompt for confirmation before running
- `[hostname]` args default to `mouse` (`FLATCAR_HOST` env var overrides)
- `tf:plan`/`tf:apply` take a workspace (`cloudflare|backblaze|tf-cloud`) and pass extra args through to terraform: `mise run tf:plan cloudflare -target=x`
- Shared shell helpers for tasks live in `.mise/lib/common.sh` — includes `log`/`die` and `download_artifact <url> <sha256|sha512|https-checksum-url> <dest>` (checksum-verified atomic downloads; use it for all artifact downloads instead of relying on mise `outputs` caching)

**Manual Butane compilation** (if needed):

```bash
butane --pretty --strict --files-dir . < infra/flatcar/butane/hosts/mouse.bu > infra/flatcar/ignition/mouse.ign
```

### Terraform (Current - Migrating to Pulumi)

**Location**: `infra/terraform/*/`

- Each subdirectory is a separate Terraform workspace
- Use `terraform` command
- Always run `terraform plan` before `apply`
- Secrets via SOPS, not hardcoded
- **⚠️ For new resources, consider implementing in Pulumi instead**

**Common workflow**:

```bash
cd infra/terraform/<workspace>
terraform init
terraform plan
terraform apply
```

### Pulumi (Planned — no code yet)

Early Go stubs were pruned (2026-06); recreate `infra/pulumi/` when this migration
gets active. Intended layout: `backblaze/`, `cloudflare/`, `tf-cloud/`, Go runtime.

**Migration strategy**:

- Keep existing Terraform workspaces running
- Implement new cloud resources in Pulumi
- Gradually migrate Terraform resources to Pulumi
- Both tools coexist during transition

### Secrets Management

- **NEVER** commit plaintext secrets
- Use SOPS for all sensitive data
- Config: `.sops.yaml` defines encryption keys
- Encrypted values: `sops -e -i <file>`
- Decrypted values: `sops -d <file>`

**Example**:

```bash
# Edit encrypted file
sops infra/shared/domains.sops.yaml

# Encrypt existing file
sops -e -i secrets.yaml
```

## 🔍 Common Tasks

### Adding a New Service

Services run **in the k0s cluster** (GitOps layout lands in Phase 3 — until then,
prototype against the VM cluster). Do NOT add host-level containers/quadlets.

### Adding a New Flatcar Host

1. Create `infra/flatcar/butane/hosts/<host>.bu` (merge `infra/flatcar/ignition/base.ign`)
2. Create `infra/k0s/<host>.yaml` (copy mouse.yaml)
3. Register ports/user in `vm_ports`/`vm_user` in `.mise/lib/common.sh`
4. Test: `mise run flatcar:bootstrap <host>`

### Adding Cloud Resources

**Prefer Pulumi for new resources**:

1. Create Pulumi program in `infra/pulumi/` (Go preferred)
2. Integrate SOPS for secrets
3. Document in relevant README

**Terraform (maintenance mode)**:

1. Add resource definitions in appropriate workspace
2. Run `terraform plan` to preview
3. Ensure secrets are via SOPS
4. Plan migration to Pulumi

### Finding Configuration

- **Migration plan/decisions**: `REFACTOR_PLANS.md`
- **Host settings**: `infra/flatcar/butane/`
- **Kubernetes**: `infra/k0s/mouse.yaml` (prod), `infra/k0s/test.yaml` (scratch)
- **Cloud resources**: `infra/terraform/*/` (maintenance; Pulumi planned, no code yet)
- **Shared secrets**: `infra/shared/domains.sops.yaml`
- **SOPS config**: `.sops.yaml`
- **TODOs**: `git grep "TODO:"`

## ⚠️ Important Considerations

### Migration Context

This project has **two active migrations**:

**uCore → Flatcar + k0s + Cilium (Host Migration)**

- Tracked in `REFACTOR_PLANS.md` — check the phase checklist before starting host work
- Flatcar configs live in `infra/flatcar/` (uCore fully decommissioned 2026-08-13; git history has the old configs)
- Workloads (rustfs, netdata) move from quadlets into the cluster
- Validate everything with `mise run flatcar:bootstrap <host>`

**Terraform → Pulumi (IaC Migration)**

- Existing Terraform workspaces remain in maintenance mode
- **Prefer Pulumi for new cloud resources** when possible
- No code yet — create `infra/pulumi/` (Go) when starting
- Both tools coexist during transition

### Testing Requirements

- **Always test Flatcar changes in VM**: `mise run flatcar:bootstrap <host>`
- Use mise tasks for building and testing
- Use pre-commit hooks: `pre-commit run --all-files`
- Validate syntax before committing
- Check for secrets leakage

### Best Practices

1. **Documentation**: Update relevant docs when changing infrastructure
2. **Idempotency**: Ensure changes can be applied multiple times safely
3. **Rollback plan**: Consider how to revert changes
4. **Secrets**: Use SOPS, never commit plaintext
5. **Comments**: Explain "why" not just "what"
6. **Commits**: Keep atomic, write clear messages

## 🐛 Troubleshooting

### Common Issues

**mise task failures**:

- Run `mise doctor` to check environment
- Check task logs for specific errors
- View task definitions in `.mise/tasks/`
- Use `mise tasks deps <task>` to see dependencies

**Flatcar build failures**:

- Check Butane syntax: `butane --strict < file.bu`
- Review build outputs in `infra/flatcar/ignition/`
- Boot loops: check `.vm/<host>-console.log` for `ignition-files ... res=failed`
  (see the Ignition limits section in REFACTOR_PLANS.md)

**SOPS decryption errors**:

- Ensure age key is available
- Check `.sops.yaml` rules match file path
- Verify key is in `~/.config/sops/age/keys.txt`

**Terraform state issues**:

- Check workspace is correct
- Ensure Terraform Cloud connection
- Verify provider versions match
- Use `terraform` (not `opentofu`) command

**Pulumi issues**:

- Check stack selection: `pulumi stack ls`
- Verify backend configuration
- Check for state conflicts: `pulumi refresh`

## 📚 Resources

### Project Documentation

- [REFACTOR_PLANS.md](REFACTOR_PLANS.md) - **Flatcar migration plan, decisions, lessons**
- [Main README](README.md) - Project overview
- uCore docs/configs: decommissioned — see git history before 2026-08-13 if needed

### External Resources

- [Flatcar Docs](https://www.flatcar.org/docs/latest/) & [sysext-bakery](https://github.com/flatcar/sysext-bakery)
- [Butane Configs](https://coreos.github.io/butane/)
- [k0s Documentation](https://docs.k0sproject.io/stable/) & [k0sctl](https://github.com/k0sproject/k0sctl)
- [Cilium Docs](https://docs.cilium.io/)
- [onedr0p/home-ops](https://github.com/onedr0p/home-ops) - GitOps layout reference
- [SOPS Documentation](https://github.com/getsops/sops)
- [Terraform Docs](https://www.terraform.io/docs) (maintenance mode)
- [Pulumi Documentation](https://www.pulumi.com/docs/)
- [mise Documentation](https://mise.jdx.dev/)

## 💡 Tips for AI Agents

1. **Context is key**: This is a homelab, not production enterprise infrastructure
2. **Personal project**: Single-user system, optimize for maintainability over scale
3. **Flatcar is primary**: All host configuration work goes to `infra/flatcar/`
4. **Read REFACTOR_PLANS.md**: Migration phases, decisions log, and Ignition gotchas live there
5. **Use mise tasks**: Check `.mise/tasks/` and suggest mise commands, not raw commands
6. **IaC migration in progress**: New cloud resources → Pulumi (Go-based stubs at `infra/pulumi/`)
7. **Read first**: Check existing implementations before suggesting new patterns
8. **Ask about secrets**: If you need credentials, remind user to use SOPS
9. **VM testing**: Always suggest testing with `mise run flatcar:bootstrap <host>` for infrastructure changes
10. **Follow conventions**: Match existing code style and structure
11. **Check TODOs**: See if requested work aligns with existing TODO items
12. **Terraform maintenance**: Existing Terraform is in maintenance mode, use `terraform` command

## 🤝 Contributing Guidelines

When suggesting changes:

1. **Understand the context**: Read relevant docs and existing code
2. **Maintain consistency**: Follow existing patterns and conventions
3. **Use mise tasks**: Suggest `mise run` commands instead of raw commands
4. **Test locally**: Provide mise task commands to test changes
5. **Document changes**: Update relevant markdown files
6. **Target Flatcar for host config**: All host configuration goes in `infra/flatcar/`
7. **Prefer Pulumi for IaC**: When adding cloud resources, suggest Pulumi implementation
8. **Security first**: Never suggest committing secrets
9. **Explain reasoning**: Help user understand why, not just how

## 📞 Getting Help

- **Project Issues**: GitHub Issues (mentioned in README)
- **Community**: K8s@Home Discord server
- **Search TODOs**: `git grep "TODO:"` for planned work
- **Git History**: Check commit history for context on changes

---

_This document is living documentation. Update it as the project evolves._
