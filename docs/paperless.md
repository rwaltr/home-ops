# Paperless-ngx (paperless.waltr.tech)

Self-hosted document archive: scans documents, runs OCR, indexes the text and
makes everything full-text searchable. For rwaltr's documents — primarily
email, PDF and images. Defined in `infra/k8s/kyz/apps/default/paperless/`.

|         |                                                                                         |
| ------- | --------------------------------------------------------------------------------------- |
| Web UI  | `https://paperless.waltr.tech` (envoy-internal **only** — not on the cloudflare tunnel) |
| Image   | `ghcr.io/paperless-ngx/paperless-ngx:3.4.2`, digest-pinned                              |
| Stack   | app (web + Celery worker + consumer) + valkey broker + gotenberg + tika                 |
| Storage | `media` + `consume` (tank hostPaths) · `data` (5Gi PVC)                                 |
| Backups | kopiur policy `paperless`, nightly `H 16 * * *`, mover uid/gid 1000                     |

## Why SQLite

Paperless defaults to SQLite and only _recommends_ PostgreSQL for multi-user or
high-throughput installs. This is a single-user archive, and SQLite keeps the
app to one container plus a couple of mounts — no extra database service to
keep, back up and reconcile. Same reasoning as FreshRSS (see the 2026-10-08
entry in `REFACTOR_PLANS.md`).

It is **not a one-way door.** Paperless ships `document_exporter` /
`document_importer` specifically for switching engines: export from the running
SQLite instance, start an empty install of the _same exact version_ with
`PAPERLESS_DBENGINE=postgresql`, import. The manifest is a database image, so
versions must match (pin the image, import, then upgrade) and the import target
must be empty. API tokens are re-created afterwards.

## Tika + Gotenberg

Both are deployed, and both are required: they are what lets Paperless ingest
**email** (`.eml`), one of the three primary inputs. They also cover Office
documents (`.docx`, `.xlsx`, `.odt`). PDFs and images would work with the base
image alone.

- Gotenberg renders email/Office to PDF (Chromium for email, LibreOffice for
  Office); Tika extracts text and metadata.
- Both endpoints are configured under the Tika namespace —
  `PAPERLESS_TIKA_ENDPOINT` and `PAPERLESS_TIKA_GOTENBERG_ENDPOINT`. There is no
  `PAPERLESS_GOTENBERG_ENDPOINT`; setting the wrong name fails silently.

## AI features

Native AI (Paperless 3.0+) is enabled: **suggestions** (title, tags,
correspondent, document type, storage path, dates), **document chat** and
**similar documents** (RAG). The non-LLM classifier still runs alongside it.

- **Generation** — `intel-vl`, a **Qwen3-VL-8B** on an Intel Arc in Dan Manners'
  cluster, reached through the local agentgateway alias, so nothing is billed to a
  model provider. His proxy does **not** store prompt or response content, so
  document text never reaches his spend logs — it is still processed in memory on
  his hardware. See `docs/agentgateway.md`.
- **Embeddings** — `huggingface` with `sentence-transformers/all-MiniLM-L6-v2`,
  running in-process. No embedding backend, no API key, nothing leaves the
  cluster. Cache lives on the tank (see storage); first use downloads ~90 MB.
- The two roles are independent. Swapping the generation model leaves the index
  alone; changing the **embedding** model requires rebuilding the LLM index
  (_Settings → LLM index_).
- Knobs are `PAPERLESS_AI_*` in the HelmRelease, or the admin under _Settings →
  Application Configuration_ — where the DB value overrides the env.

## Secrets (create before first boot)

The ExternalSecret reads 1Password item **`paperless`** (vault `home-ops`):

| Field            | Purpose                                            |
| ---------------- | -------------------------------------------------- |
| `secret_key`     | Django `SECRET_KEY` — any long random string       |
| `admin_password` | First-run superuser password (admin user `rwaltr`) |

`admin_password` is used **only when the database has no superuser yet** — the
image's `init-superuser` step does not reset an existing password. Change the
password in the UI afterwards; the 1P value only records what was used at
creation.

