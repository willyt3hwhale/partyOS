#!/usr/bin/env bash
# test-https-dualserve.sh - hardware-FREE unit + integration test for
# the HTTPS setup: the private CA + server leaf (gen-ca.sh) and the
# server DUAL-SERVING plaintext HTTP and pinned-CA HTTPS from one process. No VM,
# no real hardware - a loopback server + curl + openssl only. Three parts:
#
#   1. CA + LEAF (gen-ca.sh): run the generator into a throwaway repo-copy and
#      assert it produces a self-signed CA, a CA-SIGNED leaf, the leaf SAN carries
#      the canonical server IP 192.168.0.10, and it prints the CA fingerprint.
#      Also assert --force vs reuse: a second run WITHOUT --force keeps the SAME CA
#      (so re-signing a leaf never rotates the CA + re-pins every client).
#
#   2. DUAL-SERVE (start the REAL http_server.py): with the generated certs in
#      place, start the server and prove the three transport cases -
#        A. HTTPS WITH --cacert (pinned CA)   -> SUCCEEDS (catalog served over TLS)
#        B. HTTPS WITHOUT --cacert            -> FAILS    (pinned, no system trust)
#        C. plain HTTP                        -> WORKS    (HTTP transport unchanged)
#      The HTTPS request connects to the SAN IP (routed to loopback via --resolve)
#      so curl's SAN-vs-host check - the same one iPXE enforces - actually runs.
#
#   3. DEGRADE (no cert): start the server with the certs absent and assert it logs
#      the HTTPS warning and STILL serves HTTP (a missing cert must never crash the
#      server or brick the existing plaintext boot chain).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

GENCA="${REPO_ROOT}/scripts/deploy/gen-ca.sh"
SERVER="${REPO_ROOT}/server/http_server.py"
[ -f "${GENCA}" ]  || { echo "FAIL: gen-ca.sh not found at ${GENCA}"; exit 1; }
[ -f "${SERVER}" ] || { echo "FAIL: http_server.py not found at ${SERVER}"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "FAIL: openssl not in PATH"; exit 1; }
command -v curl    >/dev/null 2>&1 || { echo "FAIL: curl not in PATH"; exit 1; }

# Run everything against a THROWAWAY copy of the repo so the test never touches
# the real ca/ or server/tls/ (which are gitignored secrets). We symlink the
# files http_server.py needs (itself + a small file to serve) into the temp tree.
TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-tlstest.XXXXXX")"
SRV_PID=""
OCC_PID=""   # a port-occupant held for the bind-collision case (section 4)
cleanup() {
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    [ -n "${OCC_PID}" ] && kill "${OCC_PID}" 2>/dev/null || true
    rm -rf "${TMPDIR_T}"
}
trap cleanup EXIT

# Pick two free-ish high ports for HTTP + HTTPS.
HTTP_PORT=$(( (RANDOM % 2000) + 18080 ))
HTTPS_PORT=$(( HTTP_PORT + 1 ))
SAN_IP="192.168.0.10"   # the IP the leaf SAN must carry (clients connect by IP)

# ============================================================================
echo "================ 1. gen-ca.sh: CA + CA-signed leaf w/ IP SAN ==="
# ----------------------------------------------------------------------------
# A fake repo root so gen-ca.sh writes ca/ + server/tls/ under the temp dir. It
# derives the repo root from its own ../.. , so run a COPY placed at the right depth.
FAKE_ROOT="${TMPDIR_T}/repo"
install -d "${FAKE_ROOT}/scripts/deploy"
cp "${GENCA}" "${FAKE_ROOT}/scripts/deploy/gen-ca.sh"
chmod +x "${FAKE_ROOT}/scripts/deploy/gen-ca.sh"
# gen-ca.sh sources its fingerprint helper from its own directory, so the copy needs it.
cp "$(dirname "${GENCA}")/lib-ca-fingerprint.sh" "${FAKE_ROOT}/scripts/deploy/"

