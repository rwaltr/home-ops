# Jellyfin metadata: TVDB alignment with Sonarr

## Why

Sonarr manages the TV library using **TheTVDB** metadata (episode numbering,
titles). Jellyfin's `Shows` library was configured with **TMDb only**, so the
two disagreed on episode ordering. The clearest example:

| Episode | Sonarr / TVDB (aired) | Jellyfin / TMDb (default) |
| ------- | --------------------- | ------------------------- |
| S01E24  | Off the Rails         | Thomas' Christmas Party   |
| S01E25  | Down the Mine         | Off the Rails             |
| S01E26  | Thomas' Christmas Party | Down the Mine           |

The files on disk are numbered to match Sonarr, so Jellyfin displayed the wrong
title for the wrong file. Series 11 has a similar rotated block (E21–E26).

**Fix:** make Jellyfin's episode metadata come from TheTVDB, like Sonarr.

## Current configuration

- **Plugin:** `TheTVDB` `22.0.0.0` installed (Settings → Plugins → *The TVDB*).
- **Shows library** (`a656b907eb3a73532e40e44b968d0225`) metadata fetchers:
  - `Season`  → `["TheTVDB", "TheMovieDb"]`
  - `Episode` → `["TheTVDB", "TheMovieDb", "The Open Movie Database"]`
  - `Series`  → left as `["TheMovieDb", …]` on purpose, so series artwork /
    descriptions for the rest of the library are not churned.
- **Backups:** Jellyfin's config lives on the `jellyfin` PVC, which is enrolled
  in Kopia (`app/kopia.yaml`, nightly, keep 7/14/4). The plugin and library
  settings therefore survive a pod restart and are restored with the PVC.

These are **runtime state in the Jellyfin config volume**, not Kubernetes
manifests — Flux does not manage them. The steps below reproduce them.

## Reproduce / restore

Set the API token and reach the API. From a workstation you can use a
port-forward, or run the calls from inside the cluster:

```bash
JELLYFIN_API_KEY=...                 # Jellyfin Dashboard → API Keys
kubectl -n default port-forward svc/jellyfin 18096:8096 &
BASE=http://localhost:18096
H=(-H "X-Emby-Token: ${JELLYFIN_API_KEY}")
```

### 1. Install TheTVDB plugin

Look up the current plugin id/version from the catalog (the guid is stable, the
version is not):

```bash
curl -s "${H[@]}" "${BASE}/Packages" | jq -r '.[] | select(.name=="TheTVDB") | .guid, .versions[0].version'
```

Install it (replace `VERSION`), then restart the deployment so the plugin
loads:

```bash
curl -sf -X POST "${H[@]}" \
  "${BASE}/Packages/Installed/TheTVDB?assemblyGuid=a677c0dafac54cde941a7134223f14c8&version=VERSION&repositoryUrl=https://repo.jellyfin.org/files/plugin/manifest.json"

kubectl -n default rollout restart deployment/jellyfin
kubectl -n default rollout status deployment/jellyfin
```

Confirm it is `Active` (not `Restart`) via `GET /Plugins`.

### 2. Point the Shows library at TVDB

Jellyfin's update endpoint requires the **full** `LibraryOptions` object, so
read it, edit `TypeOptions`, and post it back:

```bash
curl -s "${H[@]}" "${BASE}/Library/VirtualFolders" > vf.json

jq --arg id "$(jq -r '.[]|select(.Name=="Shows").ItemId' vf.json)" '
  (.[] | select(.Name=="Shows")) as $s
  | { Id: $id,
      LibraryOptions: ($s.LibraryOptions
        | .TypeOptions |= map(
            if (.Type == "Season" or .Type == "Episode") then
              .MetadataFetchers    = (["TheTVDB"] + (.MetadataFetchers    | map(select(. != "TheTVDB"))))
              | .MetadataFetcherOrder = (["TheTVDB"] + (.MetadataFetcherOrder | map(select(. != "TheTVDB"))))
            else . end))
    }' vf.json > libopts.json

curl -sf -X POST "${H[@]}" -H "Content-Type: application/json" \
  --data-binary @libopts.json "${BASE}/Library/VirtualFolders/LibraryOptions"
```

Use `POST /Library/VirtualFolders/LibraryOptions` — **not**
`/Libraries/LibraryOptions` (that path 404s).

### 3. Refresh a series

Replace all fetched metadata so existing TMDb-derived titles are overwritten:

```bash
SERIES_ID=$1   # e.g. Thomas & Friends = f8c2dbe29484bf6c0fce4f75735fd7b1
curl -sf -X POST "${H[@]}" \
  "${BASE}/Items/${SERIES_ID}/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=None&replaceAllMetadata=true&replaceAllImages=false&regenerateTrickplay=false"
```

## Known caveat: TVDB has more than one order

TheTVDB exposes several orderings per series (*aired*, *official*, *DVD*,
*absolute*). **Sonarr uses the aired order; the Jellyfin plugin uses the
series' default (official) order.** They normally agree but diverge on a few
series, e.g. Thomas & Friends:

- S01E24–E26
- S11E21–E26

The plugin has **no setting** to choose the order, and the series item exposes
no `DisplayOrder`. Where they diverge, the Jellyfin episode titles were pinned
to the on-disk (Sonarr-numbered) content and **locked** so a refresh cannot
revert them:

```bash
# GET the full DTO, set Name, add "Name" to LockedFields, POST back
curl -s "${H[@]}" "${BASE}/Users/${JELLYFIN_USER_ID}/Items/${EPISODE_ID}" > item.json
jq --arg n "Off the Rails" '.Name=$n | .LockedFields |= ((. // []) + ["Name"] | unique)' \
  item.json > item_out.json
curl -sf -X POST "${H[@]}" -H "Content-Type: application/json" \
  --data-binary @item_out.json "${BASE}/Items/${EPISODE_ID}"
```

Note `GET /Items/{id}` returns nothing useful here; use
`/Users/{userId}/Items/{id}` to fetch the DTO.

## Verifying alignment

Compare Jellyfin episodes against Sonarr per season/episode. Ignoring
punctuation and `(1)`/`(2)` part suffixes, there should be zero differences:

```bash
# Sonarr
curl -s -H "X-Api-Key: $SONARR_API_KEY" \
  "http://sonarr.default.svc.cluster.local:8989/api/v3/episode?seriesId=84"
# Jellyfin
curl -s "${H[@]}" "${BASE}/Shows/${SERIES_ID}/Episodes"
```

## Related

- `infra/k8s/kyz/apps/default/jellyfin/` — the app manifests (plugin is *not*
  declared there; it is installed at runtime and captured by the Kopia backup).
- Library repair notes for Thomas & Friends (mixed-folders / mislabelled files)
  are in the git history around 2026-09.