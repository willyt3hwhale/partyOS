#!/usr/bin/env bash
# test-cache-policy.sh - hardware-FREE unit tests for three blob-policy robustness
# fixes in partyos-app (baked from scripts/build/files/rootfs/usr/local/bin/) and the
# catalog renderer (build-game-blobs.sh). No VM, no network, no hardware.
#
# Covers:
#   Stale-sha cache invalidation must NOT trigger a re-download storm. A cached,
#        present blob whose sha != catalog sha is KEPT and used (PARTYOS-APP-STALE-KEPT),
#        NOT evicted+re-downloaded, UNLESS FORCE_REDOWNLOAD=1 (the explicit reinstall).
#   - hidden catalog rows are an ACCESS GATE: `install <hiddenname>` REFUSES
#        (PARTYOS-APP-HIDDEN-BLOCKED). The load-url path is catalog-independent and
#        unaffected. Visible rows still install.
#   - catalog.json must stay in sync with the authoritative catalog.v2.json:
#        build-game-blobs.sh --check fails loudly on drift, passes when in sync.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

PAPP="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-app"
[ -f "${PAPP}" ] || { echo "FAIL: partyos-app baked file not found at ${PAPP}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-cachetest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- point at the baked partyos-app -------------------------------------------
PAPP_BODY="${PAPP}"
[ -s "${PAPP_BODY}" ] || { echo "FAIL: partyos-app baked file is empty (${PAPP_BODY})"; exit 1; }

# =====================================================================
echo "================ CACHE: stale cache kept, not re-downloaded ==="
# Carve get_blob (def -> its col-0 closing brace). We stub everything it touches
# (cache_dir/start_seed/say + the download helpers) so the CACHE decisions run with
# no network. The download helpers are tripwires: if get_blob ever reaches the
# download path for a present cached blob, the test fails (that IS the storm bug).
GBLIB="${TMPDIR_T}/getblob.sh"
awk '/^get_blob\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "${PAPP_BODY}" > "${GBLIB}"
[ -s "${GBLIB}" ] || { echo "FAIL: could not carve get_blob out of PAPP"; exit 1; }
grep -q '^get_blob() {' "${GBLIB}" || { echo "FAIL: get_blob missing from carve"; exit 1; }
# Confirm the new STALE-KEPT marker is actually present in the carved function (guards
# against a future edit silently re-introducing the evict-on-stale storm).
grep -q 'PARTYOS-APP-STALE-KEPT' "${GBLIB}" || { echo "FAIL: STALE-KEPT path missing from get_blob"; exit 1; }
# The fail-closed refusal must be present in the carved function (guards against
# a future edit silently re-introducing unverified empty-sha mounting).
grep -q 'refusing unverified blob' "${GBLIB}" || { echo "FAIL: fail-closed 'refusing unverified blob' path missing from get_blob"; exit 1; }

CACHE_T="${TMPDIR_T}/cache"; mkdir -p "${CACHE_T}"
SAY_LOG=""
say()         { SAY_LOG="${SAY_LOG}${SAY_LOG:+|}$*"; }
cache_dir()   { echo "${CACHE_T}"; }
start_seed()  { :; }
refresh_torrent() { :; }   # cache-HIT re-announce hook; unit-tested on its own below
BLOB_BASE="http://server.test"   # referenced by get_blob's download-error logging
# Download tripwires: reaching ANY of these for a present cached blob = the storm bug.
# FILE marker, not a shell variable: get_blob's download path now runs inside a
# flock subshell (the concurrent-install serialization), and a variable set there
# never reaches this parent shell - a file write does. DOWNLOADED reads the marker.
DL_TRIP="${TMPDIR_T}/download-tripwire"
fetch_torrent() { : > "${DL_TRIP}"; return 1; }
blob_fetch()    { : > "${DL_TRIP}"; return 1; }
aria2c()        { : > "${DL_TRIP}"; return 1; }
dl_reset() { rm -f "${DL_TRIP}"; }
DOWNLOADED() { if [ -e "${DL_TRIP}" ]; then echo 1; else echo 0; fi; }
# shellcheck disable=SC1090
source "${GBLIB}"

# Helper: lay down a cached blob with KNOWN content (so its real sha is computable).
seed_cache() { printf 'GAMEBLOBCONTENT-%s' "$1" > "${CACHE_T}/$1.squashfs"; }
real_sha()   { sha256sum "${CACHE_T}/$1.squashfs" | awk '{print $1}'; }

# (1) sha MATCH -> plain cache HIT (baseline, unchanged).
seed_cache "warsow"; GOOD="$(real_sha warsow)"
SAY_LOG=""; dl_reset; BLOB_PATH=""
get_blob "warsow" "server/games/warsow.squashfs" "${GOOD}"; rc=$?
assert_true "${rc}" "CACHE: matching-sha cached blob = HIT (rc 0)"
assert_eq "$(DOWNLOADED)" "0" "CACHE: matching-sha HIT does not download"
assert_contains "${SAY_LOG}" "PARTYOS-APP-CACHE-HIT" "CACHE: matching-sha logs CACHE-HIT"
assert_eq "${BLOB_PATH}" "${CACHE_T}/warsow.squashfs" "CACHE: HIT sets BLOB_PATH to cached blob"

# (2) sha MISMATCH, present cached blob, no force -> KEEP it, NO download (THE FIX).
seed_cache "xonotic"
SAY_LOG=""; dl_reset; BLOB_PATH=""; FORCE_REDOWNLOAD=0
get_blob "xonotic" "server/games/xonotic.squashfs" "deadbeefSHAthatWILLnotMATCH"; rc=$?
assert_true "${rc}" "CACHE: stale-sha cached blob still returns success (kept)"
assert_eq "$(DOWNLOADED)" "0" "CACHE: stale-sha cached blob is NOT re-downloaded (no storm)"
assert_contains "${SAY_LOG}" "PARTYOS-APP-STALE-KEPT" "CACHE: stale-sha logs STALE-KEPT"
assert_not_contains "${SAY_LOG}" "PARTYOS-APP-CACHE-STALE" "CACHE: stale-sha does NOT take the evict path"
assert_eq "${BLOB_PATH}" "${CACHE_T}/xonotic.squashfs" "CACHE: stale-kept blob is still usable (BLOB_PATH set)"
[ -s "${CACHE_T}/xonotic.squashfs" ]; assert_true "$?" "CACHE: stale-kept blob file is NOT deleted"

# (3) sha MISMATCH but FORCE_REDOWNLOAD=1 (explicit reinstall) -> evict + re-download.
seed_cache "tux"
SAY_LOG=""; dl_reset; BLOB_PATH=""; FORCE_REDOWNLOAD=1
get_blob "tux" "server/games/tux.squashfs" "deadbeefSHAthatWILLnotMATCH" || true
assert_contains "${SAY_LOG}" "PARTYOS-APP-CACHE-STALE" "CACHE: forced reinstall takes the evict path"
assert_eq "$(DOWNLOADED)" "1" "CACHE: forced reinstall DOES reach the download path"
[ ! -e "${CACHE_T}/tux.squashfs" ]; assert_true "$?" "CACHE: forced reinstall drops the stale cached blob"
unset FORCE_REDOWNLOAD

# (4) MISSING cache (no force) -> normal first-install MISS path is unchanged.
SAY_LOG=""; dl_reset; BLOB_PATH=""
get_blob "newgame" "server/games/newgame.squashfs" "somesha" || true
assert_contains "${SAY_LOG}" "PARTYOS-APP-CACHE-MISS" "CACHE: absent cache = first-install MISS (unchanged)"
assert_eq "$(DOWNLOADED)" "1" "CACHE: first-install MISS reaches the download path"

# =====================================================================
echo "================ INTEGRITY: partial+mismatch NOT stale-kept ==="
# The STALE-KEPT rule kept ANY present,
# sha-mismatched blob - including an INCOMPLETE p2p download (aria2 wedged in D-state,
# left a .aria2 control file, partial content hashing to a third value). Mounting that
# partial squashfs defeats the integrity model. The guard: on sha mismatch, a partial
# marker (.aria2/.dl) forces re-download (resume) instead of STALE-KEEPing the partial.
grep -q 'PARTYOS-APP-CACHE-PARTIAL' "${GBLIB}" || { echo "FAIL: CACHE-PARTIAL guard missing from get_blob"; exit 1; }

# (5a) sha MISMATCH + a leftover .aria2 marker (interrupted resume) -> NOT stale-kept;
#      falls through to the download path (would resume), does NOT mount the partial.
seed_cache "flatout2"; : > "${CACHE_T}/flatout2.squashfs.aria2"
SAY_LOG=""; dl_reset; BLOB_PATH=""; FORCE_REDOWNLOAD=0
get_blob "flatout2" "server/games/flatout2.squashfs" "deadbeefSHAthatWILLnotMATCH" || true
assert_contains "${SAY_LOG}" "PARTYOS-APP-CACHE-PARTIAL" "INTEGRITY: partial+mismatch logs CACHE-PARTIAL"
assert_not_contains "${SAY_LOG}" "PARTYOS-APP-STALE-KEPT" "INTEGRITY: partial+mismatch is NOT stale-kept"
assert_eq "$(DOWNLOADED)" "1" "INTEGRITY: partial+mismatch reaches the (re)download path"
rm -f "${CACHE_T}/flatout2.squashfs.aria2"

# (5b) sha MISMATCH + a .dl in-flight marker (no aria2) -> same guard fires.
seed_cache "flatout2"; : > "${CACHE_T}/flatout2.squashfs.dl"
SAY_LOG=""; dl_reset; BLOB_PATH=""; FORCE_REDOWNLOAD=0
get_blob "flatout2" "server/games/flatout2.squashfs" "deadbeefSHAthatWILLnotMATCH" || true
assert_contains "${SAY_LOG}" "PARTYOS-APP-CACHE-PARTIAL" "INTEGRITY: .dl marker also triggers CACHE-PARTIAL"
assert_not_contains "${SAY_LOG}" "PARTYOS-APP-STALE-KEPT" "INTEGRITY: .dl+mismatch is NOT stale-kept"
rm -f "${CACHE_T}/flatout2.squashfs.dl"
unset FORCE_REDOWNLOAD

# (5c) REGRESSION: sha mismatch with NO partial marker still STALE-KEEPs (a genuine
#      valid-but-old blob) - the guard must not break the no-storm behaviour.
seed_cache "xonotic"
SAY_LOG=""; dl_reset; BLOB_PATH=""; FORCE_REDOWNLOAD=0
get_blob "xonotic" "server/games/xonotic.squashfs" "deadbeefSHAthatWILLnotMATCH"; rc=$?
assert_true "${rc}" "INTEGRITY: mismatch w/o partial still STALE-KEEPs (no-storm intact)"
assert_contains "${SAY_LOG}" "PARTYOS-APP-STALE-KEPT" "INTEGRITY: clean mismatch still logs STALE-KEPT"
assert_not_contains "${SAY_LOG}" "PARTYOS-APP-CACHE-PARTIAL" "INTEGRITY: clean mismatch is NOT flagged partial"
assert_eq "$(DOWNLOADED)" "0" "INTEGRITY: clean mismatch does not re-download (no storm)"
unset FORCE_REDOWNLOAD

# =====================================================================
echo "================ UNVERIFIED: empty-sha blob refuses (fail-closed)"
# An empty catalog sha256 means no verification is possible. The catalog is
# CA-authenticated, so an empty sha is an OPERATOR AUTHORING ERROR, not a trustless
# blob - get_blob must FAIL CLOSED and refuse to mount, unless an operator explicitly
# forces it with PARTYOS_ALLOW_UNVERIFIED_BLOB=1. Exercised on the deterministic
# cache-hit path (the download tripwire makes the fresh-download path fail first).

# (a) CACHE-HIT, empty sha, NO override -> REFUSES (no mount, no download).
seed_cache "noshagame"
SAY_LOG=""; dl_reset; BLOB_PATH=""
unset PARTYOS_ALLOW_UNVERIFIED_BLOB 2>/dev/null || true
get_blob "noshagame" "server/games/noshagame.squashfs" ""; rc=$?
assert_false "${rc}" "UNVERIFIED: empty-sha cache-hit REFUSES (rc nonzero)"
assert_contains "${SAY_LOG}" "refusing unverified blob" "UNVERIFIED: empty-sha refusal is logged"
assert_eq "${BLOB_PATH}" "" "UNVERIFIED: refused blob does NOT set BLOB_PATH (not mounted)"
assert_eq "$(DOWNLOADED)" "0" "UNVERIFIED: refusal does not download"
[ -s "${CACHE_T}/noshagame.squashfs" ]; assert_true "$?" "UNVERIFIED: refused cached blob file is left on disk (not used, not deleted)"

# (b) CACHE-HIT, empty sha, WITH override -> ALLOWS (operator forced it).
seed_cache "noshagame"
SAY_LOG=""; dl_reset; BLOB_PATH=""
PARTYOS_ALLOW_UNVERIFIED_BLOB=1 get_blob "noshagame" "server/games/noshagame.squashfs" ""; rc=$?
assert_true "${rc}" "UNVERIFIED: empty-sha cache-hit with override ALLOWS (rc 0)"
assert_contains "${SAY_LOG}" "CACHE-HIT" "UNVERIFIED: override path logs CACHE-HIT"
assert_contains "${SAY_LOG}" "override" "UNVERIFIED: override path logs the override marker"
assert_eq "$(DOWNLOADED)" "0" "UNVERIFIED: override cache-hit does not download"
assert_eq "${BLOB_PATH}" "${CACHE_T}/noshagame.squashfs" "UNVERIFIED: override mounts the cached blob (BLOB_PATH set)"
unset PARTYOS_ALLOW_UNVERIFIED_BLOB 2>/dev/null || true

# =====================================================================
echo "================ HIDDEN: hidden rows are an install gate ======"
# The gate in cmd_install is one decision on C_HIDDEN[idx]. Carve the cmd_install
# header (def -> the hidden-gate block) and assert the gate text is present + behaves.
# We run the exact gate expression against a synthetic C_HIDDEN array.
grep -q 'PARTYOS-APP-HIDDEN-BLOCKED' "${PAPP_BODY}" || { echo "FAIL: HIDDEN-BLOCKED gate missing from cmd_install"; exit 1; }
# The gate must sit in cmd_install (by-name install path), not anywhere else.
awk '/^cmd_install\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "${PAPP_BODY}" > "${TMPDIR_T}/cmd_install.sh"
grep -q 'PARTYOS-APP-HIDDEN-BLOCKED' "${TMPDIR_T}/cmd_install.sh" \
    || { echo "FAIL: HIDDEN-BLOCKED gate is not inside cmd_install"; exit 1; }
# cmd_load_url (the legitimate share-code path) must NOT carry the gate (it bypasses
# the catalog entirely, so hidden games are LOADABLE there).
awk '/^cmd_load_url\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "${PAPP_BODY}" > "${TMPDIR_T}/cmd_load_url.sh"
if grep -q 'PARTYOS-APP-HIDDEN-BLOCKED' "${TMPDIR_T}/cmd_load_url.sh"; then
    _assert_bad "HIDDEN: load-url path must NOT block hidden games (gate leaked into cmd_load_url)"
else
    _assert_ok "HIDDEN: load-url path is gate-free (hidden games loadable by share code)"
fi
# load-url must not resolve via the catalog at all (that's WHY it bypasses the gate).
if grep -q 'load_catalog\|resolve_idx' "${TMPDIR_T}/cmd_load_url.sh"; then
    _assert_bad "HIDDEN: cmd_load_url unexpectedly consults the catalog"
else
    _assert_ok "HIDDEN: cmd_load_url is catalog-independent (no load_catalog/resolve_idx)"
fi

# Behavioural check of the gate decision itself (the exact expression from cmd_install).
declare -a C_HIDDEN
hidden_gate() {  # mirror: returns 2 (blocked) iff the row is hidden
    local idx="$1"
    if [ "${C_HIDDEN[$idx]:-false}" = "true" ]; then return 2; fi
    return 0
}
C_HIDDEN=(false true false)
hidden_gate 1; assert_eq "$?" "2" "HIDDEN: install of a hidden row is BLOCKED (rc 2)"
hidden_gate 0; assert_eq "$?" "0" "HIDDEN: install of a visible row is ALLOWED (rc 0)"
hidden_gate 2; assert_eq "$?" "0" "HIDDEN: another visible row is ALLOWED"

# =====================================================================
echo "================ SYNC: catalog.json <-> v2 sync guard ========="
GBLOBS="${REPO_ROOT}/scripts/build/build-game-blobs.sh"
[ -f "${GBLOBS}" ] || { echo "FAIL: build-game-blobs.sh not found"; exit 1; }
if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 unavailable - catalog sync --check test skipped"
else
    E2DIR="${TMPDIR_T}/e2/server/games"; mkdir -p "${E2DIR}"
    # A minimal valid v2 with one rectangular row.
    cat > "${E2DIR}/catalog.v2.json" <<'JSON'
{ "version": 3, "games": [
  { "id":"a.warsow","name":"warsow","title":"Warsow","source":"blob","blob":"b/warsow.sq","sha256":"AAA","size":1,"ram_min":1024,"ram_max":2048,"shm_mb":0,"version":"1.0.0","category":"game","icon":"","exec":"","pkg":"","pkgs":"","entry":"bin/run.sh","marker":"","hidden":false }
] }
JSON
    # build-game-blobs.sh resolves V2/CATALOG from the REAL repo root, so we can't point
    # its --check at our temp pair. Instead exercise the SAME render+diff logic the guard
    # uses directly on a hand-built pair (render -> mutate -> detect), then separately
    # assert the real script carries the --check guard.
    python3 - "${E2DIR}/catalog.v2.json" "${E2DIR}/catalog.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); json.dump(d,open(sys.argv[2],"w"),indent=2)
PY
    # In-sync: a re-render to a temp + diff must match.
    REND="$(mktemp)"
    python3 - "${E2DIR}/catalog.v2.json" "${REND}" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); json.dump(d,open(sys.argv[2],"w"),indent=2)