# gen-ca now REQUIRES the primary SAN (IP/hostname) as arg 1 - pass the canonical
# server IP explicitly so the leaf SAN carries it (the assertion below checks it).
( cd "${FAKE_ROOT}" && BACKDATE_DAYS=2 ./scripts/deploy/gen-ca.sh "${SAN_IP}" ) > "${TMPDIR_T}/genca.out" 2>&1
assert_true "$?" "gen-ca.sh ran cleanly"

CA_CRT="${FAKE_ROOT}/ca/partyos-ca.crt"
CA_KEY="${FAKE_ROOT}/ca/partyos-ca.key"
LEAF_CRT="${FAKE_ROOT}/server/tls/partyos.crt"
LEAF_KEY="${FAKE_ROOT}/server/tls/partyos.key"

assert_true "$([ -f "${CA_CRT}" ];  echo $?)" "CA cert written (ca/partyos-ca.crt)"
assert_true "$([ -f "${CA_KEY}" ];  echo $?)" "CA key written  (ca/partyos-ca.key)"
assert_true "$([ -f "${LEAF_CRT}" ]; echo $?)" "leaf cert written (server/tls/partyos.crt)"
assert_true "$([ -f "${LEAF_KEY}" ]; echo $?)" "leaf key written  (server/tls/partyos.key)"

# CA key is a SECRET -> must be mode 600 (owner-only).
caperm="$(stat -f '%Lp' "${CA_KEY}" 2>/dev/null || stat -c '%a' "${CA_KEY}" 2>/dev/null)"
assert_eq "${caperm}" "600" "CA key is mode 600 (owner-only secret)"

# Leaf is signed BY the CA (the trust chain the clients will pin).
openssl verify -CAfile "${CA_CRT}" "${LEAF_CRT}" >/dev/null 2>&1
assert_true "$?" "leaf cert is signed by the CA (openssl verify OK)"

# Leaf SAN carries the canonical server IP (iPXE/curl enforce SAN-vs-host).
santxt="$(openssl x509 -in "${LEAF_CRT}" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name')"
assert_contains "${santxt}" "${SAN_IP}" "leaf SAN contains ${SAN_IP}"

# gen-ca prints the CA SHA-256 fingerprint (needed for the iPXE TRUST= later).
assert_contains "$(cat "${TMPDIR_T}/genca.out")" "fingerprint" "gen-ca.sh prints the CA SHA-256 fingerprint"

# Re-run WITHOUT --force -> the CA must be REUSED (same fingerprint), only the
# leaf re-signed. Rotating the CA on every run would re-pin every client.
fp1="$(openssl x509 -in "${CA_CRT}" -noout -fingerprint -sha256 2>/dev/null)"
( cd "${FAKE_ROOT}" && ./scripts/deploy/gen-ca.sh "${SAN_IP}" ) > "${TMPDIR_T}/genca2.out" 2>&1
fp2="$(openssl x509 -in "${CA_CRT}" -noout -fingerprint -sha256 2>/dev/null)"
assert_eq "${fp2}" "${fp1}" "re-run without --force REUSES the CA (fingerprint unchanged)"
assert_contains "$(cat "${TMPDIR_T}/genca2.out")" "reusing" "gen-ca.sh logs that it reused the existing CA"

# ============================================================================
echo
echo "================ 2. dual-serve: HTTPS(pinned) + HTTP both work ="
# ----------------------------------------------------------------------------
# Stage a tiny file to serve over both transports, and the certs the server reads
# from <root>/server/tls/. Run the REAL http_server.py with the fake root as its
# project root by copying it in at the right depth (it serves from ../).
cp "${SERVER}" "${FAKE_ROOT}/server/http_server.py"
install -d "${FAKE_ROOT}/server/games"
printf '{"ok":true,"probe":"dualserve"}\n' > "${FAKE_ROOT}/server/games/catalog.json"

python3 -u "${FAKE_ROOT}/server/http_server.py" "${HTTP_PORT}" 127.0.0.1 "${HTTPS_PORT}" \
    > "${TMPDIR_T}/srv.log" 2>&1 &
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

# Wait for the HTTPS listener (bounded ~5s), pinning the test CA + SAN IP.
hup=0
for _ in $(seq 1 50); do
    if curl -fsS --max-time 1 --cacert "${CA_CRT}" \
        --resolve "${SAN_IP}:${HTTPS_PORT}:127.0.0.1" -o /dev/null \
        "https://${SAN_IP}:${HTTPS_PORT}/report?step=probe" 2>/dev/null; then
        hup=1; break
    fi
    sleep 0.1
