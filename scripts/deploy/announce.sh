#!/usr/bin/env bash
# announce.sh - operator broadcast tool. Push a notice onto the served notices feed
# so every booted partyOS client picks it up on its next poll.
#
# The feed is a plain JSON file at server/notices.json (relative to the repo root).
# http_server.py serves the whole repo, so the file is reachable over HTTPS at
# https://<PXE>:8443/server/notices.json - the client poller fetches it from there.
# This tool only EDITS the served file; it works whether or not the server process is
# running (no restart needed, the next client poll sees the change).
#
# Feed format: a JSON ARRAY of notice objects, each:
#   {"id":int, "ts":int, "title":str, "message":str, "level":"info"|"alert", "expires":int}
#   - id      : monotonic, auto-incremented (max existing + 1; first notice is 1).
#               Kept as a human/debug reference only - the client poller keys off ts.
#   - ts      : STRICTLY-MONOTONIC unix seconds: ts = max(now, max-existing-ts + 1).
#               This guarantees a fresh push always orders AFTER everything currently
#               in the feed, even right after a --clear (where id restarts at 1). The
#               client poller tracks a high-watermark ts, so monotonic ts is what makes
#               a post-clear broadcast still deliver.
#   - expires : unix seconds the notice stops being shown (0 = never). Absolute, and
#               based on the effective ts: expires = ts + SECONDS (0 when no --expires).
#
# Usage:
#   announce.sh "message" [--title T] [--level info|alert] [--expires SECONDS]
#       append a notice. --expires SECONDS sets expires = now + SECONDS (0/absent =
#       never). Default level = info. Default title = the party name (PARTY_NAME from
#       deploy.conf) or "partyOS" if unset.
#   announce.sh --list      print the current notices, one per line, readably.
#   announce.sh --clear     reset the feed to [] (atomic).
#   announce.sh --help      this usage.
#
# Override env (test hook, mirrors render.sh's *_OUT overrides): NOTICES_FILE points
# the tool at an alternate feed path so a test run NEVER touches the live
# server/notices.json. Unset -> the live repo path (a normal operator run is unchanged).
#   NOTICES_FILE   feed path   (default: <repo>/server/notices.json)
#
# Robustness: every write goes to a temp file in the feed's own dir then mv into place
# (atomic - never a half-written feed). The feed is bounded to the 50 most recent
# notices (oldest dropped after append). All JSON parsing/writing is python3; the
# message/title/level and the raw now-unix/expires-seconds are passed via argv (NOT
# interpolated into the python source) so quotes/spaces/unicode are injection-safe.
# The effective monotonic ts (and the absolute expires derived from it) is computed
# INSIDE python, after the feed is loaded, so it can read the max existing ts.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
CONF="${REPO_ROOT}/deploy.conf"
# Feed path: the live server/notices.json by default. NOTICES_FILE overrides it (a test
# run points it at a tempfile so the live feed is never touched). The default keeps the
# normal operator run on the served file - unchanged.
NOTICES_FILE="${NOTICES_FILE:-${REPO_ROOT}/server/notices.json}"
MAX_NOTICES=50

usage() {
    cat >&2 <<'USAGE'
announce.sh - push an operator notice onto the served partyOS feed.

  announce.sh "message" [--title T] [--level info|alert] [--expires SECONDS]
      append a notice (clients see it on their next poll).
  announce.sh --list      print the current notices readably.
  announce.sh --clear     reset the feed to [] (empty).
  announce.sh --help      this help.

  --title T          notice title (default: party name from deploy.conf, else partyOS)
  --level info|alert message severity (default: info)
  --expires SECONDS  notice stops showing SECONDS from now (default/0: never)

  env NOTICES_FILE   override the feed path (default: server/notices.json) - test hook.
USAGE
}

# party_name - PARTY_NAME from deploy.conf (plain grep parse, same style as render.sh's
# get(); never sourced), quotes tolerated. Falls back to partyOS when unset/empty.
party_name() {
    local v=""
    if [ -f "${CONF}" ]; then
        v="$(grep -E '^PARTY_NAME=' "${CONF}" | tail -1 | cut -d= -f2-)"
        # strip surrounding single/double quotes and leading/trailing whitespace.
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
    fi
    [ -n "${v}" ] && printf '%s' "${v}" || printf '%s' "partyOS"
}

# --- subcommands --------------------------------------------------------------

do_list() {
    # Parse + print with python3 (never hand-roll JSON in bash). Empty/absent/corrupt
    # feed -> a clean "no notices" line, exit 0.
    NOTICES_FILE="${NOTICES_FILE}" python3 - <<'PY'
import json, os, time
path = os.environ["NOTICES_FILE"]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, list):
        data = []
except (FileNotFoundError, ValueError):
    data = []
if not data:
    print("announce: no notices in the feed")
else:
    now = int(time.time())
    for n in data:
        ts = int(n.get("ts", 0))
        when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts)) if ts else "?"
        exp = int(n.get("expires", 0))
        if exp == 0:
            estat = "never expires"
        elif exp <= now:
            estat = "EXPIRED"
        else:
            estat = "expires in %ds" % (exp - now)
        print("#%-4s %s  [%-5s] %s: %s  (%s)" % (
            n.get("id", "?"), when, n.get("level", "info"),
            n.get("title", ""), n.get("message", ""), estat))
