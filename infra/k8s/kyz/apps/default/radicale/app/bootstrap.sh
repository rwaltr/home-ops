#!/bin/sh
# Seed the Radicale storage tree before the server starts.
#
# Three jobs:
#   1. build the htpasswd file from the per-account passwords in 1Password;
#   2. pre-create the four calendar collections, so the shares below resolve
#      before anyone's phone has ever connected;
#   3. seed the sharing database (csv) — this is what puts the shared "Family"
#      calendar and the read-only "Remind" feed inside each user's principal,
#      which is the only place CalDAV clients discover collections.
#
# Idempotent by design: an existing collection or an existing sharing.csv is
# left untouched, so state a phone or the WebUI wrote (a new event, a share
# toggled off) survives every pod restart and every Recreate.
#
# Verified against radicale 3.8.1: the .Radicale.props JSON and the csv column
# order / True-False spelling are Radicale's, not ours — re-verify both before
# bumping the image tag.
#
# The rows are seeded rather than created with `POST /.sharing/v1/map/create`
# because that API always writes EnabledByUser=False, HiddenByUser=True for a
# share handed to *another* user (the recipient has to accept it in the WebUI
# first — see the `EnabledByUser: bool = False` default in sharing/__init__.py).
# Every row below is seeded already accepted and visible (True;True;False;False)
# so a client that has never talked to this server still discovers the shares.
set -eu

ROOT=/var/lib/radicale/collections
DB="$ROOT/collection-db/sharing.csv"

seed_users() {
  # /etc/radicale-passwords is the ExternalSecret projected as files, one per
  # account (`rwaltr`, `sam`, `home-assistant`, `remind-export`); the name of the
  # file *is* the htpasswd user. Regenerated every start because it lands in an
  # emptyDir shared with the app container, which mounts it read-only.
  #
  # bcrypt cost 10: Radicale re-hashes on every request (htpasswd_cache defaults
  # to False), so this is per-request latency, not just init time.
  PASS_DIR=/etc/radicale-passwords
  USERS_FILE=/etc/radicale-users/users
  [ -d "$PASS_DIR" ] || { echo "radicale-bootstrap: no $PASS_DIR (ExternalSecret did not project)" >&2; exit 1; }
  /app/bin/python - "$PASS_DIR" "$USERS_FILE" <<'PY'
import bcrypt, os, sys
src, dst = sys.argv[1], sys.argv[2]
expected = {"rwaltr", "sam", "home-assistant", "remind-export"}
names = sorted(n for n in os.listdir(src) if os.path.isfile(os.path.join(src, n)))
if set(names) != expected:
    raise SystemExit("radicale-bootstrap: unexpected accounts %r (want %r)" % (names, sorted(expected)))
lines = []
for name in names:
    with open(os.path.join(src, name), "rb") as fh:
        password = fh.read().rstrip(b"\n")
    if not password:
        raise SystemExit("radicale-bootstrap: empty password for %r" % name)
    lines.append("%s:%s" % (name, bcrypt.hashpw(password, bcrypt.gensalt(rounds=10)).decode()))
with open(dst, "w") as fh:
    fh.write("\n".join(lines) + "\n")
print("radicale-bootstrap: generated %d htpasswd entries: %s" % (len(lines), ", ".join(names)))
PY
}

seed_users

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
    'map;/sam/rwaltr/;/rwaltr/calendar/;none;rwaltr;sam;r;True;True;False;False;1790688234;1790688234;;' \
    'map;/rwaltr/sam/;/sam/calendar/;none;sam;rwaltr;r;True;True;False;False;1790688234;1790688234;;' \
    'map;/home-assistant/rwaltr/;/rwaltr/calendar/;none;rwaltr;home-assistant;r;True;True;False;False;1790688234;1790688234;;' \
    'map;/home-assistant/sam/;/sam/calendar/;none;sam;home-assistant;r;True;True;False;False;1790688234;1790688234;;' \
    'map;/rwaltr/remind/;/remind-export/remind/;none;remind-export;rwaltr;r;True;True;False;False;1790688234;1790688234;;' \
    'map;/sam/remind/;/remind-export/remind/;none;remind-export;sam;r;True;True;False;False;1790688234;1790688234;;' \
    'map;/home-assistant/remind/;/remind-export/remind/;none;remind-export;home-assistant;r;True;True;False;False;1790688234;1790688234;;' \
    > "$DB"
  echo "radicale-bootstrap: seeded sharing database (Family, personal cross-shares, Remind feed)"
else
  echo "radicale-bootstrap: sharing database present, left as-is"
fi

# Radicale creates the per-user principal collection on first authenticated
# request; nothing to do for those.
exit 0
