---
name: home-ops-troubleshooting
description: "Troubleshoot common home-ops failures: mise task errors, Flatcar/Butane build and boot failures, SOPS age decryption, and Terraform/Terragrunt state. Use when a mise task, build, or apply fails in the home-ops repo."
---

# home-ops troubleshooting

## mise task failures

- `mise doctor` to check the environment
- Check task logs for specific errors
- View task definitions in `.mise/tasks/`
- `mise tasks deps <task>` to see dependencies

## Flatcar build failures

- Check Butane syntax: `butane --strict < file.bu`
- Review build outputs in `infra/flatcar/ignition/`
- Boot loops: check `.vm/<host>-console.log` for `ignition-files ... res=failed`
  (see the Ignition limits section in `REFACTOR_PLANS.md`)

## SOPS decryption errors

- Ensure the age key is available
- Check `.sops.yaml` rules match the file path
- Verify the key is in `~/.config/sops/age/keys.txt`

## Terraform state issues

- Check the workspace is correct (`mise run tf:plan <workspace>`)
- Ensure the Terraform Cloud connection is up
- Verify provider versions match and re-run `mise run tf:init <workspace>` if the lock/init is stale
- Use the mise `tf:*` tasks rather than raw `terraform`/`terragrunt` where a task exists
