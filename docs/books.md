# Books and audiobooks

Two workloads over the **existing** tank `books` dataset — a reader and a
streamer. **Acquisition is deliberately unsolved**; that section explains why and
what is still missing.

```
                    /var/tank/nas/library/books  (hostPath off the tank, ro)
                                  │
              ┌───────────────────┴───────────────────┐
              │                                       │
            Kavita                             Audiobookshelf
        (read: epub, comics,               (stream: audiobooks,
         pdf — browser + apps)              podcasts — native apps)
```

Everything is **internal-only** (`envoy-internal`). Publishing either is a
one-line `parentRefs` addition and rwaltr's call — the internal set is
deliberate.

## The library dataset

| Dataset                    | What it is                                                       |
| -------------------------- | ---------------------------------------------------------------- |
| `tank/nas/library/books`   | **The existing book collection.** Both apps mount this one path. |
| `tank/nas/library/archive` | exists, untouched                                                |
| `tank/nas/library/games`   | exists, untouched                                                |
| `tank/nas/library/media`   | movies/tv/videos — the Jellyfin/Sonarr/Radarr libraries          |
| `tank/nas/library/music`   | Navidrome + Jellyfin                                             |
| `tank/nas/pictures`        | Immich                                                           |

**Mount the dataset, choose the root in the UI.** Each app mounts
`/var/tank/nas/library/books` whole and its library folders are added in its own
UI. That way the on-disk layout inside the dataset — flat, or `ebooks/` +
`audiobooks/` subdirectories — does not have to match anything committed here.

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

The in-app folder picker described below browses that same directory through the
container, so it answers the layout question in one screen without a host login.

## Manifests

`infra/k8s/kyz/apps/default/` — each app is `ks.yaml` + `app/` (HelmRelease,
OCIRepository, HTTPRoute, and a kopiur policy where it is not the shared
component). All are registered in `apps/default/kustomization.yaml`.

| App            | Image (pinned)                            | Chart                | Port | Library mount |
| -------------- | ----------------------------------------- | -------------------- | ---- | ------------- |
| Kavita         | `docker.io/jvmilazz0/kavita:0.9.1`        | `app-template` 5.2.1 | 5000 | `/books` (ro) |
| Audiobookshelf | `docker.io/advplyr/audiobookshelf:2.37.2` | `app-template` 5.2.1 | 80   | `/books` (ro) |

| App            | State PVCs                                      | Backup                              |
| -------------- | ----------------------------------------------- | ----------------------------------- |
| Kavita         | `kavita-config` (5Gi)                           | shared kopiur component, `H 19`     |
| Audiobookshelf | `audiobookshelf-config`, `-metadata` (5Gi each) | hand-written two-PVC policy, `H 20` |

Audiobookshelf keeps state in **two** PVCs, and the shared component templates a
single `${PVC}`, so its policy is hand-written in `app/kopia.yaml` — the same
exception FreshRSS and Home Assistant already carry. The verification block is
duplicated with it; keep the two in step.

### Why a reader and a streamer instead of one app

Different media, different clients. Kavita reads eBooks/comics/manga in a browser
(and has mobile apps) and tracks reading position. Audiobookshelf streams
audiobooks and podcasts with progress, speed and sleep-timer support and has
native iOS/Android apps — the Navidrome-equivalent for spoken audio. Jellyfin can
technically serve audiobooks but gives none of that.

## First run

No secret is committed for either app — each creates its own account in its own
web UI on first visit, exactly like Navidrome:

- **Kavita** — `https://kavita.waltr.tech`, first visit creates the admin account.
- **Audiobookshelf** — `https://audiobooks.waltr.tech`, first visit creates the
  root user.

## Hooking in the existing library

The mounts are already in place; both apps see the collection at `/books`
read-only. What remains is per-app library creation, and it is not automatic —
there is no declarative hook for it, so it is a UI step.

**Kavita** — Settings (gear) → **Libraries** → **Add Library**:

- Type: **Book** (for epub/pdf; Manga/Comic/Light Novel are the other types)
- **Add Folder** → the dialog browses the _container_ filesystem → pick `/books`
  or the subdirectory under it
- Save, then let it scan. Turn on the library's folder watching if you want new
  files picked up without a manual scan.

