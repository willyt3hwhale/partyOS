#!/usr/bin/env bash
# test-catalog-parse.sh - hardware-FREE unit test for the BAKED partyos-app
# catalog parser (robustness guard). The image bakes partyos-app from
# scripts/build/files/rootfs/usr/local/bin/partyos-app. This test sed/awk-extracts
# load_catalog (+ the C_* array decl) from that file, sources it with
# fetch_catalog/say stubbed, and unit-tests
# the parse against synthetic catalogs. No VM, no network, no hardware.
#
# The bug this guards: the OLD load_catalog ran 13 INDEPENDENT grep passes and
# aligned the resulting parallel arrays purely by match ORDER. A single row missing
# ONE field (e.g. no "sha256") left that array one short and shifted every LATER game
# onto the wrong value (xonotic would inherit tux's sha -> wrong-hash download), and
# the ragged guard then refused the WHOLE catalog - one bad row broke the store for
# every client. The fix parses ONE brace-balanced object at a time and emits a
# complete 13-field record per VALID row, so the arrays are aligned BY CONSTRUCTION
# and a malformed row is isolated to itself.
#
# Asserts:
#   * a CLEAN catalog parses every row, perfectly aligned (incl. pkg sentinel rows),
#   * a row MISSING sha256 does NOT desync later rows (the regression): the bad
#     row gets an empty sha, every OTHER row keeps its own correct sha, store loads,
#   * a row MISSING the required "name" is SKIPPED (logged) and the rest still load,
#   * a v3 preamble _skipped object carrying a stray "name" is NOT parsed as a game.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

