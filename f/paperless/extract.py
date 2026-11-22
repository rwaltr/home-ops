#!/usr/bin/env python3
#requirements:
# wmill
"""Fill Paperless custom fields from receipt/invoice OCR text via the LLM.

Paperless' built-in "Apply AI suggestions" action can only write title, tags,
correspondent, document type, storage path and created date — it has no
custom-field path at all (`AISuggestionField` and `documents/workflows/ai.py`).
This job closes that gap: for documents typed Invoice or Receipt, it asks the
same LLM (intel-vl via agentgateway) for the total, currency, card and reference,
then PATCHes the custom fields.

It reads OCR text, not the image, so a receipt photographed with no usable text yields
nothing here. The Immich bridge enriches the files it sends from the image itself,
which is better evidence; this job covers everything else (an emailed PDF, a manual
upload) and re-fills a document whose OCR only became available after the bridge ran.

Runs as a CronJob (extract-cronjob.yaml). Idempotent: a document that already
has a Total is skipped, so re-runs only fill blanks.

Env:
  PAPERLESS_URL        default http://paperless-app.default.svc.cluster.local:8000
  PAPERLESS_API_TOKEN  from the paperless-secret
  AIGW_BASE_URL        default http://agentgateway.default.svc.cluster.local:8082/v1
  AIGW_API_KEY         placeholder; gateway's internal listener has no auth
  AIGW_MODEL           default intel-vl
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
AIGW = os.environ.get("AIGW_BASE_URL", "http://agentgateway.default.svc.cluster.local:8082/v1").rstrip("/")
AIGW_KEY = os.environ.get("AIGW_API_KEY", "unused").strip()
MODEL = os.environ.get("AIGW_MODEL", "intel-vl")
MAX_DOCS = int(os.environ.get("MAX_DOCS", "25"))

FINANCIAL_TYPES = ("Invoice", "Receipt")
PROMPT = """You extract structured fields from receipts and invoices.

Reply with a single JSON object and nothing else:
{"total": <number or null>, "currency": <ISO 4217 code or null>,
 "payment_method": <string or null>, "reference": <string or null>}

- total: the printed TOTAL / amount paid, as a number. Null if absent.
- currency: three-letter code. Null if it cannot be inferred.
- payment_method: the card brand and the last four digits, e.g.
  "MASTERCARD 3642". No asterisks and no masking. Null if there is no card.
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
        f"{AIGW}/chat/completions",
        body,
        {"Authorization": f"Bearer {AIGW_KEY}"},
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


def candidate_ids(max_docs: int) -> list[int]:
    fields = {f["name"]: f["id"] for f in list_all("/api/custom_fields/")}
    types = {t["name"]: t["id"] for t in list_all("/api/document_types/")}
    type_ids = [types[name] for name in FINANCIAL_TYPES if name in types]
    if not type_ids:
        return []
    total_id = fields.get("Total")
    docs = list_all(
        f"/api/documents/?document_type__id__in={','.join(map(str, type_ids))}"
        "&page_size=100&ordering=-added",
    )
    candidates = []
    for doc in docs:
        values = {entry["field"]: entry["value"] for entry in doc.get("custom_fields", [])}
        if total_id and values.get(total_id):
            continue
        if len((doc.get("content") or "").strip()) < 40:
            continue
        candidates.append(doc["id"])
        if len(candidates) >= max_docs:
            break
    return candidates


def process_document(document_id: int, dry_run: bool = False) -> dict:
    fields = {f["name"]: f["id"] for f in list_all("/api/custom_fields/")}
    types = {t["name"]: t["id"] for t in list_all("/api/document_types/")}
    type_ids = {types[name] for name in FINANCIAL_TYPES if name in types}
    total_id = fields.get("Total")
    document = pp("GET", f"/api/documents/{document_id}/")
    if document.get("document_type") not in type_ids:
        return {"document_id": document_id, "status": "not_invoice_or_receipt"}
    existing = {entry["field"]: entry["value"] for entry in document.get("custom_fields", [])}
    if total_id and existing.get(total_id):
        return {"document_id": document_id, "status": "already_filled"}
    content = (document.get("content") or "").strip()
    if len(content) < 40:
        return {"document_id": document_id, "status": "no_ocr_text"}
    values = clean(extract(content))
    if not values:
        return {"document_id": document_id, "status": "no_values"}
    if not dry_run:
        pp("PATCH", f"/api/documents/{document_id}/", {"custom_fields": custom_field_values(document, fields, values)})
    return {"document_id": document_id, "status": "would_update" if dry_run else "updated", "field_names": list(values)}


def main(action: str = "run", document_id: int | None = None, max_docs: int = 25, dry_run: bool = False) -> dict | list[int]:
    global AIGW, AIGW_KEY, MAX_DOCS, MODEL, PAPERLESS, TOKEN
    if os.environ.get("WM_JOB_ID"):
        import wmill

        paperless = wmill.get_resource("f/paperless/paperless_api")
        ai = wmill.get_resource("f/ai/agentgateway")
        PAPERLESS = paperless["base_url"].rstrip("/")
        TOKEN = paperless["api_token"]
        AIGW = ai["base_url"].rstrip("/")
        AIGW_KEY = ai["api_key"]
        MODEL = "intel-vl"
    if not TOKEN:
        sys.exit("PAPERLESS_API_TOKEN is required")
    MAX_DOCS = max_docs
    if action == "list":
        return {"document_ids": candidate_ids(max_docs)}
    if action == "process":
        if document_id is None:
            raise ValueError("document_id is required for action=process")
        result = process_document(document_id, dry_run)
        print(result)
        return result
    if action != "run":
        raise ValueError(f"unknown action {action!r}; expected list, process, or run")

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
        if not dry_run:
            pp("PATCH", f"/api/documents/{document['id']}/", {"custom_fields": custom_field_values(document, fields, values)})
        print(f"  {'would update' if dry_run else 'updated'} doc {document['id']}: field_names={','.join(values)}")
        done += 1

    result = {"documents": len(documents), "updated": done, "skipped": idle, "errors": errors, "dry_run": dry_run}
    print("documents={documents} updated={updated} skipped={skipped} errors={errors}".format(**result))
    return result


if __name__ == "__main__":
    main()
