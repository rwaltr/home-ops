#!/usr/bin/env python3
"""Publish a Remind file as a read-only CalDAV feed.

Run this where the Remind CLI and the `remind` Python package (which provides
`rem2ics`) are installed — i.e. on a workstation, not in the cluster. The
`.reminders` file never leaves that machine; only the rendered iCalendar events
are uploaded, to an account that has write access to nothing else.

Why it is not one PUT: RFC 4791 §4.1 requires every VEVENT in a calendar object
resource to carry the same UID, and Radicale refuses the whole resource
otherwise ("Multiple VEVENT components with different UIDs in object" → HTTP
400). So each event becomes its own resource named after its UID, with the
VTIMEZONE definitions copied into each one (rem2ics emits TZID references that
clients cannot resolve otherwise). Resources in the collection that the current
export no longer produces are deleted, so removing a line from `.reminders`
removes the event from the feed.

Read-only for everyone else is enforced server-side by the share permissions in
infra/k8s/kyz/apps/default/radicale/app/bootstrap.sh, not here.
"""

from __future__ import annotations

import argparse
import base64
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import quote, unquote

CRLF = "\r\n"


def resource_path(args: argparse.Namespace, uid: str) -> str:
    """Path of one event's resource.

    rem2ics UIDs are `<hash>@<hostname>`; `@` is legal in a path segment but
    Radicale percent-encodes it in hrefs, so encode on the way out and decode on
    the way back in (`existing()`) — otherwise every run thinks the whole feed
    is stale and deletes it.
    """
    return f"{args.collection}{quote(uid, safe='')}.ics"


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Publish a Remind file as a read-only CalDAV feed.")
    p.add_argument("--reminders", default="~/.reminders", help="Remind file to export")
    p.add_argument("--url", default=os.environ.get("REMIND_CALDAV_URL"),
                   help="Radicale base URL (or $REMIND_CALDAV_URL)")
    p.add_argument("--user", default=os.environ.get("REMIND_CALDAV_USER"),
                   help="account used for the upload (or $REMIND_CALDAV_USER)")
    p.add_argument("--password", default=os.environ.get("REMIND_CALDAV_PASSWORD"),
                   help="password (or $REMIND_CALDAV_PASSWORD; prefer a file/agent over argv)")
    p.add_argument("--collection", default="/remind-export/remind/",
                   help="collection path that receives the events")
    p.add_argument("--months", type=int, default=24,
                   help="months of events to render forward from rem2ics' start date")
    p.add_argument("--rem2ics", default="rem2ics", help="path to the rem2ics executable")
    p.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    p.add_argument("--reset", action="store_true",
                   help="delete every resource already in the collection before uploading "
                        "(recovers from a UID collision, e.g. after an out-of-band write)")
    args = p.parse_args(argv)
    if not args.url or not args.user or not args.password:
        p.error("--url/--user/--password (or the REMIND_CALDAV_* environment) are required")
    args.url = args.url.rstrip("/")
    args.collection = "/" + args.collection.strip("/") + "/"
    return args


def request(args: argparse.Namespace, method: str, path: str, body: bytes | None = None,
            headers: dict[str, str] | None = None) -> tuple[int, bytes]:
    """One authenticated CalDAV request. No third-party HTTP library needed."""
    req = urllib.request.Request(args.url + path, method=method, data=body)
    token = base64.b64encode(f"{args.user}:{args.password}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("User-Agent", "remind-to-caldav/1")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def render(args: argparse.Namespace) -> str:
    """Run rem2ics and return its iCalendar output."""
    cmd = [args.rem2ics, f"--month={args.months}", os.path.expanduser(args.reminders)]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        sys.exit(f"{args.rem2ics}: not found — install it with `uv tool install remind` "
                 "(and make sure the `remind` CLI itself is on PATH)")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"{' '.join(cmd)} failed ({exc.returncode}): {exc.stderr.strip()}")
    return result.stdout


def split(ics: str) -> dict[str, str]:
    """Split a multi-event VCALENDAR into one single-UID resource per event."""
    text = ics.replace(CRLF, "\n")
    timezones = "\n".join(re.findall(r"BEGIN:VTIMEZONE\n.*?END:VTIMEZONE\n", text, re.S))
    events = re.findall(r"BEGIN:VEVENT\n.*?END:VEVENT\n", text, re.S)
    if not events:
        return {}
    header = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//remind-to-caldav//EN\n"
    resources: dict[str, str] = {}
    for event in events:
        match = re.search(r"^UID:(.+)$", event, re.M)
        if not match:
            # check_and_sanitize_items() would assign one; refuse instead so the
            # resource name and the UID never disagree.
            sys.exit("rem2ics produced a VEVENT without a UID")
        uid = match.group(1).strip()
        body = header + timezones + event + "END:VCALENDAR\n"
        resources[uid] = body.replace("\n", CRLF)
    return resources


def existing(args: argparse.Namespace) -> list[str]:
    """UIDs currently published in the target collection."""
    body = (b'<?xml version="1.0" encoding="utf-8" ?>'
            b'<D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>')
    status, payload = request(args, "PROPFIND", args.collection, body,
                              {"Depth": "1", "Content-Type": "application/xml"})
    if status == 404:
        return []
    if status not in (207, 200):
        sys.exit(f"PROPFIND {args.collection} -> HTTP {status}")
    ns = {"D": "DAV:"}
    hrefs = [unquote(h.text) for h in ET.fromstring(payload).findall(".//D:href", ns) if h.text]
    prefix = args.collection
    return [h[len(prefix):-len(".ics")] for h in hrefs
            if h.startswith(prefix) and h.endswith(".ics")]


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    wanted = split(render(args))
    have = existing(args)
    print(f"{len(wanted)} event(s) rendered; {len(have)} already published")

    if args.reset:
        for uid in sorted(have):
            if args.dry_run:
                print(f"  (reset) DELETE {uid}.ics")
                continue
            status, _ = request(args, "DELETE", resource_path(args, uid))
            print(f"  (reset) DELETE {uid}.ics -> {status}")
        have = []

    for uid, resource in sorted(wanted.items()):
        if args.dry_run:
            print(f"  PUT {uid}.ics")
            continue
        status, payload = request(args, "PUT", resource_path(args, uid),
                                  resource.encode(), {"Content-Type": "text/calendar"})
        if status == 409:
            sys.exit(f"PUT {uid}.ics -> HTTP 409: this UID is already published under a "
                     "different name in the collection; re-run with --reset")
        if status not in (200, 201, 204):
            sys.exit(f"PUT {uid}.ics -> HTTP {status}: {payload[:200].decode(errors='replace')}")
        print(f"  PUT {uid}.ics -> {status}")

    for uid in sorted(set(have) - set(wanted)):
        if args.dry_run:
            print(f"  DELETE {uid}.ics")
            continue
        status, _ = request(args, "DELETE", resource_path(args, uid))
        if status not in (200, 204, 404):
            sys.exit(f"DELETE {uid}.ics -> HTTP {status}")
        print(f"  DELETE {uid}.ics -> {status}")

    if not args.dry_run:
        status, _ = request(args, "PROPFIND", args.collection,
                            b'<?xml version="1.0" encoding="utf-8" ?>'
                            b'<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>',
                            {"Depth": "1", "Content-Type": "application/xml"})
        print(f"published {len(wanted)} event(s); collection now answers HTTP {status}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
