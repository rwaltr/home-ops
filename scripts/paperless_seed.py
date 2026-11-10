#!/usr/bin/env python3
"""Idempotently seed Paperless-ngx with the config this repo expects.

Paperless keeps document types, tags, custom fields and workflows in its
database, not in Git, so a config wipe loses them (the same trap as Sonarr's
release profiles). This script re-applies them through the REST API instead of
depending on someone remembering the clicks.

Run it with `mise run paperless:seed`. It is safe to run repeatedly: every
object is looked up by name and created or patched, never duplicated.

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

# Trigger/action enum values (from /api/schema/):
#   trigger type 2 = Document Added, matching algorithm 4 = Regular expression
#   action type 1 = Assignment
TRIGGER_DOCUMENT_ADDED = 2
MATCH_REGEX = 4
ACTION_ASSIGN = 1
ALL_SOURCES = [1, 2, 3, 4]  # Consume Folder, Api Upload, Mail Fetch, Web UI

DOCUMENT_TYPES = ["Invoice", "Receipt"]
TAGS = ["accounting/inbox", "accounting/attached"]
CUSTOM_FIELDS = [
    ("Invoice Number", "string"),
    ("Total", "monetary"),
    ("Date Paid", "date"),
    ("Currency", "string"),
]


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


def content_workflow(name: str, order: int, match: str, doc_type: int, tags: list[int]) -> dict:
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
                "assign_tags": tags,
            },
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
    tags = upsert("tag", "/api/tags/", [(name, {"name": name}) for name in TAGS])
    upsert(
        "custom field",
        "/api/custom_fields/",
        [(name, {"name": name, "data_type": data_type}) for name, data_type in CUSTOM_FIELDS],
    )

    inbox = [tags["accounting/inbox"]]
    workflows = [
        # Invoice before receipt: a later assignment overrides an earlier one, so a
        # store receipt that also says "invoice" ends up as Receipt.
        content_workflow(
            "auto-classify: invoice",
            10,
            r"(?i)\binvoice\b|amount due|invoice (number|no\.?)|bill to",
            types["Invoice"],
            inbox,
        ),
        content_workflow(
            "auto-classify: receipt",
            20,
            r"(?i)\breceipt\b|order total|thank you for your (purchase|order)|payment received",
            types["Receipt"],
            inbox,
        ),
    ]
    existing_workflows = {obj["name"]: obj for obj in list_all("/api/workflows/")}
    for workflow in workflows:
        upsert_workflow(workflow, existing_workflows)

    print("done")


if __name__ == "__main__":
    main()
