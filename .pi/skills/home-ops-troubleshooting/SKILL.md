---
name: home-ops-troubleshooting
description: "Troubleshoot common home-ops failures: mise task errors, Flatcar/Butane build and boot failures, fnox/1Password secret resolution, and Terraform/Terragrunt state. Use when a mise task, build, or apply fails in the home-ops repo."
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

## fnox / 1Password secret resolution errors

- `fnox check` resolves every secret in the active profile without printing values
- `fnox doctor` reports config, providers and environment
- Providers and secrets live in `~/.config/fnox/config.toml` (chezmoi) and `fnox.toml`
  (this repo); the 1Password bootstrap token is in the OS keychain under service `fnox`
- `1Password: item ... does not have a field ...` means the item/field path is wrong
  (`op://<vault>/<item>/<field>`), not an auth failure
- The `tf:*` tasks run `terraform` directly with only `CLOUDFLARE_API_TOKEN`,
  `PORKBUN_API_KEY` and `PORKBUN_SECRET_KEY` exported — they deliberately do not
  inherit the whole fnox environment (provider plugins are third-party binaries)

## Terraform state issues

- Check the workspace is correct (`mise run tf:plan <workspace>`)
- Ensure the Terraform Cloud connection is up
- Verify provider versions match and re-run `mise run tf:init` if the lock/init is stale
- A workspace lock in HCP Terraform blocks every plan/apply; unlock it in the
  TFC UI or `POST /api/v2/workspaces/<id>/actions/unlock`
- Providers: `cloudflare/cloudflare` (v4 era), `icco/porkbun`; both are pinned in
  `.terraform.lock.hcl` — run `terraform init` after any version bump
- Use the mise `tf:*` tasks rather than raw `terraform`/`terragrunt` where a task exists
