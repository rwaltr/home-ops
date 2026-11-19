# PostgreSQL (CloudNativePG)

Apps that need Postgres get **their own** CloudNativePG cluster in their own
namespace. There is no shared database server. Everything else stays on SQLite,
backed up by kopiur. That's where bjw-s and onedr0p both ended up: onedr0p ran
one shared `postgres16` for years and moved his apps back to SQLite in 2024-12.
A shared server would save one process, but it costs cross-namespace
credentials and all-or-nothing outages and upgrades.

|                |                                                                                    |
| -------------- | ---------------------------------------------------------------------------------- |
| Operator       | `apps/cnpg-system/cloudnative-pg` (CNPG 1.30)                                      |
| Backups        | Barman Cloud plugin, `apps/cnpg-system/cloudnative-pg/plugin`, same namespace      |
| Object store   | RustFS `s3://cnpg/` (`tank/backup/k8s`), one prefix per database (`serverName`)    |
| S3 credentials | RustFS user `cnpg`, policy `cnpg-rw` (bucket `cnpg` only), 1Password `cnpg-rustfs` |
| Template       | `infra/k8s/kyz/components/cnpg/pg18` (ported from bjw-s-labs/home-ops)             |
| Clusters       | `immich/immich-postgres` (template), `kritika/kritika-postgres` (own, see below)   |

## The template

An app opts in from its `ks.yaml`:

```yaml
spec:
  components:
    - ../../../../components/cnpg/pg18
  postBuild:
    substitute:
      APP: immich
```

It renders:

- `Cluster/${APP}-postgres`: one instance of PG18 on the `standard` image
  (pgvector and contrib), with VectorChord loaded as an image-volume extension.
  It sits on `openebs-hostpath`, and the plugin archives WAL continuously.
- `ObjectStore`: 30-day retention, gzip.
- `ScheduledBackup`: daily at 02:00. It's six-field cron, and the first field is
  **seconds**.
- `PodMonitor`, plus the `ExternalSecret` with the `cnpg` S3 keys.

CloudNativePG generates `${APP}-postgres-app` in the app's namespace, with
`username`, `password`, `host`, `port`, `dbname` and `uri`. Point the app at its
`uri`. Nothing crosses namespaces and nothing goes through 1Password.

Optional variables are listed at the top of `pg18/cluster.yaml`: database,
owner, owner superuser, size, memory, schedule and retention. An import strips
superuser from the owner (CloudNativePG does this after `pg_restore`), so an app
that needs it, like Immich, has to set `CNPG_SUPERUSER: "true"`.

### The cluster always restores from backup

The template's `bootstrap` is a **recovery** from the object store, never
`initdb`. CloudNativePG reads `bootstrap` only when it creates the cluster, so
the stanza does nothing while the cluster runs. It does mean disaster recovery
needs no edits:

```sh
kubectl -n <ns> delete cluster <app>-postgres
kubectl -n <ns> delete pvc <app>-postgres-1   # a leftover PVC is reused, not restored
flux reconcile ks <app> -n <ns>               # recovers latest base backup + all WAL
```

It also means a **new** database has nothing to recover from, so it is seeded
once:

```sh
# app committed locally, not merged yet
mise run cnpg:seed <namespace> <kustomization>
# or import a running database (writes to it must be stopped):
mise run cnpg:seed <namespace> <kustomization> --import-host <host> --import-secret <basic-auth secret> --import-db <db>
```

The seed renders the same manifests Flux will apply. It creates a temporary
`<app>-postgres-seed` cluster with `initdb` (optionally importing through
CloudNativePG's `microservice` `pg_dump` import). It takes one base backup into
the real cluster's prefix, then deletes the seed cluster. After that, merge and
let Flux create the real cluster from that backup.

### Major upgrades

Don't edit `pg18` in place. Copy it to `pg19`, then change three things: the
image major, the vchord image, and the `-pg18` suffix on `CNPG_SERVER_NAME`. Then
point the app's `ks.yaml` at `pg19` and seed again with `--import-host` set to
the old cluster's `-rw` Service. `pg_upgrade` resets the timeline to 1, so a
shared prefix would let the new cluster overwrite the old one's WAL. Separate
prefixes rule that out.

## kritika

`kritika-postgres` uses only `components/cnpg/base`: the backups, not the
template's cluster. The kritika chart already uses a Secret named
`kritika-postgres-app` for its non-owner role (`kritika_app`), and that clashes
with the one CloudNativePG generates. Its cluster still bootstraps with
`initdb`. To restore it, replace `bootstrap` with the recovery stanza from
`pg18/cluster.yaml` (source `kritika-postgres`, serverName
`kritika-postgres-pg18`), then delete the Cluster and its PVC.

## Checking backups

```sh
kubectl get backups -A                                   # one per day per cluster
kubectl get cluster -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ARCHIVED:.status.firstRecoverabilityPoint,LASTWAL:.status.lastArchivedWAL
```

`ContinuousArchiving` in `kubectl describe cluster` must be `True`. A failing
WAL archive fills the PVC; `max_slot_wal_keep_size: 2GB` caps the slot side of
that.

## History: Immich's move (2026-11-19)

Immich ran a hand-rolled `ghcr.io/immich-app/postgres:17-vectorchord` Deployment
on PVC `immich-postgres`, which kopiur copied file by file while Postgres ran.
The move went like this:

1. Took kopiur snapshot `immich-pre-cnpg` (Retain) of that PVC.
2. Scaled down every writer: Immich server and ML, and the paperless bridge.
3. Ran `cnpg:seed` with `--import-host immich-postgres`. That's CNPG's
   `pg_dump` import into PG18, then the first base backup.
4. Merged, so Flux created `immich-postgres` from that backup.

The old PVC kept `helm.sh/resource-policy: keep`. Delete it, the 1Password
item `immich`, the `immich-postgres-import` Secret and the snapshot once the new
cluster has run for a while.
