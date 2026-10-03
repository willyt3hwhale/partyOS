#!/usr/bin/env bash
# add-blob.sh - the OPERATOR-facing side of the contributor blob flow.
#
# A trusted contributor produced a deliverable with make-blob.sh: a blob + sha256 +
# torrent + a catalog-fragment.json. The operator uses THIS to VOUCH that fragment
# into their catalog. The operator's catalog sha256 is the integrity trust root, so
# vouching = accepting the contributor's sha256 into the CA-authenticated catalog.
# WHOEVER serves the bytes is then irrelevant: a client verifies the downloaded blob
# against the catalog sha256 and fails closed on a mismatch (get_blob in
# partyos-app). So the operator can either host the bytes themselves
# OR point the row at the contributor's self-host web-seed - same sha gate either way.
#
# What it does:
#   1. Validate the fragment: rectangular row + NON-EMPTY sha256 (HARD-FAIL on empty,
#      honoring the fail-closed model - an empty sha would let an unverified blob mount).
#   2. Upsert the row into catalog.v2.json by name (idempotent; preserves operator-tuned
#      fields on an existing row, like build-app-blob.sh does).
#   3. EITHER --host <blob> (copy the blob into server/games/ + re-run gen-blob-torrents.sh
#      so the operator's web-seeds bake into the torrent) OR --webseed <url> (point the
#      torrent at the contributor's self-host, advertised HTTP).
#   4. Re-run build-game-blobs.sh to render catalog.json (the file clients fetch).
#
# Usage:
#   add-blob.sh <fragment.json> [--host <blob.squashfs> | --webseed <http-base-url>]
#               [--catalog <catalog.v2.json>]   (default: repo server/games/catalog.v2.json)
#
# --host and --webseed are mutually exclusive. With neither, the row is upserted and
# the catalog rendered, but no bytes are placed and no torrent web-seed is changed
# (useful to register a row whose bytes the operator will host out-of-band).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/scripts/build"

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

FRAGMENT=""; HOST_BLOB=""; WEBSEED=""; CATALOG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --host) HOST_BLOB="${2:?--host needs a blob path}"; shift 2;;
        --host=*) HOST_BLOB="${1#*=}"; shift;;
        --webseed) WEBSEED="${2:?--webseed needs a url}"; shift 2;;
        --webseed=*) WEBSEED="${1#*=}"; shift;;
        --catalog) CATALOG="${2:?--catalog needs a path}"; shift 2;;
        --catalog=*) CATALOG="${1#*=}"; shift;;
        -h|--help) usage 0;;
        --*) echo "[add-blob] ERROR unknown option: $1" >&2; usage 1;;
        *) if [ -z "${FRAGMENT}" ]; then FRAGMENT="$1"; else echo "[add-blob] ERROR extra arg: $1" >&2; usage 1; fi; shift;;
    esac
done

[ -n "${FRAGMENT}" ] || { echo "[add-blob] ERROR missing <fragment.json>" >&2; usage 1; }
[ -f "${FRAGMENT}" ] || { echo "[add-blob] ERROR fragment not found: ${FRAGMENT}" >&2; exit 1; }
if [ -n "${HOST_BLOB}" ] && [ -n "${WEBSEED}" ]; then
    echo "[add-blob] ERROR --host and --webseed are mutually exclusive" >&2; exit 1
fi
command -v python3 >/dev/null || { echo "[add-blob] ERROR python3 required" >&2; exit 1; }

CATALOG="${CATALOG:-${REPO_ROOT}/server/games/catalog.v2.json}"
[ -f "${CATALOG}" ] || { echo "[add-blob] ERROR catalog not found: ${CATALOG}" >&2; exit 1; }
GAMES_DIR="$(dirname "${CATALOG}")"

# --- 1. validate the fragment: rectangular + NON-EMPTY sha256 ----------------
# Reuse build-game-blobs.sh's invariants: required keys (id,name,title,source) and the
# rectangular field set. add the fail-closed empty-sha gate on top (the whole point).
NAME="$(python3 - "${FRAGMENT}" <<'PY'
import json, sys
f = json.load(open(sys.argv[1]))
row = f.get("row") if isinstance(f, dict) and "row" in f else f
if not isinstance(row, dict):
    sys.stderr.write("[add-blob] ERROR fragment has no usable row object\n"); sys.exit(2)

