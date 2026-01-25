# Secret Management for uCore

## Overview

This document describes how secrets are managed for uCore infrastructure provisioning using SOPS + age encryption.

**Key Principle:** Butane configs can be version controlled by encrypting secrets with SOPS. Generated Ignition files (`.ign`) always contain plaintext secrets and must never be committed.

## Architecture

### Hybrid SOPS + Local Files Approach

- **SOPS-encrypted Butane files** - For secrets that need version control (SSH keys, passwords, API tokens)
- **Local file references** - For large binary data or generated content (TLS certificates)
- **Gitignored Ignition files** - Build artifacts containing plaintext secrets

### Why This Approach?

1. ✅ **Consistency** - Same SOPS + age setup already used for Terraform secrets
2. ✅ **Version control** - Encrypted secrets are trackable, diffable, rollbackable
3. ✅ **Right scale** - Not overkill like Vault, not too simple like plaintext
4. ✅ **Future-proof** - Scales to multiple hosts if needed
5. ✅ **Secure defaults** - Secrets never in plaintext in git

## Directory Structure

```
infra/ucore/
├── butane/
│   ├── base.sops.bu              # SOPS-encrypted (SSH keys, users)
│   ├── storage.bu                # Public (ZFS config, no secrets)
│   ├── hosts/
│   │   ├── mouse.sops.bu         # SOPS-encrypted (host-specific secrets)
│   │   └── template.sops.bu      # Template with placeholders
│   └── secrets/                  # Local files (gitignored)
│       ├── tls/
│       │   ├── cert.pem
│       │   └── key.pem
│       └── .gitkeep
├── containers/
│   ├── minio.sops.container      # SOPS-encrypted (passwords, tokens)
│   ├── navidrome.container       # Public (no secrets)
│   ├── syncthing.container       # Public
│   └── netdata.container         # Public
└── ignition/                     # Generated (gitignored)
    ├── .gitkeep
    └── *.ign                     # NEVER commit - contains plaintext secrets
```

## Secret Types and Handling

### 1. SSH Keys (base.sops.bu)

**Storage:** SOPS-encrypted Butane file  
**Rationale:** Version controlled, need sync across machines, infrequent changes

```yaml
# base.sops.bu (encrypted)
variant: fcos
version: 1.5.0
passwd:
  users:
    - name: rwaltr
      ssh_authorized_keys:
        - ssh-rsa AAAAB3NzaC1yc2EAAAA...  # Encrypted by SOPS
        - ssh-ed25519 AAAAC3NzaC1lZDI1... # Encrypted by SOPS
```

### 2. Container Secrets (*.sops.container)

**Storage:** SOPS-encrypted Quadlet files  
**Rationale:** Need version control, track which services use which tokens

```ini
# minio.sops.container (encrypted)
[Container]
Image=quay.io/minio/minio:latest
Environment=MINIO_ROOT_USER=admin
Environment=MINIO_ROOT_PASSWORD=actual-secure-password  # Encrypted by SOPS
```

### 3. Large Binary Data (secrets/ directory)

**Storage:** Local files with `contents_local` references  
**Rationale:** Large files don't encrypt well, often generated/fetched externally

```yaml
# In base.sops.bu
storage:
  files:
    - path: /etc/ssl/certs/server.crt
      mode: 0644
      contents_local: secrets/tls/cert.pem  # File in gitignored directory
```

## File Status Reference

| File Pattern | Git Status | Encryption | Purpose |
|--------------|-----------|------------|---------|
| `*.sops.bu` | ✅ Committed | ✅ SOPS | Source of truth with secrets |
| `*.bu` (no .sops) | ✅ Committed | ❌ None | Public configs, no secrets |
| `*.ign` | ❌ Gitignored | ❌ Plaintext | Build artifacts (NEVER commit) |
| `*.sops.container` | ✅ Committed | ✅ SOPS | Container defs with secrets |
| `*.container` | ❌ Gitignored | ❌ Plaintext | Decrypted for embedding |
| `secrets/*` | ❌ Gitignored | ❌ Plaintext | Local certs, large files |

## Build Workflow

### Standard Build Process

```bash
# Decrypt SOPS files → Transpile with Butane → Generate Ignition
mise run ucore:build
```

The build task (`mise/tasks/ucore/build`) automatically:
1. Decrypts `*.sops.bu` files with SOPS
2. Transpiles to Ignition with Butane
3. Outputs plaintext `.ign` files (gitignored)

### Manual Build Example

```bash
# Single file: Decrypt → Transpile
sops -d infra/ucore/butane/base.sops.bu | \
  butane --files-dir infra/ucore --pretty --strict > \
  infra/ucore/ignition/base.ign

# Container: Decrypt for embedding
sops -d infra/ucore/containers/minio.sops.container > \
  infra/ucore/containers/minio.container
```

## SOPS Configuration

### .sops.yaml Rules

```yaml
---
keys:
  - &rwaltr age189npag0lz2hl425ldurk8czrpyv69tg4cgqgzl7wjh60w39sysesazu4u6

creation_rules:
  # uCore Butane configs
  - path_regex: infra/ucore/butane/.*\.sops\.bu$
    age:
      - *rwaltr
  
  # uCore container definitions
  - path_regex: infra/ucore/containers/.*\.sops\.container$
    age:
      - *rwaltr
  
  # Terraform secrets (existing)
  - path_regex: infra/terraform/.*/.*\.sops\.yaml$
    age:
      - *rwaltr
  
  # Default rule
  - age:
      - *rwaltr
```

### Age Key Management

