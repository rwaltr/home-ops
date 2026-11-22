#!/usr/bin/env python3
#requirements:
# wmill
"""Flag newly added Immich photos that look like documents, and copy the album
into Paperless's consume directory.

Standard library only: the job runs from a stock python image with no pip
install, so it cannot drift from its dependencies.

Two phases, in order:

  send      assets in the ALBUM are copied into Paperless's consume directory
            and tagged SENT_TAG. The album is the human answer to the review
            queue below, and the only path into the archive - which is
            permanent, so nothing enters it unreviewed.

  classify  every image added in the last WINDOW_HOURS that carries none of the
            bridge's tags is scored against Immich's CLIP smart search. Assets
            that come back for a document-ish query are tagged MAYBE_TAG so they
            can be reviewed in the UI. This phase copies nothing, ever.

State lives in Immich tags rather than in this pod, so reruns and restarts are
idempotent and the state is visible in the UI instead of hidden in a volume.
"""

import base64
import datetime
import json
import mimetypes
import os
import pathlib
import sys
import urllib.error
import urllib.request

IMMICH = os.environ.get("IMMICH_URL", "http://immich-server.default.svc.cluster.local:2283")
KEY = os.environ.get("IMMICH_API_KEY", "")
ALBUM = os.environ.get("IMMICH_ALBUM", "Paperless")
SENT_TAG = os.environ.get("SENT_TAG", "paperless-sent")
MAYBE_TAG = os.environ.get("MAYBE_TAG", "paperless-maybe")

# Only look at recently added assets. createdAfter is when the asset entered the
# library, which is what "new" means here - not when the photo was taken, so a
# photo imported from an old camera roll is still classified.
WINDOW_HOURS = int(os.environ.get("WINDOW_HOURS", "24"))
# Ceiling on pages walked per run, so a wide WINDOW_HOURS cannot make a run
# unbounded: MAX_PAGES * 200 assets, newest first.
MAX_PAGES = int(os.environ.get("MAX_PAGES", "5"))

# Immich's smart search returns its best matches for a query with no score
# threshold, so these are recall nets rather than classifiers. Several plain
# phrases beat one clever one: each is one cheap call and the union is what gets
# reviewed. Tune the list, not a numeric threshold.

# CLIP alone over-suggests: measured on this library, most of its top-100 hits
# ranked 20th or worse for their own query, and 6 of 11 tagged assets matched no
# query at all. So a candidate must show evidence before it is queued.
#
# The evidence is checked in cost order. Immich's OCR is local and free, so text
# wins first; only when OCR has nothing to say does the vision model get asked.
# VISION_MODEL points at intel-vl (Qwen3-VL-8B on Dan's Intel Arc), so that call
# costs nothing and the photo stays off a model provider.
MAX_VISION_CALLS = int(os.environ.get("MAX_VISION_CALLS", "20"))
AIGW_URL = os.environ.get("AIGW_URL", "http://agentgateway.default.svc.cluster.local:8082/v1")
VISION_MODEL = os.environ.get("VISION_MODEL", "intel-vl")
# 8082 carries no auth, so this is a placeholder: the request shape wants a bearer.
VISION_KEY = os.environ.get("AIGW_API_KEY", "unused")
DRY_RUN = False

# The closed vocabulary the model must choose from. Free-form tags sprawl into
# hundreds nobody can filter on, so anything outside this set is dropped and
# logged. Reserved for the HomeBox feed, not wired yet: homebox.
VOCAB = {
    "person",
    "casual",
    "formal",
    "landscape",
    "art",
    "food",
    "pet",
    "children",
    "vehicle",
    "screenshot",
    "indoor",
    "outdoor",
    "holiday",
    "document",
}

DOC_TAG = os.environ.get("DOC_TAG", "document")

