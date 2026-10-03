#!/usr/bin/env bash
# test-personal-site.sh - hardware-FREE unit/integration test for the auto-hosted
# personal-site feature: a guest drops an .html file into the server's site docroot
# and it is served over the LAN at http://<server>/sites/<file>, while the route
# stays STRICTLY scoped so it can never reach outside that dir (no CA key, no certs,
# no configs). No VM, no real hardware -
# a loopback http_server.py + curl only. Two halves:
#
#   1. SERVE   - drop files into a temp site docroot (via PARTYOS_SITES_DIR), start
#      the REAL http_server.py HTTP-only, and prove a dropped index.html, a dropped
#      page are each served 200 with the right body, and a directory with no
#      index.html is a 404 (no listing).
#   2. SCOPE   - prove every escape attempt is REJECTED (403/404), never the file:
#        - `..` traversal to a repo file (server/http_server.py)
#        - `..` traversal to a SIBLING secret placed OUTSIDE the site dir
#        - percent-encoded `%2e%2e` traversal (decoded before the check)
#        - an escaping SYMLINK inside the site dir pointing at the sibling secret
#      Traversal requests use `curl --path-as-is` so the literal `..` reaches the
#      server (curl otherwise collapses `..` client-side and the route never sees it).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

SERVER="${REPO_ROOT}/server/http_server.py"
[ -f "${SERVER}" ] || { echo "FAIL: http_server.py not found at ${SERVER}"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not in PATH"; exit 1; }
curl --path-as-is -sS -o /dev/null file:///dev/null 2>/dev/null \
    || { echo "FAIL: this curl lacks --path-as-is (needed to send literal ../)"; exit 1; }

# Everything runs against a THROWAWAY temp tree; the site docroot is pointed there
# via PARTYOS_SITES_DIR so the test never touches the real server/sites/.
TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-sitetest.XXXXXX")"
SRV_PID=""
cleanup() {
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    rm -rf "${TMPDIR_T}"
}
trap cleanup EXIT

SITES="${TMPDIR_T}/sites"
install -d "${SITES}/gallery"
INDEX_BODY="HELLO-FROM-A-GUEST-SITE"
PAGE_BODY="A-SECOND-DROPPED-PAGE"
printf '%s\n' "${INDEX_BODY}" > "${SITES}/index.html"
printf '%s\n' "${PAGE_BODY}"  > "${SITES}/page.html"
printf 'x\n'                  > "${SITES}/gallery/a.html"   # subdir, NO index -> 404
# A secret placed OUTSIDE the site dir (a stand-in for ca/partyos-ca.key). A correct
# scope must NEVER hand this out via a `..` climb or an escaping symlink.
SECRET_MARKER="TOPSECRET-CA-PRIVATE-KEY-DO-NOT-LEAK"
printf '%s\n' "${SECRET_MARKER}" > "${TMPDIR_T}/secret.key"
ln -s "${TMPDIR_T}/secret.key" "${SITES}/escape"           # escaping symlink

HTTP_PORT=$(( (RANDOM % 2000) + 26080 ))

# Start the REAL server HTTP-only (PARTYOS_NO_HTTPS=1 -> no cert needed), docroot
# pointed at our temp site dir.
PARTYOS_NO_HTTPS=1 PARTYOS_SITES_DIR="${SITES}" \
    python3 -u "${SERVER}" "${HTTP_PORT}" 127.0.0.1 > "${TMPDIR_T}/srv.log" 2>&1 &
SRV_PID=$!

# Wait for the HTTP listener (bounded ~5s).
up=0
for _ in $(seq 1 50); do
    if curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/report?step=probe" 2>/dev/null; then
        up=1; break
    fi
    sleep 0.1
done
assert_true "$([ "${up}" = 1 ]; echo $?)" "http_server.py HTTP listener came up on :${HTTP_PORT}"

BASE="http://127.0.0.1:${HTTP_PORT}"

# ============================================================================
echo "================ 1. serve dropped guest content ================"
# ----------------------------------------------------------------------------
# A dropped index.html is served at /sites/ (200 + its body).
codeI="$(curl -sS -o "${TMPDIR_T}/i.html" -w '%{http_code}' "${BASE}/sites/" 2>/dev/null)"
assert_eq "${codeI}" "200" "GET /sites/ -> 200 (drops index.html serves)"
assert_contains "$(cat "${TMPDIR_T}/i.html" 2>/dev/null)" "${INDEX_BODY}" "/sites/ body is the dropped index.html"

# The same file by explicit name.
codeIN="$(curl -sS -o "${TMPDIR_T}/in.html" -w '%{http_code}' "${BASE}/sites/index.html" 2>/dev/null)"
assert_eq "${codeIN}" "200" "GET /sites/index.html -> 200"
assert_contains "$(cat "${TMPDIR_T}/in.html" 2>/dev/null)" "${INDEX_BODY}" "/sites/index.html body matches"

# A second dropped page is reachable by its name (the "drop a file, it's served" path).
codeP="$(curl -sS -o "${TMPDIR_T}/p.html" -w '%{http_code}' "${BASE}/sites/page.html" 2>/dev/null)"
assert_eq "${codeP}" "200" "GET /sites/page.html -> 200 (a dropped file is served)"
assert_contains "$(cat "${TMPDIR_T}/p.html" 2>/dev/null)" "${PAGE_BODY}" "/sites/page.html body matches"

# A subdir with no index.html is a 404: there are no directory listings.
codeL="$(curl -sS -o "${TMPDIR_T}/l.html" -w '%{http_code}' "${BASE}/sites/gallery/" 2>/dev/null)"
assert_eq "${codeL}" "404" "GET /sites/gallery/ -> 404 (no directory listing)"
assert_not_contains "$(cat "${TMPDIR_T}/l.html" 2>/dev/null)" "a.html" "the 404 body does not name the file"

# A missing file under the (valid) docroot is a clean 404, not a 200/500.
code404="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/sites/nope.html" 2>/dev/null)"
assert_eq "${code404}" "404" "GET /sites/nope.html -> 404 (missing file, inside scope)"

