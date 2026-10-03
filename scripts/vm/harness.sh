#!/usr/bin/env bash
# harness.sh - orchestrate an autonomous VM test.
#
# Responsibilities:
#   1. Start the partyOS HTTP server (the existing server/http_server.py) so the
#      guest can fetch boot files and emit HTTP callbacks.
#   2. Launch one or more client VMs (run-client.sh, backgrounded).
#   3. Wait until a success condition is met, polling two feedback channels:
#        a) a MARKER string appears on a VM's serial log, and/or
#        b) an HTTP callback (GET /report?...) shows up in the server access log.
#   4. Assert the result and tear EVERYTHING down (server, net, VMs, watchdogs),
#      returning 0 on success and non-zero on failure/timeout.
#
# This script is the single entry point every `make test-stepN` target calls.
#
# Usage:
#   harness.sh --marker "STRING" [options] -- <run-client.sh args...>
#
# Options:
#   --marker STR        success marker to grep on serial (required unless
#                       --http-marker given)
#   --http-marker STR   substring to match in the HTTP access log (e.g.
#                       "step=0&status=ok"); success when it appears
#   --fail-marker STR   if this appears on serial, fail immediately
#   --timeout SEC       overall wait timeout (default: BOOT_TIMEOUT)
#   --no-server         do not start the HTTP server
#   --name NAME         client name (default: client). Passed to run-client.sh.
#   --                  everything after is forwarded verbatim to run-client.sh
#
# At least one of --marker / --http-marker must be supplied.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

MARKER="" HTTP_MARKER="" FAIL_MARKER="" START_SERVER=1
WAIT_TIMEOUT="${BOOT_TIMEOUT}"
CLIENT_NAME="client"
declare -a CLIENT_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --marker)      MARKER="$2"; shift 2;;
        --http-marker) HTTP_MARKER="$2"; shift 2;;
        --fail-marker) FAIL_MARKER="$2"; shift 2;;
        --timeout)     WAIT_TIMEOUT="$2"; shift 2;;
        --no-server)   START_SERVER=0; shift;;
        --name)        CLIENT_NAME="$2"; shift 2;;
        --) shift; CLIENT_ARGS=("$@"); break;;
        *) die "harness: unknown arg '$1'";;
    esac
done

[ -n "${MARKER}" ] || [ -n "${HTTP_MARKER}" ] || \
    die "harness: need --marker and/or --http-marker"

SERIAL_LOG="${RUN_DIR}/${CLIENT_NAME}.serial"
ACCESS_LOG="${RUN_DIR}/http_access.log"
SERVER_PIDFILE="${RUN_DIR}/server.pid"
CLIENT_PIDFILE="${RUN_DIR}/${CLIENT_NAME}.pid"