VISION_PROMPT = (
    "You are shown one photo. Answer with JSON only, no prose and no code fence, "
    "in exactly this shape: "
    '{"description": "one short sentence", "tags": ["casual", "person"], '
    '"document": false, "useful": true, "confidence": 0.0, "kind": ""}'
    "description must name what the thing IS. For a document that means the merchant "
    "and the purchase (\"H-E-B receipt for Evian water\"), never the room, table or "
    "lighting it was photographed on. For anything else describe what is happening. "
    "tags must be 1-4 words from this list, spelled exactly: "
    + ", ".join(sorted(VOCAB))
    + ". document is true only if this is a document that belongs in a paperless "
    "archive: a receipt, invoice, bill, bank statement, tax form, insurance letter, "
    "or a scan or photo of one. A photograph of a person, place, object, food, "
    "animal or scenery is not a document, and neither is a screenshot of a chat, "
    "game, map or app UI. confidence is 0 to 1 for document. kind is one of "
    "receipt, invoice, bill, statement, tax, insurance, letter or other when "
    "document is true, otherwise an empty string. "
    "useful: false when it is a document but junk with no lasting value - a discount "
    "coupon, an advertisement, a flyer, a loyalty card, a promotional slip, or "
    "something you cannot read at all. True when it is worth keeping, and true for "
    "anything that is not a document."
)

# What Paperless can ingest. Everything else (notably HEIC from iPhones) is
# fetched as Immich's fullsize JPEG instead: Paperless has no HEIC support, and
# its consumer would fail the file rather than convert it.
SAFE_EXT = {".jpg", ".jpeg", ".png", ".pdf", ".tif", ".tiff", ".webp", ".gif", ".txt"}


