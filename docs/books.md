# Books, audiobooks and music downloads

Three new workloads over the **existing** tank `books` dataset. Acquisition and
reading are deliberately split. The Soulseek client (`slskd/`) stays **disabled**
— see the section below for why.

```
                    /var/tank/nas/library/books  (hostPath off the tank)
                                  │
   ┌──────────────────┬───────────┴───────────┐
   │                  │                       │
 Chaptarr          Kavita             Audiobookshelf
 (manage/import    (read: epub,        (stream: audiobooks,
  eBook+audio, rw)  comics, pdf, ro)   podcasts; ro)
   │
 /downloads  ──── shared with SABnzbd
   │
 Prowlarr (indexers) → SABnzbd (usenet)
```

Everything is **internal-only** (`envoy-internal`). Publishing any of these is a
one-line `parentRefs` addition and rwaltr's call — the internal set is
deliberate.

## The library dataset

| Dataset                    | What it is                                                                |
| -------------------------- | ------------------------------------------------------------------------- |
| `tank/nas/library/books`   | **The existing book collection.** All three new apps mount this one path. |
| `tank/nas/library/archive` | exists, untouched                                                         |
| `tank/nas/library/games`   | exists, untouched                                                         |
| `tank/nas/library/media`   | movies/tv/videos — the Jellyfin/Sonarr/Radarr libraries                   |
| `tank/nas/library/music`   | Navidrome + Jellyfin                                                      |
| `tank/nas/pictures`        | Immich                                                                    |

**Mount the dataset, choose the root in the UI.** Each app mounts
`/var/tank/nas/library/books` whole and its library folders are added in its own
UI (Chaptarr: root folders; Kavita: libraries; Audiobookshelf: libraries). That
way the on-disk layout inside the dataset — flat, or `ebooks/` + `audiobooks/`
subdirectories — does not have to match anything committed here.

A dedicated `tank/nas/library/audiobooks` dataset is the tidier end state if the
collections are separate; creating it is a host operation (`zfs create
tank/nas/library/audiobooks`) and then a one-line `hostPath` change per app.

**What is not known from here:** only the dataset _names_ are readable in-cluster
(the node-exporter zfs collector). The agent pod has no `/var/tank` mount,
`pods/exec` is not granted and pod creation is not permitted, so file counts,
formats and the internal layout of `books` have not been measured. To scope it on
the host:

```bash
zfs list -o name,used,referenced tank/nas/library/books
du -sh /var/tank/nas/library/books/* 2>/dev/null
find /var/tank/nas/library/books -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn | head
```

## Manifests

`infra/k8s/kyz/apps/default/` — each app is `ks.yaml` + `app/` (HelmRelease,
OCIRepository, HTTPRoute, and a kopiur policy where it is not the shared
component). All are registered in `apps/default/kustomization.yaml`.

| App            | Image (pinned)                            | Chart                | Port | Library mount                     |
| -------------- | ----------------------------------------- | -------------------- | ---- | --------------------------------- |
| Chaptarr       | `docker.io/chaptarr/chaptarr:0.9.1000`    | `app-template` 5.2.1 | 8789 | `/books` (rw) + `/downloads` (rw) |
| Kavita         | `docker.io/jvmilazz0/kavita:0.9.1`        | `app-template` 5.2.1 | 5000 | `/books` (ro)                     |
| Audiobookshelf | `docker.io/advplyr/audiobookshelf:2.37.2` | `app-template` 5.2.1 | 80   | `/books` (ro)                     |

`slskd/` is still in the tree but **not registered** in the parent
kustomization — see below.

| App            | State PVCs                                      | Backup                              |
| -------------- | ----------------------------------------------- | ----------------------------------- |
| Chaptarr       | `chaptarr` (5Gi)                                | shared kopiur component, `H 18`     |
| Kavita         | `kavita-config` (5Gi)                           | shared kopiur component, `H 19`     |
| Audiobookshelf | `audiobookshelf-config`, `-metadata` (5Gi each) | hand-written two-PVC policy, `H 20` |

Audiobookshelf keeps state in **two** PVCs, and the shared component templates a
single `${PVC}`, so its policy is hand-written in `app/kopia.yaml` — the same
exception FreshRSS and Home Assistant already carry. The verification block is
duplicated with it; keep the two in step.

### Why Chaptarr and not Readarr

Readarr is retired: the upstream repo is archived (2025-06) and its metadata
servers are gone, so it cannot search or match anything. Chaptarr is the
maintained community fork and handles eBooks and audiobooks in one instance.
Note its own README calls it **beta** and warns to back up before pointing it at
a library you cannot lose — which is what the kopiur policy above is for.

### Why Audiobookshelf as well as Kavita

Different media, different clients. Kavita reads eBooks/comics/manga in a browser
and tracks reading position. Audiobookshelf streams audiobooks and podcasts with
progress, speed and sleep-timer support and has native iOS/Android apps — the
Navidrome-equivalent for spoken audio. Jellyfin can technically serve audiobooks
but gives none of that.

