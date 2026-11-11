#!/usr/bin/env python3
"""Fill Paperless custom fields from receipt/invoice OCR text via the LLM.

Paperless' built-in "Apply AI suggestions" action can only write title, tags,
correspondent, document type, storage path and created date — it has no
custom-field path at all (`AISuggestionField` and `documents/workflows/ai.py`).
This job closes that gap: for documents typed Invoice or Receipt, it asks the
same LLM (nvidia-llama — Qwen3-32B on Dan's gateway via LiteLLM) for the total,
currency, card and reference, then PATCHes the custom fields.

Runs as a CronJob (extract-cronjob.yaml). Idempotent: a document that already
has a Total is skipped, so re-runs only fill blanks.

Env:
  PAPERLESS_URL        default http://paperless-app.default.svc.cluster.local:8000
  PAPERLESS_API_TOKEN  from the paperless-secret
  LITELLM_BASE_URL     default http://litellm.default.svc.cluster.local:4000/v1
  LITELLM_API_KEY      litellm-secret/LITELLM_MASTER_KEY
  LITELLM_MODEL        default nvidia-llama
  MAX_DOCS             default 25
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

PAPERLESS = os.environ.get(
    "PAPERLESS_URL",
    "http://paperless-app.default.svc.cluster.local:8000",
).rstrip("/")
TOKEN = os.environ.get("PAPERLESS_API_TOKEN", "").strip()
LITELLM = os.environ.get("LITELLM_BASE_URL", "http://litellm.default.svc.cluster.local:4000/v1").rstrip("/")
LITELLM_KEY = os.environ.get("LITELLM_API_KEY", "").strip()
MODEL = os.environ.get("LITELLM_MODEL", "nvidia-llama")
MAX_DOCS = int(os.environ.get("MAX_DOCS", "25"))

FINANCIAL_TYPES = ("Invoice", "Receipt")
PROMPT = """You extract structured fields from receipts and invoices.

Reply with a single JSON object and nothing else:
{"total": <number or null>, "currency": <ISO 4217 code or null>,
 "payment_method": <string or null>, "reference": <string or null>}

- total: the printed TOTAL / amount paid, as a number. Null if absent.
- currency: three-letter code. Null if it cannot be inferred.
- payment_method: copy the card line as printed, brand and last four, e.g.
  "VISA **** 5678". Null if there is no card.
- reference: the invoice number or transaction id. Null if absent.

OCR can misread digits. Prefer the printed TOTAL line; do not invent a value."""


def request(method: str, url: str, body: dict | None = None, headers: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json", "Accept": "application/json", **(headers or {})},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def pp(method: str, path: str, body: dict | None = None) -> dict:
    return request(
        method,
        PAPERLESS + path,
        body,
        {"Authorization": f"Token {TOKEN}"},
    )


def list_all(path: str) -> list[dict]:
    items: list[dict] = []
    page: str | None = path
    while page:
        payload = pp("GET", page)
        items.extend(payload.get("results", []))
        nxt = payload.get("next")
        page = nxt[len(PAPERLESS):] if nxt else None
    return items


def extract(content: str) -> dict:
    body = {
        "model": MODEL,
        "temperature": 0,
        "max_tokens": 512,
        # Qwen3 is a reasoning model: without this it can spend the whole
        # budget thinking and return content:null (observed on a mangled
        # "$155. uu" total). vLLM honours the Qwen3 chat-template flag.
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [
            {"role": "system", "content": PROMPT},
            {"role": "user", "content": f"TEXT:\n{content[:8000]}"},
        ],
    }
    reply = request(
        "POST",
        f"{LITELLM}/chat/completions",
        body,
        {"Authorization": f"Bearer {LITELLM_KEY}"},
    )
    choice = reply["choices"][0]
    text = choice["message"].get("content")
    if not isinstance(text, str) or not text.strip():
        raise ValueError(f"empty reply (finish={choice.get('finish_reason')})")
    match = re.search(r"\{.*\}", text, re.S)
    if not match:
        raise ValueError(f"no JSON in reply: {text[:200]!r}")
    return json.loads(match.group(0))


def clean(fields: dict) -> dict:
    out: dict[str, object] = {}
    currency = fields.get("currency")
    code = currency.upper() if isinstance(currency, str) and re.fullmatch(r"[A-Za-z]{3}", currency) else ""
    total = fields.get("total")
    if isinstance(total, (int, float)) and total > 0:
        # Paperless monetary fields carry the currency as a 3-char prefix
        # ("CAD155.11"); the generated value_monetary_amount strips it. There is
        # deliberately no separate Currency field.
        amount = f"{float(total):.2f}"
        out["Total"] = f"{code}{amount}" if code else amount
    card = fields.get("payment_method")
    if isinstance(card, str) and card.strip():
        out["Payment method"] = card.strip()[:128]
    reference = fields.get("reference")
    if isinstance(reference, str) and reference.strip():
        out["Reference"] = reference.strip()[:128]
    return out


def custom_field_values(document: dict, ids: dict[str, int], values: dict) -> list[dict]:
    merged = {entry["field"]: entry["value"] for entry in document.get("custom_fields", [])}
    for name, value in values.items():
        if name in ids:
            merged[ids[name]] = value
    return [{"field": field, "value": value} for field, value in merged.items()]


def main() -> None:
    if not TOKEN or not LITELLM_KEY:
        sys.exit("PAPERLESS_API_TOKEN and LITELLM_API_KEY are required")

    fields = {f["name"]: f["id"] for f in list_all("/api/custom_fields/")}
    types = {t["name"]: t["id"] for t in list_all("/api/document_types/")}
    type_ids = [types[name] for name in FINANCIAL_TYPES if name in types]
    if not type_ids:
        print("no Invoice/Receipt document types, nothing to do")
        return

    documents = list_all(
        f"/api/documents/?document_type__id__in={','.join(map(str, type_ids))}"
        "&page_size=100&ordering=-added",
    )
    done = idle = errors = 0
    total_id = fields.get("Total")

    for document in documents[:MAX_DOCS]:
        existing = {entry["field"]: entry["value"] for entry in document.get("custom_fields", [])}
        if total_id and existing.get(total_id):
            continue  # already extracted (or typed by hand)
        content = (document.get("content") or "").strip()
        if len(content) < 40:
            idle += 1
            continue
        try:
            values = clean(extract(content))
        except Exception as err:  # noqa: BLE001 — one bad document must not stop the run
            print(f"  ! doc {document['id']}: {err}")
            errors += 1
            continue
        if not values:
            idle += 1
            continue
        pp("PATCH", f"/api/documents/{document['id']}/", {"custom_fields": custom_field_values(document, fields, values)})
        print(f"  + doc {document['id']}: {values}")
        done += 1

    print(f"documents={len(documents)} updated={done} skipped={idle} errors={errors}")


if __name__ == "__main__":
    main()