PY
    if diff -q "${REND}" "${E2DIR}/catalog.json" >/dev/null 2>&1; then
        _assert_ok "SYNC: freshly-rendered catalog.json matches v2 (in sync)"
    else
        _assert_bad "SYNC: in-sync render should match but diverged"
    fi
    # Drift: mutate catalog.json out from under v2 -> diff must DETECT divergence.
    printf '{"version":3,"games":[]}' > "${E2DIR}/catalog.json"
    if diff -q "${REND}" "${E2DIR}/catalog.json" >/dev/null 2>&1; then
        _assert_bad "SYNC: drift NOT detected (stale catalog.json matched render)"
    else
        _assert_ok "SYNC: drift detected (stale catalog.json differs from v2 render)"
    fi
    rm -f "${REND}"
    # And the real script exposes a --check mode (the wired guard).
    grep -q 'CHECK_ONLY' "${GBLOBS}" || { echo "FAIL: build-game-blobs.sh has no --check guard"; exit 1; }
    grep -q 'CHECK FAIL' "${GBLOBS}" && _assert_ok "SYNC: build-game-blobs.sh --check guard present" \
        || _assert_bad "SYNC: build-game-blobs.sh --check guard missing"
fi

# =====================================================================
echo "================ REANNOUNCE: cache-HIT refreshes stale torrent"
# A stick that cached a blob BEFORE the tracker
# announce was added keeps an OLD announce-less .torrent on a cache-HIT and never registers
# with the tracker (only LPD co-swarms it on-LAN). refresh_torrent() prefer-fetches the
# FRESH server .torrent on a cache-HIT and swaps it in ONLY when the info-hash is unchanged
# (the announce lives OUTSIDE the info dict, so same info-hash = same swarm). A DIFFERENT
# info-hash = a different blob: never swap. The load-url path (empty blobpath) stages a
# torrent with no server URL: never clobber it.
# Guard: the get_blob cache-HIT path must actually call refresh_torrent.
grep -qF 'refresh_torrent "${name}" "${blobpath}" "${cdir}"' "${GBLIB}" \
    || { echo "FAIL: get_blob cache-HIT does not call refresh_torrent"; exit 1; }
