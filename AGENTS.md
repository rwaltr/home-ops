# 🤖 AI Agent Guidelines for home-ops

This document provides context and guidelines for AI coding assistants (like Cursor, Copilot, Aider, or Pi) working on this homelab infrastructure repository.

## 📖 Project Overview

This is a NixOS-powered homelab infrastructure monorepo with two active migrations:
1. **OS Migration**: NixOS → Universal Blue uCore
2. **IaC Migration**: Terraform → Pulumi

It manages:
- **Host Configuration**: Currently NixOS (mouse), migrating to uCore
- **Cloud Resources**: Terraform for Cloudflare DNS and Backblaze B2 storage (migrating to Pulumi)
- **Services**: MinIO, Syncthing, Navidrome, NFS, monitoring
- **Secrets**: SOPS with age encryption

## 🏗️ Repository Structure

```
.
├── infra/
│   ├── nix/               # ⚠️ Current NixOS (DO NOT MODIFY - frozen)
│   │   ├── hosts/         # Host-specific configs (mouse)
│   │   ├── modules/       # Reusable NixOS modules
│   │   └── pkgs/          # Custom package derivations
│   ├── ucore/             # 🚧 Future uCore (PRIMARY TARGET)
│   │   ├── butane/        # Butane configs (YAML → Ignition)
│   │   ├── containers/    # Container definitions
│   │   └── *.md          # Migration docs & runbooks
│   ├── terraform/         # 🔄 Current IaC (maintenance mode)
│   │   ├── cloudflare/    # DNS & domain management
│   │   ├── backblaze/     # B2 backup storage
│   │   └── tf-cloud/      # Terraform Cloud config
│   └── pulumi/            # 🚧 Future IaC (to be created)
├── flake.nix              # Nix flake entry point (frozen)
├── .sops.yaml             # SOPS configuration
└── .mise.toml             # Development environment

```

## 🎯 Key Technologies

### Current Stack
- **NixOS 24.05**: Declarative OS configuration (⚠️ **DO NOT MODIFY**)
- **Nix Flakes**: Dependency management (⚠️ **DO NOT MODIFY**)
- **Terraform**: Infrastructure as Code (🔄 **Migrating to Pulumi**)
- **SOPS + age**: Secrets encryption
- **ZFS**: Storage with snapshots
- **Pre-commit**: Code quality hooks
- **mise**: Task runner and development environment manager

### Future Stack (Migration in Progress)
- **Universal Blue uCore**: Immutable Fedora CoreOS-based OS
- **Butane**: YAML configs compiled to Ignition
- **Podman/Docker**: Container-first workflow
- **Systemd Quadlets**: Container management
- **Pulumi**: Modern IaC with built-in cost tracking and state management

## 📝 Working with This Repository

### Before Making Changes

1. **⚠️ NEVER modify NixOS configurations**: The `infra/nix/` directory is legacy and should not be touched

2. **Consider Pulumi for new IaC**: When adding new cloud resources, prefer Pulumi over Terraform when possible

3. **Use mise tasks**: Most operations have mise task wrappers - check `.mise/tasks/` before running commands manually

4. **Read migration docs** if working on uCore:
   - `infra/ucore/README.md` - Overview & architecture
   - `infra/ucore/MIGRATION.md` - Step-by-step runbook
   - `infra/ucore/VM-TESTING.md` - Testing procedures
   - `infra/ucore/CONTAINERS.md` - Container inventory

5. **Check for TODOs**: Search for `TODO:` comments in relevant files

6. **Review existing patterns**: Look at similar implementations before creating new ones

### NixOS Configuration (Current)

**⚠️ DO NOT MODIFY - Legacy system being replaced**

**Location**: `infra/nix/` - This is the current production system but is frozen during migration to uCore. Any changes needed should be implemented in uCore instead.

### uCore Configuration (Future - Primary Development Target)

**Location**: `infra/ucore/`

- Butane configs: `butane/*.bu` (YAML)
- Compiled to Ignition: `ignition/*.ign` (JSON)
- Container definitions: Follow quadlet format
- Test in VMs before deploying (see VM-TESTING.md)

