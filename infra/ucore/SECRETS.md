# Secret Management for uCore

## Overview

This document describes the secret management approach for uCore infrastructure using SOPS + age encryption.

**Key Principle:** Sensitive values are encrypted with SOPS + age. Generated Ignition files (`.ign`) contain plaintext and are gitignored.

## Current State

### What Exists

- **`.sops.yaml`** — SOPS config with age recipient key
- **`fnox.toml`** — Alternative SOPS config (age provider)
- **`infra/shared/domains.sops.yaml`** — Encrypted domain configuration
- **`infra/terraform/backblaze/backblaze_secrets.sops.yaml`** — Encrypted Backblaze credentials
- **`infra/terraform/cloudflare/cloudflare_secrets.sops.yaml`** — Encrypted Cloudflare credentials
- **Butane files (`*.bu`)** — Currently **not** SOPS-encrypted (SSH keys are in plaintext in `base.bu`)
- **Container files (`*.container`)** — Currently **not** SOPS-encrypted (RustFS credentials are placeholder values)
- **Ignition files (`*.ign`)** — Generated build artifacts, gitignored

### What's Planned

A hybrid SOPS + local files approach for Butane configs, as detailed below.

## Architecture

### Hybrid SOPS + Local Files Approach (Planned)

- **SOPS-encrypted Butane files** — For secrets that need version control (SSH keys, passwords, API tokens)
- **Local file references** — For large binary data or generated content (TLS certificates)
- **Gitignored Ignition files** — Build artifacts containing plaintext secrets

### Why This Approach?

1. ✅ **Consistency** — Same SOPS + age setup already used for Terraform secrets
2. ✅ **Version control** — Encrypted secrets are trackable, diffable, rollbackable
3. ✅ **Right scale** — Not overkill like Vault, not too simple like plaintext
4. ✅ **Future-proof** — Scales to multiple hosts if needed
5. ✅ **Secure defaults** — Secrets never in plaintext in git

## SOPS Configuration

### .sops.yaml (Current)

```yaml
---
keys:
  - &rwaltr age189npag0lz2hl425ldurk8czrpyv69tg4cgqgzl7wjh60w39sysesazu4u6

creation_rules:
  - path_regex: k8s/.*\.sops\.ya?ml
    encrypted_regex: "^(data|stringData)$"
    key_groups:
      - age:
          - *rwaltr
  - key_groups:
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
sops -e -i myfile.yaml

# Edit encrypted file (decrypts to $EDITOR)
sops infra/shared/domains.sops.yaml

# Decrypt to stdout
sops -d infra/shared/domains.sops.yaml

# Rotate keys after key change
sops updatekeys myfile.sops.yaml
```

## File Status Reference

| File | Git Status | Encryption | Notes |
|------|-----------|------------|-------|
| `butane/base.bu` | ✅ Committed | ❌ Plaintext | Contains SSH public keys (not secret) |
| `butane/hosts/mouse.bu` | ✅ Committed | ❌ Plaintext | No secrets currently |
| `containers/rustfs.container` | ✅ Committed | ❌ Plaintext | Has placeholder credentials |
| `containers/netdata.container` | ✅ Committed | ❌ Plaintext | No secrets |
| `ignition/*.ign` | ❌ Gitignored | ❌ Plaintext | Build artifacts |
| `infra/shared/domains.sops.yaml` | ✅ Committed | ✅ SOPS | Domain configuration |
| `infra/terraform/*/*.sops.yaml` | ✅ Committed | ✅ SOPS | Terraform secrets |

## Planned: SOPS-Encrypted Butane Files

### Migration Plan

When production secrets are needed (real RustFS credentials, API tokens, etc.), the plan is to encrypt Butane and container files with SOPS:

1. **Rename files**: `base.bu` → `base.sops.bu`
2. **Encrypt with SOPS**: `sops -e -i base.sops.bu`
3. **Update build process**: Decrypt before Butane transpilation
4. **Update `.sops.yaml`**: Add path rules for `*.sops.bu` and `*.sops.container`

### Planned .sops.yaml Rules

```yaml
creation_rules:
  # uCore Butane configs
  - path_regex: infra/ucore/butane/.*\.sops\.bu$
    age:
      - *rwaltr

  # uCore container definitions
  - path_regex: infra/ucore/containers/.*\.sops\.container$
    age:
      - *rwaltr

  # Kubernetes secrets
  - path_regex: k8s/.*\.sops\.ya?ml
    encrypted_regex: "^(data|stringData)$"
    key_groups:
      - age:
          - *rwaltr

  # Default rule
  - key_groups:
      - age:
          - *rwaltr
```

### Planned Build Workflow

```bash
# Decrypt SOPS files → Transpile with Butane → Generate Ignition
# Single file: Decrypt → Transpile
sops -d infra/ucore/butane/base.sops.bu | \
  butane --files-dir infra/ucore --pretty --strict > \
  infra/ucore/ignition/base.ign
```

## Security Considerations

### What SOPS Provides

- ✅ Who changed secrets (git blame on encrypted file)
- ✅ When secrets changed (git log)
- ✅ Encrypted at rest in version control
- ❌ Cannot see what the values were (values encrypted)

### Current Risks

- ⚠️ `base.bu` contains SSH **public** keys in plaintext (acceptable — public keys aren't secret)
- ⚠️ `rustfs.container` has placeholder credentials (`admin`/`changeme`) — must be changed for production
- ✅ Ignition files are gitignored

### Critical Rules

1. **NEVER commit `.ign` files** — Always contain plaintext secrets
2. **Rotate secrets if private key compromised** — Re-encrypt all files with new key
3. **Review `.gitignore` before commits** — Ensure patterns are correct
4. **Verify SOPS encryption** — Files should show `ENC[AES256_GCM,...]` not plaintext

### Audit Before Commit

```bash
# Check for plaintext secrets in staged files
git diff --staged | grep -i "password\|secret\|token"

# Verify SOPS files are encrypted
git diff --staged | grep "ENC\[AES256_GCM"

# Ensure no .ign files staged
git status | grep "\.ign$"
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
```

### Accidentally committed .ign file

**Solution:**

```bash
# Remove from git history
git rm --cached infra/ucore/ignition/*.ign

# Verify gitignore is correct
cat .gitignore | grep "\.ign"
```

## References

### Official Documentation

- **SOPS**: <https://getsops.io/>
- **age**: <https://github.com/FiloSottile/age>
- **Fedora CoreOS Secrets**: <https://coreos.github.io/ignition/operator-notes/#secrets>
- **Butane Specification**: <https://coreos.github.io/butane/specs/>

### Related Files

- `.sops.yaml` — SOPS configuration with age recipients
- `fnox.toml` — Alternative SOPS config (age provider)
- `.gitignore` — Patterns for excluding secrets
- `.mise/tasks/ucore/build` — Build task (update when adding SOPS integration)
