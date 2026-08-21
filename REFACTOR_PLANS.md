# Refactor Plans: Flatcar + k0s + GitOps

> **Status**: Planning / Phase 0 (Flatcar validation)
> **Reference architecture**: [onedr0p/home-ops](https://github.com/onedr0p/home-ops) (reviewed 2026-08; local clone at `~/src/onedr0p/home-ops`)
> **Owner**: @rwaltr

## Goal

Migrate the homelab from uCore + Quadlets to a GitOps-managed Kubernetes stack:

```
Flatcar (ZFS sysext) → k0sctl/k0s → Cilium (BGP) → Envoy Gateway → Flux
```

Single node (`mouse`) serves **both** ZFS storage and primary compute. Nodes live in
the management VLAN but must directly serve a second VLAN.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Host OS | **Flatcar** (replacing uCore) | A/B updates, smaller surface, official ZFS sysext since 3913.0.0 (dm-verity signed, Secure Boot OK, version-locked to release). Caveat: tagged "experimental", not for root partition (data pools only — fine for us) |
| Cluster | **k0s via k0sctl** | Already deployed on mouse; k0sctl is SSH-based, distro-agnostic. ⚠️ Do NOT use `--profile flatcar` (stale docs — no such worker profile exists; silently wedges the node) |
| CNI | **Cilium** (`provider: custom` in k0s config, kube-proxy replacement) | BGP control plane replaces MetalLB/L2 announcements |
| LB/VIPs | **Cilium BGP** (`CiliumBGPClusterConfig` + `CiliumLoadBalancerIPPool`) | Router supports BGP peering; VIPs live in dedicated service CIDR announced as /32s |
| Ingress | **Envoy Gateway** (Gateway API) | Two Gateways (internal/external) with pinned VIPs via `lbipam.cilium.io/ips`; apps attach via app-template `route:` |
| GitOps | **Flux** (flux-operator + flux-instance) | onedr0p layout: single root ks → `kubernetes/apps`, Kustomize components for cross-cutting concerns |
| Charts | **bjw-s app-template via OCIRepository** for all apps | One values schema, digest-pinned images |
| Storage | **OpenEBS ZFS LocalPV** on host pool | Already chosen; no rook-ceph (single node) |
| Backups | kopiur-style snapshots → **RustFS** (S3) | Our RustFS is the S3 backend, like onedr0p's expanse |
| VLAN L2 needs | Multus + macvlan NAD **only** for discovery-dependent apps (home-assistant class) | BGP/routed VIPs cover everything else |

### Deferred

- **Istio ambient** — revisit only if workload mTLS/SPIFFE identity becomes a concrete
  need. Requires `socketLB.hostNamespaceOnly: true` + `cni.exclusive: false` with
  kube-proxy replacement, and default-deny policies block kubelet probes. Not worth it day one.
- **Secrets**: currently SOPS+age; onedr0p uses 1Password Connect + ESO. Decide before Phase 3.

### Additional decisions (2026-08-13)

- **k0s over k3s** — k0sctl's declarative YAML + zero bundled components fit this repo;
  k3s's value-adds (Klipper/Traefik/local-path) are all things we replace anyway.
  Revisit if multi-node exposes k0s autopilot issues
- **Sysexts**: adopt **tailscale** (host tailnet access); defer incus/kata/cloud-hypervisor;
  cilium sysext is redundant (CNI runs in-cluster)
- **Bakery sysext delivery**: Flatcar's `systemd-sysupdate` does NOT discover custom
  components (verified 2026-08-13, systemd 257.9 — binary never reads `sysupdate.d`).
  Use pinned, sha256-verified download units instead (see `tailscale-sysext-install.service`
  in test.bu). Revisit sysupdate on newer systemd (`*.transfer` convention)
- **tailscale sysext validated** (2026-08-13): v1.102.2 raw in `/etc/extensions`, hash-checked,
  `tailscaled.service` active, survives reboot **and** cold-boot from Ignition. Auth key via
  SOPS when going real. Caveats found during full-rebuild testing (see lessons below):
  bakery's unit requires `/etc/default/tailscaled` and can't be wired up by Ignition
- **Cilium datapath**: if kata is likely later, set `bpf.datapathMode: veth` from day one
  (netkit is kata-incompatible and the setting is node-wide)
- **Hermes agent** (planned workload): hardened regular pod + Hermes's container terminal
  sandbox backend; kata RuntimeClass as documented upgrade path. Never the default (host)
  terminal backend on the storage node. Needs PVC → lands in backup component

## Phases

- [x] **Phase 0: Validate Flatcar** ✅ 2026-08-12
  - [x] Butane config: ZFS sysext enablement (`/etc/flatcar/enabled-sysext.conf`) — official `flatcar-zfs`, cached in `/etc/extensions`
  - [x] ZFS pool create/import works after boot **and after reboot** (sysext + pool + data all persisted)
  - [x] VLAN subinterface via systemd-networkd units (`vlan40` created, no host IP)
  - [x] k0sctl installs k0s v1.36.3 on Flatcar — ⚠️ **`--profile flatcar` breaks controller+worker**: worker binaries never stage, node never registers, k0s crash-loops every ~5 min with "Lost the controller lease". Dropping the flag fixed it. (Possibly report upstream.)
  - [x] Cilium 1.20 with `provider: custom` + `kubeProxyReplacement: true` — nginx smoke test passed
  - [x] **Full clean→rebuild reproducibility** (2026-08-13): destroyed VM + disks, rebuilt from
    `test.bu` + `infra/k0s/flatcar-test.yaml` alone — same end state (hostname, update.conf,
    tailscale sysext + daemon, ZFS pool, vlan40, k0s Ready, nginx over pod network)
  - Lessons: set `hostname` in Butane (node identity); `k8sServiceHost: 127.0.0.1:7445` in onedr0p's Cilium values is **Talos KubePrism** — k0s needs the direct API address (or `nodeLocalLoadBalancing`) 
- [x] **Phase 0.5: mouse via Ignition + generic VM harness** ✅ 2026-08-13
  - [x] `infra/flatcar/butane/base.bu` (rwaltr+keys+sudoers, tailscale sysext units,
    update-strategy-off, resolved mDNS drop-in) + `hosts/mouse.bu` (hostname, hostid
    1e1719e4, ZFS sysext, **import-only** tank unit, DHCP+mDNS on NIC glob)
  - [x] Live-mouse facts baked in: mgmt on 10.10.0.0/16, igc NIC (i226-LM, MAC
    58:47:ca:74:fb:1c), tank = raidz1×2 6×5.5T at /var/tank; VLANs 30/40 NOT on host
  - [x] Bare-metal addressing: **static 10.10.0.10** via MAC-matched networkd unit
    (20-mouse-static.network); unknown NICs (VMs) fall through to DHCP (25-primary).
    Old uCore DHCP lease .105 dies with uCore — no cutover conflict
  - [x] mDNS: systemd-resolved responder (`MulticastDNS=yes`) — no avahi needed;
    mouse.local verified listening on UDP 5353 v4+v6 (end-to-end LAN test needs bare
    metal — qemu user-net blocks multicast)
  - [x] Generic host-arg'd tasks: `flatcar:{bootstrap,vm,seed,verify,k0s,clean,vm-connect} [host]`
    (default mouse; ports/users in `vm_ports`/`vm_user` in .mise/lib/common.sh).
    **`flatcar:bootstrap mouse` = full env from scratch in one command**
  - [x] Naming normalized for host-arg consistency: `.vm/<host>.*`,
    `infra/k0s/<host>.yaml` (flatcar-test.yaml → test.yaml)
  - [x] `flatcar:seed mouse` hand-creates tank (mirrors bare metal), poweroff → next
    boot exercises the real Ignition import path. Verified: tank ONLINE at /var/tank
  - [x] `infra/k0s/mouse.yaml` prod k0sctl config; task renders VM variant (address→
    127.0.0.1:2224) so the prod spec is what gets tested. k0s+Cilium+nginx ✅
  - Lessons: butane `local:` merge inlines as gzipped data: URL (works fine on Flatcar);
    k0sctl kubeconfig hardcodes :6443 → task rewrites to per-host API port; `#MISE confirm`
    aborts non-interactive chains → vm --force calls the clean script directly;
    konnectivity-agent gets stuck in NetworkNotReady backoff when CNI is out-of-band →
    task bounces it post-Cilium; VM serial upgraded to socket+logfile (interactive debug
    via `socat - UNIX-CONNECT:.vm/<host>-serial.sock`); base.bu carries 4 SSH keys —
    the 3 from uCore base.bu + this workstation (zirconium-bisync)
- [ ] **Phase 1: Bare-metal mouse** — provision real hardware
  - [x] uCore decommissioned (2026-08-13): `infra/ucore/`, `ucore:*` tasks, `kyz-0.yml`,
    FCOS ISO, `check_virsh` all removed; `hosts/template.bu` ported to Flatcar
  - [x] Hardware recon (2026-08-13): MS-01 (i9, 20c/31G), boot = nvme0n1 954GB (OS-only,
    nothing to preserve), pool = sda–sdf whole-disk vdevs (never touched by install),
    UEFI, i226-LM = AMT/vPro port (left 2.5G, carries mgmt), X710 SFP+ ×2 unused

  **Runbook** (console session; ~30 min):
  0. **AMT first** (one-time, pays off forever): BIOS (Del) → ME enabled; MEBx (Ctrl+P,
     default pw `admin`, forced change) → enable AMT + KVM → network **static 10.10.0.106**
     (AMT-over-DHCP is flaky on i226-LM). Then `https://10.10.0.106:16993` + MeshCommander
     KVM/IDE-R = remote console + virtual-media ISO boot for all future reinstalls
  1. Pre-flight: `mise run flatcar:build`; Flatcar stable ISO → USB (or AMT IDE-R);
     confirm backups (6.7T pool isn't touched, but disk-selection mistakes are final)
  2. Boot live env → DHCP → `scp infra/flatcar/ignition/mouse.ign core@<ip>:`
  3. `lsblk` — target is **nvme0n1 ONLY** (954GB; the six 5.5T are the pool)
  4. `sudo flatcar-install -d /dev/nvme0n1 -i mouse.ign` → reboot, remove media
  5. First boot applies Ignition (hostname, hostid, keys, tailscale, mDNS, update-off,
     zfs sysext) → `zfs-import-tank` imports the existing pool to /var/tank
  6. Verify from workstation: `ssh rwaltr@10.10.0.10` — zpool status (6/6 ONLINE),
     df /var/tank, tailscaled active; `sudo tailscale up` (NEW tailnet identity —
     delete the old mouse node); mouse.local via mDNS
  7. `k0sctl apply --config infra/k0s/mouse.yaml`; Cilium helm with
     `k8sServiceHost=10.10.0.10` (NOT the VM's 10.0.2.15); then Phase 2 owns cluster state
  8. Rollback: reinstall uCore from git history the same way; pool imports identically

  **How the install ACTUALLY went down (2026-08-16)** — none of the designed paths
  survived contact; what worked was disassembly:
  1. kexec into the PXE live env boots fine, but it's hostile unattended: no autologin
     on the generic path (`flatcar.autologin` didn't take), and Ignition's URL fetch
     needs BOTH the right arg (`ignition.config.url`, not `flatcar.ignition.config.url`)
     AND `ip=dhcp` (dracut skips initramfs networking otherwise) — never got a fetch
  2. `flatcar-install` from running uCore (RAM-resident fedora container) **completed
     the full image dd** before failing on `rereadpt`/`wipefs` — kernel won't reload
     the partition table of the disk the OS runs from. KEY INSIGHT: dd happens BEFORE
     those steps; the "failure" left a complete Flatcar disk missing only `config.ign`
  3. Winning move: write `config.ign` into the OEM partition via **loop device at
     absolute sector offset** (`losetup -o $((sector*512)) --sizelimit ... -f /dev/nvme0n1`)
     — bypasses the stale in-memory partition table entirely. Then `sysrq b` reboot
  4. First boot: Ignition read config.ign from the OEM partition (no URL fetch!),
     applied mouse.ign, came up at static 10.10.0.10. ✅

  **Lessons:**
  - **Export the pool BEFORE pulling disks** — a suspended pool wedges any sync()-caller
    (incl. kexec's pre-load sync) in zil_commit forever
  - flatcar-install order of ops: dd image → rereadpt → wipefs → mount OEM → cp config.ign.
    A failure late in that list may still leave a fully-imaged disk — read the script
    before assuming failure
  - `losetup --offset/--sizelimit` edits partitions on busy disks (kernel table be damned)
  - The PXE live env is for PXE. Via kexec it's a login wall with extra steps
  - AMT KVM + IDE-R + stunnel bridge = the insurance that made all risk-taking free
  - Corrupted /etc/containers/policy.json (NUL padding) = interrupted write during a
    power-cycle; only image pulls notice

  **AMT access from Linux** (validated 2026-08-16): AMT = static 10.10.0.9 on the
  i226-LM port (left 2.5G), TLS-only (16992 plain is filtered; 16993/16995 open).
  Gotcha: its TLS stack needs **legacy renegotiation** (pre-RFC5746) which OpenSSL 3
  refuses — and node.js (MeshCommander) ignores OPENSSL_CONF, so it can't be fixed
  client-side. Solution: **stunnel TLS bridge** on localhost, MeshCommander talks plain:

  ```
  # /tmp/amt-stunnel.conf — bridges BOTH port pairs (WS-Man + KVM/IDE-R)
  foreground = yes
  pid =
  [amt-wsman]
  client = yes
  accept = 127.0.0.1:16992
  connect = 10.10.0.9:16993
  options = ALLOW_UNSAFE_LEGACY_RENEGOTIATION
  [amt-redir]
  client = yes
  accept = 127.0.0.1:16994
  connect = 10.10.0.9:16995
  options = ALLOW_UNSAFE_LEGACY_RENEGOTIATION
  ```

  ```bash
  podman run -d --name amt-bridge --rm --network host \
    -v /tmp/amt-stunnel.conf:/etc/stunnel/stunnel.conf:ro,Z \
    docker.io/library/debian:trixie-slim bash -c \
    "apt-get update -qq && apt-get install -y -qq stunnel4 >/dev/null 2>&1 && stunnel /etc/stunnel/stunnel.conf"

  # MeshCommander web UI (node): host networking so its 127.0.0.1 bind is reachable
  podman run -d --name meshcommander --rm --network host \
    docker.io/library/node:22-slim bash -c \
    "cd /tmp && npm install meshcommander --no-audit --no-fund --loglevel=error && node node_modules/meshcommander"
  # → http://localhost:3000, Add Computer = 127.0.0.1, admin + MEBx pw, TLS OFF
  ```

  Direct curl works with an OPENSSL_CONF allowing UnsafeLegacyRenegotiation (SECLEVEL=1).
  AMT DHCP mode = shared host IP (snoops host's DHCP) — host is static, so AMT must be static.

  **SOL (Serial-over-LAN)** — documented, NOT yet enabled in mouse.bu:
  the ME exposes a virtual UART as ttyS0; AMT side is already live (16995 open).
  To use it later: add to the host .bu (flatcar variant supports kernel_arguments,
  verified 2026-08-16):
  ```yaml
  kernel_arguments:
    should_exist:
      - console=ttyS0,115200n8
  ```
  systemd auto-spawns serial-getty on console= ports, so that's the whole OS side.
  Client: `amtterm -h 127.0.0.1 -u admin -p <MEBx pw>` (amtterm pkg) through the
  stunnel bridge's plain 16994 side. Bonus: enable BIOS "Serial Console Redirection"
  for POST/GRUB visibility too. Use case: text-only remote console in tmux,
  loggable/scriptable, no KVM protocol needed.

  **PXE (researched, NOT chosen for n=1)**: Flatcar publishes PXE kernel+initrd
  (`flatcar_production_pxe.vmlinuz` / `_image.cpio.gz`); iPXE script boots it with
  `flatcar.ignition.config.url=http://<server>/mouse.ign` (http/https/tftp). Needs DHCP
  next-server+bootfile (router-dependent) or ProxyDHCP dnsmasq on an always-on device —
  mouse is the only server, so that's the workstation (chicken-egg). Middle ground:
  flash tiny iPXE USB → chainload HTTP script, no DHCP changes. But AMT IDE-R covers
  the same remote-boot need with zero infrastructure → **AMT > PXE for a single node**.
  Revisit PXE if a second node appears.
- [ ] **Phase 2: Bootstrap** — BUILT at `k8s/kyz/bootstrap/helmfile/` (rendered against live cluster, not yet applied). DAG: cilium → coredns → cert-manager → external-secrets → onepassword-connect → flux-operator/instance. Secrets: 1Password Connect + ESO — `op inject` seeds the Connect creds at bootstrap (`OP_SERVICE_ACCOUNT_TOKEN` env, prompted; no SOPS for k8s). Layout decision: `k8s/<site>/` (kyz = this site; future sites sit beside it). Run: `mise run k8s:bootstrap mouse` — needs 1P item `1password` in vault `home-ops` with OP_SESSION_JSON + OP_CONNECT_TOKEN. Model: `~/src/onedr0p/home-ops/bootstrap/helmfile/`
- [ ] **Phase 3: GitOps layout** — `kubernetes/{apps,components,flux}`; root ks with HelmRelease default patches; components: alerts, backup, zeroscale
- [ ] **Phase 4: Networking** — Cilium BGP resources, Envoy Gateway internal/external, cert-manager, external-dns (Cloudflare)
- [ ] **Phase 5: Workloads** — migrate rustfs/netdata quadlets into cluster; remaining apps
- [ ] **Phase 6: Automation** — Renovate (home-operations presets, tiered automerge), CI (butane validate, image pull check)

## Lessons from onedr0p/home-ops review

1. **Uniformity beats cleverness** — every app: `ks.yaml` + `app/{kustomization,ocirepository,helmrelease}.yaml`
2. **Push defaults to platform layer** — root Flux ks patches HelmRelease defaults (CRD handling, remediation) into every child
3. **Kustomize components** with `${VAR:=default}` for backup/alerts/zeroscale — one line per app
4. **Bootstrap as explicit DAG** (helmfile `needs:`), CRDs applied out-of-band to kill dependsOn chains
5. **Zero secrets in git** — resolved at render/apply time
6. **Renovate does the heavy lifting** — shared presets, digest automerge, min release age
7. **CI pulls images on PR** to catch dead registries before merge
8. Webhook `Receiver` for push-to-reconcile (seconds, not the 1h interval)

## Lessons from knuckle (`~/src/knuckle`, projectbluefin Flatcar installer)

Knuckle is a TUI/headless Butane generator — everything it produces is Butane, so
hand-written Butane stays our source of truth. Steal these:

1. **update-engine auto-reboots by default** → pin `REBOOT_STRATEGY=off` in
   `/etc/flatcar/update.conf`; reboots become deliberate (kured or manual).
   ⚠️ Exception to "everything is Butane": see Ignition limits below — this file
   can't be Ignition-written, needs a boot unit

## Ignition limits found by full-rebuild bisection (2026-08-13)

Failure mode for all three: `ignition-files` fails silently to serial, VM black-box
reboot-loops every ~5 min. Found by diffing against last-known-good config one change
at a time (console log only shows `res=failed`; detail stays in the journal).

1. **Ignition cannot overwrite `/etc/flatcar/update.conf`** — it exists in the base
   image (empty). `ignition-files` fails on overwrite. Fix: `update-strategy-off.service`
   oneshot writes `REBOOT_STRATEGY=off` post-boot
2. **Ignition cannot enable sysext-provided units** — `enabled: true` on
   `tailscaled.service` fails the same way (unit doesn't exist until merge). Fix: the
   install unit runs `systemctl enable --now tailscaled.service` after `systemd-sysext refresh`
3. **Bakery `tailscaled.service` has a mandatory `EnvironmentFile=/etc/default/tailscaled`**
   (upstream tailscale marks it optional with `-`). Unit crash-loops without it. Fix: ship
   `PORT="41641"`/`FLAGS=""` via Butane. Knuckle's "auto-starts at boot" claim needs this too
4. **systemd unit quoting**: `ExecStartPost=/bin/sh -c "echo '$${VAR}  file' | sha256sum -c"`
   — single quotes block systemd var expansion → bogus hash line, unit fails. Use escaped
   double quotes
5. **k0sctl honors the real `known_hosts`** — recreated VM = new host key = apply fails
   with "host key mismatch". The `flatcar:k0s` task auto-clears the per-host entry now
2. **Flatcar ships no swap** — fine for k8s (kubelet default), deliberate choice
3. **Bakery sysext catalog** (extensions.flatcar.org): `tailscale` (Integrated
   tier — host tailnet access), `bird` (redundant — Cilium BGP in-cluster),
   `nvidia-drivers`. Bakery sysexts update via `systemd-sysupdate` separately
   from OS updates; official sysexts ride the release
4. Knuckle headless mode may be useful later for bare-metal installer media
   for mouse instead of hand-rolling flatcar-install

## Open questions

- [ ] Controlled reboot mechanism for OS updates: kured vs manual?

- [ ] SOPS+age (keep) vs 1Password Connect + ESO (adopt)?
- [ ] Dedicated service CIDR for BGP pool: `192.168.x.0/24` — pick one
- [ ] Router ASN / node ASN assignment
- [x] ~~Which VLAN ID is the "served" VLAN?~~ → **30 (iot) + 40 (cameras), both reached
  via k8s (home-assistant/macvlan or BGP), NOT configured on the host** (2026-08-13)
- [x] ~~`infra/k0s/kyz-0.yml` superseded by `mouse.yaml`~~ → deleted with uCore decom (2026-08-13)
- [x] ~~Do other hosts stay on uCore, or does everything move to Flatcar?~~ → everything moves; uCore decommissioned 2026-08-13
