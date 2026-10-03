#!/usr/bin/env bash
# test-blob-failover.sh - hardware-FREE unit test for the BAKED partyos-app blob
# failover logic. The image bakes partyos-app from
# scripts/build/files/rootfs/usr/local/bin/partyos-app. This test sed/awk-extracts
# the blob_bases + BLOB_BASES split + blob_fetch functions from that file into a
# temp file, sources it, and unit-tests them
# with a MOCKED fetch (no network, no curl, no VM, no hardware).
#
# Asserts (ordered blob failover):
#   * blob_bases parses blob_urls=a,b,c (from a fake /proc/cmdline) into the ordered list,
#   * falls back to blob_url= (legacy singular), then to report_url= (SERVER_BASE),
#   * the BLOB_BASES array is split in order, BLOB_BASE = first base,
#   * blob_fetch tries bases IN ORDER and fails over past a dead base to a live one,
#   * a single-element list behaves exactly like one fetch (loop runs once, no failover).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

PAPP="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-app"
[ -f "${PAPP}" ] || { echo "FAIL: partyos-app baked file not found at ${PAPP}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-blobtest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- point at the baked partyos-app, then carve out just the blob functions ---
PAPP_BODY="${PAPP}"
[ -s "${PAPP_BODY}" ] || { echo "FAIL: partyos-app baked file is empty (${PAPP_BODY})"; exit 1; }

# 2. carve out ONLY the things we test (blob_bases, the BLOB_BASES split + BLOB_BASE,
#    and blob_fetch) so we don't drag in the top-level sudo re-exec / server_base /
#    mkdir side-effects. We slice from the blob_bases() definition to the end of
#    blob_fetch() (the closing `}` after the blob_fetch loop), then add the standalone
#    BLOB_BASES/BLOB_BASE assignment lines that sit between them. blob_fetch also calls
#    $(cacert_args "${base}") per base (pins the partyOS CA on https bases), so cacert_args
#    is a real dependency of the carve - grab it too or the sourced fixture errors
#    "cacert_args: command not found" on stderr every fetch. It sits above blob_bases in
#    the heredoc, so carve it as its own block (its PARTYOS_CA= path down to its `}`).
BLOBLIB="${TMPDIR_T}/bloblib.sh"
awk '
    /^PARTYOS_CA=/ {grabc=1}
    grabc {print}
    grabc && /^\}/ {grabc=0}
    /^blob_bases\(\) \{/ {grab=1}
    grab {print}
    # stop after blob_fetch closes: blob_fetch is the last function we need; its body
    # ends at the first lone "}" at column 0 AFTER we have entered blob_fetch.
    /^blob_fetch\(\) \{/ {inbf=1}
    inbf && /^\}/ {grab=0; inbf=0}
' "${PAPP_BODY}" > "${BLOBLIB}"
[ -s "${BLOBLIB}" ] || { echo "FAIL: could not carve blob functions out of PAPP"; exit 1; }

# sanity: the carve must contain all three pieces
grep -q '^blob_bases() {' "${BLOBLIB}"               || { echo "FAIL: blob_bases not in carve"; exit 1; }
grep -q 'IFS=.,. read -r -a BLOB_BASES' "${BLOBLIB}" || { echo "FAIL: BLOB_BASES split not in carve"; exit 1; }
grep -q '^blob_fetch() {' "${BLOBLIB}"               || { echo "FAIL: blob_fetch not in carve"; exit 1; }
grep -q '^cacert_args() {' "${BLOBLIB}"              || { echo "FAIL: cacert_args (blob_fetch dep) not in carve"; exit 1; }

# --- harness: a controllable /proc/cmdline + a mocked curl + a say stub --------
# The carved code reads /proc/cmdline via `cat /proc/cmdline`; we shadow cat with a
# function that prints our fake cmdline. curl is mocked to succeed only for bases on
# an allow-list (CURL_LIVE), recording every base it was asked for in CURL_TRIED.
FAKE_CMDLINE=""
cat() { if [ "$1" = "/proc/cmdline" ]; then printf '%s\n' "${FAKE_CMDLINE}"; else command cat "$@"; fi; }
say() { :; }                 # silence the marker output during unit test
SERVER_BASE="http://report.example:8080"   # the report_url= fallback (single-box)

# Mock curl: the carved blob_fetch calls `curl -fsS "$@" -o OUT "BASE/REL"`, so the URL
# is the LAST positional. REL contains slashes (e.g. server/games/catalog.json), so we
# identify the base by PREFIX-matching the URL against the known base list (CURL_BASES).
# It "succeeds" (writes OUT, rc 0) only when the matched base is in CURL_LIVE; else rc 22.
CURL_LIVE=""        # space-separated list of LIVE base-URLs
CURL_BASES=""       # space-separated list of ALL base-URLs in play (for prefix match)
CURL_TRIED=""       # the bases curl was invoked for, in order
curl() {
    local url="" out="" prev="" a
    for a in "$@"; do
        case "${prev}" in -o) out="${a}";; esac
        url="${a}"; prev="${a}"
    done
    # identify which configured base this URL belongs to (longest prefix wins).
    local base="" b
    for b in ${CURL_BASES}; do
        case "${url}" in "${b}/"*) [ "${#b}" -gt "${#base}" ] && base="${b}";; esac
    done
    [ -n "${base}" ] || base="${url}"   # fallback: whole URL (shouldn't happen)
    CURL_TRIED="${CURL_TRIED}${CURL_TRIED:+ }${base}"
    case " ${CURL_LIVE} " in
        *" ${base} "*) [ -n "${out}" ] && : > "${out}"; return 0;;
        *) return 22;;
    esac
}

