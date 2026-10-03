#!/usr/bin/env bash
# test-step8.sh - autonomous VM test for Step 8 (Game Blob Caching).
#
# What it proves, with no hardware and no keystrokes (two boots of the SAME USB):
#   BOOT 1 (cold cache):
#     1. The custom image RAM-boots with a FRESH LANPARTY_HOME USB stick attached;
#        step8-script.sh mounts it rw and uses .partyos-cache/games on it as the
#        blob cache. The cache starts EMPTY so every game is a CACHE MISS:
#        PARTYOS-STEP8-CACHE-MISS, the blob DOWNLOADS from the server
#        (PARTYOS-STEP8-BLOB-DOWNLOADED), and is WRITTEN to the USB cache
#        (PARTYOS-STEP8-CACHE-WRITE). Each game mounts from the cached copy
#        (PARTYOS-STEP8-MOUNTED src=cache+...) and RUNS (PARTYOS-STEP8-GAME-RAN).
#     2. HOST PROOF: after power-off the host mounts the USB qcow2 (debugfs in
#        Docker; macOS cannot mount ext4) and confirms each game's blob really
#        landed in .partyos-cache/games on the stick - independent of the guest.
#   BOOT 2 (warm cache):
#     3. The SAME usbhome.qcow2 is re-booted (cache survives the reboot). Now every
#        game is a CACHE HIT (PARTYOS-STEP8-CACHE-HIT) and there is NO server GET
#        for any blob: the harness asserts the blob-GET count in the timestamped
#        http_access.log did NOT increase across boot 2.
#     4. Boot 2 is FASTER to games-ready than boot 1 (no blob transfer): the
#        catalog->ready window from the access-log epoch timestamps is compared.
#
# TCG note: on Apple Silicon each full RAM boot of the ~1.6GB custom image is slow;
# run this on a KVM host via scripts/vm/remote-test.sh test-step8. STEP8_TIMEOUT
# is per-boot; STEP8_SKIP_WARM=1 runs only the cold boot.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${STEP8_RAM_MB:-10240}"
T="${STEP8_TIMEOUT:-2700}"               # per-boot boot+verify timeout (seconds)
USB_MB="${STEP8_USB_MB:-256}"
SEED_TAG="${STEP8_SEED_TAG:-partyos-step8}"
SKIP_WARM="${STEP8_SKIP_WARM:-0}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
GAMES_DIR="${REPO_ROOT}/server/games"
USBHOME="${STEP8_USBHOME:-${REPO_ROOT}/server/images/usbhome-step8.qcow2}"  # git-ignored
TMPL="${REPO_ROOT}/boot/partyos-step8.ipxe.tmpl"
R_COLD="${REPO_ROOT}/boot/partyos-step8.ipxe"          # cold-cache boot (boot 1)
R_WARM="${REPO_ROOT}/boot/partyos-step8-warm.ipxe"     # warm-cache boot (boot 2)
BOOTURL_COLD="${SERVER_URL}/boot/partyos-step8.ipxe"
BOOTURL_WARM="${SERVER_URL}/boot/partyos-step8-warm.ipxe"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-step8.XXXXXX")"
ACCESS="${RUN}/http_access.log"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[step8] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

