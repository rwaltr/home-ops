#!/bin/sh
# Seed the Radicale storage tree before the server starts.
#
# Two jobs:
#   1. pre-create the four calendar collections, so the shares below resolve
#      before anyone's phone has ever connected;
#   2. seed the sharing database (csv) — this is what puts the shared "Family"
#      calendar and the read-only "Remind" feed inside each user's principal,
#      which is the only place CalDAV clients discover collections.
#
# Idempotent by design: an existing collection or an existing sharing.csv is
# left untouched, so state a phone or the WebUI wrote (a new event, a share
# toggled off) survives every pod restart and every Recreate.
#
# Verified against radicale 3.8.1: the .Radicale.props JSON and the csv rows
# below are byte-for-byte what `MKCOL` and `POST /.sharing/v1/map/create`
# produce. The csv column order and the `True/False` spelling are Radicale's,
# not ours — re-verify both before bumping the image tag.
set -eu

ROOT=/var/lib/radicale/collections
DB="$ROOT/collection-db/sharing.csv"

seed_collection() {
  # seed_collection <path under collection-root> <display name> <colour>
  if [ ! -s "$ROOT/collection-root/$1/.Radicale.props" ]; then
    mkdir -p "$ROOT/collection-root/$1"
    printf '%s' \
      "{\"C:supported-calendar-component-set\": \"VEVENT,VTODO\", \"D:displayname\": \"$2\", \"ICAL:calendar-color\": \"$3\", \"tag\": \"VCALENDAR\"}" \
      > "$ROOT/collection-root/$1/.Radicale.props"
    echo "radicale-bootstrap: seeded $1 (\"$2\")"
  fi
}

seed_collection rwaltr/calendar      "Rwaltr"             "#4a90d9ff"
seed_collection sam/calendar         "Sam"                "#d94a90ff"
seed_collection rwaltr/family        "Family"             "#4ad98aff"
seed_collection remind-export/remind "Remind (read-only)" "#8a8a8aff"

if [ ! -e "$DB" ]; then
  mkdir -p "$ROOT/collection-db"
  # ShareType;PathOrToken;PathMapped;Conversion;Owner;User;Permissions;
  # EnabledByOwner;EnabledByUser;HiddenByOwner;HiddenByUser;Created;Updated;
  # Properties;Actions  (CRLF-terminated, as the API writes it)
  printf '%s\r\n' \
    'ShareType;PathOrToken;PathMapped;Conversion;Owner;User;Permissions;EnabledByOwner;EnabledByUser;HiddenByOwner;HiddenByUser;TimestampCreated;TimestampUpdated;Properties;Actions' \
    'map;/sam/family/;/rwaltr/family/;none;rwaltr;sam;rw;True;True;False;False;1790688234;1790688234;;' \
    'map;/home-assistant/family/;/rwaltr/family/;none;rwaltr;home-assistant;rw;True;True;False;False;1790688234;1790688234;;' \
    'map;/rwaltr/remind/;/remind-export/remind/;none;remind-export;rwaltr;r;True;True;False;False;1790688234;1790688234;;' \
    'map;/sam/remind/;/remind-export/remind/;none;remind-export;sam;r;True;True;False;False;1790688234;1790688234;;' \
    'map;/home-assistant/remind/;/remind-export/remind/;none;remind-export;home-assistant;r;True;True;False;False;1790688234;1790688234;;' \
    > "$DB"
  echo "radicale-bootstrap: seeded sharing database (3 collections + Remind feed)"
else
  echo "radicale-bootstrap: sharing database present, left as-is"
fi

# Radicale creates the per-user principal collection on first authenticated
# request; nothing to do for those.
exit 0