done
assert_true "$([ "${hup}" = 1 ]; echo $?)" "http_server.py HTTPS listener came up on :${HTTPS_PORT}"

# CASE A: HTTPS WITH --cacert -> SUCCEEDS.
codeA="$(curl -sS --cacert "${CA_CRT}" --resolve "${SAN_IP}:${HTTPS_PORT}:127.0.0.1" \
    -o "${TMPDIR_T}/a.json" -w '%{http_code}' \
    "https://${SAN_IP}:${HTTPS_PORT}/server/games/catalog.json" 2>/dev/null)"
assert_eq "${codeA}" "200" "HTTPS WITH pinned --cacert -> 200 (catalog served over TLS)"
assert_contains "$(cat "${TMPDIR_T}/a.json" 2>/dev/null)" "dualserve" "TLS-served body matches the staged catalog"

# CASE B: HTTPS WITHOUT --cacert -> FAILS (pinned, no system-trust leak).
curl -sS --max-time 5 --resolve "${SAN_IP}:${HTTPS_PORT}:127.0.0.1" -o /dev/null \
    "https://${SAN_IP}:${HTTPS_PORT}/server/games/catalog.json" 2>/dev/null
assert_false "$?" "HTTPS WITHOUT --cacert -> FAILS (cert pinned to our CA, not system trust)"

# CASE C: plain HTTP -> STILL WORKS (transport unchanged).
codeC="$(curl -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${HTTP_PORT}/server/games/catalog.json" 2>/dev/null)"
assert_eq "${codeC}" "200" "plain HTTP still serves the catalog (HTTP transport unaffected)"

# The server logged BOTH listeners coming up (one process, dual-serve).
srvlog="$(cat "${TMPDIR_T}/srv.log" 2>/dev/null)"
assert_contains "${srvlog}" "HTTP server running"  "server logged the HTTP listener"
assert_contains "${srvlog}" "HTTPS server running" "server logged the HTTPS listener"

# Per-request log lines self-identify the listener they arrived on: a request to
# the TLS listener logs an [HTTPS:<port>]-tagged line, a request to the plaintext
# listener logs an [HTTP:<port>]-tagged line. This is what lets the HTTPS boot
# chain be verified from the log alone, with no live lsof port-attribution.
assert_contains "${srvlog}" "[HTTPS:${HTTPS_PORT}]" "HTTPS:${HTTPS_PORT} request logs an [HTTPS:${HTTPS_PORT}]-tagged line"
assert_contains "${srvlog}" "[HTTP:${HTTP_PORT}]"   "HTTP:${HTTP_PORT} request logs an [HTTP:${HTTP_PORT}]-tagged line"

kill "${SRV_PID}" 2>/dev/null || true; SRV_PID=""

# ============================================================================
echo
echo "================ 2b. HTTPS-ONLY: PARTYOS_HTTP_DISABLE drops :8080 ="
# ----------------------------------------------------------------------------
# Start the REAL server with PARTYOS_HTTP_DISABLE=1: it must serve HTTPS on the
# HTTPS port but NOT bind the plaintext HTTP port (connection refused there).
# Fresh ports so we don't clash with the part-2 listeners. Cert is still present
# (part 3 hides it later), so HTTPS comes up and the safety-net HTTP fallback is
# NOT triggered. This proves the prod HTTPS-only default keeps TLS alive while
# the plaintext :8080 attack surface is gone.
HOFF_PORT=$(( (RANDOM % 2000) + 20080 ))   # the HTTP port that must NOT be bound
HSONLY_PORT=$(( HOFF_PORT + 1 ))           # the HTTPS port that MUST be served
PARTYOS_HTTP_DISABLE=1 python3 -u "${FAKE_ROOT}/server/http_server.py" \
    "${HOFF_PORT}" 127.0.0.1 "${HSONLY_PORT}" > "${TMPDIR_T}/httpsonly.log" 2>&1 &
