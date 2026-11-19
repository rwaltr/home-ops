# PVC Backups

## Purpose

Which persistent volumes are backed up, how, and how a failure becomes visible.
Derived from the kopiur component, the per-app enrolment, and the kopiur-system
README; not a live check of snapshot state. Why kopiur and RustFS:
`docs/adr/0005-kopiur-to-in-cluster-rustfs.md`; why hostpath and no CSI snapshots:
`docs/adr/0004-tank-outside-pvc-lifecycle.md`.

## Requirements

### Requirement: Back up every PVC that holds state which cannot be recreated

A PVC holding state that cannot be recreated from git, 1Password, or a re-download
SHALL be enrolled in a nightly kopiur SnapshotPolicy. A PVC that is deliberately not
enrolled SHALL say why in a comment next to its persistence definition.

#### Scenario: Add a stateful app

- **WHEN** a new app with a stateful PVC is added
- **THEN** its `ks.yaml` includes `components/kopiur/backup` with `APP` and `PVC` set
- **AND** a nightly SnapshotSchedule and its SnapshotPolicy render for that PVC

#### Scenario: Add a cache or model PVC

- **GIVEN** a PVC whose contents are re-downloadable (model weights, an index)
- **WHEN** it is left out of backups
- **THEN** its definition carries a comment saying it is re-downloadable and not backed up

### Requirement: Enrol through the shared component

Backup policies SHALL come from `infra/k8s/kyz/components/kopiur/backup`, so the PVC
name is one visible line in `ks.yaml`. A hand-written `app/kopia.yaml` SHALL be used
only when the component cannot express the policy.

#### Scenario: Back up an app with two PVCs

- **GIVEN** an app with more than one PVC, which Flux string substitution cannot
  template into one `sources` list
- **WHEN** its backup is defined
- **THEN** it uses a hand-written `app/kopia.yaml` listed in `app/kustomization.yaml`

### Requirement: Copy volumes directly and as the app's user

Every SnapshotPolicy SHALL use `copyMethod: Direct`, and its mover SHALL run as a UID
and GID that can read the app's files.

#### Scenario: Back up a hostpath volume

- **WHEN** a snapshot runs
- **THEN** the mover reads the live volume (`copyMethod: Direct`), because hostpath has
  no CSI snapshot support
- **AND** it runs as `KOPIUR_RUNAS` (default 1000), set per app where the app's user
  differs

### Requirement: Keep a fixed retention

The component SHALL keep the latest 7 snapshots, 14 daily, and 4 weekly.

#### Scenario: Count retained snapshots

- **WHEN** a policy has run nightly for over a month
- **THEN** the repository holds at most 7 latest, 14 daily, and 4 weekly snapshots for it

### Requirement: Verify backups on a schedule

Every policy SHALL run a daily quick verification and a weekly deep verification that
restores to a scratch volume, and a run SHALL fail on any error.

#### Scenario: Run the weekly deep verification

- **WHEN** the deep verification runs
- **THEN** it restores into a scratch PVC on `openebs-hostpath`
- **AND** it succeeds only if files were restored and `stats.errors == 0`

### Requirement: Distribute repository credentials by namespace label

A namespace SHALL receive the kopia repository credentials by carrying the label
`kopiur.home-operations.com/repo: cluster-kopia`, and SHALL NOT have them copied in by
hand.

#### Scenario: Enrol a new namespace

- **WHEN** a namespace outside `default` gets its first backed-up app
- **THEN** its `namespace.yaml` gains the label, and the ClusterExternalSecret supplies
  the credentials

## Baseline Evidence

Traceability pointers, not additional requirements:

- `infra/k8s/kyz/components/kopiur/backup/{snapshotpolicy,snapshotschedule}.yaml`.
- 30 apps enrolled (27 via the component, 3 hand-written: `audiobookshelf`, `freshrss`,
  `home-assistant`), counted 2026-11-19. All 30 are registered in their namespace's
  `kustomization.yaml`. `mosquitto`, `otbr` (`KOPIUR_RUNAS: "0"`, as its files are
  root-owned 0600) and `cliproxyapi` (`cliproxyapi-auth`, runs as 10000) were added on
  2026-11-19, with PVC names read from the live cluster. The disabled `music-assistant`
  and `slskd` were removed the same day.
- PVCs with no policy, each with a comment: `parakeet` and the `kubesearch-mcp` index
  (both re-downloadable). litellm and its models PVC were deleted on 2026-11-18. The disabled `go2rtc` and `matrix` apps also have no
  policy.
- Re-downloadable does not mean excluded. `wyoming-piper` and `wyoming-whisper` are
  enrolled even though they look like model caches; this requirement does not
  prohibit that.
- `infra/k8s/kyz/apps/kopiur-system/README.md`, `REFACTOR_PLANS.md` → "What the
  backup-component refactor exposed".

## Verification Limits

This baseline does not assert that last night's snapshots succeeded, that any
verification passed, or that a restore works today; `kubectl get snapshotpolicies -A`
and the kopiur metrics are the checks for that. There is no offsite copy: losing
`tank` loses the backups too.