## First run

No secret is committed for any of these — each app creates its own account in its
own web UI on first visit, exactly like Navidrome:

- Chaptarr — first visit creates the admin user; add root folders against
  `/books` (ebook and audiobook roots) and `/downloads` for imports.
- Kavita — first visit creates the admin account; add libraries against
  `/books`.
- Audiobookshelf — first visit creates the root user; add a library against
  `/books/<audiobook subdirectory>`.

## slskd (Soulseek) — left disabled (CGNAT)

`infra/k8s/kyz/apps/default/slskd/` is in the tree but **not registered** in the
parent kustomization, and it was decided on 2026-11-14 to leave it that way. It
briefly merged registered in #1005 and was taken back out in #1007 — the pod sat
in `CreateContainerConfigError` the whole time, because the 1Password item it
needs did not exist.

The blocker is connectivity, not the software. The site is CGNAT with no port
forwards, so slskd's listening port (default 50300) has no inbound route.
Outbound still works — searching and downloading are fine, because the client
connects out to peers. What doesn't work is peers connecting _to us_, which is
the upload half. Soulseek expects reciprocity: a client that shares nothing gets
ignored or blocked, and this one would look like a low-connectivity peer
permanently. Shipping that is worse than not shipping it.

**What was fixed anyway**, so a later re-enable does not reintroduce two faults
that were dormant only because the app never worked:

- **The music hostPath was wrong.** It pointed at
  `/var/tank/nas/library/media/music`, which is not a path on the tank; kubelet
  created it empty, so slskd would have shared nothing. Corrected to
  `/var/tank/nas/library/music` (the dataset Navidrome and Jellyfin mount).
- **The kopiur PVC name was wrong.** `ks.yaml` passed `PVC: slskd-app-data`, but
  app-template renders the claim as plain `slskd` (it only suffixes the name once
  a second PVC exists), so the snapshot policy named a claim that does not exist.
  Corrected to `slskd`.

**To re-enable**, when there is an inbound route for the port (a tailnet path or
a forward): uncomment the one line in the parent `kustomization.yaml`, and create
the 1Password item **`slskd`** with fields `soulseek_username` and
`soulseek_password` — the ExternalSecret reads exactly those names, and a
mismatch syncs an empty value rather than erroring. (Its absence is precisely why
the pod above could not start: missing item means no Secret, and the container
never gets env.) The Soulseek account itself is created by the first successful
login; there is no registration. The web UI's own credential is separate and
defaults to `slskd` / `slskd`.

**Soulseek has no supported bridge into Chaptarr or Lidarr** — Soularr is
Lidarr→slskd for music only — so a Soulseek transfer is a manual workflow:
download it, then let the app import from `/downloads` or drop it in the library.

## Kavita's config seed lives in the image's `/tmp`

`jvmilazz0/kavita` ships its default config at **`/tmp/config/appsettings.json`**
(`COPY Kavita.Server/config/appsettings.json /tmp/config/appsettings.json` in its
Dockerfile) and Kavita copies it into `/kavita/config` on first boot. That means
**do not add a `tmp: emptyDir` mounted at `/tmp`** to this app — it shadows the
baked seed file and the container dies with:

```text
Kavita configuration file does not exist, copying from temp...
cp: cannot stat '/tmp/config/appsettings.json': No such file or directory
```

Other apps in the tree carry that mount legitimately; Kavita must not. With no
`/tmp` mount the container layer is writable anyway
(`readOnlyRootFilesystem: false`), so nothing is needed there.

## Unverified at merge time

These are stated so a later reader does not mistake them for measurements:

- **Ports and probes.** Container ports come from the images' own `ExposedPorts`
  and READMEs (8789 / 5000 / 80). The probes are the chart's default `tcpSocket`,
  not an HTTP path, because no health route was verified against a running
  container — this pod has no docker daemon. Chaptarr's image config also carries
  `ASPNETCORE_HTTP_PORTS=8080` while its docs publish 8789, so the entrypoint is
  assumed to front 8080 on 8789.
- **Non-root.** All three images run as root by default and use wrapper
  entrypoints. They are pinned to `runAsNonRoot` + `1000:1000` with an
  fsGroup-owned PVC, which is believed sufficient (Chaptarr gets `PUID`/`PGID`;
  Audiobookshelf's entrypoint does no chown). If an entrypoint insists on root,
  the one-line remedy is `runAsUser: 0` in that app's `defaultPodOptions`.
- **Root filesystem.** Left writable (`readOnlyRootFilesystem: false`) for all
  three rather than assumed clean.
- **Chaptarr is beta** and writes to the library; the copy of the `books` dataset
  is the only protection, and it is a host-path dataset that kopiur does **not**
  cover. Snapshotting `tank/nas/library` on the host is worth considering.
