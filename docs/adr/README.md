# Architecture decision records

Short records of decisions that are hard to reverse, would surprise a reader, and
came out of a real trade-off. Each one says what was decided and why, and points at
the fuller history — usually a dated entry in [`REFACTOR_PLANS.md`](../../REFACTOR_PLANS.md),
which stays frozen as the long-form log.

What does not belong here: per-app runbooks (`docs/*.md`), testable contracts
(`openspec/specs/`), and gotchas (the `home-ops-troubleshooting` skill).

New ADR: next free number, `NNNN-slug.md`, one paragraph is enough. When a decision
is replaced, set `Status: superseded by NNNN` rather than deleting the file.

| ADR                                                   | Decision                                                             |
| ----------------------------------------------------- | -------------------------------------------------------------------- |
| [0001](0001-flatcar-host-os.md)                       | Flatcar Container Linux replaces uCore                               |
| [0002](0002-k0s-over-k3s.md)                          | k0s via k0sctl, not k3s                                              |
| [0003](0003-cilium-bgp-vips.md)                       | LoadBalancer VIPs announced over BGP, one session per address family |
| [0004](0004-tank-outside-pvc-lifecycle.md)            | The tank pool stays outside the PVC lifecycle                        |
| [0005](0005-kopiur-to-in-cluster-rustfs.md)           | PVC backups: kopiur + kopia into an in-cluster RustFS                |
| [0006](0006-waltr-tech-ops-zone.md)                   | `waltr.tech` is the ops zone, one level deep                         |
| [0007](0007-multus-only-for-discovery-apps.md)        | Multus/macvlan only for discovery-dependent apps                     |
| [0008](0008-no-scale-to-zero.md)                      | No scale-to-zero (zeroscale rejected)                                |
| [0009](0009-amt-over-pxe.md)                          | Intel AMT, not PXE, for remote install and console                   |
| [0010](0010-istio-ambient-deferred.md)                | Istio ambient deferred                                               |
| [0011](0011-flux-reads-github-mirror.md)              | Forgejo is authoritative; Flux reads the GitHub mirror               |
| [0012](0012-1password-connect-and-eso-for-secrets.md) | 1Password Connect + External Secrets, not SOPS                       |
| [0013](0013-no-cluster-log-store.md)                  | No cluster log store                                                 |
| [0014](0014-no-local-llm.md)                          | No local LLM in the gateway                                          |
| [0015](0015-sqlite-by-default.md)                     | SQLite by default for single-user apps                               |
| [0016](0016-cgnat-cloudflare-tunnel-only-inbound.md)  | Behind CGNAT, the Cloudflare tunnel is the only inbound path         |
| [0017](0017-manual-os-update-reboots.md)              | OS-update reboots are manual while there is one node                 |
| [0018](0018-every-alert-actionable.md)                | Every alert must be actionable, or removed                           |
