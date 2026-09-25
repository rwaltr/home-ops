# Language filtering in Sonarr/Radarr

How non-English releases get into the library, how to audit for them, and the
guard that stops it. Written after the 2026-09-24 "downloadathon" pulled four
**TRUEFRENCH** Bluey episodes.

## TL;DR

- Sonarr has **no working language guard on its own** — it imported a release
  literally named `Bluey.S01E06.TRUEFRENCH.1080p.WEB.H264-FTMVHD`.
- Radarr's built-in `Original Language` check **does** work (it rejected every
  German release of _Dead Space: Downfall_).
- Fix is a **manual** release profile in each app: `ignored` terms
  (`TRUEFRENCH`, `VFF`, `VOSTFR`, `DEUTSCH`, …). It is **not** Recyclarr-managed,
  so it is not in git — see [Drift](#drift).

## How it happened

Sonarr's history tells the whole story for Bluey S01E06:

```
19:42  grabbed                 Bluey.2018.S01E06.1080p.BluRay.h264-REACTANT   <- correct English
19:47  downloadFailed          Bluey.2018.S01E06.1080p.BluRay.h264-REACTANT   <- dead NZB
19:48  grabbed                 Bluey.S01E06.TRUEFRENCH.1080p.WEB.H264-FTMVHD  <- fallback
19:59  downloadFolderImported  (French audio lands in the library)
```

The English release failed, so Sonarr took the next-best scoring candidate and
nothing objected to the language.

Why Sonarr's own checks did not catch it:

- **Quality profiles have no `language` field in Sonarr v4.** `GET
/api/v3/qualityprofile/4` returns keys
  `cutoff, cutoffFormatScore, formatItems, id, items, minFormatScore,
minUpgradeFormatScore, name, upgradeAllowed` — there is no `language`.
- Sonarr _does_ auto-create a **`Language: Not Original`** custom format
  (`LanguageSpecification`, id 42, score `-10000`, present on profile 4). It
  rejects `TRUEFRENCH` correctly _now_ — but did not at grab time, most likely
  because the series' `originalLanguage` was not yet `English` when the grab
  was evaluated. So it cannot be relied on as the only guard.
- `Bluey (2018)` reports `originalLanguage: English`, and the release still
  imported.

## Audit method (reproducible)

### 1. Pull every audio track's language from Jellyfin

Paging `MediaStreams` is the cheapest first pass — no disk I/O, no ffprobe:

```bash
kubectl -n default exec deploy/jellyfin -- sh -c "curl -s \
  -H 'X-Emby-Token: <token>' \
  'http://localhost:8096/Items?Recursive=true&IncludeItemTypes=Episode,Movie&Fields=MediaStreams,Path&EnableImages=false&Limit=500&StartIndex=0'"
```

Then bucket each item by the set of audio languages:

| Bucket                                           | Meaning                                      |
| ------------------------------------------------ | -------------------------------------------- |
| has `eng`/`und`/`mul`                            | fine                                         |
| only real foreign codes (`fre`, `ger`, `ita`, …) | **suspect — fix**                            |
| only `unk`                                       | undetermined; ffprobe cannot help, needs ASR |

### 2. Confirm suspects with ffprobe

```bash
ffprobe -v error -select_streams a -show_entries stream_tags=language -of csv=p=0 FILE
```

### 3. Resolve `unk` with ASR

`unk` is written into the _file's_ stream tag — Jellyfin is reading it
correctly, so ffprobe adds nothing. Only transcription tells you the language.
Sample ~30 s from 40 % into each file and transcribe via the cluster's
`wyoming-whisper` (`default.svc:10300`). Run it **inside a pod that has ffmpeg,
python3 and the media mounted** — the `unmanic` pod has all three
(`/usr/local/bin/ffmpeg`, `/opt/venv/bin/python3`). Do not use `kubectl exec`
without `-i`; it silently forwards no stdin and the loop produces zero rows.

Score Englishness by stopword ratio; anything below ~0.10 is worth a human
look. A 275-file run came back with **min 0.143 / median 0.571 / zero below
0.10** — i.e. all English. Low scorers are sparse dialogue (Mister Rogers), not
foreign audio.

## Findings (2026-09-25)

8 of 6,307 items had foreign-only audio:

| Item                                    | Audio | Verdict                                           |
| --------------------------------------- | ----- | ------------------------------------------------- |
| Bluey S01E06 / S01E11 / S01E12 / S01E13 | `fre` | wrong — deleted + re-searched                     |
| Dead Space: Downfall (2008)             | `ger` | wrong — deleted, re-acquire failing               |
| The 24 Hour War (2016)                  | `war` | **mis-tag** — audio is English; retagged to `eng` |
| Belle de Jour (1967)                    | `fra` | correct — original language                       |
| Malena (2000)                           | `ita` | correct — original language                       |

`war` is the ISO code for Waray, a Philippine language — a bogus tag on a US
documentary. Retag in place without re-encoding:

```bash
ffmpeg -v error -i IN -map 0 -c copy -metadata:s:a:0 language=eng \
  -movflags +faststart OUT && mv OUT IN
```

Beware filename scanning: a grep for language words matched 25 files, **all
false positives** — episode _titles_ like "Passengers and Polish", "The French
Mistake", "French Horns", "Turning Japanese".

## The guard

A release profile named **`Block Non-English Releases`** in both apps,
`tags: []` (empty ⇒ applies to all series/movies), `enabled: true`:

```
TRUEFRENCH  VFF  VFQ  VOSTFR  SUBFRENCH  DEUTSCH  CASTELLANO
LATINO  ITALIAN.DL  SPANISH.DL  PORTUGUESE.DL  RUSSIAN.DL  DUTCH.DL
```

Deliberately **excluded**: bare `FRENCH`, `GERMAN`, `ITALIAN`, `SPANISH`, and
`MULTI`. Those are substring matches, so bare language words would block
legitimate titles (_The French Connection_, _The Italian Job_, _The Spanish
Prisoner_) — and `MULTI` releases are fine here, most of the working Bluey
library is `MULTI` with English included.

Verify with an interactive search; Sonarr reports rejection reasons:

```bash
curl -s -H 'X-Api-Key: <key>' 'http://sonarr.default.svc:8989/api/v3/release?episodeId=9706' \
  | jq '.[] | select(.rejected) | {title, rejections}'
```

Confirmed: `Contains these ignored terms: TRUEFRENCH`.

## Drift

**Release profiles are not managed by Recyclarr**, which only handles quality
profiles and custom formats. They exist only in the live Sonarr/Radarr
databases — a config wipe loses them. Recreate with:

```bash
curl -s -H 'X-Api-Key: <key>' -H 'Content-Type: application/json' \
  -X POST -d '{"name":"Block Non-English Releases","enabled":true,"required":[],
  "ignored":["TRUEFRENCH","VFF","VFQ","VOSTFR","SUBFRENCH","DEUTSCH","CASTELLANO",
  "LATINO","ITALIAN.DL","SPANISH.DL","PORTUGUESE.DL","RUSSIAN.DL","DUTCH.DL"],
  "indexerId":0,"tags":[]}' \
  http://sonarr.default.svc:8989/api/v3/releaseprofile
```

## Residual risk

- Re-acquisition of _Dead Space: Downfall_ is failing: every English release
  Radarr finds is blocklisted, dead, or under the profile's 3.7 GB size floor.
  It stays monitored so RSS will catch one if it appears.
- Language tags are only as good as the release name. A release with no
  language marker but foreign-only audio still gets through — the audit above
  is the only way to find those.