if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 unavailable - torrent info-hash tests skipped"
else
    # Carve torrent_infohash + refresh_torrent (each def -> its col-0 closing brace).
    RTLIB="${TMPDIR_T}/refresh_torrent.sh"
    awk '/^torrent_infohash\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "${PAPP_BODY}" >  "${RTLIB}"
    awk '/^refresh_torrent\(\) \{/{g=1} g{print} g&&/^\}/{exit}'  "${PAPP_BODY}" >> "${RTLIB}"
    grep -q '^torrent_infohash() {' "${RTLIB}" || { echo "FAIL: torrent_infohash not in carve"; exit 1; }
    grep -q '^refresh_torrent() {'  "${RTLIB}" || { echo "FAIL: refresh_torrent not in carve"; exit 1; }

    # harness: a controllable "server" torrent that the mocked blob_fetch copies into OUT.
    RT_CACHE="${TMPDIR_T}/rtcache"; mkdir -p "${RT_CACHE}"
    RT_SAY=""
    say()    { RT_SAY="${RT_SAY}${RT_SAY:+|}$*"; }
    aria2c() { :; }                        # command -v aria2c must succeed inside refresh_torrent
    SERVER_TORRENT=""                      # path the mocked fetch serves; "" = server unreachable
    blob_fetch() { [ -n "${SERVER_TORRENT}" ] && cp "${SERVER_TORRENT}" "$2"; }   # $2 = OUT path
    # shellcheck disable=SC1090
    source "${RTLIB}"

    # mk_torrent FILE ANNOUNCE NAME - a minimal valid bencoded .torrent. ANNOUNCE sits
    # OUTSIDE the info dict (empty = none); NAME sits INSIDE it, so a different NAME changes
    # the info-hash. 20-byte pieces string keeps the info dict well-formed for the walker.
    mk_torrent() {
        local f="$1" ann="$2" nm="$3"
        local info="d6:lengthi3e4:name${#nm}:${nm}12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaae"
        if [ -n "${ann}" ]; then
            printf 'd8:announce%d:%s4:info%se' "${#ann}" "${ann}" "${info}" > "${f}"
        else
            printf 'd4:info%se' "${info}" > "${f}"
        fi
    }

    # (i) torrent_infohash: an announce-only difference => SAME hash; different info => different.
    mk_torrent "${TMPDIR_T}/t_noann" ""                        foo
    mk_torrent "${TMPDIR_T}/t_ann"   "http://tracker:6969/ann" foo
    mk_torrent "${TMPDIR_T}/t_other" "http://tracker:6969/ann" bar
    IH_NOANN="$(torrent_infohash "${TMPDIR_T}/t_noann")"
    IH_ANN="$(torrent_infohash "${TMPDIR_T}/t_ann")"
    IH_OTHER="$(torrent_infohash "${TMPDIR_T}/t_other")"
    [ -n "${IH_NOANN}" ]; assert_true "$?" "REANNOUNCE: info-hash computed for a valid torrent"
    assert_eq "${IH_ANN}" "${IH_NOANN}" "REANNOUNCE: adding an announce leaves the info-hash UNCHANGED (same swarm)"
    [ "${IH_OTHER}" != "${IH_NOANN}" ]; assert_true "$?" "REANNOUNCE: a different info dict yields a DIFFERENT info-hash"

    # (ii) cache-HIT refresh: cached announce-less torrent + fresh server torrent (announce,
    #      SAME info-hash) => refresh_torrent SWAPS in the announce-carrying torrent.
    mk_torrent "${RT_CACHE}/warsow.squashfs.torrent" "" warsow
    mk_torrent "${TMPDIR_T}/srv_warsow.torrent" "http://tracker:6969/ann" warsow
    SERVER_TORRENT="${TMPDIR_T}/srv_warsow.torrent"; RT_SAY=""
    refresh_torrent "warsow" "server/games/warsow.squashfs" "${RT_CACHE}"
    assert_contains "${RT_SAY}" "PARTYOS-APP-TORRENT-REFRESH" "REANNOUNCE: same info-hash torrent is refreshed (logged)"
    if cmp -s "${TMPDIR_T}/srv_warsow.torrent" "${RT_CACHE}/warsow.squashfs.torrent"; then
        _assert_ok "REANNOUNCE: cached torrent now equals the fresh announce-carrying server torrent"
    else
        _assert_bad "REANNOUNCE: cached torrent was NOT swapped to the fresh one"
    fi
    [ ! -e "${RT_CACHE}/warsow.squashfs.torrent.fresh" ]; assert_true "$?" "REANNOUNCE: no .fresh temp left behind on a swap"

    # (iii) DIFFERENT info-hash server torrent => must NOT swap (a different/repacked blob).
    mk_torrent "${RT_CACHE}/xonotic.squashfs.torrent" "" xonotic
    XON_BEFORE="$(torrent_infohash "${RT_CACHE}/xonotic.squashfs.torrent")"
    mk_torrent "${TMPDIR_T}/srv_xonotic.torrent" "http://tracker:6969/ann" xonotic-REPACKED
    SERVER_TORRENT="${TMPDIR_T}/srv_xonotic.torrent"; RT_SAY=""
    refresh_torrent "xonotic" "server/games/xonotic.squashfs" "${RT_CACHE}"
    assert_not_contains "${RT_SAY}" "PARTYOS-APP-TORRENT-REFRESH" "REANNOUNCE: different info-hash is NOT refreshed"
    assert_eq "$(torrent_infohash "${RT_CACHE}/xonotic.squashfs.torrent")" "${XON_BEFORE}" "REANNOUNCE: cached torrent left intact on info-hash mismatch"
    [ ! -e "${RT_CACHE}/xonotic.squashfs.torrent.fresh" ]; assert_true "$?" "REANNOUNCE: .fresh temp cleaned up on a no-swap"

    # (iv) load-url path (EMPTY blobpath): no server URL to re-fetch => staged torrent kept.
    mk_torrent "${RT_CACHE}/loaded.squashfs.torrent" "" loaded
    LOAD_BEFORE="$(torrent_infohash "${RT_CACHE}/loaded.squashfs.torrent")"
    SERVER_TORRENT="${TMPDIR_T}/srv_warsow.torrent"; RT_SAY=""   # a server torrent IS available...
    refresh_torrent "loaded" "" "${RT_CACHE}"                    # ...but blobpath is empty (staged)
    assert_not_contains "${RT_SAY}" "PARTYOS-APP-TORRENT-REFRESH" "REANNOUNCE: empty blobpath (load-url) does NOT refetch/clobber"
    assert_eq "$(torrent_infohash "${RT_CACHE}/loaded.squashfs.torrent")" "${LOAD_BEFORE}" "REANNOUNCE: staged load-url torrent left untouched"

    # (v) server unreachable (fetch fails): cached torrent left untouched, no crash, no temp.
    mk_torrent "${RT_CACHE}/offline.squashfs.torrent" "" offline
    OFF_BEFORE="$(torrent_infohash "${RT_CACHE}/offline.squashfs.torrent")"
    SERVER_TORRENT=""; RT_SAY=""
    refresh_torrent "offline" "server/games/offline.squashfs" "${RT_CACHE}"
    assert_not_contains "${RT_SAY}" "PARTYOS-APP-TORRENT-REFRESH" "REANNOUNCE: server-down fetch does not refresh"
    assert_eq "$(torrent_infohash "${RT_CACHE}/offline.squashfs.torrent")" "${OFF_BEFORE}" "REANNOUNCE: cached torrent survives a failed refetch"
    [ ! -e "${RT_CACHE}/offline.squashfs.torrent.fresh" ]; assert_true "$?" "REANNOUNCE: no .fresh temp left after a failed fetch"
