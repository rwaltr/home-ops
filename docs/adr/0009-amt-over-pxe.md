# Intel AMT, not PXE, for remote install and console

Status: accepted (2026-08-16)

Reinstalls and remote console use Intel AMT on mouse's i226-LM port (static
10.10.0.9): KVM plus IDE-R virtual media. PXE was researched and not chosen: it needs
DHCP next-server changes or an always-on ProxyDHCP host, and mouse is the only server,
so the PXE host would have to be the workstation. AMT covers the same need with no
infrastructure.

## Consequences

- AMT's TLS needs legacy renegotiation, which OpenSSL 3 and node refuse; access goes
  through a local stunnel bridge (recipe in `REFACTOR_PLANS.md` Phase 1).
- Revisit PXE when a second node appears.

See `REFACTOR_PLANS.md` → Phase 1, "AMT access from Linux" and "PXE (researched, NOT
chosen for n=1)".
