#!/usr/bin/env bash
# test-serversplit.sh - autonomous VM test for the server split.
#
# The single hub is split into independently-configured listeners:
#   * NETBOOT server (SERVER_PORT)  - serves ONLY the boot image
#     (kernel/initramfs/squashfs) + the boot script + the /report callback.
#   * BLOB server 1 (BLOB_PORT1)    - serves the game catalog + blobs.
#   * BLOB server 2 (BLOB_PORT2)    - a SECOND blob server (same content) for
#     FAILOVER. The client is handed an ordered blob-URL list (BLOB_URLS) that is
#     independent of the netboot URL.
#
# What it proves, with no hardware and no keystrokes (two boots):
#   BOOT 1 (both blob servers up):
#     1. The client RAM-boots from the NETBOOT server (its access log shows the
#        kernel/initramfs/sfs GETs; the report callback lands here).
#     2. The client fetches the catalog + both blobs from BLOB server 1 (the FIRST
#        blob URL) - a DIFFERENT listener on a DIFFERENT port. The HOST proves the
#        split by per-listener access logs: boot GETs on the netboot listener, blob
#        GETs on the blob-1 listener, and NO blob GET on the netboot listener.
#     3. Both games mount (squashfs+overlay) + run from the blob-server copy.
#   BOOT 2 (blob server 1 KILLED -> failover):
#     4. The harness KILLS blob server 1 before boot. The client's first blob URL
#        no longer answers, so it FAILS OVER to blob server 2 (the second URL):
#        PARTYOS-SS-FAILOVER + PARTYOS-SS-BLOB-DOWNLOADED via=<blob2>. The HOST
#        proves it: blob-2's access log now shows the blob GETs and blob-1's log is
#        unchanged (it was dead). The party keeps working with a blob server down.
#
# Heavy under TCG - run on a KVM host via scripts/vm/remote-test.sh
# test-serversplit. SERVERSPLIT_RAM_MB / SERVERSPLIT_TIMEOUT tune each boot;
# SERVERSPLIT_SKIP_FAILOVER=1 runs only boot 1.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
# Accept both SERVERSPLIT_* and the remote-test.sh-injected names (no step number
# in the target name, so remote-test.sh does not inject a RAM cap automatically).
RAM_MB="${SERVERSPLIT_RAM_MB:-10240}"
T="${SERVERSPLIT_TIMEOUT:-2700}"           # per-boot boot+verify timeout (seconds)
SKIP_FAILOVER="${SERVERSPLIT_SKIP_FAILOVER:-0}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
GAMES_DIR="${REPO_ROOT}/server/games"
TMPL="${REPO_ROOT}/boot/partyos-serversplit.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-serversplit.ipxe"
BOOTURL="${NETBOOT_URL}/boot/partyos-serversplit.ipxe"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-serversplit.XXXXXX")"
NETBOOT_LOG="${RUN}/netboot_access.log"     # netboot/report listener log
BLOB1_LOG="${RUN}/blob1_access.log"         # blob server 1 listener log
BLOB2_LOG="${RUN}/blob2_access.log"         # blob server 2 listener log
NB_PID=""; B1_PID=""; B2_PID=""; VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${B2_PID}" ] && kill "${B2_PID}" 2>/dev/null || true
    [ -n "${B1_PID}" ] && kill "${B1_PID}" 2>/dev/null || true
    [ -n "${NB_PID}" ] && kill "${NB_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[serversplit] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

ser_has()  { [ -f "$1" ] && grep -qF -- "$2" "$1" 2>/dev/null; }
log_has()  { grep -qF -- "$2" "$1" 2>/dev/null; }
vm_alive() { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
# count blob GET lines (catalog or *.squashfs) in a given listener's access log.
# Emit a SINGLE clean integer: grep -c prints 0 AND exits non-zero on no match, so
# a `|| echo 0` would append a second 0 ("0\n0") and break the -eq test. Pipe to
# wc -l instead so the result is always exactly one number.
count_blob_gets() { grep -E 'GET /server/games/(catalog\.json|[a-z]+\.squashfs)' "$1" 2>/dev/null | wc -l | tr -d ' '; }

# --- 0. dependencies: custom image + freshly-built game blobs ----------------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[serversplit] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "SERVERSPLIT: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "SERVERSPLIT: FAIL - no custom sfs" >&2; exit 1; }
echo "[serversplit] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

echo "[serversplit] building game catalog + blobs -> ${GAMES_DIR}..." >&2
bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" "${GAMES_DIR}" >&2 || {
    echo "SERVERSPLIT: FAIL - game blob build failed" >&2; exit 1; }