# required keys (same as build-game-blobs.sh:50)
req = ("id", "name", "title", "source")
missing = [k for k in req if k not in row]
if missing:
    sys.stderr.write("[add-blob] ERROR fragment row missing required keys: %s\n" % ", ".join(missing)); sys.exit(2)

if row.get("source") != "blob":
    sys.stderr.write("[add-blob] ERROR fragment source must be 'blob' (got %r)\n" % row.get("source")); sys.exit(2)

# FAIL CLOSED on empty/missing sha256 - mirrors get_blob's refusal to mount an
# unverified blob. An empty sha in the catalog is an operator authoring error that
# would let an unverified blob mount, defeating the integrity model.
sha = (row.get("sha256") or "").strip()
if not sha:
    sys.stderr.write("[add-blob] ERROR fragment has EMPTY sha256 - refusing (fail-closed; the catalog sha is the trust root)\n"); sys.exit(3)
if len(sha) != 64 or any(c not in "0123456789abcdefABCDEF" for c in sha):
    sys.stderr.write("[add-blob] ERROR sha256 is not a 64-hex digest: %r\n" % sha); sys.exit(3)

# size must be a positive int (a blob is never empty)
try:
    if int(row.get("size", 0)) <= 0:
        sys.stderr.write("[add-blob] ERROR fragment size must be > 0\n"); sys.exit(3)
except (TypeError, ValueError):
    sys.stderr.write("[add-blob] ERROR fragment size is not an integer\n"); sys.exit(3)

print(row["name"])
PY
)" || { echo "[add-blob] fragment validation FAILED" >&2; exit 1; }

echo "[add-blob] fragment valid: name=${NAME}" >&2

# --- 2. upsert the row into catalog.v2.json (idempotent, preserves operator fields) --
FRAGMENT="${FRAGMENT}" NAME="${NAME}" python3 - "${CATALOG}" <<'PY'
import json, os, sys
cat_path = sys.argv[1]
f = json.load(open(os.environ["FRAGMENT"]))
new = f.get("row") if isinstance(f, dict) and "row" in f else f
name = os.environ["NAME"]

d = json.load(open(cat_path))
games = d.setdefault("games", [])
existing = next((r for r in games if r.get("name") == name), None)
if existing is None:
    games.append(dict(new))
    print("[add-blob] inserted new row %s" % name, file=sys.stderr)
else:
    # Preserve operator-tuned fields (config_*, server_pkg, needs_server, version,
    # marker, icon, ...) on a re-add - only the build-DERIVED facts (sha256/size and
    # the contributor's blob/entry/ram/proton/shm_mb) come from the fragment. Same
    # idempotent-preserve discipline as build-app-blob.sh. This makes a re-add of
    # the SAME fragment a no-op on operator-tuned fields, and a re-add with a NEW
    # sha/size update exactly those.
    DERIVED = ("sha256", "size", "blob", "entry", "ram_min", "ram_max",
               "proton", "shm_mb", "exec", "marker", "source")
    for k in DERIVED:
        if k in new:
            existing[k] = new[k]
    # backfill any field the existing row lacks (without clobbering operator values)
    for k, v in new.items():
        existing.setdefault(k, v)
    print("[add-blob] updated existing row %s (sha %s, operator fields preserved)" % (name, str(new.get("sha256",""))[:12]), file=sys.stderr)

# Atomic write: a mid-party vouch rewrites the catalog while clients fetch it.
tmp = cat_path + ".add.tmp"
with open(tmp, "w") as handle:
    json.dump(d, handle, indent=2)
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, cat_path)
PY

