# beancount-stack (ledger + investment reports)

[Beancount](https://beancount.github.io/) v3 with [Fava](https://beancount.github.io/fava/)
as the UI, plus the statement importers and investment reports that made
Beancount the choice over ledger-cli and hledger.

| piece                      | why                                                         |
| -------------------------- | ----------------------------------------------------------- |
| `beancount` 3.2.3          | the ledger engine (v3)                                      |
| `fava` 1.30.16             | web UI                                                      |
| `beancount-reds-importers` | chase, fidelity, etrade, vanguard, schwab, ibkr, ally, amex |
| `smart-importer`           | ML payee/account suggestion during import                   |
| `fava-investor`            | asset allocation, tax-loss harvesting, gains minimisation   |

The image is built and published from **github.com/rwaltr/beancount-stack**
(public, `ghcr.io/rwaltr/beancount-stack`). home-ops only references a pinned
tag + digest; the Dockerfile, lockfile and importers live in that repo.

## Shape

```
browser ── HTTPS → k8s-gateway DNS → envoy-internal ──→ beancount-stack:5000
           (beancount.waltr.tech, on-LAN + tailnet — NO envoy-external parentRef)

/data/ledger.beancount  ← ConfigMap `beancount-stack-example`, read-only
                          example data, not real finances
/tmp, /home/beancount   ← emptyDir (readOnlyRootFilesystem is on)
```

## Manifests

`infra/k8s/kyz/apps/default/beancount-stack/` — `ks.yaml` plus `app/`
(HelmRelease, OCIRepository, ConfigMap, kustomization). Registered in
`apps/default/kustomization.yaml`.

| Piece    | Value                                                                |
| -------- | -------------------------------------------------------------------- |
| Image    | `ghcr.io/rwaltr/beancount-stack:0.1.0` (digest pinned)               |
| Chart    | shared `app-template` `5.2.1`                                        |
| Port     | 5000 (`/` — Fava answers 302, which kubelet counts as healthy)       |
| User     | `1000:1000` — the `beancount` user the image creates                 |
| Root FS  | read-only; `/tmp` and `/home/beancount` are emptyDir                 |
| State    | **none** — ledger is a ConfigMap in git, so no PVC and no kopiur job |
| Exposure | `envoy-internal` only — **not published to Cloudflare**              |

No kopiur component on purpose: there is nothing to snapshot while the ledger
lives in git. That changes the moment the real ledger moves into a PVC.

## The URL is decided by the ledger, not the manifest

Fava derives the first path segment of every URL from the ledger's
`option "title"`. The example ledger is titled `beancount`, so the UI is at
`/beancount/` and `/` redirects to `/beancount/income_statement/`. Set the
title deliberately when the real ledger lands, or the URL changes underneath
you. The probes deliberately hit `/` and accept the 3xx so they do not depend
on it.

## Reaching it

- **On the LAN / via the tailnet**: `https://beancount.waltr.tech`. The router
  forwards `waltr.tech` to k8s-gateway, and the tailnet connector advertises
  `10.10.100.0/24` with split DNS, so both resolve to the envoy-internal VIP.
- Covered by the existing wildcard `*.waltr.tech` certificate — no new
  Certificate, no Cloudflare DNS record, and no chance of it leaking out of the
  tunnel.

## The example ledger

`app/configmap.yaml` is a small hand-written example: opening balances, five
months of payroll and spending, one VTI purchase with cost basis, a price series
and a closing balance assertion. Every Fava view has something real in it, and
it is short enough to read.

For a fully populated UI instead, `uv run bean-example` (beancount 3.2.3)
generates a far richer file — but do **not** pass `--date-begin` to shrink it.
That truncates the ledger _after_ the balance assertions covering the full range
were emitted, so the result fails `bean-check` (`Balance failed for
Assets:US:Federal:PreTax401k`) and Fava refuses to load it. It also ships
misspelled narration that this repo's typos check rejects.

Replacing this file with the real ledger is a one-file change plus a reconcile;
the reloader annotation rolls the pod automatically.

## Not done yet

- the import script — `beangulp` ships no CLI, so extraction is a script we
  write using it plus the reds importers; it needs an account-naming decision
- where the ledger actually lives (private git repo vs PVC + kopiur)
- `bean-download`'s automatic statement download needs per-institution
  credentials (1Password), and it is unproven that the institutions still
  support it; manual downloads + the importers need no credentials at all
