#!/usr/bin/env python3
"""Idempotently seed Paperless-ngx with the config this repo expects.

Paperless keeps document types, tags, custom fields and workflows in its
database, not in Git, so a config wipe loses them (the same trap as Sonarr's
release profiles). This script re-applies them through the REST API instead of
depending on someone remembering the clicks.

Run it with `mise run paperless:seed`. It is safe to run repeatedly: every
object is looked up by name and created or patched, never duplicated.

The design is a provenance trail:

  status/inbox        transient — stamped on every new document, removed by the
                      classification workflow in the same consume. Visible only
                      if a workflow failed.
  status/ai-enriched  terminal — the document was classified by the LLM.
  accounting/unlinked financial doc not yet matched to a ledger transaction.
                      Set by the rules immediately, and by an hourly scheduled
                      sweep for documents the AI typed.
  accounting/beancounted
                      matched. The Beancount bridge owns the transition:
                      remove unlinked and add beancounted.

Env:
  PAPERLESS_URL        default https://paperless.waltr.tech
  PAPERLESS_API_TOKEN  resolved from 1Password (item `paperless`, field
                       `api_token`) via fnox, see .mise/tasks/paperless/seed
"""

from __future__ import annotations

import json
import os
import socket
import sys
import urllib.error
import urllib.request

# The ingress name publishes an unreachable IPv6 ULA record for this LAN and
# Python has no Happy Eyeballs, so each connection would stall on the AAAA
# address (the full timeout) before falling back to IPv4. Pin to IPv4.
_orig_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, type=0, proto=0, flags=0: _orig_getaddrinfo(  # noqa: E731
    host, port, socket.AF_INET, type, proto, flags
)

BASE = os.environ.get("PAPERLESS_URL", "https://paperless.waltr.tech").rstrip("/")
TOKEN = os.environ.get("PAPERLESS_API_TOKEN", "").strip()

# Enum values from /api/schema/:
#   trigger type 2 = Document Added, matching algorithm 4 = Regular expression
#   action types: 1 = Assignment, 2 = Removal, 8 = Apply AI suggestions
TRIGGER_DOCUMENT_ADDED = 2
TRIGGER_SCHEDULED = 4
MATCH_REGEX = 4
ACTION_ASSIGN = 1
ACTION_REMOVE = 2
ACTION_AI = 8
ALL_SOURCES = [1, 2, 3, 4]  # Consume Folder, Api Upload, Mail Fetch, Web UI

# status/* is document processing, accounting/* is ledger linkage.
TAGS = [
    ("status/inbox", {"is_inbox_tag": True}),
    ("status/ai-enriched", {}),
    ("accounting/unlinked", {}),
    ("accounting/beancounted", {}),
]
# Superseded by the scheme above; deleted so the namespace does not drift.
REMOVED_TAGS = ["accounting/inbox", "accounting/attached"]

DOCUMENT_TYPES = [
    "Invoice",
    "Receipt",
    "Statement",
    "Contract",
    "Manual",
    "Policy",
    "Medical",
    "Correspondence",
    "Other",
]

# Reference holds an invoice number or a receipt transaction id; the date already
# lives in the document's `created` field, so Date Paid is gone.
CUSTOM_FIELDS = [
    ("Reference", "string"),
    ("Total", "monetary"),
    ("Currency", "string"),
    ("Payment method", "string"),
]
CUSTOM_FIELD_RENAMES = {"Invoice Number": "Reference"}
REMOVED_CUSTOM_FIELDS = ["Date Paid"]

# The AI may title and type the document and set a correspondent; it never
# touches tags, so the tag namespace stays hand-designed. ai_create_missing is
# global (it also allows the AI to invent a document type), accepted so the AI
# can create correspondents at all.
AI_SUGGESTION_FIELDS = ["title", "correspondent", "document_type"]