**Audiobookshelf** — Settings → **Libraries** → **Add Library**:

- Media type: **Books** (Podcasts is the other option)
- **Add Folder** → same container-scoped picker → `/books` or a subdirectory
- Save; ABS scans and matches metadata itself.

Two things to expect:

- **Both mounts are read-only.** Files get into the library by landing on the
  tank, not through these apps.
- **The folder picker is the fastest way to learn the layout.** If `/books` comes
  back empty, the dataset is empty and there is nothing to hook in yet — that is
  a finding, not a misconfiguration.

Once a library exists, the scan outcome is readable from here: Kavita logs
`Library`/`Scan` lines and Audiobookshelf logs `Scanner`/`Watcher` lines, so a
zero-item scan or a permission failure can be diagnosed from the pod logs without
a host login.

## Acquisition is unsolved

This is the honest state, not an oversight. PR #1005 brought a manager
(`chaptarr`) and a Soulseek client (`slskd`); both were removed again on
2026-11-14, for two different reasons.

**Usenet does not carry this material.** Prowlarr searches for two Black Library
titles (_Vagabond Squadron_, _Da Freebooterz Code_) returned nothing, and
Infected Mushroom — the most established act in its genre — came back slim. That
is one indexer (NZBgeek) speaking, so the accurate reading is "usenet is the
movies/TV engine, not the books engine". Prowlarr's book coverage is thin in
general: of 584 indexer definitions only EBookBay (public, ebooks), ABtorrents
(private, audiobooks) and BookTracker (RU) are book-related, and **MyAnonaMouse
has no Prowlarr definition at all**.

**Chaptarr was not limited to usenet — it was still the wrong tool here.**
Verified against its source tree, it ships `Newznab` _and_ `Torznab` indexers plus
`MyAnonaMouse`, `IPTorrents`, `FileList`, `Gazelle`, `Nyaa` and `Torrentleech`
built in, and torrent download clients including `QBittorrent`, `Transmission`,
`Deluge`, `rTorrent`, `uTorrent` and `Blackhole`. So a book manager can absolutely
be pointed at torrents. It was removed because there is no working supply path in
this house to point it at:

- **No torrent download client is deployed.** SABnzbd is the only client in the
  cluster, and it speaks usenet.
- **CGNAT degrades torrents the same way it degraded Soulseek, differently.**
  Downloads still work — the client connects out to peers. Seeding is what
  suffers, and the trackers that actually carry books are ratio-gated private
  ones.
- **A manager with nothing to manage is noise.** It was one more pod, one more
  PVC, one more credential surface, and one more thing to keep updated.

**What is left as candidates**, none deployed:

- **Shelfmark** and **Calibre-Web-Automated** — eBooks from direct sources rather
  than a tracker; a different supply model, and the one least affected by CGNAT.
- **A torrent client + MyAnonaMouse** — if the ratio question is acceptable with
  no inbound port.
- **Manual** — drop files on the tank; both apps pick them up on their next scan.

`slskd/` remains in the tree, unregistered, with its latent faults fixed — see
below before re-enabling it.

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

A Soulseek transfer would be a manual workflow either way — download it, then
drop it in the library or let a watcher pick it up.

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
  and READMEs (5000 / 80). The probes are the chart's default `tcpSocket`, not an
  HTTP path, because no health route was verified against a running container —
  this pod has no docker daemon.
- **Non-root.** Both images run as root by default and use wrapper entrypoints.
  They are pinned to `runAsNonRoot` + `1000:1000` with an fsGroup-owned PVC, the
  same pair Navidrome and Jellyfin use against the same tank, which is why the
  library is expected to be readable as uid 1000.
- **Root filesystem.** Left writable (`readOnlyRootFilesystem: false`) for both
  rather than assumed clean.
- **Audiobookshelf serves from a base path.** Its log says `Serving from base
path "/audiobookshelf"` while the HTTPRoute matches the host root, so the UI
  lives one path segment down. It works (logins succeed) but the two do not agree;
  pinning the base path to `/` is the tidy fix if the subpath becomes annoying.

## Out-of-band

The `books` dataset is a hostPath, so kopiur does **not** cover it. Anything that
writes to the library — now including these apps' own bookmarks and progress,
though not the files — is protected only by a host-side snapshot of
`tank/nas/library`.
