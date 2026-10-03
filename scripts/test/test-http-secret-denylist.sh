#!/usr/bin/env bash
# test-http-secret-denylist.sh - hardware-FREE unit/integration test for the
# secret denylist in server/http_server.py.
#
# The boot server serves the WHOLE repo as its docroot, which also holds operator
# secrets - the CA PRIVATE key (ca/partyos-ca.key, the pinned trust root), the TLS
# leaf key (server/tls/partyos.key), player PII (users/), deploy.conf, the report
# inbox (server/reports/) and .git. Before the fix `GET /ca/partyos-ca.key` handed
# any LAN client the trust root, nullifying the entire pinned-CA boot chain. This
# test drives the REAL http_server.py over loopback and asserts:
#
#   1. DENY   - every secret path (and its traversal / percent-encoding /
#      double-slash variants) returns 403 and the body NEVER contains the key
#      material ('PRIVATE KEY') or a planted decoy marker.
#   2. SERVE  - the legitimate public artifacts (a boot artifact, the catalog,
#      /sites/index.html) still return 200 - the denylist did not over-block.
#
# To stay meaningful in a CLEAN git worktree (where the gitignored *.key files are
# absent), the test plants a decoy key at each *.key path ONLY IF it does not
# already exist, and removes exactly what it created on exit - it NEVER touches the
# operator's real keys. No VM, no hardware: loopback http_server.py + curl only.
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

# The server's docroot is the repo root (hardcoded in http_server.py), so the test
# runs against the real tree. A distinctive decoy marker lets us prove no secret
# body leaked; the literal "PRIVATE KEY" mirrors the real PEM header so the same
# grep catches the real key if this were ever run before the fix.
DECOY_MARKER="PARTYOS-TEST-DECOY-KEY-MATERIAL-DO-NOT-LEAK"
DECOY_BODY="-----BEGIN PRIVATE KEY-----
${DECOY_MARKER}
-----END PRIVATE KEY-----"

SRV_PID=""
CREATED_FILES=()
CREATED_DIRS=()
cleanup() {
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    # Remove ONLY what we planted (never the operator's real keys/dirs).
    local f d
    for f in "${CREATED_FILES[@]:-}"; do [ -n "${f}" ] && rm -f "${f}"; done
    for d in "${CREATED_DIRS[@]:-}"; do [ -n "${d}" ] && rmdir "${d}" 2>/dev/null || true; done
    rm -f "/tmp/partyos-denytest.$$.out" "/tmp/partyos-denytest.$$.log" 2>/dev/null || true
}
trap cleanup EXIT

# ensure_decoy REL_PATH - plant a decoy key at REPO_ROOT/REL_PATH iff nothing is
# already there, recording what we created so cleanup removes exactly that. If the
# real file exists we leave it untouched (its real 'PRIVATE KEY' content is what a
# pre-fix run would leak, which is exactly what we assert is now blocked).
ensure_decoy() {
    local rel="$1" abs="${REPO_ROOT}/$1" dir
    [ -e "${abs}" ] && return 0
    dir="$(dirname "${abs}")"
    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}"
        CREATED_DIRS+=("${dir}")
    fi
    printf '%s\n' "${DECOY_BODY}" > "${abs}"
    CREATED_FILES+=("${abs}")
}

ensure_decoy "ca/partyos-ca.key"
ensure_decoy "server/tls/partyos.key"

HTTP_PORT=$(( (RANDOM % 2000) + 27080 ))

# Start the REAL server HTTP-only (PARTYOS_NO_HTTPS=1 -> no cert needed), docroot =
# the repo root. srv.log captures the DENY log lines we assert on.
SRV_LOG="/tmp/partyos-denytest.$$.log"
PARTYOS_NO_HTTPS=1 python3 -u "${SERVER}" "${HTTP_PORT}" 127.0.0.1 > "${SRV_LOG}" 2>&1 &
SRV_PID=$!

up=0
for _ in $(seq 1 50); do
    if curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/report?step=probe" 2>/dev/null; then
        up=1; break
    fi
    sleep 0.1
done
assert_true "$([ "${up}" = 1 ]; echo $?)" "http_server.py HTTP listener came up on :${HTTP_PORT}"