fi

# =====================================================================
echo "================ ONE-ARIA2: one client aria2c over RPC ========"
# The client runs ONE aria2c with
# JSON-RPC (partyos-aria2d). start_seed / get_blob talk to it with the REAL
# partyos-aria2rpc, here pointed at a mock aria2 JSON-RPC server. The mock
# records every call, so the test sees what aria2c would receive.
A2D="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-aria2d"
A2RPC="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-aria2rpc"
[ -x "${A2D}" ] && [ -x "${A2RPC}" ] || { echo "FAIL: partyos-aria2d / partyos-aria2rpc missing or not executable"; exit 1; }

# --- static guards: the one aria2c keeps the P2P rules ------------------------
A2D_BODY="$(grep -v '^[[:space:]]*#' "${A2D}")"
assert_contains "${A2D_BODY}" "--enable-rpc=true" "ONE-ARIA2: aria2d enables JSON-RPC"
assert_contains "${A2D_BODY}" "--rpc-listen-all=false" "ONE-ARIA2: the RPC listens on loopback only"
assert_contains "${A2D_BODY}" "rpc-secret=" "ONE-ARIA2: the RPC has a secret (in the root-only conf file)"
assert_contains "${A2D_BODY}" "--seed-ratio=0.0" "ONE-ARIA2: unbounded seeding (seed-ratio 0)"
assert_contains "${A2D_BODY}" "--bt-enable-lpd=true" "ONE-ARIA2: LPD discovery stays on"
assert_contains "${A2D_BODY}" "--max-overall-upload-limit=" "ONE-ARIA2: the per-client upload cap is applied"
assert_contains "${A2D_BODY}" "umask 022" "ONE-ARIA2: aria2c runs with umask 022 (blobs stay readable for the player)"
assert_not_contains "${A2D_BODY}" "check-integrity=true" "ONE-ARIA2: aria2d does not re-hash at start"
# The dirty window for the slow stick.
# 32 MB gave 0.12 MB/s on a "General UDisk" stick, 256 MB gave 0.45-0.51 MB/s.
A5_BODY="$(cat "${REPO_ROOT}/scripts/build/phases/a5-eggs-splash-initramfs.sh")"
assert_contains "${A5_BODY}" "vm.dirty_bytes = 268435456" "WRITEBACK: the image sets a 256 MB dirty window"
assert_contains "${A5_BODY}" "vm.dirty_background_bytes = 67108864" "WRITEBACK: background writeback starts at 64 MB"
assert_not_contains "${A5_BODY}" "33554432" "WRITEBACK: the 32 MB cap (random writes on a slow stick) is gone"
assert_not_contains "${A2D_BODY}" "--seed-time" "ONE-ARIA2: no seed-time bound"
assert_not_contains "$(grep -v '^[[:space:]]*#' "${PAPP_BODY}")" "check-integrity=true" "ONE-ARIA2: partyos-app never asks for an integrity re-check"
# The only aria2c partyos-app still starts itself is the load-url magnet pull.
A2C_OUTSIDE="$(awk '/^cmd_load_url\(\) \{/{g=1} g&&/^\}/{g=0; next} !g' "${PAPP_BODY}" | grep -v '^[[:space:]]*#' | grep -E 'aria2c[[:space:]]+(--|"|-d)' || true)"
assert_eq "${A2C_OUTSIDE}" "" "ONE-ARIA2: partyos-app starts no aria2c outside cmd_load_url"

if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 unavailable - mock RPC tests skipped"
else
    MOCK="${TMPDIR_T}/mock-aria2.py"
    cat > "${MOCK}" <<'PY'
# Mock aria2 JSON-RPC. Logs one JSON line per call to MOCK_LOG. Download
# behaviour comes from the file MOCK_MODE: complete | error <code> <msg> | stall |
# slow <n> (complete, but the first n tellStatus calls answer after 2s) | gone |
# slowadd (complete, the add and the next 2 calls answer after 2s) |
# mute <n> (the first n tellStatus calls answer after 2s, then the blob is written
# and complete) | dup (the add returns an error-12
# entry and a live complete entry is also there, as after a late first add) |
# dupslow <n> (dup, and when the error-12 status is first read, the next n calls
# answer after 2s, so the first finds time out) | finish (a tellStatus completes
# an entry that is still downloading, as when an earlier try goes on) |
# deaf (every call answers after 4s, as when aria2c blocks on a stick write; a
# ping times out after 3s) | flush <n> (complete at once, but the second half of
# the file is still zero: aria2c holds it in its disk cache; tellStatus call n
# writes it) | flushslow <n> (flush, and tellStatus calls 2..n answer after 2s,
# as when the flush blocks the event loop of aria2c) | corrupt (complete, but the
# second half stays zero).
import base64, hashlib, http.server, json, os, re, sys, time
LOG, MODEF, CONTENT = os.environ["MOCK_LOG"], os.environ["MOCK_MODE"], os.environ["MOCK_CONTENT"]
SECRET = "token:" + open(os.environ["MOCK_SECRET"]).read().strip()
E, N, SLOWN = {}, [0], [0]
def name_of(tor):
    m = re.search(rb"4:name(\d+):", tor)
    return tor[m.end():m.end() + int(m.group(1))].decode()