# ============================================================================
echo
echo "================ 2. scope: traversal + symlink escape REJECTED ="
# ----------------------------------------------------------------------------
# assert_rejected LABEL URL  - GET URL with --path-as-is; PASS iff the code is
# 403/404 (NOT 200) AND the response body does NOT contain the secret marker.
assert_rejected() {
    local label="$1" url="$2" out="${TMPDIR_T}/rej.out" code
    code="$(curl -sS --path-as-is -o "${out}" -w '%{http_code}' "${url}" 2>/dev/null)"
    case "${code}" in
        403|404) _assert_ok "${label} -> rejected (${code})";;
        *)       _assert_bad "${label} -> NOT rejected (got ${code}, expected 403/404)";;
    esac
    assert_not_contains "$(cat "${out}" 2>/dev/null)" "${SECRET_MARKER}" "${label} -> secret NOT leaked in body"
}

# `..` climb to a real repo source file (the exact case named in the feature spec).
assert_rejected "traversal /sites/../../server/http_server.py" \
    "${BASE}/sites/../../server/http_server.py"
# Prove that same request body never contains this file's own handler symbol.
codeT1="$(curl -sS --path-as-is -o "${TMPDIR_T}/t1.out" -w '%{http_code}' \
    "${BASE}/sites/../../server/http_server.py" 2>/dev/null)"
assert_not_contains "$(cat "${TMPDIR_T}/t1.out" 2>/dev/null)" "PartyOSHTTPHandler" \
    "traversal to http_server.py did not leak the server source"

# `..` climb to the CA-key path (resolves outside the docroot).
assert_rejected "traversal /sites/../../ca/partyos-ca.key" \
    "${BASE}/sites/../../ca/partyos-ca.key"

# `..` climb to the SIBLING secret that actually EXISTS one level up (would-be leak).
assert_rejected "traversal /sites/../secret.key (existing sibling)" \
    "${BASE}/sites/../secret.key"

# Percent-encoded `..` must be decoded BEFORE the containment check, then rejected.
assert_rejected "encoded traversal /sites/%2e%2e/secret.key" \
    "${BASE}/sites/%2e%2e/secret.key"

# An escaping SYMLINK inside the docroot resolves (realpath) outside it -> rejected.
assert_rejected "symlink escape /sites/escape -> outside secret" \
    "${BASE}/sites/escape"

# Absolute-path smuggling: extra leading slashes must not escape the docroot.
assert_rejected "absolute smuggle /sites//etc/hostname" \
    "${BASE}/sites//etc/hostname"

# ============================================================================
echo
echo "================ 3. additive: the route only touches /sites ====="
# ----------------------------------------------------------------------------
# The site route is a narrow diversion: the existing /report callback still answers
# on the same server, proving the feature did not replace the base serve path.
codeR="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/report?step=probe&status=ok" 2>/dev/null)"
assert_eq "${codeR}" "200" "/report still works alongside the /sites route (additive)"

kill "${SRV_PID}" 2>/dev/null || true; SRV_PID=""

assert_summary "test-personal-site" || exit 1
echo "test-personal-site: ALL PASS"