## Logging in through Kanidm

Paperless authenticates through Kanidm via django-allauth's `openid_connect`
provider, configured entirely by environment variables: `PAPERLESS_APPS` adds the
provider (it is additive, not a replacement), and
`PAPERLESS_SOCIALACCOUNT_PROVIDERS` carries the whole provider config as one JSON
blob.

That blob is why the Kanidm client is **public**. It cannot be assembled from
separate Secret keys, so the client id has to be a literal — and a public client's
id is its Kanidm name (`paperless`) with no secret beside it. PKCE is enabled, as
Kanidm requires for public clients. The trade-off is that public clients cannot use
client-authenticated APIs such as RFC 7662 token introspection; Paperless does not.

`PAPERLESS_SOCIAL_AUTO_SIGNUP` is on, so the first login creates the account. The
pre-existing local `rwaltr` account is a _separate_ account until it is linked —
either link it in the UI or use the OIDC-created one.

The registered redirect URL is allauth's callback path for the provider id
`kanidm`, and it is matched exactly by Kanidm.

**A consent screen is expected.** Kanidm requires the consent prompt on public
clients, so the first screen after logging in at `idm.waltr.tech` is Kanidm asking
you to allow Paperless. Asking the operator to disable it (`disableConsentPrompt`)
does not work — it retries a write Kanidm refuses (`PATCH /v1/oauth2/paperless` →
403 `requested_pres: {OAuth2ConsentPromptEnable} !⊆ allowed`) indefinitely while the
rest of the client stays reconciled. The prompt is inherent to the client type, not
a misconfiguration.

## First run

1. Create the 1Password item above (or `mise run secrets:verify` will flag it).
2. Let Flux apply. The app's startup probe allows up to 5 minutes for the first
   Django migration + index build.
3. Log in at `https://paperless.waltr.tech` as `rwaltr` with `admin_password`.
4. Add an email account (or set a mail rule) under _Settings → Mail_ to start
   ingesting email, and create API tokens under _Settings → API Tokens_ for the
   mobile app / scanner.

Off-LAN access is over the tailnet; there is deliberately no `envoy-external`
parentRef (email and personal documents should not be internet-reachable).
Adding that parentRef is the whole publish step if it is ever wanted.

## Tags and automatic classification

The archive is **keep-everything, permanent**: no retention field, no expiry,
no scheduled deletes. Tags are a **provenance trail** — what happened to a
document — split across two namespaces:

| Tag                      | Set by                     | Cleared by                  | Meaning                               |
| ------------------------ | -------------------------- | --------------------------- | ------------------------------------- |
| `status/inbox`           | Paperless (`is_inbox_tag`) | the classification workflow | transient; visible only if one failed |
| `status/ai-enriched`     | the AI workflow            | never                       | classified by the LLM, not by a rule  |
| `accounting/unlinked`    | rules + hourly sweep       | the bridge, on a match      | financial, not yet matched            |
| `accounting/beancounted` | the Beancount bridge       | never                       | matched to a transaction              |

`status/inbox` is stamped on every new document and removed by whichever
classification workflow handles it, in the same consume. It is deliberately
transient: a document keeps it only when a workflow failed, so it is an error
signal, not a to-do list. There is no retry; a stuck document is handled by hand.

Paperless stores this config in its **database**, not Git, so a wipe loses it.
`mise run paperless:seed` re-applies it through the REST API (idempotent, by
name):

- **Document types:** `Invoice`, `Receipt`, `Statement`, `Contract`, `Manual`,
  `Policy`, `Medical`, `Correspondence`, `Other`
- **Tags:** `status/inbox`, `status/ai-enriched`, `accounting/unlinked`,
  `accounting/beancounted`
- **Custom fields:** `Reference`, `Total` (monetary), `Payment method`,
  `Transaction date`
- **Workflows:** `auto-classify: invoice`, `auto-classify: receipt`,
  `auto-classify: ai`, `mark accounting/unlinked`

