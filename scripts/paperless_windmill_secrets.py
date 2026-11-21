#!/usr/bin/env python3
"""Sync the 1Password-backed Paperless pipeline credentials into Windmill secrets."""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = os.environ.get("WINDMILL_URL", "https://windmill.waltr.tech").rstrip("/")
WORKSPACE = "admins"
TOKEN = os.environ["WINDMILL_TOKEN"]


def request(method: str, path: str, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{BASE_URL}/api/w/{WORKSPACE}/{path}",
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            if not raw:
                return None
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                return None
    except urllib.error.HTTPError as err:
        raise RuntimeError(f"Windmill API {method} {path} failed with HTTP {err.code}") from None


def upsert(path: str, value: str, description: str) -> None:
    encoded_path = urllib.parse.quote(path, safe="/")
    exists = request("GET", f"variables/exists/{encoded_path}")
    verb = "update" if exists else "create"
    endpoint = f"variables/{verb}/{encoded_path}" if exists else "variables/create"
    body = {"path": path, "value": value, "is_secret": True, "description": description}
    request("POST", endpoint, body)
    print(f"Windmill secret variable {verb}: {path}")


def main() -> None:
    upsert(
        "f/paperless/paperless_api_token",
        os.environ["PAPERLESS_API_TOKEN"],
        "Paperless API token, synced from 1Password item paperless/api_token.",
    )
    upsert(
        "f/paperless/immich_api_key",
        os.environ["IMMICH_PAPERLESS_API_KEY"],
        "Immich API key, synced from 1Password item paperless-bridge/credential.",
    )


if __name__ == "__main__":
    main()
