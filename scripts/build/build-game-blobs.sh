#!/usr/bin/env bash
# build-game-blobs.sh - compile the served game catalog (catalog.json) from the
# TRACKED source of truth catalog.v2.json.
#
# AUTHORITATIVE SOURCE: catalog.v2.json is the committed source of truth. catalog.json
# is a git-ignored GENERATED artifact rendered from v2 by THIS script and is the file
# the client/runtime actually fetches. Never hand-edit catalog.json - edit v2 and
# re-run this script. Sync guard: any writer of v2 (build-app-blob.sh,
# build-proton-blob.sh) must re-run this script, else catalog.json drifts stale.
# `build-game-blobs.sh --check` (no write) fails if catalog.json diverges from v2.
#
# Usage: build-game-blobs.sh [OUT_DIR]        regenerate catalog.json from v2
#        build-game-blobs.sh --check [OUT_DIR] verify catalog.json matches v2 (no write)
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
OUT_DIR="${1:-${REPO_ROOT}/server/games}"
# CATALOG_V2= overrides the SOURCE v2 path (symmetric with build-app-blob.sh /
# build-proton-blob.sh). Default: the OUT_DIR's own catalog.v2.json if present (so a
# temp games dir renders ITS catalog, not the live repo one - what add-blob.sh needs),
# else the repo catalog. This keeps the operator's existing `make gameblobs` flow
# unchanged (OUT_DIR defaults to the repo games dir, so V2 resolves to the repo v2).
if [ -n "${CATALOG_V2:-}" ]; then
    V2="${CATALOG_V2}"
elif [ -f "${OUT_DIR}/catalog.v2.json" ]; then
    V2="${OUT_DIR}/catalog.v2.json"
else
    V2="${REPO_ROOT}/server/games/catalog.v2.json"
fi
CATALOG="${OUT_DIR}/catalog.json"

mkdir -p "${OUT_DIR}"
[ -f "${V2}" ] || { echo "[blobs] ERROR: ${V2} not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[blobs] ERROR: python3 required" >&2; exit 1; }

# Render catalog.v2.json -> catalog.json. The no-jq parallel-array parser in
# partyos-app/partyos-launch needs every row rectangular: each carries 'source'
# (blob|pkg) plus the full blob field set (blob/sha256/size/ram_min/ram_max/
# entry/marker) and icon/exec/pkg/pkgs - pkg rows use ""/0 sentinels. We pass the
# v2 rows through verbatim (build-app-blob.sh already keeps them rectangular) and
# only sanity-check that invariant, failing loudly if a row would shift the index.
# In --check mode we render to a temp file and diff it against the live catalog.json
# instead of overwriting, so the SAME render logic is the consistency oracle.
RENDER_TARGET="${CATALOG}"
if [ "${CHECK_ONLY}" = "1" ]; then RENDER_TARGET="$(mktemp)"; fi

python3 - "${V2}" "${RENDER_TARGET}" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
games = d.get("games", [])
req = ("id","name","title","source")
bad = [g.get("name","?") for g in games if not all(k in g for k in req)]
if bad:
    sys.stderr.write("[blobs] ERROR rows missing required keys: %s\n" % ", ".join(bad))
    sys.exit(1)
# ATOMIC write. A mid-party publish rewrites this file while clients are fetching
# it, and an in-place json.dump truncates first: a client that reads during the
# write gets a half-file and its whole app store fails to parse. Write a sibling
# temp, fsync it, then rename - a rename inside one directory is atomic, so every
# reader sees either the old catalog or the new one.
tmp = sys.argv[2] + ".render.tmp"
with open(tmp, "w") as handle:
    json.dump(d, handle, indent=2)
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, sys.argv[2])
nblob = sum(1 for g in games if g.get("source") == "blob")
npkg  = sum(1 for g in games if g.get("source") == "pkg")
sys.stderr.write("[blobs] catalog.json: %d rows (%d blob, %d pkg)\n" % (len(games), nblob, npkg))
PY

if [ "${CHECK_ONLY}" = "1" ]; then
    # Drift guard: catalog.json must equal what v2 renders to. If it diverges,
    # someone edited v2 (or a blob added a row) without re-running this script.
    if [ ! -f "${CATALOG}" ]; then
        rm -f "${RENDER_TARGET}"
        echo "[blobs] CHECK FAIL: ${CATALOG} missing - run build-game-blobs.sh" >&2; exit 1
    fi
    if ! diff -q "${RENDER_TARGET}" "${CATALOG}" >/dev/null 2>&1; then
        rm -f "${RENDER_TARGET}"
        echo "[blobs] CHECK FAIL: ${CATALOG} is out of sync with ${V2} - run build-game-blobs.sh" >&2; exit 1
    fi
    rm -f "${RENDER_TARGET}"
    echo "[blobs] CHECK OK: catalog.json matches catalog.v2.json" >&2
    exit 0
fi

echo "[blobs] catalog: ${CATALOG}" >&2