# load_bloblib FAKE_CMDLINE - re-source the carve under a given fake cmdline so the
# top-level BLOB_BASES split re-runs against it. Resets the mock trackers.
load_bloblib() {
    FAKE_CMDLINE="$1"
    CURL_TRIED=""
    BLOB_WON=""; BLOB_DID_FAILOVER=0
    # shellcheck disable=SC1090
    source "${BLOBLIB}"
}

echo "================ blob_bases parsing ==========================="

# 1. blob_urls= ordered list wins
load_bloblib "BOOT_IMAGE=x blob_urls=http://a:1,http://b:2,http://c:3 quiet"
assert_eq "$(blob_bases)" "http://a:1,http://b:2,http://c:3" "blob_bases: blob_urls= parsed verbatim (ordered)"
assert_eq "${BLOB_BASES[0]}" "http://a:1" "BLOB_BASES[0] = first base"
assert_eq "${BLOB_BASES[1]}" "http://b:2" "BLOB_BASES[1] = second base"
assert_eq "${BLOB_BASES[2]}" "http://c:3" "BLOB_BASES[2] = third base"
assert_eq "${#BLOB_BASES[@]}" "3"          "BLOB_BASES has 3 elements"
assert_eq "${BLOB_BASE}" "http://a:1"      "BLOB_BASE = first base"

# 2. fall back to blob_url= (legacy singular) when blob_urls= absent
load_bloblib "BOOT_IMAGE=x blob_url=http://legacy:9 quiet"
assert_eq "$(blob_bases)" "http://legacy:9" "blob_bases: falls back to blob_url= (legacy)"
assert_eq "${#BLOB_BASES[@]}" "1"           "legacy blob_url= -> 1-element list"

# 3. fall back to report_url= (SERVER_BASE) when neither blob param present (single-box)
load_bloblib "BOOT_IMAGE=x report_url=${SERVER_BASE} quiet"
assert_eq "$(blob_bases)" "${SERVER_BASE}"  "blob_bases: falls back to SERVER_BASE (single-box)"
assert_eq "${#BLOB_BASES[@]}" "1"           "single-box -> 1-element list (= report server)"

# 3b. PRECEDENCE: render.sh emits BOTH blob_urls= AND blob_url= together (the
# list + the back-compat singular). The canonical ordered LIST must WIN - if a
# precedence flip made the singular win, a split deploy would silently lose its
# failover list. Both present on the SAME cmdline:
load_bloblib "blob_urls=http://a:1,http://b:2 blob_url=http://a:1 report_url=${SERVER_BASE}"
assert_eq "$(blob_bases)" "http://a:1,http://b:2" "blob_bases: blob_urls= WINS over blob_url= when both present"
assert_eq "${#BLOB_BASES[@]}" "2"                  "both-present -> the 2-element list, not the singular"