SRV_PID=$!

# Wait for the HTTPS listener (bounded ~5s), pinning the test CA + SAN IP.
hsup=0
for _ in $(seq 1 50); do
    if curl -fsS --max-time 1 --cacert "${CA_CRT}" \
        --resolve "${SAN_IP}:${HSONLY_PORT}:127.0.0.1" -o /dev/null \
        "https://${SAN_IP}:${HSONLY_PORT}/report?step=probe" 2>/dev/null; then
        hsup=1; break
    fi
    sleep 0.1
done
assert_true "$([ "${hsup}" = 1 ]; echo $?)" "HTTPS-only: HTTPS listener came up on :${HSONLY_PORT}"

# HTTPS with the pinned CA still serves the catalog -> 200 (TLS unaffected).
codeS="$(curl -sS --cacert "${CA_CRT}" --resolve "${SAN_IP}:${HSONLY_PORT}:127.0.0.1" \
    -o /dev/null -w '%{http_code}' \
    "https://${SAN_IP}:${HSONLY_PORT}/server/games/catalog.json" 2>/dev/null)"
assert_eq "${codeS}" "200" "HTTPS-only: HTTPS WITH pinned --cacert -> 200 (TLS still served)"

# Plain HTTP to the (un-bound) http port -> connection REFUSED (curl can't connect).
# The exit code is the authoritative signal; the stderr wording varies by curl
# build ("Connection refused" vs "Couldn't connect to server"), so accept either.
httperr="$(curl -sS --max-time 2 "http://127.0.0.1:${HOFF_PORT}/server/games/catalog.json" 2>&1)"
assert_false "$?" "HTTPS-only: plain HTTP to :${HOFF_PORT} FAILS (listener not bound)"
if printf '%s' "${httperr}" | grep -qiE 'refused|couldn.t connect|failed to connect'; then
    refrc=0; else refrc=1; fi
assert_true "${refrc}" "HTTPS-only: curl reports it could not connect to the HTTP port"

# The server logged HTTPS up but NOT the plaintext HTTP listener.
hsonlylog="$(cat "${TMPDIR_T}/httpsonly.log" 2>/dev/null)"
assert_contains "${hsonlylog}" "HTTPS server running" "HTTPS-only: server logged the HTTPS listener"
assert_not_contains "${hsonlylog}" "HTTP server running" "HTTPS-only: server did NOT start the plaintext HTTP listener"

kill "${SRV_PID}" 2>/dev/null || true; SRV_PID=""

# ============================================================================
echo
echo "================ 3. degrade: no cert -> warn + HTTP-only ======="
# ----------------------------------------------------------------------------
# Hide the leaf cert and prove the server warns + serves HTTP without crashing.
mv "${LEAF_CRT}" "${LEAF_CRT}.hidden"
DPORT=$(( (RANDOM % 2000) + 22080 ))
python3 -u "${FAKE_ROOT}/server/http_server.py" "${DPORT}" 127.0.0.1 $(( DPORT + 1 )) \
    > "${TMPDIR_T}/degrade.log" 2>&1 &
SRV_PID=$!
dup=0
for _ in $(seq 1 50); do
    if curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:${DPORT}/report?step=probe" 2>/dev/null; then
        dup=1; break
    fi
    sleep 0.1
done
assert_true "$([ "${dup}" = 1 ]; echo $?)" "server still serves HTTP with the cert ABSENT (no crash)"
assert_contains "$(cat "${TMPDIR_T}/degrade.log" 2>/dev/null)" "HTTP-only" "server logs the HTTPS-disabled warning when cert is missing"
kill "${SRV_PID}" 2>/dev/null || true; SRV_PID=""
mv "${LEAF_CRT}.hidden" "${LEAF_CRT}"