PAPP="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-app"
[ -f "${PAPP}" ] || { echo "FAIL: partyos-app baked file not found at ${PAPP}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-cattest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- the baked partyos-app is the body; carve out load_catalog ----------------
PAPP_BODY="${PAPP}"
[ -s "${PAPP_BODY}" ] || { echo "FAIL: partyos-app baked file is empty (${PAPP_BODY})"; exit 1; }

# Carve load_catalog (def -> its col-0 closing brace). Standalone, runs nothing at
# top level. We provide the C_* array decl + fetch_catalog/say stubs in the harness.
CATLIB="${TMPDIR_T}/catlib.sh"
awk '/^load_catalog\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "${PAPP_BODY}" > "${CATLIB}"
[ -s "${CATLIB}" ] || { echo "FAIL: could not carve load_catalog out of PAPP"; exit 1; }
grep -q '^load_catalog() {' "${CATLIB}" || { echo "FAIL: load_catalog missing from carve"; exit 1; }

# --- harness: stub fetch_catalog (point it at a file) + say -------------------
declare -a C_ID=() C_NAME=() C_TITLE=() C_BLOB=() C_SHA=() C_ENTRY=() C_MARKER=()
declare -a C_CAT=() C_RMIN=() C_RMAX=() C_SRC=() C_ICON=() C_HIDDEN=()
say() { :; }
CATALOG=""
fetch_catalog() { [ -s "${CATALOG}" ]; }
# shellcheck disable=SC1090
source "${CATLIB}"

# idx_of NAME -> echo the catalog index for NAME, or empty (mirror of resolve_idx
# on name only, enough to assert a row landed at the right alignment).
idx_of() {
    local key="$1" i=0
    while [ "${i}" -lt "${#C_NAME[@]}" ]; do
        [ "${C_NAME[$i]}" = "${key}" ] && { echo "${i}"; return 0; }
        i=$((i+1))
    done
    return 1
}
sha_of() { local i; i="$(idx_of "$1")" || { echo "__NOROW__"; return; }; echo "${C_SHA[$i]:-}"; }

echo "================ (a) clean catalog parses, aligned ==========="
CATALOG="${TMPDIR_T}/clean.json"
cat > "${CATALOG}" <<'JSON'
{
  "version": 3,
  "_skipped": [ { "name": "python", "reason": "in base" } ],
  "_aur_blob_pipeline": [ "mindustry" ],
  "games": [
    { "id":"a.warsow","name":"warsow","hidden":false,"title":"Warsow","source":"blob","blob":"b/warsow.sq","sha256":"AAA","ram_min":1024,"ram_max":2048,"category":"game","icon":"/i/warsow.png","entry":"bin/run.sh","marker":"" },
    { "id":"a.xonotic","name":"xonotic","hidden":false,"title":"Xonotic","source":"blob","blob":"b/xonotic.sq","sha256":"BBB","ram_min":1024,"ram_max":2048,"category":"game","icon":"/i/xonotic.png","entry":"bin/run.sh","marker":"" },
    { "id":"a.gimp","name":"gimp","hidden":false,"title":"GIMP","source":"pkg","blob":"","sha256":"","ram_min":0,"ram_max":0,"category":"creative","icon":"","entry":"","marker":"" }
  ]
}
JSON
load_catalog; LC_RC=$?
assert_true "${LC_RC}" "clean catalog: load_catalog succeeds"
assert_eq "${#C_NAME[@]}" "3" "clean: 3 rows parsed"
assert_eq "$(sha_of warsow)"  "AAA" "clean: warsow keeps its sha (AAA)"
assert_eq "$(sha_of xonotic)" "BBB" "clean: xonotic keeps its sha (BBB)"
# the _skipped preamble "python" must NOT become a game row (v3 preamble leak guard)
idx_of python >/dev/null; assert_false $? "clean: preamble _skipped 'python' is NOT a game row"
# pkg sentinel row: empty blob/sha, src=pkg - preserved exactly
i_gimp="$(idx_of gimp)"
assert_eq "${C_SRC[$i_gimp]}" "pkg" "clean: gimp is source=pkg"
assert_eq "${C_BLOB[$i_gimp]}" ""   "clean: gimp pkg row has empty blob sentinel"

echo
echo "================ (b) missing sha256 does NOT desync ==========="
CATALOG="${TMPDIR_T}/missing-sha.json"
cat > "${CATALOG}" <<'JSON'
{
  "version": 3,
  "games": [
    { "id":"a.warsow","name":"warsow","hidden":false,"title":"Warsow","source":"blob","blob":"b/warsow.sq","sha256":"AAA","ram_min":1024,"ram_max":2048,"category":"game","icon":"/i/warsow.png","entry":"bin/run.sh","marker":"" },
    { "id":"a.xonotic","name":"xonotic","hidden":false,"title":"Xonotic","source":"blob","blob":"b/xonotic.sq","ram_min":1024,"ram_max":2048,"category":"game","icon":"/i/xonotic.png","entry":"bin/run.sh","marker":"" },
    { "id":"a.tux","name":"tux","hidden":false,"title":"Tux","source":"blob","blob":"b/tux.sq","sha256":"CCC","ram_min":512,"ram_max":1024,"category":"game","icon":"/i/tux.png","entry":"bin/run.sh","marker":"" }
  ]
}
JSON
load_catalog; LC_RC=$?
assert_true "${LC_RC}" "missing-sha: store still loads (one bad field != dead store)"
assert_eq "${#C_NAME[@]}" "3" "missing-sha: all 3 rows still present"
# THE KEY ASSERTION: the bad row gets an EMPTY sha (its own), tux keeps CCC (not shifted onto it).
assert_eq "$(sha_of warsow)"  "AAA" "missing-sha: warsow keeps AAA"
assert_eq "$(sha_of xonotic)" ""    "missing-sha: xonotic (bad row) gets EMPTY sha, not desynced"
assert_eq "$(sha_of tux)"     "CCC" "missing-sha: tux keeps its OWN sha CCC (NOT shifted from the bad row)"

echo
echo "================ (c) missing required name is skipped ========="
CATALOG="${TMPDIR_T}/missing-name.json"
cat > "${CATALOG}" <<'JSON'
{
  "version": 3,
  "games": [
    { "id":"a.warsow","name":"warsow","hidden":false,"title":"Warsow","source":"blob","blob":"b/warsow.sq","sha256":"AAA","ram_min":1024,"ram_max":2048,"category":"game","icon":"/i/warsow.png","entry":"bin/run.sh","marker":"" },
    { "id":"a.noname","hidden":false,"title":"Nameless","source":"blob","blob":"b/x.sq","sha256":"XXX","ram_min":1,"ram_max":2,"category":"game","icon":"","entry":"","marker":"" },
    { "id":"a.tux","name":"tux","hidden":false,"title":"Tux","source":"blob","blob":"b/tux.sq","sha256":"CCC","ram_min":512,"ram_max":1024,"category":"game","icon":"/i/tux.png","entry":"bin/run.sh","marker":"" }
  ]
}
JSON
# Capture the SKIP warning (stderr) to a file but run load_catalog in THIS shell -
# a $(...) capture would subshell it and discard the populated C_* arrays.
SKIP_FILE="${TMPDIR_T}/skip.log"
load_catalog 2>"${SKIP_FILE}"; LC_RC=$?
SKIP_LOG="$(cat "${SKIP_FILE}")"
assert_true "${LC_RC}" "missing-name: store still loads"
assert_eq "${#C_NAME[@]}" "2" "missing-name: the nameless row is dropped (2 of 3 survive)"
assert_eq "$(sha_of warsow)" "AAA" "missing-name: warsow survives with AAA"
assert_eq "$(sha_of tux)"    "CCC" "missing-name: tux survives with CCC"
assert_contains "${SKIP_LOG}" "PARTYOS-APP-CATALOG-SKIP" "missing-name: a SKIP warning was logged"

echo
echo "================ (d) real catalog parses end to end =========="
REALCAT="${REPO_ROOT}/server/games/catalog.json"
if [ -s "${REALCAT}" ]; then
    CATALOG="${REALCAT}"
    load_catalog; LC_RC=$?
    assert_true "${LC_RC}" "real catalog: load_catalog succeeds"
    assert_true "$([ "${#C_NAME[@]}" -ge 1 ] && echo 0 || echo 1)" "real catalog: parsed >=1 row (n=${#C_NAME[@]})"
    # every parsed row must have a non-empty name (alignment sanity)
    ragged=0; i=0
    while [ "${i}" -lt "${#C_NAME[@]}" ]; do [ -n "${C_NAME[$i]}" ] || ragged=1; i=$((i+1)); done
    assert_eq "${ragged}" "0" "real catalog: every parsed row has a name (no empty/ragged slot)"
else
    echo "  (skip: ${REALCAT} not present)"
fi

# --- drift guard: the SERVED catalog must match its tracked source ---------
# catalog.v2.json is the source of truth. catalog.json is what the client fetches.
# Any writer of v2 - a blob build, the event wizard, a hand edit - has to re-render
# catalog.json, and this is the backstop that fails when one of them forgot.
# render.sh renders it on every run, so a red result here means the render never ran.
echo "================ served catalog vs its source ================"
REAL_V2="${REPO_ROOT}/server/games/catalog.v2.json"
if [ -f "${REAL_V2}" ]; then
    DRIFT_OUT="$(bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" --check "${REPO_ROOT}/server/games" 2>&1)"
    DRIFT_RC=$?
    assert_true "${DRIFT_RC}" "catalog.json matches catalog.v2.json (${DRIFT_OUT})"
else
    echo "  (skip: ${REAL_V2} not present)"
fi

assert_summary "test-catalog-parse" || exit 1
echo "test-catalog-parse: ALL PASS"