# --- teardown --------------------------------------------------------------
cleanup() {
    local rc=$?
    log "tearing down (rc=${rc})"
    # Kill client VM(s)
    for pf in "${RUN_DIR}"/*.pid; do
        [ -e "$pf" ] || continue
        local p; p="$(cat "$pf" 2>/dev/null || true)"
        [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true
    done
    # Kill HTTP server (process group)
    if [ -f "${SERVER_PIDFILE}" ]; then
        local sp; sp="$(cat "${SERVER_PIDFILE}" 2>/dev/null || true)"
        [ -n "$sp" ] && kill "$sp" 2>/dev/null || true
    fi
    # Kill any stray watchdog/sleep children of this shell
    pkill -P $$ 2>/dev/null || true
    # Remove scratch dir only on success to preserve logs for debugging.
    # KEEP_RUNDIR=1 forces preservation (used for timing analysis).
    if [ "$rc" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN_DIR}"; else
        log "logs preserved in ${RUN_DIR}"; fi
}
trap cleanup EXIT INT TERM

# --- start HTTP server -----------------------------------------------------
if [ "${START_SERVER}" -eq 1 ]; then
    # Render iPXE scripts with the current SERVER_URL before serving so no IP is
    # ever hardcoded in a served boot script.
    if [ -f "${REPO_ROOT}/boot/partyos.ipxe.tmpl" ]; then
        bash "${VM_DIR}/render-ipxe.sh" >&2 || die "iPXE render failed"
    fi
    log "starting HTTP server on ${SERVER_BIND}:${SERVER_PORT} (access log -> ${ACCESS_LOG})"
    : > "${ACCESS_LOG}"
    # -u (unbuffered) so request log lines appear immediately for the live grep.
    python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" \
        >"${ACCESS_LOG}" 2>&1 &
    echo $! > "${SERVER_PIDFILE}"
    # Wait for it to accept connections.
    for _ in $(seq 1 20); do
        if curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null; then
            break; fi
        sleep 0.25
    done
    log "HTTP server up (pid $(cat "${SERVER_PIDFILE}"))"
fi

# --- launch client ---------------------------------------------------------
# Share this harness's RUN_DIR with run-client.sh so its pidfile/qmp land where
# the wait loop and cleanup expect them.
export RUN_DIR
log "launching client '${CLIENT_NAME}'"
bash "${VM_DIR}/run-client.sh" --name "${CLIENT_NAME}" \
    --serial "${SERIAL_LOG}" --pidfile "${CLIENT_PIDFILE}" \
    --background "${CLIENT_ARGS[@]}" >&2

# --- wait loop -------------------------------------------------------------
log "waiting up to ${WAIT_TIMEOUT}s for success condition"
log "  serial marker : ${MARKER:-<none>}"
log "  http marker   : ${HTTP_MARKER:-<none>}"
log "  fail marker   : ${FAIL_MARKER:-<none>}"

deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
result="timeout"
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if [ -n "${FAIL_MARKER}" ] && [ -f "${SERIAL_LOG}" ] && \
         grep -qF -- "${FAIL_MARKER}" "${SERIAL_LOG}" 2>/dev/null; then
        result="failmarker"; break
    fi
    if [ -n "${MARKER}" ] && [ -f "${SERIAL_LOG}" ] && \
         grep -qF -- "${MARKER}" "${SERIAL_LOG}" 2>/dev/null; then
        result="ok"; break
    fi
    if [ -n "${HTTP_MARKER}" ] && [ -f "${ACCESS_LOG}" ] && \
         grep -qF -- "${HTTP_MARKER}" "${ACCESS_LOG}" 2>/dev/null; then
        result="ok"; break
    fi
    # If the client VM died before producing a marker, stop early.
    if [ -f "${CLIENT_PIDFILE}" ]; then
        cp_pid="$(cat "${CLIENT_PIDFILE}" 2>/dev/null || true)"
        if [ -n "${cp_pid}" ] && ! kill -0 "${cp_pid}" 2>/dev/null; then
            # Give one last grep in case the marker landed at exit.
            sleep 0.5
            if [ -n "${MARKER}" ] && grep -qF -- "${MARKER}" "${SERIAL_LOG}" 2>/dev/null; then
                result="ok"; break; fi
            if [ -n "${HTTP_MARKER}" ] && grep -qF -- "${HTTP_MARKER}" "${ACCESS_LOG}" 2>/dev/null; then
                result="ok"; break; fi
            result="vmexited"; break
        fi
    fi
    sleep 0.5
done

# --- assert ----------------------------------------------------------------
echo "----- serial tail (${CLIENT_NAME}) -----" >&2
tail -20 "${SERIAL_LOG}" 2>/dev/null | tr -d '\000' >&2 || true
echo "----------------------------------------" >&2

case "${result}" in
    ok)
        log "PASS: success condition met"
        exit 0;;
    failmarker)
        log "FAIL: fail-marker '${FAIL_MARKER}' observed on serial"
        exit 1;;
    vmexited)
        log "FAIL: VM exited before emitting the success marker"
        exit 1;;
    *)
        log "FAIL: timeout after ${WAIT_TIMEOUT}s without success condition"
        exit 1;;
esac