**Public key (recipient):**  
`age189npag0lz2hl425ldurk8czrpyv69tg4cgqgzl7wjh60w39sysesazu4u6`

**Private key locations:**
- ✅ Development machine: `~/.config/sops/age/keys.txt`
- ✅ CI/CD: Stored in CI secrets
- ❌ Production host: Should NOT have decryption key (provision-time only)

### Common SOPS Operations

```bash
# Encrypt a new file
sops -e infra/ucore/butane/base.bu > infra/ucore/butane/base.sops.bu

# Encrypt in-place
sops -e -i infra/ucore/butane/base.sops.bu

# Edit encrypted file (decrypts to $EDITOR)
sops infra/ucore/butane/base.sops.bu

# Decrypt to stdout
sops -d infra/ucore/butane/base.sops.bu

# Rotate keys after key change
sops updatekeys infra/ucore/butane/base.sops.bu
```

## VM Testing with Secrets

### Test vs Production Secrets

**Problem:** VM testing shouldn't use production passwords

**Solution 1:** Environment-based key selection

```bash
# Use test key for VM builds
export SOPS_AGE_KEY_FILE=~/.config/sops/age/test-key.txt
mise run ucore:vm

# Use production key for real deployment
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
mise run ucore:build
```

**Solution 2:** Separate config files

```
butane/hosts/
├── mouse.sops.bu          # Production secrets
└── mouse-test.sops.bu     # Test secrets (weak passwords, test keys)
```

## Security Considerations

### What SOPS Provides

- ✅ Who changed secrets (git blame on encrypted file)
- ✅ When secrets changed (git log)
- ✅ Encrypted at rest in version control
- ❌ Cannot see what the values were (values encrypted)

### Critical Rules

1. **NEVER commit `.ign` files** - Always contain plaintext secrets
2. **NEVER commit decrypted `.container` files** - Temporary build artifacts
3. **Rotate secrets if private key compromised** - Re-encrypt all files with new key
4. **Review `.gitignore` before commits** - Ensure patterns are correct
5. **Verify SOPS encryption** - Files should show `ENC[AES256_GCM,...]` not plaintext

### Audit Before Commit

```bash
# Check for plaintext secrets in staged files
git diff --staged | grep -i "password\|secret\|token"

# Verify SOPS files are encrypted
git diff --staged | grep "ENC\[AES256_GCM"

# Ensure no .ign files staged
git status | grep "\.ign$"
```

## Migration from NixOS

### NixOS Secret Handling (Previous)

- SSH keys: Declared in Nix configuration
- Container secrets: Module options (unclear if encrypted)
- Terraform: SOPS + age (✅ same as uCore approach)

### Migration Steps

1. **Extract secrets from NixOS config**
   - SSH keys from user configuration
   - Service passwords from module options
   - API tokens from environment files

2. **Create SOPS-encrypted Butane files**
   ```bash
   # Create base.sops.bu with SSH keys
   sops infra/ucore/butane/base.sops.bu
   ```

3. **Create SOPS-encrypted container files**
   ```bash
   # Add real passwords to containers
   sops infra/ucore/containers/minio.sops.container
   ```

4. **Update build process**
   - Modify `.mise/tasks/ucore/build` to handle SOPS decryption
   - Test with `mise run ucore:vm -- --force`

5. **Verify secrets are encrypted**
   ```bash
   # Files should contain ENC[...] not plaintext
   cat infra/ucore/butane/base.sops.bu
   ```

## Troubleshooting

### "failed to get the data key required to decrypt"

**Cause:** SOPS cannot find age private key

**Solution:**
```bash
# Check key location
ls -la ~/.config/sops/age/keys.txt

# Set explicit key path
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# Or use age CLI
export SOPS_AGE_KEY=$(cat ~/.config/sops/age/keys.txt)
```

### Accidentally committed .ign file

**Solution:**
```bash
# Remove from git history
git rm --cached infra/ucore/ignition/*.ign

# Verify gitignore is correct
cat .gitignore | grep "\.ign$"

# Force add gitignore rule if missing
echo "infra/ucore/ignition/*.ign" >> .gitignore
```

### Build fails with "permission denied"

**Cause:** Trying to read SOPS file without decryption

**Solution:**
```bash
# Don't read encrypted files directly
# WRONG: butane base.sops.bu > base.ign

# RIGHT: Decrypt first
sops -d base.sops.bu | butane > base.ign
```

## References

### Official Documentation

- **Fedora CoreOS Secrets**: https://coreos.github.io/ignition/operator-notes/#secrets
- **Butane Specification**: https://coreos.github.io/butane/specs/
- **Butane Examples**: https://coreos.github.io/butane/examples/
- **SOPS**: https://getsops.io/
- **age**: https://github.com/FiloSottile/age

### Related Files

- `.sops.yaml` - SOPS configuration with age recipients
- `fnox.toml` - Alternative SOPS config (age provider)
- `.gitignore` - Patterns for excluding secrets
- `.mise/tasks/ucore/build` - Build task with SOPS integration

### Butane Issue #111

**Status:** Open since 2020  
**Topic:** Add native variable substitution to Butane  
**Link:** https://github.com/coreos/butane/issues/111

**Community workarounds:**
- `envsubst` - Shell variable expansion (limited)
- `j2cli` - Jinja2 templating (requires Python)
- `gomplate` - Go templating (proposed but not implemented)
- **SOPS** - Encryption-based approach (our choice)

**Why SOPS instead of templating:**
- Official support (SOPS is industry standard)
- Version control friendly (encrypted diffs)
- Audit trail (who/when changed)
- No preprocessing step required
- Consistent with Terraform approach