def api(method: str, path: str, body: dict | None = None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Token {TOKEN}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        detail = err.read().decode(errors="replace")
        raise SystemExit(f"{method} {path} -> {err.code}: {detail}") from None


def list_all(path: str) -> list[dict]:
    items: list[dict] = []
    page: str | None = path
    while page:
        payload = api("GET", page)
        items.extend(payload.get("results", []))
        nxt = payload.get("next")
        page = nxt[len(BASE):] if nxt else None
    return items


def upsert(kind: str, path: str, desired: list[tuple[str, dict]]) -> dict[str, int]:
    """Create or patch each named object. Returns {name: id}."""
    existing = {obj["name"]: obj for obj in list_all(path)}
    ids: dict[str, int] = {}
    for name, payload in desired:
        current = existing.get(name)
        if current is None:
            obj = api("POST", path, payload)
            print(f"  + {kind}: {name} (id {obj['id']})")
        else:
            obj = api("PATCH", f"{path}{current['id']}/", payload)
            print(f"  = {kind}: {name} (id {obj['id']})")
        ids[name] = obj["id"]
    return ids


def sync_custom_fields(desired: list[tuple[str, dict]]) -> dict[str, int]:
    """Apply renames/deletions first, then upsert the current set by name."""
    existing = {obj["name"]: obj for obj in list_all("/api/custom_fields/")}
    for old, new in CUSTOM_FIELD_RENAMES.items():
        if old in existing and new not in existing:
            api("PATCH", f"/api/custom_fields/{existing[old]['id']}/", {"name": new})
            print(f"  ~ custom field: {old} -> {new}")
            existing[new] = existing.pop(old)
    for name in REMOVED_CUSTOM_FIELDS:
        if name in existing:
            api("DELETE", f"/api/custom_fields/{existing[name]['id']}/")
            print(f"  - custom field: {name} (deleted)")
            del existing[name]
    return upsert("custom field", "/api/custom_fields/", desired)


def delete_tags(names: list[str]) -> None:
    existing = {obj["name"]: obj for obj in list_all("/api/tags/")}
    for name in names:
        current = existing.get(name)
        if current is None:
            continue
        api("DELETE", f"/api/tags/{current['id']}/")
        print(f"  - tag: {name} (deleted)")


def upsert_workflow(payload: dict, existing: dict[str, dict]) -> int:
    """Patch in place; if the nested serializer refuses an update, recreate."""
    name = payload["name"]
    current = existing.get(name)
    if current is not None:
        try:
            obj = api("PATCH", f"/api/workflows/{current['id']}/", payload)
            print(f"  = workflow: {name} (id {obj['id']})")
            return obj["id"]
        except SystemExit:
            api("DELETE", f"/api/workflows/{current['id']}/")
            print(f"  ~ workflow: {name} recreated")
    obj = api("POST", "/api/workflows/", payload)
    print(f"  + workflow: {name} (id {obj['id']})")
    return obj["id"]


def rule_workflow(
    name: str,
    order: int,
    match: str,
    doc_type: int,
    inbox: list[int],
    unlinked: list[int],
) -> dict:
    return {
        "name": name,
        "order": order,
        "enabled": True,
        "triggers": [
            {
                "type": TRIGGER_DOCUMENT_ADDED,
                "sources": ALL_SOURCES,
                "matching_algorithm": MATCH_REGEX,
                "is_insensitive": True,
                "match": match,
            },
        ],
        "actions": [
            {
                "type": ACTION_ASSIGN,
                "assign_document_type": doc_type,
                "assign_tags": unlinked,
            },
            {"type": ACTION_REMOVE, "remove_tags": inbox},
        ],
    }


def ai_workflow(untyped_type_ids: list[int], ai_enriched: list[int], inbox: list[int]) -> dict:
    # filter_has_not_document_types with every known type == "has no type": the
    # matcher skips the exclusion when document_type_id is null.
    return {
        "name": "auto-classify: ai",
        "order": 30,
        "enabled": True,
        "triggers": [
            {
                "type": TRIGGER_DOCUMENT_ADDED,
                "sources": ALL_SOURCES,
                "filter_has_not_document_types": untyped_type_ids,
            },
        ],
        "actions": [
            {
                "type": ACTION_AI,
                "ai_suggestion_fields": AI_SUGGESTION_FIELDS,
                "ai_create_missing": True,
                "ai_overwrite_existing": True,
            },
            {"type": ACTION_ASSIGN, "assign_tags": ai_enriched},
            {"type": ACTION_REMOVE, "remove_tags": inbox},
        ],
    }


def unlinked_sweep(
    financial_type_ids: list[int],
    unlinked: list[int],
    beancounted: list[int],
) -> dict:
    # Scheduled: re-queries documents each time check_scheduled_workflows runs
    # (hourly) and pre-filters by type/tag. It exists because workflow mutations
    # do not re-fire document_updated, so a follow-up Added/Updated workflow
    # cannot catch documents the AI typed as Invoice/Receipt.
    return {
        "name": "mark accounting/unlinked",
        "order": 40,
        "enabled": True,
        "triggers": [
            {
                "type": TRIGGER_SCHEDULED,
                "schedule_date_field": "added",
                "schedule_offset_days": 0,
                "schedule_is_recurring": True,
                "schedule_recurring_interval_days": 1,
                "filter_has_any_document_types": financial_type_ids,
                "filter_has_not_tags": unlinked + beancounted,
            },
        ],
        "actions": [
            {"type": ACTION_ASSIGN, "assign_tags": unlinked},
        ],
    }


def main() -> None:
    if not TOKEN:
        sys.exit("PAPERLESS_API_TOKEN is not set")

    print(f"seeding {BASE}")
    types = upsert(
        "document type",
        "/api/document_types/",
        [(name, {"name": name}) for name in DOCUMENT_TYPES],
    )
    tags = upsert(
        "tag",
        "/api/tags/",
        [(name, {"name": name, **extra}) for name, extra in TAGS],
    )
    sync_custom_fields(
        [(name, {"name": name, "data_type": data_type}) for name, data_type in CUSTOM_FIELDS],
    )
    delete_tags(REMOVED_TAGS)

    inbox = [tags["status/inbox"]]
    ai_enriched = [tags["status/ai-enriched"]]
    unlinked = [tags["accounting/unlinked"]]
    beancounted = [tags["accounting/beancounted"]]
    workflows = [
        # Invoice before receipt: a later assignment overrides an earlier one, so a
        # store receipt that also says "invoice" ends up as Receipt.
        rule_workflow(
            "auto-classify: invoice",
            10,
            r"(?i)\binvoice\b|amount due|invoice (number|no\.?)|bill to",
            types["Invoice"],
            inbox,
            unlinked,
        ),
        rule_workflow(
            "auto-classify: receipt",
            20,
            r"(?i)\breceipt\b|order total|thank you for your (purchase|order)|payment received",
            types["Receipt"],
            inbox,
            unlinked,
        ),
        # Last: only documents the rules did not type. Clears status/inbox, so a
        # document keeps it only when this workflow fails (the error signal).
        ai_workflow([types[name] for name in DOCUMENT_TYPES], ai_enriched, inbox),
        # The AI types a document asynchronously, so the rules cannot tag it. This
        # sweep is what closes that gap.
        unlinked_sweep([types["Invoice"], types["Receipt"]], unlinked, beancounted),
    ]
    existing_workflows = {obj["name"]: obj for obj in list_all("/api/workflows/")}
    for workflow in workflows:
        upsert_workflow(workflow, existing_workflows)

    print("done")


if __name__ == "__main__":
    main()