echo
echo "================ blob_fetch failover order ===================="

# 4. failover: first base dead, second live -> tries A then B, wins on B
load_bloblib "blob_urls=http://dead-a:1,http://live-b:2"
CURL_BASES="http://dead-a:1 http://live-b:2"
CURL_LIVE="http://live-b:2"
blob_fetch "server/games/catalog.json" "${TMPDIR_T}/out1"
rc=$?
assert_true "${rc}" "blob_fetch succeeds when a later base is live"
assert_eq "${CURL_TRIED}" "http://dead-a:1 http://live-b:2" "blob_fetch tried A then B in order (failover)"
assert_eq "${BLOB_WON}" "http://live-b:2" "blob_fetch reports the winning base"
assert_eq "${BLOB_DID_FAILOVER}" "1"      "blob_fetch flags BLOB_DID_FAILOVER on a skip"

# 5. first base live -> stops immediately, no failover, no second attempt
load_bloblib "blob_urls=http://live-a:1,http://live-b:2"
CURL_BASES="http://live-a:1 http://live-b:2"
CURL_LIVE="http://live-a:1 http://live-b:2"
blob_fetch "server/games/catalog.json" "${TMPDIR_T}/out2"
assert_eq "${CURL_TRIED}" "http://live-a:1" "blob_fetch stops at first live base (no needless failover)"
assert_eq "${BLOB_WON}" "http://live-a:1"   "blob_fetch wins on the first base"
assert_eq "${BLOB_DID_FAILOVER}" "0"        "no failover flag when first base answers"

# 6. single-element list behaves exactly like one fetch (loop runs once)
load_bloblib "blob_url=http://only:1"
CURL_BASES="http://only:1"
CURL_LIVE="http://only:1"
blob_fetch "x/y" "${TMPDIR_T}/out3"
assert_eq "${CURL_TRIED}" "http://only:1" "single-element list = exactly one fetch attempt"
assert_eq "${BLOB_WON}" "http://only:1"   "single-element list wins on its only base"

# 7. ALL bases dead -> blob_fetch returns non-zero (no base answered)
load_bloblib "blob_urls=http://dead-a:1,http://dead-b:2"
CURL_BASES="http://dead-a:1 http://dead-b:2"
CURL_LIVE=""
blob_fetch "x/y" "${TMPDIR_T}/out4"; rc=$?
assert_false "${rc}" "blob_fetch returns non-zero when ALL bases are dead"
assert_eq "${CURL_TRIED}" "http://dead-a:1 http://dead-b:2" "blob_fetch exhausts every base before failing"

echo
echo "================ cacert_args dep resolves (no stray stderr) ==="
# REGRESSION GUARD: blob_fetch calls $(cacert_args "${base}") per base to pin the partyOS
# CA on https bases. cacert_args is a real function in the heredoc; if the carve ever drops
# it again (or the real code invokes an undefined helper as a bare command), the fetch
# prints "<file>: line N: cacert_args: command not found" on stderr while the mocked curl
# still lets the asserts pass - stderr grit that hid here before. cacert_args must be a
# defined function (no CA flag for an http base), and a real fetch's stderr must be clean.
load_bloblib "blob_urls=http://dead-a:1,http://live-b:2"
CURL_BASES="http://dead-a:1 http://live-b:2"
CURL_LIVE="http://live-b:2"
assert_eq "$(cacert_args http://x:1)" "" "cacert_args() is defined and adds no CA flag for an http base"
BF_ERR="$(blob_fetch "server/games/catalog.json" "${TMPDIR_T}/out5" 2>&1 >/dev/null)"
assert_not_contains "${BF_ERR}" "command not found" "blob_fetch stderr is clean (cacert_args dependency resolves)"

assert_summary "test-blob-failover" || exit 1
echo "test-blob-failover: ALL PASS"