BASE="http://127.0.0.1:${HTTP_PORT}"
OUT="/tmp/partyos-denytest.$$.out"

# ============================================================================
echo "================ 1. secrets DENIED (403, no key leaked) ========"
# ----------------------------------------------------------------------------
# assert_denied LABEL URL - GET URL with --path-as-is; PASS iff code is exactly
# 403 AND the body contains neither 'PRIVATE KEY' nor the decoy marker.
assert_denied() {
    local label="$1" url="$2" code
    code="$(curl -sS --path-as-is -o "${OUT}" -w '%{http_code}' "${url}" 2>/dev/null)"
    assert_eq "${code}" "403" "${label} -> 403"
    assert_not_contains "$(cat "${OUT}" 2>/dev/null)" "PRIVATE KEY" "${label} -> no 'PRIVATE KEY' in body"
    assert_not_contains "$(cat "${OUT}" 2>/dev/null)" "${DECOY_MARKER}" "${label} -> no decoy key material in body"
}

# The worst leak: the CA private key (the pinned trust root).
assert_denied "GET /ca/partyos-ca.key"            "${BASE}/ca/partyos-ca.key"
# The TLS leaf key.
assert_denied "GET /server/tls/partyos.key"       "${BASE}/server/tls/partyos.key"
# The deploy config (root-executed boot hook + party settings).
assert_denied "GET /deploy.conf"                  "${BASE}/deploy.conf"
# Player PII (real names + pinned IPs) under users/.
assert_denied "GET /users/README.md"              "${BASE}/users/README.md"
# .git history.
assert_denied "GET /.git/config"                  "${BASE}/.git/config"
# The PUBLIC CA cert is pinned client-side (baked into iPXE/initramfs), never
# fetched over the LAN - denying all of ca/ (incl. the .crt) breaks no boot path.
assert_denied "GET /ca/partyos-ca.crt"            "${BASE}/ca/partyos-ca.crt"

echo
echo "---- traversal / encoding / double-slash variants of the CA key ----"
# Percent-encoded `..` must be decoded BEFORE the check, then collapse to the key.
assert_denied "GET /%2e%2e/ca/partyos-ca.key"     "${BASE}/%2e%2e/ca/partyos-ca.key"
# Literal `..` round-trip inside ca/.
assert_denied "GET /ca/../ca/partyos-ca.key"      "${BASE}/ca/../ca/partyos-ca.key"
# Leading double-slash (urlsplit would mangle netloc; the guard uses translate_path).
assert_denied "GET //ca/partyos-ca.key"           "${BASE}//ca/partyos-ca.key"
# Deeper `..` climb that still resolves back onto the key.
assert_denied "GET /server/../ca/partyos-ca.key"  "${BASE}/server/../ca/partyos-ca.key"

echo
echo "---- the denial is logged (one greppable line) ----"
assert_true "$(grep -q 'DENY secret request' "${SRV_LOG}"; echo $?)" \
    "server logged a DENY line for a secret request"

# ============================================================================
echo
echo "================ 2. public artifacts STILL served (200) ========"
# ----------------------------------------------------------------------------
# assert_served LABEL URL - GET URL; PASS iff code is 200.
assert_served() {
    local label="$1" url="$2" code
    code="$(curl -sS --path-as-is -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)"
    assert_eq "${code}" "200" "${label} -> 200"
}

# A boot artifact (the step-3 boot script, a public tracked file). Templates
# (*.tmpl) are not served any more (see test-http-allowlist).
assert_served "GET /boot/step3-script.sh"         "${BASE}/boot/step3-script.sh"
# The catalog the app-store/eviction clients fetch (v2 is tracked in a clean tree).
assert_served "GET /server/games/catalog.v2.json" "${BASE}/server/games/catalog.v2.json"
# The auto-hosted personal-site index (proves the /sites route is untouched).
assert_served "GET /sites/index.html"             "${BASE}/sites/index.html"

kill "${SRV_PID}" 2>/dev/null || true; SRV_PID=""

assert_summary "test-http-secret-denylist" || exit 1
echo "test-http-secret-denylist: ALL PASS"