# ============================================================================
echo
echo "================ 4. bind-fatal: HTTPS-only bind failure EXITS !=0 ="
# ----------------------------------------------------------------------------
# Regression: in
# HTTPS-only prod mode, if the TLS listener cannot bind (a stale process already
# on the port) the server used to print a false "HTTP still serving" and EXIT 0
# with ZERO listeners - a silent failure, and run-servers.sh never noticed. Now
# the bind failure is FATAL + LOUD: non-zero exit and a stderr error naming the
# addr:port that failed. Cert is present again (section 3 restored it) so ctx is
# not None and the HTTPS-only path really attempts the TLS bind.
COLLIDE_PORT=$(( (RANDOM % 2000) + 24080 ))   # the HTTPS port we pre-occupy
BF_HTTP_PORT=$(( COLLIDE_PORT + 1 ))          # HTTP port (never bound in HTTPS-only)

# Occupy COLLIDE_PORT with a plain listening socket (no SO_REUSEADDR) so the real
# server's bind hits EADDRINUSE - the stale-holder scenario.
python3 - "${COLLIDE_PORT}" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
time.sleep(60)
PY
OCC_PID=$!

# Wait until the occupant is actually listening (bounded ~5s).
occ_up=0
for _ in $(seq 1 50); do
    if python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),0.3).close()' \
        "${COLLIDE_PORT}" 2>/dev/null; then
        occ_up=1; break
    fi
    sleep 0.1
done
assert_true "$([ "${occ_up}" = 1 ]; echo $?)" "test occupant is holding :${COLLIDE_PORT}"

# Start the REAL server HTTPS-only against the OCCUPIED TLS port. It must bail fast
# (bind collision), NOT block serving. Bounded wait so a regression (old exit-0 with
# a HANG, or serve-forever) is caught instead of wedging the suite.
PARTYOS_HTTP_DISABLE=1 python3 -u "${FAKE_ROOT}/server/http_server.py" \
    "${BF_HTTP_PORT}" 127.0.0.1 "${COLLIDE_PORT}" > "${TMPDIR_T}/bindfail.log" 2>&1 &
BF_PID=$!
bf_rc=""
for _ in $(seq 1 50); do
    if ! kill -0 "${BF_PID}" 2>/dev/null; then
        wait "${BF_PID}"; bf_rc=$?; break
    fi
    sleep 0.1
done
if [ -z "${bf_rc}" ]; then
    kill "${BF_PID}" 2>/dev/null || true; wait "${BF_PID}" 2>/dev/null || true
fi
assert_true "$([ -n "${bf_rc}" ]; echo $?)" \
    "HTTPS-only bind collision: server EXITED (did not hang serving a stale port)"
assert_false "${bf_rc:-0}" \
    "HTTPS-only bind collision on :${COLLIDE_PORT}: exit code is NON-zero (no silent exit-0, zero-listener)"

bflog="$(cat "${TMPDIR_T}/bindfail.log" 2>/dev/null)"
assert_contains "${bflog}" "FATAL" "bind failure is logged as FATAL (loud, not silent)"
assert_contains "${bflog}" ":${COLLIDE_PORT}" "the FATAL error names the addr:port that failed (:${COLLIDE_PORT})"
assert_not_contains "${bflog}" "HTTP still serving" "the false 'HTTP still serving' message is gone in HTTPS-only mode"
assert_not_contains "${bflog}" "HTTPS server running" "no false success line - the TLS listener never came up"

kill "${OCC_PID}" 2>/dev/null || true; OCC_PID=""

# Static wiring: run-servers.sh must also SUPERVISE the http_server + tracker (not
# just the seeder), so a death/bind-failure of either is logged + respawned rather
# than leaving the stack half-up. Runtime effect needs a real server restart; the
# wiring is pinned here.
runsrc="$(cat "${REPO_ROOT}/scripts/deploy/run-servers.sh")"
assert_contains "${runsrc}" "role_supervisor()" \
    "run-servers.sh defines a generic role_supervisor (respawn wrapper)"
assert_contains "${runsrc}" 'role_supervisor "${label} ${ip}:${hport}"' \
    "http_server.py listener runs UNDER role_supervisor (respawns on death/bind-failure)"
assert_contains "${runsrc}" 'role_supervisor "TRACKER' \
    "bt_tracker.py runs UNDER role_supervisor (respawns on death)"
assert_contains "${runsrc}" "respawning in" \
    "role_supervisor logs each respawn"

assert_summary "test-https-dualserve" || exit 1
echo "test-https-dualserve: ALL PASS"
