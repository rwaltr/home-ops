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