The three classification workflows trigger on **Document Added**:

1. `invoice` and `receipt` regex-match the OCR text, assign the document type
   and tag `accounting/unlinked`. Invoice runs first, receipt second, so a store
   receipt that also says "invoice" lands as `Receipt` (a later assignment wins).
2. `ai` runs on documents the rules left **untyped** and applies AI suggestions
   (title, correspondent, document type) plus `status/ai-enriched`. It may create
   correspondents; a document it cannot type becomes `Other`.

Because the rules only catch invoices and receipts, the AI is effectively the
primary classifier — expect `status/ai-enriched` on most documents. If the LLM
is unreachable the workflow fails and the document keeps `status/inbox`.

A fourth workflow, `mark accounting/unlinked`, is **scheduled** (hourly). It
re-queries documents typed Invoice/Receipt that have neither accounting tag and
adds `accounting/unlinked`. It exists because workflow mutations do not re-fire
`document_updated`, so a follow-up Added/Updated workflow cannot catch documents
the AI typed. Up to an hour of latency; the rules cover the immediate case.

The Beancount bridge owns the transition: it removes `accounting/unlinked` and
adds `accounting/beancounted` when it matches a transaction (issue #988).

Limits worth knowing:

- Paperless' Apply AI Suggestions action covers title/correspondent/type/storage
  path/created only — it cannot touch custom fields. A separate extractor fills
  `Total`/`Payment method`/`Reference` (next section).
- There is no "was OCRed" tag: Paperless stores no such flag. Adding one would
  need a post-consume script comparing the original against the OCR'd archive.
- Mail rules are _not_ seeded (they need an IMAP account) — the content
  workflows cover mail-ingested documents anyway.
- `ai_create_missing` is global, so the AI can invent a document type as well as
  a correspondent. With nine types pre-seeded it usually picks one, but not
  always — a test manual came back typed `User Manual` rather than `Manual`.
  Merge the strays when they appear.
- AI classification lands **asynchronously**: the action queues
  `apply_ai_suggestions`, which runs seconds after consumption. `status/ai-enriched`
  is set when the workflow dispatches it, so a document can carry the tag with no
  type for a few seconds. If that task fails, the document keeps `ai-enriched` and
  no type — that shape is the failure signature.
- Re-run `mise run paperless:seed` after changing the definitions, and after any
  Paperless config wipe.

## Receipt metadata (extractor)

Paperless' AI suggestion action cannot write custom fields, so the Windmill
`f/paperless/extract_flow` visual flow fills the financial ones. Its five-minute
schedule lists eligible documents, then loops over them with an extraction
script step that asks `intel-vl` through agentgateway and PATCHes the document:

| Field            | Example     |
| ---------------- | ----------- |
| `Total`          | `USD155.11` |
| `Payment method` | `VISA 5678` |
| `Reference`      | `987654`    |

It reads **OCR text**, not the image, so a receipt photographed with no usable
text yields nothing here. The Immich bridge does the same job from the image for
the files it sends (next section) — better evidence — so this job is what covers
everything else: an emailed PDF, a manual upload, or a document whose OCR only
became available after the bridge ran.

A document that already has a `Total` is skipped, so the job only fills blanks
and is safe to re-run. `Payment method` is written as `<BRAND> <last4>`, no
asterisks — the same shape both writers use.

One gotcha worth keeping:

- `Total` is a monetary field that carries its own currency as a 3-char prefix
  (`USD155.11`); Paperless parses the amount out of it. There is deliberately no
  separate `Currency` field.

## Storage layout

Paperless puts everything under three defaults, mounted explicitly:

| Mount                        | Backing                           | Contents                                       |
| ---------------------------- | --------------------------------- | ---------------------------------------------- |
| `/usr/src/paperless/media`   | `/var/tank/nas/paperless/media`   | The archived documents (originals + PDF/A)     |
| `/usr/src/paperless/consume` | `/var/tank/nas/paperless/consume` | Ingestion dropbox                              |
| `/usr/src/paperless/data`    | `paperless-data` PVC (5Gi)        | SQLite DB, search index, matcher model         |
| `/usr/src/paperless/models`  | `/var/tank/nas/paperless/models`  | Hugging Face embedding cache (re-downloadable) |

`media` and `consume` are tank hostPaths (`DirectoryOrCreate`), so ZFS raidz1
covers the documents — the same tradeoff as immich's photo library: redundant
against disk failure, **not** versioned by kopia. `data` is on the PVC and is
snapshotted nightly, which is what preserves the metadata and tags.

## Operational notes

- **Runs as root, writable root FS.** The image's s6 init needs root to remap
  the internal `paperless` user to `USERMAP_UID=1000` and chown the mounts;
  `readOnlyRootFilesystem` must stay `false` (same call as freshrss). Caps are
  narrowed to CHOWN/SETUID/SETGID/DAC_OVERRIDE/FOWNER.
- **Probes use `/`**, which returns a 302 login redirect — a 2xx–3xx is success
  for the kubelet.
- **Restarting is safe** but the app is single-writer (SQLite, `strategy:
Recreate`); never run two pods against `data/`.
- **Gotenberg and Tika are separate Deployments** sized for conversion spikes
  (the JVM sizes its heap from the Tika container's memory limit).
- **The first AI call downloads the embedding model** (~90 MB) into the models
  hostPath. The RAG index is rebuilt nightly at 02:10 by default
  (`PAPERLESS_LLM_INDEX_TASK_CRON`) and on demand from the admin.
- **The generation model is shared.** `intel-vl` is one Qwen3-VL on someone
  else's GPU, so it can flap or run slow while its owner redeploys it. The bridge
  treats any failure as "no answer" and re-asks later rather than caching it, and
  Paperless' own AI simply fails the workflow and leaves `status/inbox`.
- **The PVC name is pinned** with `forceRename: paperless-data`: app-template
  only suffixes PVC names once a second PVC exists, and the kopiur policy
  references this exact name.

## Immich bridge (photo → archive)

Receipts photographed on a phone land in Immich. Windmill's
`f/paperless/immich_pipeline` visual flow runs every five minutes over the last
15 minutes; an hourly backstop scans the last 24 hours. Its canvas has classify,
upload, and enrich script steps. The former Immich WebSocket listener is retired,
so a new photo may take up to five minutes to be examined. State remains in
Immich tags, so the poller is idempotent and recovers work after a Windmill outage.

`docs/immich-paperless-flow.html` is the historical diagram of the retired
WebSocket/consume-directory design; it no longer describes the deployed trigger
or send path.

**The vision model decides everything.** One call to `intel-vl` answers with a
JSON verdict — `description`, `tags`, `document`, `useful`, `confidence`,
`kind` — and that answer drives the rest. There is no CLIP gate, no local-OCR
gate and no review queue.

**classify** — every image in the window that carries none of the bridge's tags
is offered to the model, newest first, walking `MAX_PAGES` pages of 200. Immich
caps a metadata page at 200 and has no "everything since" call, so the pages have
to be walked; without that a candidate older than the newest page could never be
examined at all.

| Verdict                           | What happens                                           |
| --------------------------------- | ------------------------------------------------------ |
| `document: true`, useful          | added to the `Paperless` album, tagged `document`      |
| `document: true`, `useful: false` | tagged `useless` — junk that must never queue          |
| `document: false`                 | nothing beyond its content tags                        |
| no answer at all                  | **nothing**: an outage must not be cached as a verdict |

The description is written onto the asset, and the model's `tags` are applied,
restricted to `VOCAB` (`person`, `casual`, `formal`, `landscape`, `art`, `food`,
`pet`, `children`, `vehicle`, `screenshot`, `indoor`, `outdoor`, `holiday`,
`document`). A photo of a person or a dog is deliberately **not** labelled: it is
not a document, and its content tags are the record of that decision. `useless`
means the same thing here as it does in Paperless — a document worth reading and
not worth keeping — so a coupon never reaches the archive at all.

One tag namespace marks the decision, so a re-run asks nothing twice: `VOCAB`
plus `document`, `useless` and `paperless-sent`. A tag an operator adds by hand
counts as their answer too. There is no `paperless-skip` or `paperless-maybe`
any more; both were retired with the CLIP/OCR cascade.

**send** — assets tagged `document` are uploaded directly through Paperless'
`/api/documents/post_document/` endpoint:

1. skips any asset already carrying `paperless-sent`, and any video;
2. downloads the original — or, for formats Paperless cannot read (HEIC straight
   off an iPhone), Immich's `fullsize` JPEG;
3. uploads it as `<date> <description>.<ext>` with the matching Paperless title;
4. tags the asset `paperless-sent` only after Paperless accepts the upload.

The Windmill worker no longer mounts or writes to Paperless' consume directory.

The **tag** is the queue, not the album. Immich's album API reports no assets for
an album the key's user does not own, so an album-driven send reads back empty and
silently sends nothing; the album is a display grouping only.

**enrich** — Paperless' own AI is text-only, so a receipt photographed with no
usable OCR arrives titled after its camera filename. Once the document exists,
the bridge asks the vision model about the _image_ and writes back, joining the
two systems on the filename:

| Written            | Where                                                 |
| ------------------ | ----------------------------------------------------- |
| title              | the document title; the filename begins with it       |
| merchant           | the correspondent, created if new                     |
| transaction date   | `created` **and** the `Transaction date` custom field |
| total              | `Total`, currency prefixed (`USD20.64`)               |
| card               | `Payment method`, as `MASTERCARD 3642`                |
| reference          | `Reference`                                           |
| the reading itself | appended to `content` behind a marker                 |

Content is **appended**, never replaced, so the OCR text and an operator's own
description survive. Custom fields and tags are merged rather than assigned (a
PATCH replaces both lists wholesale). A document the model cannot make sense of —
`useful: false`, or a reading too thin to act on — is tagged `useless` in
Paperless rather than left untitled, so it can be found and deleted.

Documents already carrying `status/vision-enriched` are skipped, so the pass is
idempotent, and the join accepts both the current filename and the camera stem,
for files sent before the filename carried the description.

### State and review

All state lives in Immich tags, so "did this get looked at?" and "what did the
model decide?" are answerable from the Immich UI, and the job is restartable.

| Tag                      | Set by     | Means                                |
| ------------------------ | ---------- | ------------------------------------ |
| `document`               | the bridge | queued for Paperless (the send gate) |
| `useless`                | the bridge | read and judged not worth keeping    |
| `paperless-sent`         | the bridge | already handed to Paperless          |
| `status/vision-enriched` | the bridge | the Paperless side has the reading   |

To undo a decision, remove the `document` tag (or replace it with `useless`)
before the next run: the bridge never re-tags an asset carrying any of its own
tags.

### Credentials and deployment

The Windmill project is versioned under `f/paperless/`. It reads the existing
1Password items `paperless/api_token` and `paperless-bridge/credential`.
`mise run paperless:windmill` refreshes them into Windmill **secret variables**
and syncs resource types, resource references, scripts and schedules. Resource
values store `$var:` references rather than historical copies of the tokens;
job tokens are scoped to the specific resources and variables they need.

A failed API or model call leaves the document/asset unmodified for the next
schedule to retry; the failure appears in Windmill's execution logs.

### Editing and backfilling

Edit a flow in `f/paperless/*__flow/flow.yaml` or its scripts
`f/paperless/extract.py` / `f/paperless/immich_bridge.py`, run the local tests,
then deploy with `mise run paperless:windmill`. The backstop schedule is
resumable because Immich tags are the idempotency state. For a larger backfill,
increase `window_hours` and `max_pages` in
`f/paperless/immich_backstop.schedule.yaml`; keep `max_vision_calls` bounded
because the model is a shared GPU.
