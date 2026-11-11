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

- **Generation** — `nvidia-llama`, the self-hosted **Qwen3-32B** (151k context)
  on Dan Manners' cluster, reached through the local LiteLLM. The key is
  `litellm-secret` / `LITELLM_MASTER_KEY`. His proxy does **not** store prompt or
  response content (`store_prompts_in_spend_logs` unset → false), so document
  text never reaches his spend logs — it is still processed in memory on his
  vLLM node. See `docs/local-llm.md` and the retention notes there.
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
- **Custom fields:** `Reference`, `Total` (monetary), `Payment method`
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

Paperless' AI suggestion action cannot write custom fields, so a CronJob fills
the financial ones. `paperless-extract` (`paperless_extract.py`, every 5
minutes) scans documents typed `Invoice` or `Receipt`, asks the same LLM
(`nvidia-llama` via LiteLLM) for the values, and PATCHes the document:

| Field            | Example          |
| ---------------- | ---------------- |
| `Total`          | `CAD155.11`      |
| `Payment method` | `VISA **** 5678` |
| `Reference`      | `987654`         |

The merchant stays the correspondent and the transaction date is the document's
`created` date (Paperless parses it), so neither is a custom field. A document
that already has a `Total` is skipped, so the job only fills blanks and is safe
to re-run.

Two gotchas worth keeping:

- Qwen3 is a reasoning model. Without
  `chat_template_kwargs.enable_thinking=false` it spends the token budget
  thinking and returns `content: null` — observed on a receipt whose OCR read
  `TOTAL: $155. uu`. The extractor sets it.
- `Total` is a monetary field that carries its own currency as a 3-char prefix
  (`CAD155.11`); Paperless parses the amount out of it. There is deliberately no
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
- **Qwen3-32B is a reasoning model.** LiteLLM separates its thinking into
  `reasoning_content`, so it does not pollute the answer, but suggestions spend
  extra tokens/latency before emitting JSON.
- **The PVC name is pinned** with `forceRename: paperless-data`: app-template
  only suffixes PVC names once a second PVC exists, and the kopiur policy
  references this exact name.

## Immich bridge (photo → archive)

Receipts photographed on a phone land in Immich and used to stay there.
`immich-paperless` (`infra/k8s/kyz/apps/default/immich-paperless/`) is a
CronJob that every 15 minutes:

**classify** — every image added in the last 24 hours that carries none of the
bridge's tags is scored against Immich's CLIP smart search (`DOC_QUERIES` in the
script). Assets that come back for a document-ish query are tagged
`paperless-maybe` so they can be reviewed in the UI. Immich's OCR text boxes are
logged alongside as corroboration (`ocr_rows=N`), never as a gate: Immich only
writes them once its OCR job has run, so anything added before OCR was enabled
has none, and thresholding on them would silently classify nothing.

**send** — assets in the Immich album named `Paperless` are copied into the
consume dropbox:

1. skips any asset already carrying `paperless-sent`, and any video (a video
   would otherwise be archived as a single JPEG frame);
2. downloads the original — or, for formats Paperless cannot read (HEIC straight
   off an iPhone), Immich's `fullsize` JPEG. The bridge never hands Paperless a
   HEIC, because its consumer would fail the file rather than convert it;
3. writes it into the consume dropbox as `<date> immich <name>.<ext>`, mode 0644
   so the consumer (uid 1000) can read it;
4. tags the asset `paperless-sent`.

Paperless then does everything it normally does: OCR, then its workflows assign
the document type and the `accounting/inbox` tag. **The bridge holds no
Paperless credential** — it only writes into the dropbox — so its only secret is
an Immich API key.

### The review loop

The archive is permanent, so nothing enters it unreviewed — the automatic path
only proposes.

| Tag               | Set by  | Means                                     |
| ----------------- | ------- | ----------------------------------------- |
| `paperless-maybe` | the job | CLIP thinks this is a document; review it |
| `paperless-sent`  | the job | already handed to Paperless               |
| `paperless-skip`  | you     | never suggest this one again              |

To archive a suggestion: filter Immich by the `paperless-maybe` tag (the tag page
is `/tags`), add the real documents to the `Paperless` album, and the next run
copies them. To decline one, replace its tag with `paperless-skip` — create that
tag once, because the job reads it but never creates it. The job never re-tags an
asset that already carries any of its own tags.

State lives in Immich (the tags), not in a volume, so the job is idempotent,
restartable, and "did this one get sent?" is answerable from the Immich UI. A
missing album is **not** an error: the album is opt-in, so an empty review queue
is the normal state.

### Setting it up

1. Create an Immich API key (Account Settings → API Keys). The bridge needs
   `album.read`, `asset.read`, `asset.view`, `asset.download`, `tag.read`,
   `tag.create` and `tag.asset`.
2. Add it to 1Password as an **API Credential** item named `paperless-bridge` in
   the `home-ops` vault, with the key in the **credential** field. The
   ExternalSecret reads `paperless-bridge/credential`, and the vault matters: the
   ClusterSecretStore is pinned to `home-ops`, so an item in any other vault is
   invisible to the sync.
3. `mise run secrets:verify` should then report it as resolving.

Without step 2 the job fails with an explicit message instead of silently doing
nothing.

Backfilling is Immich UI work, not a mise task: Administration → Jobs → **OCR →
All** gives existing photos OCR text (corroboration only), and **Smart Search →
All** rebuilds embeddings if smart search ever returns nothing. The classify
window is 24 hours; to classify the existing library in one go, run the script
once with a wider `WINDOW_HOURS`.