# --- 3. host the bytes (--host) OR point at a contributor web-seed (--webseed) -------
if [ -n "${HOST_BLOB}" ]; then
    [ -f "${HOST_BLOB}" ] || { echo "[add-blob] ERROR --host blob not found: ${HOST_BLOB}" >&2; exit 1; }
    # verify the supplied blob matches the fragment sha BEFORE hosting it - the operator
    # is about to vouch this sha, so the bytes they host must actually hash to it.
    FRAG_SHA="$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); r=f.get("row",f); print((r.get("sha256") or "").strip())' "${FRAGMENT}")"
    GOT_SHA="$(sha256sum "${HOST_BLOB}" 2>/dev/null | awk '{print $1}')"
    if [ "${GOT_SHA}" != "${FRAG_SHA}" ]; then
        echo "[add-blob] ERROR --host blob sha (${GOT_SHA:0:12}) != fragment sha (${FRAG_SHA:0:12}) - refusing to host mismatched bytes" >&2
        exit 1
    fi
    DEST="${GAMES_DIR}/${NAME}.squashfs"
    # copy unless the bytes are already in place at DEST (operator re-hosting an
    # already-hosted blob); cp errors on an identical source==dest under set -e.
    if [ "$(cd "$(dirname "${HOST_BLOB}")" && pwd)/$(basename "${HOST_BLOB}")" != "$(cd "${GAMES_DIR}" && pwd)/${NAME}.squashfs" ]; then
        cp -f "${HOST_BLOB}" "${DEST}"
    fi
    printf '%s\n' "${FRAG_SHA}" > "${DEST}.sha256"
    echo "[add-blob] hosted blob -> ${DEST} (sha verified)" >&2
    # re-bake the torrent so the OPERATOR'S web-seeds are embedded. gen-blob-torrents.sh
    # globs *.squashfs in the dir; WEBSEED is the operator's deploy-time choice (left to
    # the deploy/render path normally - here we just (re)generate a base torrent).
    if command -v docker >/dev/null 2>&1 || command -v mktorrent >/dev/null 2>&1; then
        bash "${BUILD_DIR}/gen-blob-torrents.sh" "${GAMES_DIR}" || \
            echo "[add-blob] WARN torrent (re)generation failed (non-fatal; deploy render re-bakes web-seeds)" >&2
    else
        echo "[add-blob] NOTE no mktorrent/docker - skipping torrent regen (deploy render will bake it)" >&2
    fi
elif [ -n "${WEBSEED}" ]; then
    # Self-host model: the contributor serves the bytes; the operator only vouches the
    # sha. Advertise the web-seed over HTTP: the client's blob fetch verifies the
    # sha256 regardless of transport, and an HTTPS contributor host would fail the
    # pinned-CA aria2 check. Bake the web-seed into THIS blob's torrent if the bytes are
    # locally present to hash; otherwise record the web-seed on the row for the deploy
    # render path. We always record it on the row so the operator can re-derive it.
    case "${WEBSEED}" in
        https://*) echo "[add-blob] WARN web-seed is HTTPS - clients pin a private CA; a contributor HTTPS host will fail the aria2 cert check. Advertise HTTP." >&2;;
    esac
    WS="${WEBSEED%/}"
    NAME="${NAME}" WS="${WS}" python3 - "${CATALOG}" <<'PY'
import json, os, sys
cat_path = sys.argv[1]; name = os.environ["NAME"]; ws = os.environ["WS"]
d = json.load(open(cat_path))
row = next((r for r in d.get("games", []) if r.get("name") == name), None)
if row is not None:
    row["webseed"] = "%s/%s.squashfs" % (ws, name)
    # Atomic write: a mid-party vouch rewrites the catalog while clients fetch it.
    tmp = cat_path + ".add.tmp"
    with open(tmp, "w") as handle:
        json.dump(d, handle, indent=2)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, cat_path)
    print("[add-blob] recorded contributor web-seed on row %s: %s" % (name, row["webseed"]), file=sys.stderr)
PY
    # if the blob bytes happen to be co-located (the operator received them too), bake
    # the web-seed into the torrent now; else the deploy render path handles it.
    if [ -f "${GAMES_DIR}/${NAME}.squashfs" ]; then
        WEBSEED="${WS}" bash "${BUILD_DIR}/gen-blob-torrents.sh" "${GAMES_DIR}" || \
            echo "[add-blob] WARN torrent regen with web-seed failed (non-fatal)" >&2
    else
        echo "[add-blob] NOTE blob bytes not local - torrent web-seed will bake at deploy render time" >&2
    fi
else
    echo "[add-blob] NOTE no --host / --webseed - row registered only (operator hosts bytes out-of-band)" >&2
fi

# --- 4. render catalog.json (the file clients fetch) -------------------------
bash "${BUILD_DIR}/build-game-blobs.sh" "${GAMES_DIR}"

echo "[add-blob] DONE ${NAME} vouched into ${CATALOG}" >&2