def api(path, method="GET", payload=None, raw=False):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{IMMICH}/api{path}",
        method=method,
        data=data,
        headers={"x-api-key": KEY, "Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read()
            return body if raw else json.loads(body or b"{}")
    except urllib.error.HTTPError as err:
        # A bare traceback is useless in a CronJob log, and so is our own guess at the
        # cause: Immich answers a bad field with a zod body naming it, and dropping that
        # turned a one-line diagnosis into an evening. 401/403 still means the
        # paperless-bridge credential is not an Immich API key, or lacks a scope.
        detail = err.read().decode("utf-8", "replace").strip()[:300]
        sys.exit(f"Immich API returned {err.code} for {method} {path}: {detail}")


def safe_name(asset):
    """Name the file after what the photo is, because Paperless titles from it.

    Paperless's own AI is text-only. For a photographed receipt whose OCR comes back
    empty it has nothing to work with and the title stays the camera filename; the
    vision model already described the image, so the filename carries that instead.
    """
    when = (asset.get("fileCreatedAt") or "")[:10] or datetime.date.today().isoformat()
    stem = ((asset.get("exifInfo") or {}).get("description") or "").strip()
    if not stem:
        stem = pathlib.Path(asset.get("originalFileName") or "photo").stem
    # 90 characters is a comfortable title; a paragraph helps nobody.
    keep = "".join(c if c.isalnum() or c in " -_$" else "-" for c in stem).strip(" -_") or "photo"
    ext = pathlib.Path(asset.get("originalFileName") or "").suffix.lower()
    if ext not in SAFE_EXT:
        return f"{when} {keep[:90]}.jpg"
    return f"{when} {keep[:90]}{ext}"


def tags_by_name():
    return {t["name"]: t["id"] for t in api("/tags")}


def ensure_tag(tags, name):
    """Return the tag id, creating the tag if this is the first run."""
    if name not in tags:
        tags[name] = api("/tags", "POST", {"name": name})["id"]
    return tags[name]


def already_tagged(asset_id, names):
    """True if any of the given tags is already on this asset.

    Asked per asset rather than read off the search result: /search/metadata
    does not include tags on its items, and assuming it did made every rerun
    re-tag the same assets - which also meant an operator's paperless-skip could
    never take effect, so a declined suggestion came back forever.
    """
    try:
        asset = api(f"/assets/{asset_id}")
    except SystemExit:
        # Cannot read it (deleted mid-run, or a scope we lack): leave it alone
        # rather than tag it again. Said out loud, because a silent skip here is
        # indistinguishable from a working skip in the log.
        print(f"warn: cannot read {asset_id}, leaving it untouched", flush=True)
        return True
    return bool({t.get("name") for t in asset.get("tags") or []} & set(names))


def parse_verdict(text):
    """The model's answer as a dict, or (None, why) when it did not answer."""
    text = text.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
    try:
        answer = json.loads(text)
    except ValueError:
        return None, "unparsable answer"
    if not isinstance(answer, dict) or "document" not in answer:
        # A reply without the gate is not a verdict: treating a missing field as
        # false would silently park real documents forever.
        return None, "answer had no document field"
    return answer, ""


def vision_verdict(asset_id):
    """Ask the configured vision model about one photo. Returns (verdict, why).

    verdict is the model's dict, or None when no answer came back. None must never
    be treated as a rejection: an outage would otherwise teach the library that
    every unreadable asset is junk, and that verdict is cached as a tag.
    """
    try:
        image = api(f"/assets/{asset_id}/thumbnail?size=preview", raw=True)
    except SystemExit as err:
        return None, f"thumbnail failed ({err})"
    body = {
        "model": VISION_MODEL,
        "max_tokens": 300,
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": VISION_PROMPT},
                    {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(image).decode()}},
                ],
            }
        ],
    }
    req = urllib.request.Request(
        AIGW_URL.rstrip("/") + "/chat/completions",
        method="POST",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {VISION_KEY}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            payload = json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as err:
        return None, f"agentgateway {err.code}"
    except Exception as err:  # noqa: BLE001 - any transport failure means no answer
        return None, f"agentgateway unreachable ({err})"
    text = ((payload.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
    return parse_verdict(text)


def ensure_album():
    """The Paperless album, created on first use. This album is the queue."""
    for album in api("/albums?withoutAssets=true"):
        if album.get("albumName") == ALBUM:
            return album["id"]
    return api("/albums", "POST", {"albumName": ALBUM})["id"]


def describe(asset_id, verdict, tags):
    """Write the model's description and tags onto the asset. Returns writes made."""
    writes = 0
    asset = api(f"/assets/{asset_id}")
    existing = ((asset.get("exifInfo") or {}).get("description") or "").strip()
    description = (verdict.get("description") or "").strip()
    if description and not existing:
        # Never overwrite a description: the operator's words outrank the model's.
        try:
            api(f"/assets/{asset_id}", "PUT", {"description": description})
            writes += 1
        except SystemExit as err:
            # Best effort only. A HEIC with no exif row answers "Not found or no
            # asset.update access" to this write, and that must not cost the asset its tags.
            print(f"describe: {asset_id} description refused ({err})", flush=True)
    for name in verdict.get("tags") or []:
        if name not in VOCAB:
            print(f"describe: dropping {name!r}, not in the vocabulary", flush=True)
            continue
        api(f"/tags/{ensure_tag(tags, name)}/assets", "PUT", {"ids": [asset_id]})
        writes += 1
    return writes

def classify(tags, window_hours=None):
    # The sweep uses the configured window. The event path passes minutes instead,
    # so one upload is examined on its own rather than re-scanning the day.
    hours = WINDOW_HOURS if window_hours is None else window_hours
    since = (datetime.datetime.now(datetime.UTC) - datetime.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    # Immich caps a metadata page at 200 and has no "everything in this window" call,
    # so walk pages. Oldest first: with a per-run model budget, this drains the
    # backlog from the far end instead of restacking the newest page every run.
    recent = []
    for page in range(1, MAX_PAGES + 1):
        found = api(
            "/search/metadata",
            "POST",
# Newest first: the event path catches fresh uploads, but the sweep is what
# recovers anything that arrived while it was down, so it looks at the recent end.
# Already-decided assets are skipped, so successive runs still walk backwards
# through the window. The old backlog is not reachable from here at all: it needs
# its own explicit run with a wide window, not the hourly sweep.
            {"createdAfter": since, "type": "IMAGE", "size": 200, "page": page, "order": "desc"},
        )
        items = ((found.get("assets") or {}).get("items")) or []
        recent.extend(items)
        if len(items) < 200:
            break
    if not recent:
        print(f"classify: no images added in the last {hours}h", flush=True)
        return 0

    if DRY_RUN:
        decided = maybe = junk = album = None
    else:
        decided = ensure_tag(tags, DOC_TAG)
        maybe = ensure_tag(tags, MAYBE_TAG)
        # Junk is a decision, not a missing one, and it needs a tag so the next run does not
        # ask again. This is the old skip tag under the name that means the same thing on
        # both sides of the bridge, so junk is labelled in the same place it is judged.
        junk = ensure_tag(tags, USELESS_TAG)
        album = ensure_album()
    documents = skipped = vision_calls = 0
    for asset in recent:
        # Any of these means the question is already answered: sent, archived, or
        # declined. paperless-maybe is deliberately absent, so assets queued by the
        # old OCR gate get a real verdict now instead of sitting in review forever.
        # Decided means the question is answered: sent, a document, or carrying any of
        # the content tags this script writes. There is no skip tag - a photo that is not
        # a document needs no record, and its description and content tags are that record.
        # A tag the operator added by hand counts as their answer too.
        if already_tagged(asset["id"], set(VOCAB) | {SENT_TAG, DOC_TAG, USELESS_TAG}):
            continue
        if vision_calls >= MAX_VISION_CALLS:
            print(f"classify: {asset['id']} left for the next run, vision budget of {MAX_VISION_CALLS} spent", flush=True)
            continue
        vision_calls += 1
        verdict, why = vision_verdict(asset["id"])
        if verdict is None:
            # No answer: write nothing, so a later run asks again. Writing skip here
            # would turn an outage into a permanent verdict.
            print(f"classify: {asset['id']} untouched, no answer ({why})", flush=True)
            continue
        if DRY_RUN:
            if verdict.get("document") and verdict.get("useful") is not False:
                documents += 1
            else:
                skipped += 1
            print(f"classify: {asset['id']} would be classified; no Immich changes in dry-run", flush=True)
            continue
        try:
            wrote = describe(asset["id"], verdict, tags)
            # One verdict, and maybe is cleared whichever way it went.
            api(f"/tags/{maybe}/assets", "DELETE", {"ids": [asset["id"]]})
            # A document the model itself calls junk - a coupon, a flyer, an advert, a
            # loyalty card - must never be tagged as one. The tag is what queues it for
            # Paperless, and the point is that junk never gets there at all.
            if verdict.get("document") and verdict.get("useful") is not False:
                # Album first, tag second: the tag is what makes a later run skip this
                # asset, so it must never be written before the album add succeeded.
                api(f"/albums/{album}/assets", "PUT", {"ids": [asset["id"]]})
                api(f"/tags/{decided}/assets", "PUT", {"ids": [asset["id"]]})
                documents += 1
                print(f"classify: {asset['id']} -> {DOC_TAG}, {wrote} write(s), kind={verdict.get('kind') or '?'}, conf={verdict.get('confidence')}: {verdict.get('description') or '?'}", flush=True)
            else:
                # useless is reserved for a document the model read and called junk, so
                # the tag means the same thing on both sides of the bridge. A photo of a
                # person or a dog is not labelled: it is not a document, and its content
                # tags are already the record of that decision.
                if verdict.get("document"):
                    api(f"/tags/{junk}/assets", "PUT", {"ids": [asset["id"]]})
                    print(f"classify: {asset['id']} -> {USELESS_TAG} (junk document), {wrote} write(s): {verdict.get('description') or '?'}", flush=True)
                else:
                    print(f"classify: {asset['id']} -> not a document, {wrote} write(s): {verdict.get('description') or '?'}", flush=True)
                skipped += 1
        except SystemExit as err:
            # api() exits on any non-2xx, so one asset that cannot be written would abort the
            # run and strand every asset after it - which is exactly what the HEIC 400 did.
            print(f"classify: {asset['id']} write failed, left alone ({err})", flush=True)
            continue

    print(
        f"classify: {len(recent)} image(s), {documents} document(s), {skipped} skipped, "
        f"{vision_calls} vision call(s)",
        flush=True,
    )
    return documents


# ---------------------------------------------------------------- Paperless metadata
# Paperless's own AI writes title, tags, correspondent, document type, storage path and
# created date, and it reads text only. It has no custom-field path at all. So a
# photographed receipt whose OCR came back empty is titled after its camera filename with
# nothing filled in. This asks the vision model about the image instead and writes what
# it reads into the fields this stack already uses (see paperless_extract.py).
PAPERLESS_URL = os.environ.get("PAPERLESS_URL", "http://paperless-app.default.svc.cluster.local:8000").rstrip("/")
PAPERLESS_KEY = os.environ.get("PAPERLESS_API_TOKEN", "")
VISION_TAG = os.environ.get("VISION_TAG", "status/vision-enriched")
# Documents the model examined and could not read. Labelled rather than left
# untitled so they can be found and deleted.
USELESS_TAG = os.environ.get("USELESS_TAG", "useless")
ENRICH_PROMPT = (
    "You are shown one photo of a receipt, invoice, bill or statement. Reply with JSON "
    "only, no prose and no code fence, in exactly this shape: "
    '{"title": "H-E-B receipt for Evian water", "merchant": "H-E-B", '
    '"date": "2026-11-08", "total": 20.64, "currency": "USD", '
    '"payment_method": "MASTERCARD 3642", "reference": "", "useful": true} '
    "title: the merchant and what was bought, under 80 characters. Name the shop and a "
    "couple of items. Never describe the room, table, lighting or camera angle. "
    "merchant: the shop, as printed. date: the transaction date, YYYY-MM-DD. "
    "total: the printed TOTAL as a number, not a string, or null. "
    "currency: three-letter code, or null. payment_method: the card line as printed, "
    "brand and the last four digits, like MASTERCARD 3642, with no asterisks. reference: invoice or transaction id, or an empty string. "
    "OCR is unreliable on digits: prefer the printed TOTAL line and do not invent a value. "
    "useful: false when the document is junk with no lasting value - a discount coupon, "
    "an advertisement, a flyer, a loyalty card, a promotional slip, or something you "
    "cannot read at all. True when it is worth keeping."
)


def paperless(path, method="GET", payload=None):
    """Talk to Paperless. Separate from api(), which talks to Immich."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        PAPERLESS_URL + "/api" + path,
        data=data,
        method=method,
        headers={"Authorization": "Token " + PAPERLESS_KEY, "Content-Type": "application/json"},
    )
    try:
        raw = urllib.request.urlopen(req, timeout=90).read().decode()
    except urllib.error.HTTPError as err:
        # Paperless puts the reason in the body - "Object violates owner / name unique
        # constraint" - and a bare "HTTP Error 400" is what hid it. Keep the exception
        # type: ensure_named catches it to re-look-up a name it lost a race on.
        detail = err.read().decode("utf-8", "replace").strip()[:300]
        raise urllib.error.HTTPError(
            err.url, err.code, f"{err.reason}: {detail}", err.headers, None
        ) from None
    return json.loads(raw) if raw.strip() else {}


def paperless_upload(filename, content):
    """Upload one file through Paperless's API instead of the shared consume mount."""
    boundary = "----WindmillPaperless" + os.urandom(16).hex()
    safe_filename = filename.replace('"', "_").replace("\r", "_").replace("\n", "_")
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{safe_filename}\"\r\n"
        f"Content-Type: {mimetypes.guess_type(filename)[0] or 'application/octet-stream'}\r\n\r\n".encode(),
        content,
        f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\n{pathlib.Path(filename).stem}\r\n"
        f"--{boundary}--\r\n".encode(),
    ]
    req = urllib.request.Request(
        PAPERLESS_URL + "/api/documents/post_document/",
        data=b"".join(parts),
        method="POST",
        headers={
            "Authorization": "Token " + PAPERLESS_KEY,
            "Accept": "application/json",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            return json.loads(response.read().decode() or "null")
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace").strip()[:300]
        raise RuntimeError(f"Paperless upload returned {err.code}: {detail}") from None


def find_named(kind, name):
    """The id of an existing Paperless object with this name, or None.

    Paperless pages its list endpoints at 25 and its name filter matches loosely, so the
    exact match can sit on a later page. Without walking them an existing correspondent is
    invisible and the create below is rejected as a duplicate - which is what failed the
    hourly job and fired KubeJobFailed.
    """
    for page in range(1, 11):
        found = paperless("/%s/?name=%s&page_size=200&page=%d" % (kind, urllib.parse.quote(name), page))
        for item in found.get("results", []):
            if (item.get("name") or "").strip().lower() == name.lower():
                return item["id"]
        if not found.get("next"):
            break
    return None


def ensure_named(kind, name):
    """The id of the Paperless object of this kind, created if this is the first."""
    name = name.strip()[:128]
    known = find_named(kind, name)
    if known:
        return known
    try:
        return paperless("/%s/" % kind, "POST", {"name": name})["id"]
    except urllib.error.HTTPError:
        # Lost a race, or a name differing only by a character we cannot see. Look it up
        # once more rather than failing the document over it.
        known = find_named(kind, name)
        if known:
            return known
        raise


def ensure_custom_field(name, data_type):
    """The id of a custom field, created with the right type if this is the first."""
    found = paperless("/custom_fields/?name=%s" % urllib.parse.quote(name))
    for item in found.get("results", []):
        if (item.get("name") or "").strip().lower() == name.lower():
            return item["id"]
    return paperless("/custom_fields/", "POST", {"name": name, "data_type": data_type})["id"]


def reading_block(answer):
    """The model's reading as text, so it is searchable inside Paperless."""
    title = (answer.get("title") or "").strip()
    bits = []
    for label, key in (
        ("Merchant", "merchant"),
        ("Transaction date", "date"),
        ("Total", "total"),
        ("Payment method", "payment_method"),
        ("Reference", "reference"),
    ):
        value = answer.get(key)
        if value not in (None, "", 0):
            bits.append(f"{label}: {value}")
    if not title and not bits:
        return ""
    return "--- read by the vision model ---\n" + "\n".join([b for b in [title] + bits if b])


def vision_fields(asset_id):
    """The model's reading of one document image, or None if it did not answer."""
    try:
        image = api(f"/assets/{asset_id}/thumbnail?size=preview", raw=True)
    except SystemExit as err:
        return None, f"thumbnail failed ({err})"
    body = {
        "model": VISION_MODEL,
        "max_tokens": 400,
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": ENRICH_PROMPT},
                    {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(image).decode()}},
                ],
            }
        ],
    }
    req = urllib.request.Request(
        AIGW_URL.rstrip("/") + "/chat/completions",
        method="POST",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {VISION_KEY}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            payload = json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as err:
        return None, f"agentgateway {err.code}"
    except Exception as err:  # noqa: BLE001 - any transport failure means no answer
        return None, f"agentgateway unreachable ({err})"
    text = ((payload.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
    text = text.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
    try:
        answer = json.loads(text)
    except ValueError:
        return None, "unparsable answer"
    if not isinstance(answer, dict):
        return None, "answer was not an object"
    # A parsed but empty answer is still an answer: the caller labels it useless.
    return answer, ""


def enrich_document(tags, doc, asset, answer):
    """Write the model's reading onto one Paperless document. Returns fields written."""
    patch = {}
    title = (answer.get("title") or "").strip()[:128]
    if title and title != (doc.get("title") or ""):
        patch["title"] = title
    merchant = (answer.get("merchant") or "").strip()
    if merchant:
        patch["correspondent"] = ensure_named("correspondents", merchant)
    when = (answer.get("date") or "").strip()
    dated = len(when) == 10 and when[4] == "-" and when[7] == "-"
    if dated:
        # created is the document's own date, which for a receipt is the transaction
        # date. The custom field keeps the transaction date visible in its own right,
        # because the two are not always the same thing.
        patch["created"] = when
    # Paperless replaces the whole custom-field list on PATCH, so merge with what is
    # there. Monetary fields carry the currency as a three-character prefix.
    values = {entry["field"]: entry["value"] for entry in doc.get("custom_fields") or []}
    fields = {f["name"]: f["id"] for f in paperless("/custom_fields/?page_size=100").get("results", [])}
    total = answer.get("total")
    code = (answer.get("currency") or "").strip().upper()
    code = code if len(code) == 3 and code.isalpha() else ""
    if isinstance(total, (int, float)) and total > 0 and "Total" in fields:
        values[fields["Total"]] = f"{code}{float(total):.2f}"
    # "<BRAND> <last4>". The masked form carries the same information with noise in it,
    # and the two writers here disagreed on the shape, which is the inconsistency.
    card = answer.get("payment_method")
    if isinstance(card, str) and card.strip() and "Payment method" in fields:
        values[fields["Payment method"]] = " ".join(card.replace("*", " ").replace("#", " ").split())[:128]
    reference = answer.get("reference")
    if isinstance(reference, str) and reference.strip() and "Reference" in fields:
        values[fields["Reference"]] = reference.strip()[:128]
    if dated:
        values[ensure_custom_field("Transaction date", "date")] = when
    if values:
        patch["custom_fields"] = [{"field": k, "value": v} for k, v in values.items()]
    # Content is the only text Paperless can search, and a document whose OCR came back
    # empty has none at all. Appended, never replaced: the OCR text is the raw evidence.
    marker = "--- read by the vision model"
    block = reading_block(answer)
    existing = doc.get("content") or ""
    if block and marker not in existing:
        patch["content"] = (existing.rstrip() + "\n\n" + block).strip()
    # A coupon is a document the model can read perfectly and that nobody will ever
    # file. useful=false covers that as well as a reading too thin to act on.
    usable = answer.get("useful") is not False and any([
        title,
        merchant,
        dated,
        isinstance(total, (int, float)) and total > 0,
        (answer.get("payment_method") or "").strip(),
        (answer.get("reference") or "").strip(),
    ])
    tag_ids = {t["name"]: t["id"] for t in paperless("/tags/?page_size=200").get("results", [])}
    # Paperless replaces the whole tag list too, so merge rather than assign: what the
    # document already carries stays. Immich hands back tag dicts, not names.
    ids = list(doc.get("tags") or [])
    for entry in asset.get("tags") or []:
        name = entry.get("name") if isinstance(entry, dict) else entry
        if name in VOCAB and name in tag_ids:
            ids.append(tag_ids[name])
    ids.append(ensure_named("tags", VISION_TAG))
    if not usable:
        ids.append(ensure_named("tags", USELESS_TAG))
    patch["tags"] = sorted(set(ids))
    paperless("/documents/%s/" % doc["id"], "PATCH", patch)
    return len([k for k in patch if k != "tags"])


def enrich_all(tags):
    """Fill in the Paperless side for documents we have already sent.

    The join is the filename: send() named the file from the asset, so the document
    can be found again. Idempotent via VISION_TAG on the document.
    """
    if not PAPERLESS_KEY:
        print("enrich: no PAPERLESS_API_TOKEN, skipping", flush=True)
        return 0
    sent = tags.get(SENT_TAG) if DRY_RUN else ensure_tag(tags, SENT_TAG)
    if sent is None:
        print(f"enrich: {SENT_TAG} tag not yet present", flush=True)
        return 0
    wanted = {t["name"]: t["id"] for t in paperless("/tags/?page_size=200").get("results", [])}
    done_id = wanted.get(VISION_TAG)
    docs = paperless("/documents/?page_size=200&ordering=id").get("results", [])
    # One pass over the sent assets: the filename is what joins the two systems, so it
    # is computed once rather than per document.
    by_stem = {}
    for candidate in assets_with_tag(sent):
        full = api(f"/assets/{candidate['id']}")
        by_stem[pathlib.Path(safe_name(full)).stem] = full
        # Two keys: the name send() would choose now, and the camera stem that files sent
        # before the filename carried the description were named after.
        legacy = pathlib.Path(full.get("originalFileName") or "").stem
        if legacy:
            by_stem[legacy] = full
    enriched = calls = 0
    for doc in docs:
        # Paperless returns tag ids here, not objects.
        if done_id and done_id in (doc.get("tags") or []):
            continue
        fname = doc.get("original_file_name") or ""
        asset = next((full for stem, full in by_stem.items() if stem in fname), None)
        if asset is None:
            continue
        if calls >= MAX_VISION_CALLS:
            print(f"enrich: {doc['id']} left for the next run, vision budget spent", flush=True)
            break
        calls += 1
        answer, why = vision_fields(asset["id"])
        if answer is None:
            # No answer: leave the document untouched so a later run asks again.
            print(f"enrich: {doc['id']} untouched, no answer ({why})", flush=True)
            continue
        if DRY_RUN:
            enriched += 1
            print(f"enrich: {doc['id']} would be enriched; no Paperless changes in dry-run", flush=True)
            continue
        try:
            written = enrich_document(tags, doc, asset, answer)
        except (SystemExit, urllib.error.HTTPError) as err:
            # One document Paperless refuses must not end the run. A duplicate
            # correspondent name did exactly that every hour and fired KubeJobFailed.
            print(f"enrich: {doc['id']} write refused, left alone ({err})", flush=True)
            continue
        enriched += 1
        print(f"enrich: {doc['id']} {written} field(s)", flush=True)
    print(f"enrich: {enriched} document(s) enriched, {calls} vision call(s)", flush=True)
    return enriched


def assets_with_tag(tag_id, limit=200):
    """Immich assets carrying a tag."""
    found = api("/search/metadata", "POST", {"tagIds": [tag_id], "type": "IMAGE", "size": limit})
    return ((found.get("assets") or {}).get("items")) or []


def send(tags):
    """Copy every asset tagged document into Paperless, once.

    Driven by the tag rather than the album. The album is a display grouping, and the
    list API reports no assets for an album the key's user does not own, so it reads
    back empty even when the assets are in it. The tag is the gate.
    """
    document = tags.get(DOC_TAG)
    if not document:
        print(f"send: nothing tagged {DOC_TAG} yet", flush=True)
        return 0
    assets = []
    for page in range(1, MAX_PAGES + 1):
        found = api(
            "/search/metadata",
            "POST",
            {"tagIds": [document], "type": "IMAGE", "size": 200, "page": page},
        )
        items = ((found.get("assets") or {}).get("items")) or []
        assets.extend(items)
        if len(items) < 200:
            break
    sent_tag = tags.get(SENT_TAG) if DRY_RUN else ensure_tag(tags, SENT_TAG)
    if sent_tag is None:
        print(f"send: {SENT_TAG} tag not yet present", flush=True)
        return 0
    sent = 0
    for asset in assets:
        if already_tagged(asset["id"], (SENT_TAG,)):
            continue
        # Videos are not documents. Without this guard, a video in the album
        # would be sent as a single fullsize JPEG frame and archived as a
        # document.
        if asset.get("type") == "VIDEO" or (asset.get("originalMimeType") or "").startswith("video/"):
            print(f"send: skip {asset['id']}: video", flush=True)
            continue
        ext = pathlib.Path(asset.get("originalFileName") or "").suffix.lower()
        if ext in SAFE_EXT:
            path, suffix = f"/assets/{asset['id']}/original", ext
        else:
            path, suffix = f"/assets/{asset['id']}/thumbnail?size=fullsize", ".jpg"
        # The metadata search result carries no exifInfo, so read the asset: that is
        # where the description lives, and the filename is built from it.
        described = api(f"/assets/{asset['id']}")
        filename = safe_name(described)
        if pathlib.Path(filename).suffix.lower() != suffix:
            filename = str(pathlib.Path(filename).with_suffix(suffix))
        if DRY_RUN:
            print(f"send: {asset['id']} would upload {filename}; no Paperless/Immich changes in dry-run", flush=True)
            sent += 1
            continue
        paperless_upload(filename, api(path, raw=True))
        api(f"/tags/{sent_tag}/assets", "PUT", {"ids": [asset["id"]]})
        print(f"send: {asset['id']} -> {filename}", flush=True)
        sent += 1

    print(f"send: {sent} sent, {len(assets)} tagged {DOC_TAG}", flush=True)
    return sent


def main(stage: str = "all", window_hours: float = 24, max_pages: int = 5, max_vision_calls: int = 20, dry_run: bool = False) -> dict:
    global AIGW_URL, DRY_RUN, IMMICH, KEY, MAX_PAGES, MAX_VISION_CALLS, PAPERLESS_KEY, PAPERLESS_URL, VISION_KEY, WINDOW_HOURS
    if os.environ.get("WM_JOB_ID"):
        import wmill

        immich = wmill.get_resource("f/paperless/immich_api")
        paperless = wmill.get_resource("f/paperless/paperless_api")
        ai = wmill.get_resource("f/ai/agentgateway")
        IMMICH = immich["base_url"].rstrip("/")
        KEY = immich["api_key"]
        PAPERLESS_URL = paperless["base_url"].rstrip("/")
        PAPERLESS_KEY = paperless["api_token"]
        AIGW_URL = ai["base_url"].rstrip("/")
        VISION_KEY = ai["api_key"]
    if not KEY:
        sys.exit("Immich API key resource is empty")
    if not PAPERLESS_KEY:
        sys.exit("Paperless API token resource is empty")

    WINDOW_HOURS = window_hours
    MAX_PAGES = max_pages
    MAX_VISION_CALLS = max_vision_calls
    DRY_RUN = dry_run
    tags = tags_by_name()
    if stage == "classify":
        result = {"documents": classify(tags, window_hours=window_hours), "dry_run": dry_run}
    elif stage == "send":
        result = {"sent": send(tags), "dry_run": dry_run}
    elif stage == "enrich":
        result = {"enriched": enrich_all(tags), "dry_run": dry_run}
    elif stage == "all":
        result = {
            "documents": classify(tags, window_hours=window_hours),
            "sent": send(tags),
            "enriched": enrich_all(tags),
            "dry_run": dry_run,
        }
    else:
        raise ValueError(f"unknown stage {stage!r}; expected classify, send, enrich, or all")
    print(f"{stage}: {result}", flush=True)
    return result


if __name__ == "__main__":
    main()
