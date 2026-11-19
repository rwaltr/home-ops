# `waltr.tech` is the ops zone, one level deep

Status: accepted (2026-09-09)

Every service hostname is `<app>.waltr.tech` — exactly one label below the apex. The
earlier scheme (`<app>.kyz.rwalt.pro`) broke on Cloudflare's free Universal SSL, which
covers only `<zone>` and `*.<zone>`: two-level names fail the edge TLS handshake
outright. Subdomain zones (Enterprise), partial setup (Business), Advanced Certificate
Manager ($10/month) and per-host Cloudflare-for-SaaS were all considered and rejected
for a zero-cost, wildcard-friendly single zone. `rwalt.pro` stays personal and mail.

## Consequences

- Never add a second label (`foo.bar.waltr.tech`) to anything that goes through the
  tunnel; it will not get an edge certificate.
- One wildcard certificate (`waltr.tech` + `*.waltr.tech`) serves both gateways, and the
  tunnel's `*.waltr.tech` ingress rule means publishing a host needs no tunnel edit.
- The `kyz` site label survives in paths (`infra/k8s/kyz`) but not in DNS.

See `REFACTOR_PLANS.md` → "Additional decisions (2026-09-09, cloudflare tunnel +
waltr.tech ops zone)".