[ -f "${GAMES_DIR}/catalog.json" ] || { echo "SERVERSPLIT: FAIL - no catalog.json" >&2; exit 1; }
NCAT="$(grep -c '"name":' "${GAMES_DIR}/catalog.json" 2>/dev/null || echo 0)"
echo "[serversplit] catalog has ${NCAT} game(s)" >&2
[ "${NCAT}" -ge 2 ] || { echo "SERVERSPLIT: FAIL - catalog needs >=2 games" >&2; exit 1; }

# --- render the server-split iPXE script (NETBOOT_URL + BLOB_URLS) -----------
echo "[serversplit] netboot=${NETBOOT_URL} blob_urls=${BLOB_URLS}" >&2
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || {
    echo "SERVERSPLIT: FAIL - iPXE render" >&2; exit 1; }
# sanity: the rendered script must carry the netboot URL AND the blob list, and
# they must be DIFFERENT (independent configuration, not derived).
grep -q "blob_urls=${BLOB_URLS}" "${RENDERED}" || { echo "SERVERSPLIT: FAIL - blob_urls not rendered" >&2; exit 1; }
[ "${NETBOOT_URL}" != "${BLOB_URL1}" ] || { echo "SERVERSPLIT: FAIL - netboot and blob1 share a URL (not split)" >&2; exit 1; }

# --- start the THREE listeners (netboot + two blob servers) ------------------
start_server() {
    local port="$1" logf="$2" label="$3" pidvar="$4"
    : > "${logf}"
    python3 -u "${REPO_ROOT}/server/http_server.py" "${port}" >"${logf}" 2>&1 &
    local pid=$!
    printf -v "${pidvar}" '%s' "${pid}"
    local up=0
    for _ in $(seq 1 20); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null && { up=1; break; }
        sleep 0.25
    done
    [ "${up}" -eq 1 ] || { echo "SERVERSPLIT: FAIL - ${label} server did not come up on ${port}" >&2; exit 1; }
    echo "[serversplit] ${label} server up pid=${pid} port=${port} log=${logf}" >&2
}

start_server "${NETBOOT_PORT}" "${NETBOOT_LOG}" "NETBOOT" NB_PID
start_server "${BLOB_PORT1}"   "${BLOB1_LOG}"   "BLOB-1"  B1_PID
start_server "${BLOB_PORT2}"   "${BLOB2_LOG}"   "BLOB-2"  B2_PID

# host-side: the netboot server serves the boot script; both blob servers serve
# the catalog (independent endpoints on independent ports).
curl -fsS -o /dev/null "http://127.0.0.1:${NETBOOT_PORT}/boot/serversplit-script.sh" 2>/dev/null \
    || { echo "SERVERSPLIT: FAIL - netboot server does not serve the boot script" >&2; exit 1; }
curl -fsS -o /dev/null "http://127.0.0.1:${BLOB_PORT1}/server/games/catalog.json" 2>/dev/null \
    || { echo "SERVERSPLIT: FAIL - blob-1 server does not serve the catalog" >&2; exit 1; }
curl -fsS -o /dev/null "http://127.0.0.1:${BLOB_PORT2}/server/games/catalog.json" 2>/dev/null \
    || { echo "SERVERSPLIT: FAIL - blob-2 server does not serve the catalog" >&2; exit 1; }
echo "[serversplit] all three listeners serve their roles (host check)" >&2

boot_vm() {
    local serial="$1" pidfile="$2" qmp="$3"
    export RUN_DIR="${RUN}"
    bash "${SELF_DIR}/run-client.sh" --name serversplit \
        --serial "${serial}" --pidfile "${pidfile}" --qmp "${qmp}" \
        --background \
        --boot-rom --bootfile "${BOOTURL}" \
        --ram "${RAM_MB}" --timeout "${T}" >&2
    VM_PID="$(cat "${pidfile}" 2>/dev/null || true)"
    echo "[serversplit] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2
}