**Use mise tasks** for common operations:
```bash
# Build all Ignition files (incremental)
mise run ucore:build

# Build single Ignition file
mise run ucore:build-single <name>

# Download Fedora CoreOS ISO (cached)
mise run ucore:download-iso

# Create custom install ISO
mise run ucore:customize-iso <host>

# Create and auto-install VM (full chain)
mise run ucore:vm [hostname]

# Connect to existing VM
mise run ucore:vm-connect [hostname]

# Clean up VMs and disks
mise run ucore:clean [hostname]

# View available tasks
mise tasks

# View task dependencies
mise tasks deps ucore:vm
```

**Manual Butane compilation** (if needed):
```bash
butane --pretty --strict < butane/mouse.bu > ignition/mouse.ign
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

### Pulumi (Future - Primary IaC Target)

**Location**: TBD (likely `infra/pulumi/`)

**Benefits**:
- Built-in cost estimation and tracking
- Modern programming languages (Python, TypeScript, Go)
- Better state management and team collaboration
- Enhanced secrets integration with SOPS
- Preview changes with cost impact before deployment

**Planned workflow**:
```bash
# Preview changes with cost estimates
pulumi preview

# Show cost estimates
pulumi preview --show-costs

# Deploy with cost tracking
pulumi up

# View cost insights
pulumi stack export
```

**Migration strategy**:
- Keep existing Terraform workspaces running
- Implement new cloud resources in Pulumi
- Gradually migrate Terraform resources to Pulumi
- Use Pulumi's cost tracking for budget management

### Secrets Management

- **NEVER** commit plaintext secrets
- Use SOPS for all sensitive data
- Config: `.sops.yaml` defines encryption keys
- Encrypted values: `sops -e -i <file>`
- Decrypted values: `sops -d <file>`

**Example**:
```bash
# Edit encrypted file
sops infra/nix/secrets/example.yaml

# Encrypt existing file
sops -e -i secrets.yaml
```

## 🔍 Common Tasks

### Adding a New Service

**⚠️ Do not add to NixOS** - Implement in uCore only

**uCore (Primary Development Target)**:
1. Define container in Butane config
2. Add to `CONTAINERS.md` inventory
3. Create systemd quadlet configuration
4. Test in VM: `mise run ucore:vm [hostname]`
5. Connect and verify: `mise run ucore:vm-connect [hostname]`

### Adding Cloud Resources

**Prefer Pulumi for new resources** (when available):
1. Create Pulumi program in appropriate language
2. Use cost tracking: `pulumi preview --show-costs`
3. Integrate SOPS for secrets
4. Document in relevant README

**Terraform (maintenance mode)**:
1. Add resource definitions in appropriate workspace
2. Run `terraform plan` to preview
3. Ensure secrets are via SOPS
4. Plan migration to Pulumi

### Updating Dependencies

**Nix** (⚠️ DO NOT MODIFY):
- NixOS dependencies are frozen during migration

**Terraform** (maintenance mode):
```bash
cd infra/terraform/<workspace>
terraform init -upgrade
```

**Pulumi** (when implemented):
```bash
cd infra/pulumi/<stack>
pulumi plugin install
pulumi refresh
```

**mise tools**:
```bash
# Update all tools
mise upgrade