PY
}

do_clear() {
    mkdir -p "$(dirname "${NOTICES_FILE}")"
    local tmp
    tmp="$(mktemp "$(dirname "${NOTICES_FILE}")/.notices.XXXXXX")"
    printf '[]\n' > "${tmp}"
    mv "${tmp}" "${NOTICES_FILE}"
    echo "announce: feed cleared (${NOTICES_FILE})"
}

do_append() {
    local message="$1" title="$2" level="$3" expires_secs="$4"
    local now
    now="$(date +%s)"
    mkdir -p "$(dirname "${NOTICES_FILE}")"
    # All mutation in python3: load the array (or [] on missing/corrupt), compute max id
    # AND max ts BEFORE trimming, derive a STRICTLY-MONOTONIC effective ts
    # (eff_ts = max(now, max-existing-ts + 1)) so a fresh push always orders after the
    # whole feed - even right after a --clear restarts ids at 1 - then append, trim to
    # the newest MAX_NOTICES, and write atomically (temp file in the same dir, then
    # os.replace). The raw now-unix + expires-seconds come in via argv - NOT interpolated
    # into the source - so quotes/spaces/unicode are safe.
    local newid
    newid="$(NOTICES_FILE="${NOTICES_FILE}" MAX_NOTICES="${MAX_NOTICES}" python3 - \
        "${title}" "${message}" "${level}" "${now}" "${expires_secs}" <<'PY'
import json, os, sys, tempfile
path = os.environ["NOTICES_FILE"]
cap  = int(os.environ["MAX_NOTICES"])
title, message, level = sys.argv[1], sys.argv[2], sys.argv[3]
now, expires_secs = int(sys.argv[4]), int(sys.argv[5])

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, list):
        data = []
except (FileNotFoundError, ValueError):
    data = []

# max id AND max ts from the file BEFORE trimming (ids never collide; ts stays
# strictly monotonic). eff_ts is the effective timestamp we actually stamp.
maxid = 0
maxts = 0
for n in data:
    try:
        maxid = max(maxid, int(n.get("id", 0)))
    except (TypeError, ValueError):
        pass
    try:
        maxts = max(maxts, int(n.get("ts", 0)))
    except (TypeError, ValueError):
        pass
newid = maxid + 1
# strictly greater than every ts already in the feed, and never below wall-clock now.
eff_ts = max(now, maxts + 1)
# expires stays ABSOLUTE unix and is based on the effective ts (0 = never).
expires = eff_ts + expires_secs if expires_secs > 0 else 0

data.append({
    "id": newid,
    "ts": eff_ts,
    "title": title,
    "message": message,
    "level": level,
    "expires": expires,
})

# bound the feed: keep only the newest `cap` notices (drop oldest).
if len(data) > cap:
    data = data[-cap:]

# atomic write: temp file in the same dir, fsync, os.replace.
d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".notices.", dir=d)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise

print(newid)
PY
)"
    echo "broadcast #${newid} to clients: ${message}"
}

# --- arg parse ----------------------------------------------------------------

# bare subcommands first.
case "${1:-}" in
    ""|--help|-h) usage; exit 0;;
    --list)  do_list;  exit 0;;
    --clear) do_clear; exit 0;;
esac

MESSAGE=""
TITLE=""
LEVEL="info"
EXPIRES_SECS=0
HAVE_MESSAGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --title)
            [ $# -ge 2 ] || { echo "announce: --title needs a value" >&2; exit 1; }
            TITLE="$2"; shift 2;;
        --level)
            [ $# -ge 2 ] || { echo "announce: --level needs a value" >&2; exit 1; }
            LEVEL="$2"; shift 2;;
        --expires)
            [ $# -ge 2 ] || { echo "announce: --expires needs a value" >&2; exit 1; }
            EXPIRES_SECS="$2"; shift 2;;
        --list|--clear|--help|-h)
            echo "announce: ${1} cannot be combined with a message" >&2; exit 1;;
        --*)
            echo "announce: unknown option: $1" >&2; usage; exit 1;;
        *)
            if [ "${HAVE_MESSAGE}" -eq 1 ]; then
                echo "announce: only one message allowed (got an extra arg: $1)" >&2; exit 1
            fi
            MESSAGE="$1"; HAVE_MESSAGE=1; shift;;
    esac
done

[ "${HAVE_MESSAGE}" -eq 1 ] && [ -n "${MESSAGE}" ] || { echo "announce: a message is required" >&2; usage; exit 1; }

# validate --level is EXACTLY info or alert.
case "${LEVEL}" in
    info|alert) ;;
    *) echo "announce: --level must be 'info' or 'alert' (got: ${LEVEL})" >&2; exit 1;;
esac

# validate --expires is a non-negative integer.
case "${EXPIRES_SECS}" in
    ''|*[!0-9]*) echo "announce: --expires must be a non-negative integer (got: ${EXPIRES_SECS})" >&2; exit 1;;
esac

# default title = party name.
[ -n "${TITLE}" ] || TITLE="$(party_name)"

do_append "${MESSAGE}" "${TITLE}" "${LEVEL}" "${EXPIRES_SECS}"