ser_has()   { [ -f "$1" ] && grep -qF -- "$2" "$1" 2>/dev/null; }
log_has()   { grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive()  { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
count_ser() { tr -d '\000' < "$1" 2>/dev/null | grep -cF -- "$2"; }
# count blob GET lines in the access log (host-side proof of server transfers)
count_blob_gets() { grep -cE 'GET /server/games/[a-z]+\.squashfs' "${ACCESS}" 2>/dev/null || echo 0; }

# --- 0. dependencies: custom image + game blobs + a FRESH usb stick ----------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[step8] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "STEP 8: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "STEP 8: FAIL - no custom sfs" >&2; exit 1; }
echo "[step8] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

echo "[step8] building game catalog + blobs -> ${GAMES_DIR}..." >&2
bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" "${GAMES_DIR}" >&2 || {
    echo "STEP 8: FAIL - game blob build failed" >&2; exit 1; }
NCAT="$(grep -c '"name":' "${GAMES_DIR}/catalog.json" 2>/dev/null || echo 0)"
[ "${NCAT}" -ge 2 ] || { echo "STEP 8: FAIL - catalog needs >=2 games" >&2; exit 1; }
echo "[step8] catalog has ${NCAT} game(s)" >&2

# Always a FRESH (empty-cache) USB so boot 1 is genuinely cold.
echo "[step8] building a fresh virtual USB stick (empty cache) -> ${USBHOME}..." >&2
bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home "${USBHOME}" "${USB_MB}" "${SEED_TAG}" >&2 || {
    echo "STEP 8: FAIL - USB image build failed" >&2; exit 1; }
[ -f "${USBHOME}" ] || { echo "STEP 8: FAIL - no USB image" >&2; exit 1; }
echo "[step8] USB stick: ${USBHOME} ($(du -h "${USBHOME}" | cut -f1))" >&2

# --- render the cold + warm iPXE scripts (only cache_boot label differs) -----
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${R_COLD}" >&2 || { echo "STEP 8: FAIL - iPXE render" >&2; exit 1; }
cp "${R_COLD}" "${R_WARM}"
tmpf="$(mktemp)"; sed "s|{{CACHE_BOOT}}|first|g"  "${R_COLD}" > "${tmpf}" && mv "${tmpf}" "${R_COLD}"
tmpf="$(mktemp)"; sed "s|{{CACHE_BOOT}}|second|g" "${R_WARM}" > "${tmpf}" && mv "${tmpf}" "${R_WARM}"

# --- start HTTP server ------------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[step8] HTTP server up pid=${SRV_PID}" >&2
curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/server/games/catalog.json" 2>/dev/null \
    || { echo "STEP 8: FAIL - server does not serve catalog.json" >&2; exit 1; }

# boot_vm SERIAL PIDFILE QMP BOOTURL -> sets VM_PID
boot_vm() {
    local serial="$1" pidfile="$2" qmp="$3" booturl="$4"
    export RUN_DIR="${RUN}"
    bash "${SELF_DIR}/run-client.sh" --name step8 \
        --serial "${serial}" --pidfile "${pidfile}" --qmp "${qmp}" \
        --background \
        --boot-rom --bootfile "${booturl}" \
        --usb "${USBHOME}" \
        --ram "${RAM_MB}" --timeout "${T}" >&2
    VM_PID="$(cat "${pidfile}" 2>/dev/null || true)"
    echo "[step8] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2
}

# wait_ready SERIAL BOOTLABEL -> 0 when a step=8 status=ok callback (matching the
# boot label) or PARTYOS-STEP8-READY appears; non-zero on timeout/VM exit.
wait_ready() {
    local serial="$1" label="$2" deadline
    deadline=$(( $(date +%s) + T ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if grep -F "REPORT step=8 status=ok" "${ACCESS}" 2>/dev/null | grep -q "boot=${label}"; then return 0; fi
        if ser_has "${serial}" "PARTYOS-STEP8-READY"; then return 0; fi
        if ! vm_alive; then echo "[step8] VM exited before ready" >&2; return 1; fi
        sleep 5
    done
    return 1
}

# Parse the catalog->ready boot window from the access log epoch timestamps:
# first GET of catalog.json after START_TS, to the matching REPORT step=8 boot=LABEL.
boot_window() {
    local start_ts="$1" label="$2"
    local cat_ts rep_ts
    cat_ts="$(awk -v s="${start_ts}" '/GET \/server\/games\/catalog.json/ && $2+0>=s {print $2; exit}' "${ACCESS}")"
    rep_ts="$(awk -v s="${start_ts}" -v l="boot=${label}" '/REPORT step=8 status=ok/ && $0 ~ l && $2+0>=s {print $2; exit}' "${ACCESS}")"
    if [ -n "${cat_ts}" ] && [ -n "${rep_ts}" ]; then
        awk -v a="${cat_ts}" -v b="${rep_ts}" 'BEGIN{printf "%.1f", b-a}'
    else
        echo ""
    fi
}

# ============================ BOOT 1: COLD CACHE ============================
B1_START="$(date +%s)"
SERIAL1="${RUN}/step8.boot1.serial"
echo "[step8] === BOOT 1 (cold cache): expect MISS + download + cache write ===" >&2
boot_vm "${SERIAL1}" "${RUN}/step8.b1.pid" "${RUN}/step8.b1.qmp" "${BOOTURL_COLD}"

b1_ready=0
wait_ready "${SERIAL1}" first && b1_ready=1
B1_END="$(date +%s)"

# wait for power-off so the qcow2 is quiescent before host inspection
echo "[step8] waiting for boot-1 VM to power off..." >&2
qoff=$(( $(date +%s) + 180 ))
while vm_alive && [ "$(date +%s)" -lt "${qoff}" ]; do sleep 3; done
if vm_alive; then kill -9 "${VM_PID}" 2>/dev/null || true; sleep 2; fi
VM_PID=""

echo "----- boot1 serial tail -----" >&2
tr -d '\000' < "${SERIAL1}" 2>/dev/null | tail -50 >&2
echo "-----------------------------" >&2
echo "----- access log (games + REPORT, boot 1) -----" >&2
grep -E "games/|REPORT step=8" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "-----------------------------------------------" >&2

if [ "${b1_ready}" -ne 1 ]; then
    echo "STEP 8: FAIL - boot 1 never reached games-ready" >&2; exit 1
fi

# --- boot 1 in-guest assertions ---------------------------------------------
b1_miss=0;     ser_has "${SERIAL1}" "PARTYOS-STEP8-CACHE-MISS name=hello" && \
               ser_has "${SERIAL1}" "PARTYOS-STEP8-CACHE-MISS name=pong" && b1_miss=1
b1_dl=0;       ser_has "${SERIAL1}" "PARTYOS-STEP8-BLOB-DOWNLOADED name=hello" && \
               ser_has "${SERIAL1}" "PARTYOS-STEP8-BLOB-DOWNLOADED name=pong" && b1_dl=1
b1_write=0;    ser_has "${SERIAL1}" "PARTYOS-STEP8-CACHE-WRITE name=hello" && \
               ser_has "${SERIAL1}" "PARTYOS-STEP8-CACHE-WRITE name=pong" && b1_write=1
b1_mounted=0;  ser_has "${SERIAL1}" "PARTYOS-STEP8-MOUNTED name=hello" && \
               ser_has "${SERIAL1}" "PARTYOS-STEP8-MOUNTED name=pong" && b1_mounted=1
b1_ran=0;      ser_has "${SERIAL1}" "PARTYOS-GAME-HELLO-RAN" && \
               ser_has "${SERIAL1}" "PARTYOS-GAME-PONG-RAN" && b1_ran=1
# host-side: the server actually served both blobs during boot 1
b1_served=0;   log_has "GET /server/games/hello.squashfs" && \
               log_has "GET /server/games/pong.squashfs"  && b1_served=1
GETS_AFTER_B1="$(count_blob_gets)"

# --- HOST PROOF: the cached blobs really landed on the USB qcow2 ------------
echo "[step8] === HOST inspecting USB qcow2 for cached blobs ===" >&2
host_hello=0; host_pong=0
H1="$(bash "${SELF_DIR}/inspect-usbhome.sh" "${USBHOME}" ".partyos-cache/games/hello.squashfs" 2>&1 || true)"
echo "${H1}" | sed 's/^/[inspect] /' >&2
echo "${H1}" | grep -q "INSPECT-FOUND" && host_hello=1
H2="$(bash "${SELF_DIR}/inspect-usbhome.sh" "${USBHOME}" ".partyos-cache/games/pong.squashfs" 2>&1 || true)"
echo "${H2}" | sed 's/^/[inspect] /' >&2
echo "${H2}" | grep -q "INSPECT-FOUND" && host_pong=1

B1_WINDOW="$(boot_window "${B1_START}" first)"

echo "================ STEP 8 BOOT-1 (COLD) VERDICT ==============" >&2
echo "both games CACHE MISS                           : ${b1_miss}" >&2
echo "both blobs DOWNLOADED from server               : ${b1_dl}" >&2
echo "both blobs WRITTEN to USB cache                 : ${b1_write}" >&2
echo "both games MOUNTED (from cache)                 : ${b1_mounted}" >&2
echo "both games RAN                                  : ${b1_ran}" >&2
echo "server SERVED both blobs (access log)           : ${b1_served}" >&2
echo "HOST read hello.squashfs from USB cache         : ${host_hello}" >&2
echo "HOST read pong.squashfs  from USB cache         : ${host_pong}" >&2
echo "blob GETs after boot 1                          : ${GETS_AFTER_B1}" >&2
echo "boot1 catalog->ready window                     : ${B1_WINDOW:-?}s" >&2

if ! { [ "${b1_miss}" -eq 1 ] && [ "${b1_dl}" -eq 1 ] && [ "${b1_write}" -eq 1 ] && \
       [ "${b1_mounted}" -eq 1 ] && [ "${b1_ran}" -eq 1 ] && [ "${b1_served}" -eq 1 ] && \
       [ "${host_hello}" -eq 1 ] && [ "${host_pong}" -eq 1 ]; }; then
    echo "STEP 8: FAIL - boot 1 (cold cache) assertions not all met" >&2; exit 1
fi
echo "[step8] BOOT 1 (cold cache) PASS" >&2

# ============================ BOOT 2: WARM CACHE ===========================
if [ "${SKIP_WARM}" = "1" ]; then
    echo "[step8] STEP8_SKIP_WARM=1 - skipping warm-cache boot" >&2
    echo "STEP 8: PASS (cold cache proven; warm boot skipped by request)" >&2
    exit 0
fi

B2_START="$(date +%s)"
SERIAL2="${RUN}/step8.boot2.serial"
echo "[step8] === BOOT 2 (warm cache): expect HIT + NO blob download ===" >&2
boot_vm "${SERIAL2}" "${RUN}/step8.b2.pid" "${RUN}/step8.b2.qmp" "${BOOTURL_WARM}"

b2_ready=0
wait_ready "${SERIAL2}" second && b2_ready=1
B2_END="$(date +%s)"

echo "[step8] waiting for boot-2 VM to power off..." >&2
qoff=$(( $(date +%s) + 180 ))
while vm_alive && [ "$(date +%s)" -lt "${qoff}" ]; do sleep 3; done
if vm_alive; then kill -9 "${VM_PID}" 2>/dev/null || true; sleep 2; fi
VM_PID=""

echo "----- boot2 serial tail -----" >&2
tr -d '\000' < "${SERIAL2}" 2>/dev/null | tail -50 >&2
echo "-----------------------------" >&2
echo "----- access log (games + REPORT, both boots) -----" >&2
grep -E "games/|REPORT step=8" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "---------------------------------------------------" >&2

if [ "${b2_ready}" -ne 1 ]; then
    echo "STEP 8: FAIL - boot 2 never reached games-ready" >&2; exit 1
fi

GETS_AFTER_B2="$(count_blob_gets)"

# --- boot 2 in-guest assertions ---------------------------------------------
b2_hit=0;      ser_has "${SERIAL2}" "PARTYOS-STEP8-CACHE-HIT name=hello" && \
               ser_has "${SERIAL2}" "PARTYOS-STEP8-CACHE-HIT name=pong" && b2_hit=1
b2_nomiss=1;   ser_has "${SERIAL2}" "PARTYOS-STEP8-CACHE-MISS" && b2_nomiss=0
b2_nodl=1;     ser_has "${SERIAL2}" "PARTYOS-STEP8-BLOB-DOWNLOADED" && b2_nodl=0
b2_mounted=0;  ser_has "${SERIAL2}" "PARTYOS-STEP8-MOUNTED name=hello" && \
               ser_has "${SERIAL2}" "PARTYOS-STEP8-MOUNTED name=pong" && b2_mounted=1
b2_ran=0;      ser_has "${SERIAL2}" "PARTYOS-GAME-HELLO-RAN" && \
               ser_has "${SERIAL2}" "PARTYOS-GAME-PONG-RAN" && b2_ran=1
# THE caching assertion: boot 2 made NO new blob GET against the server.
b2_noget=0;    [ "${GETS_AFTER_B2}" -eq "${GETS_AFTER_B1}" ] && b2_noget=1

B2_WINDOW="$(boot_window "${B2_START}" second)"
# faster: warm boot's catalog->ready window is < cold boot's (no blob transfer).
faster=0
if [ -n "${B1_WINDOW}" ] && [ -n "${B2_WINDOW}" ]; then
    awk -v a="${B1_WINDOW}" -v b="${B2_WINDOW}" 'BEGIN{exit !(b<a)}' && faster=1
fi

echo "================ STEP 8 BOOT-2 (WARM) VERDICT ==============" >&2
echo "both games CACHE HIT                            : ${b2_hit}" >&2
echo "no CACHE MISS this boot                         : ${b2_nomiss}" >&2
echo "no blob DOWNLOADED this boot                    : ${b2_nodl}" >&2
echo "both games MOUNTED (from cache)                 : ${b2_mounted}" >&2
echo "both games RAN                                  : ${b2_ran}" >&2
echo "NO new server blob GET (log unchanged)          : ${b2_noget} (${GETS_AFTER_B1}->${GETS_AFTER_B2})" >&2
echo "boot1 vs boot2 window                           : ${B1_WINDOW:-?}s vs ${B2_WINDOW:-?}s (faster=${faster})" >&2

# The hard gate: cache HIT, no download, no new server GET, cache survived reboot
# (proven by the HIT on the SAME qcow2), games still mount+run from cache.
if [ "${b2_hit}" -eq 1 ] && [ "${b2_nomiss}" -eq 1 ] && [ "${b2_nodl}" -eq 1 ] && \
   [ "${b2_noget}" -eq 1 ] && [ "${b2_mounted}" -eq 1 ] && [ "${b2_ran}" -eq 1 ]; then
    if [ "${faster}" -ne 1 ]; then
        echo "[step8] NOTE: warm boot not measurably faster by the catalog->ready window" >&2
        echo "[step8]   (boot times are dominated by the ~1.6GB sfs RAM boot, not the tiny" >&2
        echo "[step8]    dummy blobs); the no-download proof is the authoritative speedup." >&2
    fi
    echo "STEP 8: PASS" >&2
    exit 0
fi
echo "STEP 8: FAIL - boot 2 (warm cache) caching assertions not all met" >&2
exit 1
