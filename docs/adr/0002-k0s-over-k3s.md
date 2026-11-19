# k0s via k0sctl, not k3s

Status: accepted (2026-08-13)

The cluster is k0s, installed and upgraded by k0sctl from `infra/k0s/<host>.yaml`.
k0sctl's declarative YAML and k0s's zero bundled components fit a repo where every
component is chosen explicitly; k3s's value-adds (Klipper, Traefik, local-path) are all
things this cluster replaces anyway. Revisit if a second node exposes problems with
k0s autopilot.

## Consequences

- Do **not** use `k0sctl --profile flatcar`: no such worker profile exists, and it
  silently wedges a controller+worker node.
- k0s's pod CIDR is `10.244.0.0/16` and it hardcodes `--node-cidr-mask-size-ipv6=117`,
  which constrains the v6 pod CIDR (see ADR 0003's notes in `REFACTOR_PLANS.md`).

See `REFACTOR_PLANS.md` → "Additional decisions (2026-08-13)".
