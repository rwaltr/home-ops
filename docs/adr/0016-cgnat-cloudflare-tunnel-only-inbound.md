# Behind CGNAT, the Cloudflare tunnel is the only inbound path

Status: accepted (2026-09-09)

The ISP puts the site behind CGNAT: the WAN is RFC 1918 and there is no inbound IPv4
and no delegated IPv6. No port forward can exist, so public services reach the cluster
only through the outbound `cloudflared` tunnel (`*.waltr.tech` → `envoy-external`), and
device-level remote access goes through Tailscale. This is a constraint, not a
preference, and it is invisible from the manifests.

## Consequences

- Anything that needs a listening port reachable from the internet does not work here:
  slskd stays disabled and torrent seeding is degraded. The tunnel carries HTTP(S)
  only, so non-HTTP protocols (XMPP c2s on 5222, for the comms demo) have no public
  path either — off-LAN clients need Tailscale or a relay.
- Publishing a service is attaching its route to `envoy-external`; no router or tunnel
  change is involved (ADR 0006).
- Internal VIPs appear in public DNS for dual-homed names; CGNAT makes them unreachable
  from outside, which was accepted.

See `README.md` → Networking, `docs/books.md` → slskd, and `REFACTOR_PLANS.md` → DNS
split and Cloudflare tunnel entries.