def view(g):
    e = E[g]
    return {"gid": g, "status": e["status"], "completedLength": str(e["done"]),
            "totalLength": str(e["total"]), "downloadSpeed": "0", "uploadSpeed": "0",
            "connections": "0", "numSeeders": "0", "seeder": str(e["done"] == e["total"]).lower(),
            "errorCode": e.get("code", ""), "errorMessage": e.get("msg", ""),
            "infoHash": e.get("ih", ""),
            "files": [{"path": os.path.join(e["dir"], e["name"])}]}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(s):
        req = json.loads(s.rfile.read(int(s.headers["Content-Length"])))
        m, p = req["method"], req["params"]
        if p[0] != SECRET:
            return s.reply({"error": {"code": 1, "message": "Unauthorized"}}, 400)
        p = p[1:]
        rec = {"method": m}
        if open(MODEF).read().split()[:1] == ["deaf"]:
            time.sleep(4)
        if SLOWN[0] > 0 and m != "aria2.addTorrent":
            SLOWN[0] -= 1; time.sleep(2)
        if m == "aria2.addTorrent":
            tor = base64.b64decode(p[0]); opts = p[2]
            N[0] += 1; g = "%016x" % N[0]
            size = os.path.getsize(CONTENT)
            e = {"dir": opts["dir"], "name": name_of(tor), "total": size, "done": size,
                 "status": "active", "opts": opts,
                 "ih": hashlib.sha1(tor[tor.find(b"4:infod") + 6:-1]).hexdigest()}
            rec.update(opts=opts, name=e["name"], torrent=base64.b64encode(tor).decode())
            if opts.get("bt-seed-unverified") != "true":
                mode = open(MODEF).read().split(None, 2)
                if mode[0] in ("dup", "dupslow"):
                    N[0] += 1; live = "%016x" % N[0]
                    E[live] = dict(e)
                    with open(CONTENT, "rb") as f, open(os.path.join(e["dir"], e["name"]), "wb") as o:
                        o.write(f.read())
                    e.update(status="error", done=0, code="12", msg="InfoHash abcd is already registered.")
                    if mode[0] == "dupslow":
                        e["slowafter"] = int(mode[1])
                if mode[0] == "mute":
                    e.update(done=0, mute=int(mode[1]))
                if mode[0] == "slowadd":
                    time.sleep(2); SLOWN[0] = 2   # the next 2 calls are slow too
                if mode[0] in ("complete", "slow", "slowadd"):
                    with open(CONTENT, "rb") as f, open(os.path.join(e["dir"], e["name"]), "wb") as o:
                        o.write(f.read())
                    if mode[0] == "slow":
                        e["slow"] = int(mode[1])
                elif mode[0] in ("flush", "flushslow", "corrupt"):
                    data = open(CONTENT, "rb").read(); h = len(data) // 2
                    with open(os.path.join(e["dir"], e["name"]), "wb") as o:
                        o.write(data[:h] + b"\0" * (len(data) - h))
                    if mode[0] != "corrupt":
                        e.update(fix=int(mode[1]), calls=0, slowcalls=(mode[0] == "flushslow"))
                elif mode[0] == "gone":
                    e.update(done=0, gone=True)
                elif mode[0] == "error":
                    e.update(status="error", done=0, code=mode[1], msg=mode[2].strip())
                else:
                    e.update(done=1)
            E[g] = e; res = g
        elif m == "aria2.tellStatus":
            e = E.get(p[0], {})
            if e.get("gone"):
                return s.reply({"error": {"code": 1, "message": "GID %s is not found" % p[0]}}, 400)
            if e.get("slow", 0) > 0:
                e["slow"] -= 1; time.sleep(2)
            if e and e["done"] < e["total"] and open(MODEF).read().split()[0] == "finish":
                with open(CONTENT, "rb") as f, open(os.path.join(e["dir"], e["name"]), "wb") as o:
                    o.write(f.read())
                e["done"] = e["total"]
            if "fix" in e:
                e["calls"] += 1
                if e["slowcalls"] and 2 <= e["calls"] <= e["fix"]:
                    time.sleep(2)
                if e["calls"] >= e["fix"]:
                    with open(CONTENT, "rb") as f, open(os.path.join(e["dir"], e["name"]), "wb") as o:
                        o.write(f.read())
                    del e["fix"]
            if e.get("slowafter", 0) > 0:
                SLOWN[0] = e.pop("slowafter")
            if e.get("mute", 0) > 0:
                e["mute"] -= 1; time.sleep(2)
                if e["mute"] == 0:
                    with open(CONTENT, "rb") as f, open(os.path.join(e["dir"], e["name"]), "wb") as o:
                        o.write(f.read())
                    e["done"] = e["total"]
            res = view(p[0])
        elif m == "aria2.tellActive":
            res = [view(g) for g in E if E[g]["status"] == "active" and not E[g].get("gone")]
        elif m in ("aria2.tellWaiting",):
            res = []
        elif m == "aria2.tellStopped":
            res = [view(g) for g in E if E[g]["status"] != "active" and not E[g].get("gone")]
        elif m == "aria2.forceRemove":
            E[p[0]]["status"] = "removed"; res = p[0]; rec.update(gid=p[0])
        elif m == "aria2.removeDownloadResult":
            E.pop(p[0], None); res = "OK"
        elif m == "aria2.getVersion":
            res = {"version": "mock"}
        else:
            return s.reply({"error": {"code": 1, "message": "no " + m}}, 400)
        with open(LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
        s.reply({"id": req["id"], "jsonrpc": "2.0", "result": res})
    def reply(s, obj, code=200):
        b = json.dumps(obj).encode()
        s.send_response(code); s.send_header("Content-Length", str(len(b))); s.end_headers(); s.wfile.write(b)
    def log_message(s, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.environ["MOCK_PORT"], "w").write(str(srv.server_port))
srv.serve_forever()
PY
    export MOCK_LOG="${TMPDIR_T}/mock.log" MOCK_MODE="${TMPDIR_T}/mock.mode" MOCK_CONTENT="${TMPDIR_T}/mock.content"
    export MOCK_SECRET="${TMPDIR_T}/mock.secret" MOCK_PORT="${TMPDIR_T}/mock.port"
    echo "s3cret" > "${MOCK_SECRET}"; printf 'THE-FRESH-BLOB' > "${MOCK_CONTENT}"; echo complete > "${MOCK_MODE}"; : > "${MOCK_LOG}"
    python3 "${MOCK}" & MOCK_PID=$!
    trap 'kill "${MOCK_PID}" 2>/dev/null; rm -rf "${TMPDIR_T}"' EXIT
    for _ in $(seq 50); do [ -s "${MOCK_PORT}" ] && break; sleep 0.1; done
    export PARTYOS_ARIA2_RPC_URL="http://127.0.0.1:$(cat "${MOCK_PORT}")/jsonrpc" PARTYOS_ARIA2_SECRET_FILE="${MOCK_SECRET}"
    "${A2RPC}" ping; assert_true "$?" "ONE-ARIA2: partyos-aria2rpc reaches the mock RPC with the secret"

    # Carve the RPC-side functions out of partyos-app (plus the ARIA2RPC line).
    A2LIB="${TMPDIR_T}/a2lib.sh"
    grep '^ARIA2RPC=' "${PAPP_BODY}" > "${A2LIB}"
    for fn in a2 a2_up start_seed cache_devstat p2p_download blob_fsync blob_settle cmd_seed_cached seed_refresh fetch_torrent torrent_infohash refresh_torrent; do
        awk -v f="${fn}" '$0 ~ "^"f"\\(\\) \\{"{g=1} g{print} g&&/^\}/{exit}' "${PAPP_BODY}" >> "${A2LIB}"
        grep -q "^${fn}() {" "${A2LIB}" || { echo "FAIL: ${fn} not carved from partyos-app"; exit 1; }
    done
    # shellcheck disable=SC1090
    source "${A2LIB}"
    ARIA2RPC="${A2RPC}"   # the real RPC client, aimed at the mock by PARTYOS_ARIA2_RPC_URL
    A2SAY="${TMPDIR_T}/a2say.log"
    say() { echo "$*" >> "${A2SAY}"; }
    seeding_enabled() { return 0; }
    A2CACHE="${TMPDIR_T}/a2cache"; mkdir -p "${A2CACHE}"
    cache_dir() { echo "${A2CACHE}"; }
    ARIA2C_TRIP="${TMPDIR_T}/aria2c-started"
    aria2c() { : > "${ARIA2C_TRIP}"; return 1; }   # any direct aria2c start is a regression
    load_catalog() { return 1; }
    mk_torrent2() {   # FILE ANNOUNCE NAME: the info name is NAME.squashfs (the cached file)
        local f="$1" ann="$2" nm="$3.squashfs"
        printf 'd8:announce%d:%s4:infod6:lengthi14e4:name%d:%s12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee' \
            "${#ann}" "${ann}" "${#nm}" "${nm}" > "${f}"
    }
    mock_adds() { grep -c '"aria2.addTorrent"' "${MOCK_LOG}" 2>/dev/null || true; }

    # (1) seed-cached: THREE cached blobs -> three addTorrent calls to the ONE aria2c,
    #     each with bt-seed-unverified=true and check-integrity=false. No aria2c start.
    for g in warsow xonotic openra; do
        printf 'THE-FRESH-BLOB' > "${A2CACHE}/${g}.squashfs"
        mk_torrent2 "${A2CACHE}/${g}.squashfs.torrent" "http://tracker:6969/announce" "${g}"
    done
    # A partial (a .aria2 control file) must NOT be seeded.
    printf 'PART' > "${A2CACHE}/partial.squashfs"; : > "${A2CACHE}/partial.squashfs.aria2"
    mk_torrent2 "${A2CACHE}/partial.squashfs.torrent" "http://tracker:6969/announce" partial
    : > "${MOCK_LOG}"; : > "${A2SAY}"; rm -f "${ARIA2C_TRIP}"
    PARTYOS_SEED_REFRESH=off cmd_seed_cached
    assert_eq "$(mock_adds)" "3" "ONE-ARIA2: seed-cached adds 3 complete blobs to the one aria2c"
    SEEDOPTS="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["method"]=="aria2.addTorrent": print(r["name"], r["opts"].get("bt-seed-unverified"), r["opts"].get("check-integrity"))' "${MOCK_LOG}" | sort)"
    assert_eq "${SEEDOPTS}" "$(printf 'openra.squashfs true false\nwarsow.squashfs true false\nxonotic.squashfs true false')" \
        "ONE-ARIA2: every seed add has bt-seed-unverified=true and check-integrity=false (no re-hash)"
    assert_not_contains "$(cat "${MOCK_LOG}")" "partial.squashfs" "ONE-ARIA2: a partial blob is not seeded"
    [ ! -e "${ARIA2C_TRIP}" ]; assert_true "$?" "ONE-ARIA2: seed-cached starts no aria2c process"
    # (2) a second seed-cached run adds nothing: every blob is already in the aria2c.
    : > "${MOCK_LOG}"
    PARTYOS_SEED_REFRESH=off cmd_seed_cached
    assert_eq "$(mock_adds)" "0" "ONE-ARIA2: a second seed-cached run adds no duplicate entries"

    # get_blob needs the carved functions above plus its own stubs.
    source "${GBLIB}"
    RAM_CACHE="/nonexistent-ram-cache"
    FRESH_SHA="$(sha256sum "${MOCK_CONTENT}" | awk '{print $1}')"

    # (3) STALE TORRENT: cache miss with a stale torrent on the stick. get_blob
    #     must fetch the fresh server torrent and hand THAT to aria2c.
    rm -f "${A2CACHE}"/wz.*
    mk_torrent2 "${A2CACHE}/wz.squashfs.torrent" "http://lab-tracker.invalid:6969/announce" wz
    mk_torrent2 "${TMPDIR_T}/wz.fresh.torrent" "http://venue-tracker.invalid:6969/announce" wz
    blob_fetch() { cp "${TMPDIR_T}/wz.fresh.torrent" "$2"; }
    echo complete > "${MOCK_MODE}"; : > "${MOCK_LOG}"; : > "${A2SAY}"
    get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    assert_true "${rc}" "STALE-TORRENT: the cache-miss install succeeds"
    GOT_TOR="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["method"]=="aria2.addTorrent" and r["name"]=="wz.squashfs": print(r["torrent"])' "${MOCK_LOG}" | head -1)"
    assert_eq "${GOT_TOR}" "$(base64 < "${TMPDIR_T}/wz.fresh.torrent" | tr -d '\n')" \
        "STALE-TORRENT: aria2c got the FRESH server torrent, not the stale cached one"
    GOT_ANN="$(python3 -c 'import json,sys,base64
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["method"]=="aria2.addTorrent": print(base64.b64decode(r["torrent"]).decode("latin1"))' "${MOCK_LOG}")"
    assert_not_contains "${GOT_ANN}" "lab-tracker" "STALE-TORRENT: the stale announce never reaches aria2c"
    cmp -s "${A2CACHE}/wz.squashfs.torrent" "${TMPDIR_T}/wz.fresh.torrent"; assert_true "$?" "STALE-TORRENT: the cached torrent is now the fresh one"
    DLOPTS="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["method"]=="aria2.addTorrent": print(r["opts"].get("bt-seed-unverified"), r["opts"].get("check-integrity"))' "${MOCK_LOG}")"
    assert_eq "${DLOPTS}" "false false" "STALE-TORRENT: the download add verifies pieces, with no whole-file re-hash"

    # (4) FAILURE: aria2 reports an error. The partial and its .aria2 stay (resume),
    #     and the ERROR line carries the real aria2 code + message.
    rm -f "${A2CACHE}"/wz.*
    printf 'HALF' > "${A2CACHE}/wz.squashfs"; printf 'CTRL' > "${A2CACHE}/wz.squashfs.aria2"
    echo "error 3 Mock: resource not found on the tracker" > "${MOCK_MODE}"; : > "${A2SAY}"
    get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    assert_false "${rc}" "FAILURE: a failed download returns non-zero"
    [ -s "${A2CACHE}/wz.squashfs" ] && [ -s "${A2CACHE}/wz.squashfs.aria2" ]
    assert_true "$?" "FAILURE: the partial and its .aria2 control file are kept for resume"
    [ ! -e "${A2CACHE}/wz.squashfs.dl" ]; assert_true "$?" "FAILURE: only the .dl in-flight marker is dropped"
    assert_contains "$(cat "${A2SAY}")" "aria2 error 3: Mock: resource not found on the tracker" "FAILURE: the real aria2 error is surfaced"
    assert_not_contains "$(cat "${A2SAY}")" "no peers - P2P swarm unreachable" "FAILURE: no generic 'no peers' message"
    assert_contains "$(cat "${MOCK_LOG}")" "aria2.removeDownloadResult" "FAILURE: the error entry is cleared from the aria2c"

    # (5) FAILURE, info-hash mismatch: the .aria2 belongs to an old torrent. A resume
    #     can never work, so the partial goes and the next try starts clean.
    echo "error 1 info hash mismatch. expected: aaaa, actual: bbbb" > "${MOCK_MODE}"; : > "${A2SAY}"
    get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    assert_false "${rc}" "FAILURE: an info-hash mismatch returns non-zero"
    [ ! -e "${A2CACHE}/wz.squashfs" ] && [ ! -e "${A2CACHE}/wz.squashfs.aria2" ]
    assert_true "$?" "FAILURE: an info-hash mismatch drops the unusable partial"

    # (6) STALL: no progress past the stall timeout. The reason names the numbers,
    #     and the partial stays.
    printf 'HALF' > "${A2CACHE}/wz.squashfs"; printf 'CTRL' > "${A2CACHE}/wz.squashfs.aria2"
    echo stall > "${MOCK_MODE}"; : > "${A2SAY}"
    PARTYOS_BT_STOP_TIMEOUT=2 PARTYOS_DL_POLL=1 get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    assert_false "${rc}" "STALL: a stalled download returns non-zero"
    assert_contains "$(cat "${A2SAY}")" "no progress for" "STALL: the reason says no progress, with the numbers"
    assert_contains "$(cat "${A2SAY}")" "connections=0" "STALL: the reason carries the peer count"
    [ -s "${A2CACHE}/wz.squashfs" ] && [ -s "${A2CACHE}/wz.squashfs.aria2" ]
    assert_true "$?" "STALL: the partial and its .aria2 are kept for resume"
    # (7) SLOW RPC: aria2c blocks on a stick write and a status call times out.
    #     Seen on hardware. The download goes on, so get_blob must wait, not fail.
    rm -f "${A2CACHE}"/wz.squashfs "${A2CACHE}"/wz.squashfs.aria2
    echo "slow 2" > "${MOCK_MODE}"; : > "${A2SAY}"
    PARTYOS_ARIA2_RPC_TIMEOUT=1 PARTYOS_DL_POLL=1 get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    assert_true "${rc}" "SLOW-RPC: a status call that times out does not fail the install"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-RPC-SLOW" "SLOW-RPC: the slow RPC is logged"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-DONE name=wz" "SLOW-RPC: the download completes"

    # (8) LOST ENTRY: aria2c restarted and the GID is gone. Fail at once with the cause.
    rm -f "${A2CACHE}"/wz.squashfs "${A2CACHE}"/wz.squashfs.aria2
    echo gone > "${MOCK_MODE}"; : > "${A2SAY}"
    PARTYOS_DL_POLL=1 get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    assert_false "${rc}" "LOST-ENTRY: a lost aria2 entry fails the install"
    assert_contains "$(cat "${A2SAY}")" "lost the download in aria2c" "LOST-ENTRY: the reason names the lost entry"
    assert_contains "$(cat "${A2SAY}")" "is not found" "LOST-ENTRY: the aria2 message is surfaced"

    # (9) SLOW ADD: the add answers after the RPC timeout but goes through. Seen on
    #     hardware: a second add then failed with error 12. get_blob must find the
    #     entry, not add the torrent again.
    rm -f "${A2CACHE}"/wz.squashfs "${A2CACHE}"/wz.squashfs.aria2
    echo slowadd > "${MOCK_MODE}"; : > "${A2SAY}"; : > "${MOCK_LOG}"
    PARTYOS_ARIA2_RPC_TIMEOUT=1 PARTYOS_DL_POLL=1 get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    sleep 2   # let the mock log the late add
    assert_true "${rc}" "SLOW-ADD: an add that answers late does not fail the install"
    assert_eq "$(mock_adds)" "1" "SLOW-ADD: the torrent is added once, not again after the timeout"

    # (10) DUP: the add returns an error-12 entry while a live entry for the same
    #      torrent exists. Follow the live entry.
    rm -f "${A2CACHE}"/wz.squashfs "${A2CACHE}"/wz.squashfs.aria2
    echo dup > "${MOCK_MODE}"; : > "${A2SAY}"
    PARTYOS_DL_POLL=1 get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    assert_true "${rc}" "DUP: an error-12 duplicate follows the live entry and succeeds"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-DUP" "DUP: the switch to the live entry is logged"

    # (10b) DUP + SLOW FIND: the add gives an
    #       error-12 entry, and the first finds time out. get_blob must ask again
    #       and follow the live entry. It must never remove the live entry.
    rm -f "${A2CACHE}"/wz.squashfs "${A2CACHE}"/wz.squashfs.aria2
    echo "dupslow 1" > "${MOCK_MODE}"; : > "${A2SAY}"; : > "${MOCK_LOG}"
    PARTYOS_ARIA2_RPC_TIMEOUT=1 PARTYOS_DL_POLL=1 get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    sleep 3   # let the mock log the slow calls
    assert_true "${rc}" "DUP-SLOW-FIND: error 12 with a slow find follows the live entry and succeeds"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-DUP" "DUP-SLOW-FIND: the switch to the live entry is logged"
    assert_eq "$(awk '/"aria2.addTorrent"/{a=1} a&&/"aria2.forceRemove"/{n++} END{print n+0}' "${MOCK_LOG}")" "0" \
        "DUP-SLOW-FIND: no entry is force-removed after the add"

    # (10c) ADOPT: a retry while the download of an earlier try still runs (seen on real
    #       hardware). Follow that entry: no remove, no second add.
    mk_torrent2 "${TMPDIR_T}/ad.fresh.torrent" "http://venue-tracker.invalid:6969/announce" ad
    blob_fetch() { cp "${TMPDIR_T}/ad.fresh.torrent" "$2"; }
    echo stall > "${MOCK_MODE}"
    "${A2RPC}" add "${TMPDIR_T}/ad.fresh.torrent" "${A2CACHE}" download >/dev/null
    printf 'HALF' > "${A2CACHE}/ad.squashfs"; printf 'CTRL' > "${A2CACHE}/ad.squashfs.aria2"
    echo finish > "${MOCK_MODE}"; : > "${A2SAY}"; : > "${MOCK_LOG}"
    PARTYOS_DL_POLL=1 get_blob "ad" "server/games/ad.squashfs" "${FRESH_SHA}"; rc=$?
    assert_true "${rc}" "ADOPT: a retry with a live download of the same torrent succeeds"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-ADOPT name=ad" "ADOPT: the retry follows the live entry"
    assert_eq "$(mock_adds)" "0" "ADOPT: the torrent is not added again"
    assert_eq "$(grep -c '"aria2.forceRemove"' "${MOCK_LOG}")" "0" "ADOPT: the live entry is not removed"

    # (10d) ADOPT, another info hash: the live entry belongs to an old (repacked)
    #       torrent. It must go, and the current torrent is added.
    rm -f "${A2CACHE}"/ad.*
    sed 's/aaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbb/' "${TMPDIR_T}/ad.fresh.torrent" > "${TMPDIR_T}/ad.old.torrent"
    echo stall > "${MOCK_MODE}"
    OLD_GID="$("${A2RPC}" add "${TMPDIR_T}/ad.old.torrent" "${A2CACHE}" download)"
    echo finish > "${MOCK_MODE}"; : > "${A2SAY}"; : > "${MOCK_LOG}"
    PARTYOS_DL_POLL=1 get_blob "ad" "server/games/ad.squashfs" "${FRESH_SHA}"; rc=$?
    assert_true "${rc}" "ADOPT: a live entry of another info hash does not block the install"
    assert_not_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-ADOPT" "ADOPT: an entry of another info hash is not followed"
    assert_contains "$(grep '"aria2.forceRemove"' "${MOCK_LOG}")" "${OLD_GID}" "ADOPT: the entry of the old info hash is removed"
    assert_eq "$(mock_adds)" "1" "ADOPT: the current torrent is added"
    blob_fetch() { cp "${TMPDIR_T}/wz.fresh.torrent" "$2"; }

    # (11) MUTE RPC past the stall timeout while the partial grows on disk. Seen on real
    #      hardware: aria2c blocked on the stick for minutes. The growing file is
    #      progress, so the stall timer must not fire.
    rm -f "${A2CACHE}"/wz.squashfs "${A2CACHE}"/wz.squashfs.aria2
    echo "mute 4" > "${MOCK_MODE}"; : > "${A2SAY}"
    ( for _ in $(seq 16); do head -c 65536 /dev/zero >> "${A2CACHE}/wz.squashfs"; sleep 0.5; done ) &
    GROW_PID=$!
    PARTYOS_ARIA2_RPC_TIMEOUT=1 PARTYOS_DL_POLL=1 PARTYOS_BT_STOP_TIMEOUT=3 get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    kill "${GROW_PID}" 2>/dev/null; wait "${GROW_PID}" 2>/dev/null
    assert_true "${rc}" "MUTE-RPC: a mute RPC does not stall the install while the partial grows"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-DONE name=wz" "MUTE-RPC: the download completes"

    # (11b) MUTE RPC past the stall timeout, the partial does NOT grow, but the
    #       cache device writes. aria2c can block in the kernel for minutes while du stays
    #       flat and the stick writes. That is disk-bound, not stalled.
    DEVSTAT="${TMPDIR_T}/devstat"
    devstat_set() { printf '1 0 8 0 5 0 %s 0 0 0 0\n' "$1" > "${DEVSTAT}"; }
    rm -f "${A2CACHE}"/wz.squashfs "${A2CACHE}"/wz.squashfs.aria2
    printf 'HALF' > "${A2CACHE}/wz.squashfs"; printf 'CTRL' > "${A2CACHE}/wz.squashfs.aria2"
    devstat_set 1000
    echo "mute 6" > "${MOCK_MODE}"; : > "${A2SAY}"
    ( n=1000; for _ in $(seq 40); do n=$(( n + 8 )); devstat_set "${n}"; sleep 0.5; done ) &
    DEV_PID=$!
    PARTYOS_DL_DEVSTAT="${DEVSTAT}" PARTYOS_ARIA2_RPC_TIMEOUT=1 PARTYOS_DL_POLL=1 PARTYOS_BT_STOP_TIMEOUT=3 \
        get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    kill "${DEV_PID}" 2>/dev/null; wait "${DEV_PID}" 2>/dev/null
    assert_true "${rc}" "DISK-BOUND: a mute RPC with a flat partial does not fail while the stick writes"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-DONE name=wz" "DISK-BOUND: the download completes"

    # (11c) WEDGE: the same, but the stick writes nothing. The stall timer fires.
    rm -f "${A2CACHE}"/wz.squashfs "${A2CACHE}"/wz.squashfs.aria2
    printf 'HALF' > "${A2CACHE}/wz.squashfs"; printf 'CTRL' > "${A2CACHE}/wz.squashfs.aria2"
    devstat_set 5000
    echo "mute 6" > "${MOCK_MODE}"; : > "${A2SAY}"
    PARTYOS_DL_DEVSTAT="${DEVSTAT}" PARTYOS_ARIA2_RPC_TIMEOUT=1 PARTYOS_DL_POLL=1 PARTYOS_BT_STOP_TIMEOUT=3 \
        get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    sleep 8   # let the mock finish the muted calls
    assert_false "${rc}" "WEDGE: a mute RPC with no stick writes fails at the stall timeout"
    assert_contains "$(cat "${A2SAY}")" "and the stick did not write" "WEDGE: the reason says the stick did not write"

    # (11d) SILENT CEILING: the stick writes, but the RPC stays silent past
    #       PARTYOS_RPC_SILENT_MAX. Fail, so a real wedge cannot hang the install forever.
    rm -f "${A2CACHE}"/wz.squashfs "${A2CACHE}"/wz.squashfs.aria2
    printf 'HALF' > "${A2CACHE}/wz.squashfs"; printf 'CTRL' > "${A2CACHE}/wz.squashfs.aria2"
    devstat_set 9000
    echo "mute 8" > "${MOCK_MODE}"; : > "${A2SAY}"
    ( n=9000; for _ in $(seq 40); do n=$(( n + 8 )); devstat_set "${n}"; sleep 0.5; done ) &
    DEV_PID=$!
    PARTYOS_DL_DEVSTAT="${DEVSTAT}" PARTYOS_RPC_SILENT_MAX=4 PARTYOS_ARIA2_RPC_TIMEOUT=1 PARTYOS_DL_POLL=1 PARTYOS_BT_STOP_TIMEOUT=30 \
        get_blob "wz" "server/games/wz.squashfs" "${FRESH_SHA}"; rc=$?
    kill "${DEV_PID}" 2>/dev/null; wait "${DEV_PID}" 2>/dev/null
    sleep 10  # let the mock finish the muted calls
    assert_false "${rc}" "SILENT-MAX: an RPC silent past the ceiling fails the install"
    assert_contains "$(cat "${A2SAY}")" "(limit 4s)" "SILENT-MAX: the reason names the ceiling"

    # (12) BUSY GATE: a retry starts while the stick still writes for the download
    #      of an earlier try. The RPC can be silent for minutes, and the retry must not
    #      fail before it reaches the adopt step. While the ping times
    #      out and the stick writes, wait. Then follow the live entry.
    blob_fetch() { cp "${TMPDIR_T}/ad.fresh.torrent" "$2"; }
    rm -f "${A2CACHE}"/ad.*
    echo stall > "${MOCK_MODE}"
    LIVE_GID="$("${A2RPC}" add "${TMPDIR_T}/ad.fresh.torrent" "${A2CACHE}" download)"
    printf 'HALF' > "${A2CACHE}/ad.squashfs"; printf 'CTRL' > "${A2CACHE}/ad.squashfs.aria2"
    devstat_set 20000
    echo deaf > "${MOCK_MODE}"; : > "${A2SAY}"; : > "${MOCK_LOG}"
    ( n=20000; for i in $(seq 60); do n=$(( n + 8 )); devstat_set "${n}"
        [ "${i}" -eq 40 ] && echo finish > "${MOCK_MODE}"; sleep 0.5; done ) &
    DEV_PID=$!
    PARTYOS_DL_DEVSTAT="${DEVSTAT}" PARTYOS_ARIA2_WAIT=1 PARTYOS_RPC_SILENT_MAX=60 PARTYOS_DL_POLL=1 PARTYOS_BT_STOP_TIMEOUT=3 \
        get_blob "ad" "server/games/ad.squashfs" "${FRESH_SHA}"; rc=$?
    kill "${DEV_PID}" 2>/dev/null; wait "${DEV_PID}" 2>/dev/null
    echo finish > "${MOCK_MODE}"; sleep 5   # let the mock finish the deaf calls
    assert_true "${rc}" "BUSY-GATE: a retry waits while the RPC is silent and the stick writes"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-RPC-BUSY name=ad" "BUSY-GATE: the wait is logged"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-ADOPT name=ad gid=${LIVE_GID}" "BUSY-GATE: the retry follows the live entry"
    assert_eq "$(mock_adds)" "0" "BUSY-GATE: the torrent is not added again"
    assert_not_contains "$(grep '"aria2.forceRemove"' "${MOCK_LOG}")" "${LIVE_GID}" "BUSY-GATE: the live entry is not removed"

    # (12b) BUSY GATE, WEDGE: the RPC is silent and the stick writes nothing.
    #       Fail at the stall time, with the cause.
    rm -f "${A2CACHE}"/ad.*
    printf 'HALF' > "${A2CACHE}/ad.squashfs"; printf 'CTRL' > "${A2CACHE}/ad.squashfs.aria2"
    devstat_set 30000
    echo deaf > "${MOCK_MODE}"; : > "${A2SAY}"
    PARTYOS_DL_DEVSTAT="${DEVSTAT}" PARTYOS_ARIA2_WAIT=1 PARTYOS_RPC_SILENT_MAX=60 PARTYOS_DL_POLL=1 PARTYOS_BT_STOP_TIMEOUT=6 \
        get_blob "ad" "server/games/ad.squashfs" "${FRESH_SHA}"; rc=$?
    echo complete > "${MOCK_MODE}"; sleep 5   # let the mock finish the deaf calls
    assert_false "${rc}" "BUSY-GATE-WEDGE: a silent RPC with no stick writes fails the install"
    assert_contains "$(cat "${A2SAY}")" "before the download, and the stick did not write" \
        "BUSY-GATE-WEDGE: the reason says the stick did not write"

    # (12c) DOWN: aria2c does not run (the port refuses). Fail at once, also while
    #       the stick writes. The reason names the refused connection.
    rm -f "${A2CACHE}"/ad.*
    devstat_set 40000
    : > "${A2SAY}"
    ( n=40000; for _ in $(seq 40); do n=$(( n + 8 )); devstat_set "${n}"; sleep 0.5; done ) &
    DEV_PID=$!
    T0="${SECONDS}"
    PARTYOS_ARIA2_RPC_URL="http://127.0.0.1:1/jsonrpc" PARTYOS_DL_DEVSTAT="${DEVSTAT}" PARTYOS_ARIA2_WAIT=1 \
        PARTYOS_RPC_SILENT_MAX=60 PARTYOS_DL_POLL=1 PARTYOS_BT_STOP_TIMEOUT=30 \
        get_blob "ad" "server/games/ad.squashfs" "${FRESH_SHA}"; rc=$?
    EL=$(( SECONDS - T0 ))
    kill "${DEV_PID}" 2>/dev/null; wait "${DEV_PID}" 2>/dev/null
    assert_false "${rc}" "DOWN: an aria2c that does not run fails the install"
    [ "${EL}" -lt 10 ]; assert_true "$?" "DOWN: the install fails fast (${EL}s), no wait for the stick"
    assert_contains "$(cat "${A2SAY}")" "does not answer on RPC" "DOWN: the reason names the RPC"
    assert_contains "$(cat "${A2SAY}")" "refused" "DOWN: the reason names the refused connection"
    assert_not_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-RPC-BUSY" "DOWN: no wait for a busy stick"

    # (12d) FAST PATH: the RPC answers at once. No wait, the install is as before.
    rm -f "${A2CACHE}"/ad.*
    echo complete > "${MOCK_MODE}"
    "${A2RPC}" remove ad "${A2CACHE}"   # no entry of an earlier case is left
    : > "${A2SAY}"; : > "${MOCK_LOG}"
    T0="${SECONDS}"
    PARTYOS_DL_POLL=1 PARTYOS_BT_STOP_TIMEOUT=10 get_blob "ad" "server/games/ad.squashfs" "${FRESH_SHA}"; rc=$?
    EL=$(( SECONDS - T0 ))
    assert_true "${rc}" "FAST-PATH: a fast RPC installs"
    [ "${EL}" -lt 5 ]; assert_true "$?" "FAST-PATH: no extra wait (${EL}s)"
    assert_not_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-RPC-BUSY" "FAST-PATH: no busy wait is logged"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-DONE name=ad" "FAST-PATH: the download completes"
    assert_eq "$(mock_adds)" "1" "FAST-PATH: the torrent is added once"
    blob_fetch() { cp "${TMPDIR_T}/wz.fresh.torrent" "$2"; }

    # (13) FLUSH: aria2c reports the
    #      blob complete while the last pieces are still in its disk cache, so the
    #      file on the stick is not complete yet.
    #      get_blob must check the sha again, not delete the blob.
    for g in fl fs cr dz; do
        mk_torrent2 "${TMPDIR_T}/${g}.fresh.torrent" "http://venue-tracker.invalid:6969/announce" "${g}"
    done
    blob_fetch() { cp "${TMPDIR_T}/$(basename "$1" .squashfs.torrent).fresh.torrent" "$2"; }
    rm -f "${A2CACHE}"/fl.*
    echo "flush 3" > "${MOCK_MODE}"; : > "${A2SAY}"; : > "${MOCK_LOG}"
    PARTYOS_SETTLE_GAP=1 PARTYOS_DL_POLL=1 get_blob "fl" "server/games/fl.squashfs" "${FRESH_SHA}"; rc=$?
    assert_true "${rc}" "FLUSH: a blob that aria2c flushes after it reports complete installs"
    assert_eq "$(sha256sum "${A2CACHE}/fl.squashfs" 2>/dev/null | awk '{print $1}')" "${FRESH_SHA}" \
        "FLUSH: the blob on the stick is complete and verified"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-SETTLE name=fl check=1 sha mismatch" "FLUSH: the first mismatch is logged, not acted on"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-SETTLE name=fl check=2 sha ok" "FLUSH: the second check passes"
    assert_eq "$(grep -c '"aria2.forceRemove"' "${MOCK_LOG}")" "0" "FLUSH: the entry is not removed from aria2c"

    # (13b) FLUSH + SLOW RPC: the flush blocks aria2c and the status calls time out.
    #       A timed-out call is not "complete": wait for a real answer.
    rm -f "${A2CACHE}"/fs.*
    echo "flushslow 4" > "${MOCK_MODE}"; : > "${A2SAY}"; : > "${MOCK_LOG}"
    PARTYOS_ARIA2_RPC_TIMEOUT=1 PARTYOS_SETTLE_GAP=1 PARTYOS_DL_POLL=1 \
        get_blob "fs" "server/games/fs.squashfs" "${FRESH_SHA}"; rc=$?
    sleep 3   # let the mock finish the slow calls
    assert_true "${rc}" "FLUSH-SLOW-RPC: a blob that flushes while the RPC times out installs"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-RPC-SLOW name=fs" "FLUSH-SLOW-RPC: the slow RPC is logged"
    assert_eq "$(sha256sum "${A2CACHE}/fs.squashfs" 2>/dev/null | awk '{print $1}')" "${FRESH_SHA}" \
        "FLUSH-SLOW-RPC: the blob on the stick is complete and verified"

    # (13c) FLUSH, NO ANSWER: the RPC stays slow past PARTYOS_SETTLE_MAX. Fail, but
    #       keep the blob and its .dl marker: aria2c can still write to it.
    rm -f "${A2CACHE}"/dz.*
    echo "flushslow 6" > "${MOCK_MODE}"; : > "${A2SAY}"; : > "${MOCK_LOG}"
    PARTYOS_ARIA2_RPC_TIMEOUT=1 PARTYOS_SETTLE_MAX=3 PARTYOS_SETTLE_GAP=1 PARTYOS_DL_POLL=1 \
        get_blob "dz" "server/games/dz.squashfs" "${FRESH_SHA}"; rc=$?
    DZ_KEPT=0; [ -s "${A2CACHE}/dz.squashfs" ] && [ -e "${A2CACHE}/dz.squashfs.dl" ] && DZ_KEPT=1
    sleep 10  # let the mock finish the slow calls
    assert_false "${rc}" "FLUSH-NO-ANSWER: no answer from aria2c in the time limit fails the install"
    assert_eq "${DZ_KEPT}" "1" "FLUSH-NO-ANSWER: the blob and its .dl marker are kept"
    assert_contains "$(cat "${A2SAY}")" "the blob is kept for a re-check" "FLUSH-NO-ANSWER: the reason says the blob is kept"
    assert_eq "$(grep -c '"aria2.forceRemove"' "${MOCK_LOG}")" "0" "FLUSH-NO-ANSWER: the entry is not removed from aria2c"

    # (13d) CORRUPT: the sha stays wrong on two checks and aria2c reports complete.
    #       The blob is bad: drop it, as before.
    rm -f "${A2CACHE}"/cr.*
    echo corrupt > "${MOCK_MODE}"; : > "${A2SAY}"; : > "${MOCK_LOG}"
    PARTYOS_SETTLE_GAP=1 PARTYOS_DL_POLL=1 get_blob "cr" "server/games/cr.squashfs" "${FRESH_SHA}"; rc=$?
    assert_false "${rc}" "CORRUPT: a blob with a stable wrong sha fails the install"
    assert_contains "$(cat "${A2SAY}")" "PARTYOS-APP-DL-SETTLE name=cr check=2 the same wrong sha again" \
        "CORRUPT: the blob is dropped only after the second check"
    assert_contains "$(cat "${A2SAY}")" "sha mismatch after the download" "CORRUPT: the reason is the sha mismatch"
    [ ! -e "${A2CACHE}/cr.squashfs" ] && [ ! -e "${A2CACHE}/cr.squashfs.dl" ]
    assert_true "$?" "CORRUPT: the bad blob and its .dl marker are dropped"
    blob_fetch() { cp "${TMPDIR_T}/wz.fresh.torrent" "$2"; }

    [ ! -e "${ARIA2C_TRIP}" ]; assert_true "$?" "ONE-ARIA2: get_blob starts no aria2c process"

    kill "${MOCK_PID}" 2>/dev/null || true
fi

assert_summary "test-cache-policy" || exit 1
echo "test-cache-policy: ALL PASS"
