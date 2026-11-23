#!/usr/bin/env python3
"""Create a non-admin Matrix bot account on this Tuwunel server.

Reads the registration shared secret from Kubernetes, creates one account through
Tuwunel's Synapse-compatible shared-secret endpoint, then prints the account ID and
access token. The secret and generated password are never printed.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_HOMESERVER = "https://matrix.waltr.tech"
DEFAULT_NAMESPACE = "default"
DEFAULT_SECRET = "matrix-secret"
DEFAULT_SECRET_KEY = "registration_shared_secret"
LOCALPART_RE = re.compile(r"^[a-z0-9._=-]+$")


def read_registration_secret(namespace: str, secret_name: str, key: str) -> bytes:
    """Read a Kubernetes Secret without putting its value in argv or shell history."""
    jsonpath = f"{{.data.{key}}}"
    try:
        result = subprocess.run(
            [
                "kubectl",
                "-n",
                namespace,
                "get",
                "secret",
                secret_name,
                "-o",
                f"jsonpath={jsonpath}",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("kubectl was not found in PATH") from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip() or f"kubectl exited with status {exc.returncode}"
        raise RuntimeError(f"could not read {namespace}/{secret_name}: {detail}") from exc

    try:
        value = base64.b64decode(result.stdout, validate=True)
    except ValueError as exc:
        raise RuntimeError("the registration Secret value is not valid base64") from exc
    if not value:
        raise RuntimeError("the registration Secret value is empty")
    return value


def api_json(url: str, payload: dict[str, object] | None = None) -> dict[str, object]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {} if data is None else {"Content-Type": "application/json"}
    request = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        # Do not print request bodies. The registration request carries an HMAC.
        raise RuntimeError(f"Tuwunel returned HTTP {exc.code} for {urllib.parse.urlparse(url).path}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"could not reach Tuwunel: {exc.reason}") from exc
    if not isinstance(result, dict):
        raise RuntimeError("Tuwunel returned an unexpected response")
    return result


def registration_payload(
    nonce: str, username: str, password: str, registration_secret: bytes
) -> dict[str, object]:
    """Build Tuwunel's non-admin signed registration request."""
    mac_data = b"\0".join(
        (nonce.encode(), username.encode(), password.encode(), b"notadmin")
    )
    mac = hmac.new(registration_secret, mac_data, hashlib.sha1).hexdigest()
    return {
        "nonce": nonce,
        "username": username,
        "password": password,
        "admin": False,
        "mac": mac,
    }


def provision(homeserver: str, username: str, registration_secret: bytes) -> tuple[str, str]:
    base = homeserver.rstrip("/")
    parsed = urllib.parse.urlparse(base)
    if parsed.scheme != "https" or not parsed.netloc:
        raise RuntimeError("homeserver must be an https:// URL")

    endpoint = f"{base}/_synapse/admin/v1/register"
    nonce_response = api_json(endpoint)
    nonce = nonce_response.get("nonce")
    if not isinstance(nonce, str) or not nonce:
        raise RuntimeError("Tuwunel did not return a registration nonce")

    # The random password satisfies the API but is unused. Password login is
    # disabled on this homeserver. Tuwunel's HMAC marker is `notadmin`.
    password = secrets.token_urlsafe(32)
    result = api_json(
        endpoint,
        registration_payload(nonce, username, password, registration_secret),
    )

    user_id = result.get("user_id")
    access_token = result.get("access_token")
    if not isinstance(user_id, str) or not isinstance(access_token, str):
        raise RuntimeError("Tuwunel did not return a user ID and access token")
    return user_id, access_token


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("username", help="bot account localpart, e.g. teletran")
    parser.add_argument("--homeserver", default=DEFAULT_HOMESERVER)
    parser.add_argument("--namespace", default=DEFAULT_NAMESPACE)
    parser.add_argument("--secret", default=DEFAULT_SECRET)
    parser.add_argument("--secret-key", default=DEFAULT_SECRET_KEY)
    args = parser.parse_args()

    if not LOCALPART_RE.fullmatch(args.username):
        parser.error("username must be a lowercase Matrix localpart")

    try:
        shared_secret = read_registration_secret(args.namespace, args.secret, args.secret_key)
        user_id, access_token = provision(args.homeserver, args.username, shared_secret)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(f"User: {user_id}")
    print("Access token (store in 1Password; never commit it):")
    print(access_token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