wait_ready() {
    local serial="$1" deadline
    deadline=$(( $(date +%s) + T ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if log_has "${NETBOOT_LOG}" "REPORT step=serversplit status=ok"; then return 0; fi
        if ser_has "${serial}" "PARTYOS-SS-READY"; then return 0; fi
        if ! vm_alive; then echo "[serversplit] VM exited before ready" >&2; return 1; fi
        sleep 5
    done
    return 1
}

# ===================== BOOT 1: BOTH BLOB SERVERS UP ========================
SERIAL1="${RUN}/serversplit.boot1.serial"
echo "[serversplit] === BOOT 1 (both blob servers up): blobs come from BLOB-1 ===" >&2
boot_vm "${SERIAL1}" "${RUN}/ss.b1.pid" "${RUN}/ss.b1.qmp"

b1_ready=0
wait_ready "${SERIAL1}" && b1_ready=1

echo "[serversplit] waiting for boot-1 VM to power off..." >&2
qoff=$(( $(date +%s) + 120 ))
while vm_alive && [ "$(date +%s)" -lt "${qoff}" ]; do sleep 3; done
if vm_alive; then kill -9 "${VM_PID}" 2>/dev/null || true; sleep 2; fi
VM_PID=""

echo "----- boot1 serial tail -----" >&2
tr -d '\000' < "${SERIAL1}" 2>/dev/null | tail -45 >&2
echo "-----------------------------" >&2
echo "----- NETBOOT listener log (boot + REPORT) -----" >&2
grep -E "vmlinuz|initramfs|airootfs|serversplit-script|REPORT step=serversplit" "${NETBOOT_LOG}" 2>/dev/null | tail -15 >&2 || echo "(none)" >&2
echo "----- BLOB-1 listener log (catalog + blobs) -----" >&2
grep -E "games/" "${BLOB1_LOG}" 2>/dev/null | tail -10 >&2 || echo "(none)" >&2
echo "-------------------------------------------------" >&2

if [ "${b1_ready}" -ne 1 ]; then
    echo "SERVERSPLIT: FAIL - boot 1 never reached ready" >&2; exit 1
fi

# --- boot 1 assertions: the split is real ------------------------------------
# guest: catalog + blobs came from BLOB-1 (the first blob URL).
b1_cat_via1=0; ser_has "${SERIAL1}" "PARTYOS-SS-CATALOG-OK" && \
               tr -d '\000' < "${SERIAL1}" | grep -F "PARTYOS-SS-CATALOG-OK" | grep -q "via=${BLOB_URL1}" && b1_cat_via1=1
b1_dl=0;       ser_has "${SERIAL1}" "PARTYOS-SS-BLOB-DOWNLOADED name=hello" && \
               ser_has "${SERIAL1}" "PARTYOS-SS-BLOB-DOWNLOADED name=pong" && b1_dl=1
b1_dl_via1=0;  tr -d '\000' < "${SERIAL1}" | grep -F "PARTYOS-SS-BLOB-DOWNLOADED" | grep -q "via=${BLOB_URL1}" && b1_dl_via1=1
b1_mounted=0;  ser_has "${SERIAL1}" "PARTYOS-SS-MOUNTED name=hello" && \
               ser_has "${SERIAL1}" "PARTYOS-SS-MOUNTED name=pong" && b1_mounted=1
b1_ran=0;      ser_has "${SERIAL1}" "PARTYOS-GAME-HELLO-RAN" && \
               ser_has "${SERIAL1}" "PARTYOS-GAME-PONG-RAN" && b1_ran=1
# HOST: the netboot listener served the BOOT IMAGE (kernel) + the boot script.
h_nb_kernel=0; log_has "${NETBOOT_LOG}" "GET /server/images/vmlinuz-linux" && h_nb_kernel=1
h_nb_script=0; log_has "${NETBOOT_LOG}" "GET /boot/serversplit-script.sh" && h_nb_script=1
# HOST: the report callback landed on the NETBOOT listener.
h_nb_report=0; log_has "${NETBOOT_LOG}" "REPORT step=serversplit status=ok" && h_nb_report=1
# HOST: BLOB-1 listener served the catalog + both blobs.
h_b1_cat=0;    log_has "${BLOB1_LOG}" "GET /server/games/catalog.json"  && h_b1_cat=1
h_b1_hello=0;  log_has "${BLOB1_LOG}" "GET /server/games/hello.squashfs" && h_b1_hello=1
h_b1_pong=0;   log_has "${BLOB1_LOG}" "GET /server/games/pong.squashfs"  && h_b1_pong=1
# HOST: the netboot listener served NO blob (boot vs blob came from DIFFERENT listeners).
nb_blob_gets="$(count_blob_gets "${NETBOOT_LOG}")"
h_nb_no_blob=0; [ "${nb_blob_gets}" -eq 0 ] && h_nb_no_blob=1
B1_GETS_ON_BLOB1="$(count_blob_gets "${BLOB1_LOG}")"

echo "================ SERVERSPLIT BOOT-1 VERDICT ================" >&2
echo "guest catalog via BLOB-1 (${BLOB_URL1})       : ${b1_cat_via1}" >&2
echo "guest downloaded both blobs                   : ${b1_dl}" >&2
echo "guest blobs via BLOB-1                         : ${b1_dl_via1}" >&2
echo "guest mounted both / ran both                  : ${b1_mounted} / ${b1_ran}" >&2
echo "HOST netboot served kernel / boot-script       : ${h_nb_kernel} / ${h_nb_script}" >&2
echo "HOST report callback on netboot listener       : ${h_nb_report}" >&2
echo "HOST blob-1 served catalog/hello/pong          : ${h_b1_cat}/${h_b1_hello}/${h_b1_pong}" >&2
echo "HOST netboot listener served NO blob           : ${h_nb_no_blob} (blob gets on netboot=${nb_blob_gets})" >&2

if ! { [ "${b1_cat_via1}" -eq 1 ] && [ "${b1_dl}" -eq 1 ] && [ "${b1_dl_via1}" -eq 1 ] && \
       [ "${b1_mounted}" -eq 1 ] && [ "${b1_ran}" -eq 1 ] && \
       [ "${h_nb_kernel}" -eq 1 ] && [ "${h_nb_script}" -eq 1 ] && [ "${h_nb_report}" -eq 1 ] && \
       [ "${h_b1_cat}" -eq 1 ] && [ "${h_b1_hello}" -eq 1 ] && [ "${h_b1_pong}" -eq 1 ] && \
       [ "${h_nb_no_blob}" -eq 1 ]; }; then
    echo "SERVERSPLIT: FAIL - boot 1 (split) assertions not all met" >&2; exit 1
fi
echo "[serversplit] BOOT 1 (split: boot vs blob from different listeners) PASS" >&2

# ===================== BOOT 2: BLOB-1 KILLED (FAILOVER) ====================
if [ "${SKIP_FAILOVER}" = "1" ]; then
    echo "[serversplit] SERVERSPLIT_SKIP_FAILOVER=1 - skipping failover boot" >&2
    echo "SERVERSPLIT: PASS (split proven; failover skipped by request)" >&2
    exit 0
fi

echo "[serversplit] === KILLING BLOB-1 (port ${BLOB_PORT1}) to force failover ===" >&2
kill "${B1_PID}" 2>/dev/null || true
wait "${B1_PID}" 2>/dev/null || true
B1_PID=""
# confirm BLOB-1 is genuinely down
if curl -s --max-time 3 -o /dev/null "http://127.0.0.1:${BLOB_PORT1}/server/games/catalog.json" 2>/dev/null; then
    echo "SERVERSPLIT: FAIL - blob-1 still answering after kill" >&2; exit 1
fi
echo "[serversplit] BLOB-1 confirmed down; BLOB-2 (port ${BLOB_PORT2}) still up" >&2
B2_GETS_BEFORE="$(count_blob_gets "${BLOB2_LOG}")"

SERIAL2="${RUN}/serversplit.boot2.serial"
echo "[serversplit] === BOOT 2 (blob-1 dead): expect FAILOVER to BLOB-2 ===" >&2
boot_vm "${SERIAL2}" "${RUN}/ss.b2.pid" "${RUN}/ss.b2.qmp"

b2_ready=0
wait_ready "${SERIAL2}" && b2_ready=1

echo "[serversplit] waiting for boot-2 VM to power off..." >&2
qoff=$(( $(date +%s) + 120 ))
while vm_alive && [ "$(date +%s)" -lt "${qoff}" ]; do sleep 3; done
if vm_alive; then kill -9 "${VM_PID}" 2>/dev/null || true; sleep 2; fi
VM_PID=""

echo "----- boot2 serial tail -----" >&2
tr -d '\000' < "${SERIAL2}" 2>/dev/null | tail -45 >&2
echo "-----------------------------" >&2
echo "----- BLOB-2 listener log (catalog + blobs, failover) -----" >&2
grep -E "games/" "${BLOB2_LOG}" 2>/dev/null | tail -10 >&2 || echo "(none)" >&2
echo "-----------------------------------------------------------" >&2

if [ "${b2_ready}" -ne 1 ]; then
    echo "SERVERSPLIT: FAIL - boot 2 never reached ready (failover did not recover)" >&2; exit 1
fi

# --- boot 2 assertions: failover to BLOB-2 -----------------------------------
b2_failover=0; ser_has "${SERIAL2}" "PARTYOS-SS-FAILOVER" && \
               tr -d '\000' < "${SERIAL2}" | grep -F "PARTYOS-SS-FAILOVER" | grep -q "to=${BLOB_URL2}" && b2_failover=1
b2_cat_via2=0; tr -d '\000' < "${SERIAL2}" | grep -F "PARTYOS-SS-CATALOG-OK" | grep -q "via=${BLOB_URL2}" && b2_cat_via2=1
b2_dl_via2=0;  tr -d '\000' < "${SERIAL2}" | grep -F "PARTYOS-SS-BLOB-DOWNLOADED" | grep -q "via=${BLOB_URL2}" && b2_dl_via2=1
b2_mounted=0;  ser_has "${SERIAL2}" "PARTYOS-SS-MOUNTED name=hello" && \
               ser_has "${SERIAL2}" "PARTYOS-SS-MOUNTED name=pong" && b2_mounted=1
b2_ran=0;      ser_has "${SERIAL2}" "PARTYOS-GAME-HELLO-RAN" && \
               ser_has "${SERIAL2}" "PARTYOS-GAME-PONG-RAN" && b2_ran=1
# HOST: BLOB-2 now served the catalog + both blobs (failover went there).
h_b2_cat=0;    log_has "${BLOB2_LOG}" "GET /server/games/catalog.json"  && h_b2_cat=1
h_b2_hello=0;  log_has "${BLOB2_LOG}" "GET /server/games/hello.squashfs" && h_b2_hello=1
h_b2_pong=0;   log_has "${BLOB2_LOG}" "GET /server/games/pong.squashfs"  && h_b2_pong=1
B2_GETS_AFTER="$(count_blob_gets "${BLOB2_LOG}")"
# HOST: BLOB-2 served MORE during boot 2 than before it (the failover traffic).
h_b2_grew=0;   [ "${B2_GETS_AFTER}" -gt "${B2_GETS_BEFORE}" ] && h_b2_grew=1

echo "================ SERVERSPLIT BOOT-2 (FAILOVER) VERDICT ================" >&2
echo "guest FAILOVER to BLOB-2 (${BLOB_URL2})        : ${b2_failover}" >&2
echo "guest catalog via BLOB-2                        : ${b2_cat_via2}" >&2
echo "guest blobs via BLOB-2                          : ${b2_dl_via2}" >&2
echo "guest mounted both / ran both                   : ${b2_mounted} / ${b2_ran}" >&2
echo "HOST blob-2 served catalog/hello/pong           : ${h_b2_cat}/${h_b2_hello}/${h_b2_pong}" >&2
echo "HOST blob-2 traffic grew during failover        : ${h_b2_grew} (${B2_GETS_BEFORE}->${B2_GETS_AFTER})" >&2

if [ "${b2_failover}" -eq 1 ] && [ "${b2_cat_via2}" -eq 1 ] && [ "${b2_dl_via2}" -eq 1 ] && \
   [ "${b2_mounted}" -eq 1 ] && [ "${b2_ran}" -eq 1 ] && \
   [ "${h_b2_cat}" -eq 1 ] && [ "${h_b2_hello}" -eq 1 ] && [ "${h_b2_pong}" -eq 1 ] && \
   [ "${h_b2_grew}" -eq 1 ]; then
    echo "SERVERSPLIT: PASS" >&2
    exit 0
fi
echo "SERVERSPLIT: FAIL - boot 2 (failover) assertions not all met" >&2
exit 1