# Update specific tool
mise upgrade <tool-name>
```

### Finding Configuration

- **Host settings**: `infra/nix/hosts/mouse/` (read-only reference)
- **Service configs**: `infra/ucore/butane/` (active development)
- **Cloud resources**: `infra/terraform/*/` (maintenance) or `infra/pulumi/` (future)
- **Secrets**: Search for `sops.secrets` or `.sops.yaml`
- **TODOs**: `git grep "TODO:"`

## ⚠️ Important Considerations

### Migration Context

This project has **two active migrations**:

**1. NixOS → uCore (OS/Host Migration)**
- **⚠️ DO NOT modify NixOS configurations** - they are frozen during migration
- **All new work should target uCore** (`infra/ucore/`)
- NixOS system remains in production but is not being updated
- Reference `infra/ucore/MIGRATION.md` for migration status
- Use mise tasks for all uCore operations

**2. Terraform → Pulumi (IaC Migration)**
- Existing Terraform workspaces remain in maintenance mode
- **Prefer Pulumi for new cloud resources** when possible
- Gradually migrate Terraform resources to Pulumi
- Leverage Pulumi's cost tracking for budget management
- Both tools may coexist during transition

### Testing Requirements

- **Always test uCore changes in VM**: `mise run ucore:vm [hostname]`
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
7. **Cost awareness**: Use Pulumi's cost tracking for cloud resources

## 🐛 Troubleshooting

### Common Issues

**mise task failures**:
- Run `mise doctor` to check environment
- Check task logs for specific errors
- View task definitions in `.mise/tasks/`
- Use `mise tasks deps <task>` to see dependencies

**uCore build failures**:
- Use `mise run ucore:build --force` to rebuild
- Check Butane syntax: `butane --strict < file.bu`
- Review build outputs in `ignition/` directory

**SOPS decryption errors**:
- Ensure age key is available
- Check `.sops.yaml` rules match file path
- Verify key is in `~/.config/sops/age/keys.txt`

**Terraform state issues**:
- Check workspace is correct
- Ensure Terraform Cloud connection
- Verify provider versions match
- Use `terraform` (not `opentofu`) command

**Pulumi issues** (when implemented):
- Check stack selection: `pulumi stack ls`
- Verify backend configuration
- Check for state conflicts: `pulumi refresh`
- Review cost estimates: `pulumi preview --show-costs`

## 📚 Resources

### Project Documentation
- [Main README](README.md) - Project overview
- [uCore Migration](infra/ucore/README.md) - Migration plan
- [uCore Testing](infra/ucore/VM-TESTING.md) - VM testing guide
- [uCore Runbook](infra/ucore/MIGRATION.md) - Migration steps
- [Terraform Cloud](infra/terraform/tf-cloud/readme.md) - TF Cloud setup

### External Resources
- [NixOS Manual](https://nixos.org/manual/nixos/stable/) (reference only - no modifications)
- [Nix Flakes](https://nixos.wiki/wiki/Flakes) (reference only - no modifications)
- [Universal Blue Docs](https://universal-blue.org/)
- [Butane Configs](https://coreos.github.io/butane/)
- [SOPS Documentation](https://github.com/getsops/sops)
- [Terraform Docs](https://www.terraform.io/docs) (maintenance mode)
- [Pulumi Documentation](https://www.pulumi.com/docs/)
- [Pulumi Cost Tracking](https://www.pulumi.com/docs/pulumi-cloud/cost/)
- [mise Documentation](https://mise.jdx.dev/)

## 💡 Tips for AI Agents

1. **Context is key**: This is a homelab, not production enterprise infrastructure
2. **Personal project**: Single-user system, optimize for maintainability over scale
3. **⚠️ NixOS is frozen**: Never suggest modifications to `infra/nix/` - all work goes to uCore
4. **Use mise tasks**: Check `.mise/tasks/` and suggest mise commands, not raw commands
5. **Two migrations in progress**: 
   - OS: All new features → uCore
   - IaC: New cloud resources → Pulumi (when possible)
6. **Cost awareness**: When suggesting Pulumi implementations, highlight cost tracking capabilities
7. **Read first**: Check existing implementations before suggesting new patterns
8. **Ask about secrets**: If you need credentials, remind user to use SOPS
9. **VM testing**: Always suggest testing with `mise run ucore:vm` for infrastructure changes
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
6. **Target uCore only**: All new work should be in `infra/ucore/`
7. **Prefer Pulumi for IaC**: When adding cloud resources, suggest Pulumi implementation with cost tracking
8. **Never touch NixOS**: `infra/nix/` is frozen during migration
9. **Security first**: Never suggest committing secrets
10. **Show cost implications**: When using Pulumi, demonstrate cost estimation commands
11. **Explain reasoning**: Help user understand why, not just how

## 📞 Getting Help

- **Project Issues**: GitHub Issues (mentioned in README)
- **Community**: K8s@Home Discord server
- **Search TODOs**: `git grep "TODO:"` for planned work
- **Git History**: Check commit history for context on changes

---

*This document is living documentation. Update it as the project evolves.*
