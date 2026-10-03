#!/usr/bin/env bash
# test-step9.sh - autonomous VM test for Step 9 (Server Boot Scripts).
#
# What it proves, with no hardware and no keystrokes (two boots of the SAME image):
#   BOOT 1 (config server UP):
#     1. The custom image RAM-boots (same machinery as Steps 3-8); step9-script.sh
#        FETCHES the SERVER-side per-boot script (server/boot-config.sh) over HTTP
#        and EXECUTES it BEFORE the desktop (PARTYOS-STEP9-SERVER-SCRIPT-FETCHED +
#        PARTYOS-STEP9-SERVER-SCRIPT-RAN rc=0).
#     2. The script's EFFECT is applied on the client and a SERVER-DRIVEN value
#        (announce=...) is carried back in the step=9 callback - proving the server
#        script (not a baked default) drove the client.
#     3. The headless XFCE desktop comes up (PARTYOS-STEP9-DESKTOP-READY + an active
#        xfce4-session).
#   BOOT 2 (config server KILLED before boot):
#     4. The OS server stays up (so the image still RAM-boots) but the SEPARATE
#        boot-script server is DEAD: the fetch fails, step9-script.sh tolerates it
#        (PARTYOS-STEP9-SERVER-SCRIPT-MISSING) and the client STILL reaches the
#        desktop (PARTYOS-STEP9-DESKTOP-READY) - failure tolerance.
#
# Two HTTP servers: the OS/report server on SERVER_PORT (serves kernel/initramfs/
# sfs + /report) stays up for BOTH boots; a SECOND boot-script server on
# CONFIG_PORT serves /server/boot-config.sh and is what gets KILLED for boot 2.
# config_url= in the iPXE script points step9-script.sh at the boot-script server.
#
# TCG note: each full RAM boot of the ~1.6GB custom image is slow on Apple Silicon;
# run this on a KVM host via scripts/vm/remote-test.sh test-step9. STEP9_TIMEOUT
# is per-boot; STEP9_SKIP_FAILTEST=1 runs only the server-up boot.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${STEP9_RAM_MB:-10240}"
T="${STEP9_TIMEOUT:-2700}"               # per-boot boot+verify timeout (seconds)
CONFIG_PORT="${STEP9_CONFIG_PORT:-8090}" # the SEPARATE boot-script server port
SKIP_FAILTEST="${STEP9_SKIP_FAILTEST:-0}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
BOOT_CONFIG="${REPO_ROOT}/server/boot-config.sh"
TMPL="${REPO_ROOT}/boot/partyos-step9.ipxe.tmpl"
R_UP="${REPO_ROOT}/boot/partyos-step9.ipxe"          # server-up boot (boot 1)
R_DOWN="${REPO_ROOT}/boot/partyos-step9-serverdown.ipxe"  # server-down boot (boot 2)
BOOTURL_UP="${SERVER_URL}/boot/partyos-step9.ipxe"
BOOTURL_DOWN="${SERVER_URL}/boot/partyos-step9-serverdown.ipxe"
CONFIG_URL="http://${SERVER_IP}:${CONFIG_PORT}/server/boot-config.sh"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-step9.XXXXXX")"
ACCESS="${RUN}/http_access.log"
CFGLOG="${RUN}/config_access.log"
SRV_PID=""
CFG_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${CFG_PID}" ] && kill "${CFG_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[step9] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

ser_has()   { [ -f "$1" ] && grep -qF -- "$2" "$1" 2>/dev/null; }
log_has()   { grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive()  { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }

# --- 0. dependencies: custom image + the server boot script ------------------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[step9] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "STEP 9: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "STEP 9: FAIL - no custom sfs" >&2; exit 1; }
echo "[step9] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2
[ -f "${BOOT_CONFIG}" ] || { echo "STEP 9: FAIL - no server boot script ${BOOT_CONFIG}" >&2; exit 1; }
echo "[step9] server boot script: ${BOOT_CONFIG}" >&2

# --- render the server-up + server-down iPXE scripts ------------------------
# Both carry config_url= pointing at the SEPARATE boot-script server; only the
# boot_label= differs (serverup vs serverdown) so the harness can tell them apart.
render() {
    local out="$1" label="$2"
    bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${out}" >&2 || { echo "STEP 9: FAIL - iPXE render" >&2; exit 1; }
    local tmpf
    tmpf="$(mktemp)"; sed -e "s|{{CONFIG_URL}}|${CONFIG_URL}|g" -e "s|{{BOOT_LABEL}}|${label}|g" "${out}" > "${tmpf}" && mv "${tmpf}" "${out}"
}
render "${R_UP}"   serverup
render "${R_DOWN}" serverdown

# --- start the OS/report HTTP server (stays up for BOTH boots) ---------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[step9] OS/report server up pid=${SRV_PID} port=${SERVER_PORT}" >&2

# --- start the SEPARATE boot-script (config) HTTP server ---------------------
: > "${CFGLOG}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${CONFIG_PORT}" >"${CFGLOG}" 2>&1 &
CFG_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${CONFIG_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[step9] boot-script (config) server up pid=${CFG_PID} port=${CONFIG_PORT}" >&2
curl -fsS -o /dev/null "http://127.0.0.1:${CONFIG_PORT}/server/boot-config.sh" 2>/dev/null \
    || { echo "STEP 9: FAIL - config server does not serve boot-config.sh" >&2; exit 1; }
echo "[step9] config server serves boot-config.sh OK (host check)" >&2

# boot_vm SERIAL PIDFILE QMP BOOTURL -> sets VM_PID
boot_vm() {
    local serial="$1" pidfile="$2" qmp="$3" booturl="$4"
    export RUN_DIR="${RUN}"
    bash "${SELF_DIR}/run-client.sh" --name step9 \
        --serial "${serial}" --pidfile "${pidfile}" --qmp "${qmp}" \
        --background \
        --boot-rom --bootfile "${booturl}" \
        --ram "${RAM_MB}" --timeout "${T}" >&2
    VM_PID="$(cat "${pidfile}" 2>/dev/null || true)"
    echo "[step9] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2
}

# wait_ready SERIAL -> 0 when PARTYOS-STEP9-DESKTOP-READY appears on serial (the
# proof that works even when the callback can't reach a down server); non-zero on
# timeout/VM exit.
wait_ready() {
    local serial="$1" deadline
    deadline=$(( $(date +%s) + T ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if ser_has "${serial}" "PARTYOS-STEP9-DESKTOP-READY"; then return 0; fi
        if ! vm_alive; then echo "[step9] VM exited before desktop-ready" >&2; return 1; fi
        sleep 5
    done
    return 1
}

wait_poweroff() {
    local qoff; qoff=$(( $(date +%s) + 180 ))
    while vm_alive && [ "$(date +%s)" -lt "${qoff}" ]; do sleep 3; done
    if vm_alive; then kill -9 "${VM_PID}" 2>/dev/null || true; sleep 2; fi
    VM_PID=""
}

# ======================= BOOT 1: CONFIG SERVER UP ==========================
SERIAL1="${RUN}/step9.boot1.serial"
echo "[step9] === BOOT 1 (config server UP): expect server script run + effect applied ===" >&2
boot_vm "${SERIAL1}" "${RUN}/step9.b1.pid" "${RUN}/step9.b1.qmp" "${BOOTURL_UP}"

b1_ready=0
wait_ready "${SERIAL1}" && b1_ready=1
echo "[step9] waiting for boot-1 VM to power off..." >&2
wait_poweroff

echo "----- boot1 serial tail -----" >&2
tr -d '\000' < "${SERIAL1}" 2>/dev/null | tail -50 >&2
echo "-----------------------------" >&2
echo "----- OS server access log (REPORT step=9) -----" >&2
grep -E "REPORT step=9|boot-config" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "----- config server access log (boot-config.sh GETs) -----" >&2
grep -E "boot-config.sh" "${CFGLOG}" 2>/dev/null >&2 || echo "(none)" >&2
echo "-----------------------------------------------" >&2

if [ "${b1_ready}" -ne 1 ]; then
    echo "STEP 9: FAIL - boot 1 never reached desktop-ready" >&2; exit 1
fi

# --- boot 1 in-guest assertions ---------------------------------------------
b1_fetched=0;  ser_has "${SERIAL1}" "PARTYOS-STEP9-SERVER-SCRIPT-FETCHED" && b1_fetched=1
b1_ran=0;      ser_has "${SERIAL1}" "PARTYOS-STEP9-SERVER-SCRIPT-RAN rc=0" && b1_ran=1
b1_effect=0;   ser_has "${SERIAL1}" "PARTYOS-STEP9-SERVER-EFFECT announce=" && b1_effect=1
b1_desktop=0;  ser_has "${SERIAL1}" "PARTYOS-STEP9-DESKTOP-READY" && b1_desktop=1
b1_session=0;  ser_has "${SERIAL1}" "PARTYOS-STEP9-SESSION-ACTIVE" && \
               ser_has "${SERIAL1}" "xfce4-session=yes" && b1_session=1
# HOST proof: the config server actually served the boot script to the guest.
b1_served=0;   grep -qE 'GET /server/boot-config.sh' "${CFGLOG}" 2>/dev/null && b1_served=1
# callback carries the SERVER-driven announce value (effect proven end-to-end).
b1_callback=0; grep -E "REPORT step=9 status=ok" "${ACCESS}" 2>/dev/null | grep -q "server_script=ran" && \
               grep -E "REPORT step=9 status=ok" "${ACCESS}" 2>/dev/null | grep -q "announce=" && b1_callback=1

echo "================ STEP 9 BOOT-1 (SERVER UP) VERDICT ==============" >&2
echo "server boot script FETCHED                      : ${b1_fetched}" >&2
echo "server boot script RAN rc=0                     : ${b1_ran}" >&2
echo "server-driven EFFECT (announce) on client       : ${b1_effect}" >&2
echo "config server SERVED boot-config.sh (host log)  : ${b1_served}" >&2
echo "callback carries server_script=ran + announce   : ${b1_callback}" >&2
echo "headless XFCE DESKTOP-READY                      : ${b1_desktop}" >&2
echo "active xfce4-session                            : ${b1_session}" >&2

if ! { [ "${b1_fetched}" -eq 1 ] && [ "${b1_ran}" -eq 1 ] && [ "${b1_effect}" -eq 1 ] && \
       [ "${b1_served}" -eq 1 ] && [ "${b1_callback}" -eq 1 ] && \
       [ "${b1_desktop}" -eq 1 ] && [ "${b1_session}" -eq 1 ]; }; then
    echo "STEP 9: FAIL - boot 1 (server up) assertions not all met" >&2; exit 1
fi
echo "[step9] BOOT 1 (server up) PASS" >&2

# ==================== BOOT 2: CONFIG SERVER KILLED =========================
if [ "${SKIP_FAILTEST}" = "1" ]; then
    echo "[step9] STEP9_SKIP_FAILTEST=1 - skipping server-down boot" >&2
    echo "STEP 9: PASS (server-up proven; failure-tolerance boot skipped by request)" >&2
    exit 0
fi

echo "[step9] === KILLING the boot-script (config) server before boot 2 ===" >&2
kill "${CFG_PID}" 2>/dev/null || true
wait "${CFG_PID}" 2>/dev/null || true
CFG_PID=""
# Confirm it is genuinely down from the host side.
if curl -s --max-time 3 -o /dev/null "http://127.0.0.1:${CONFIG_PORT}/server/boot-config.sh" 2>/dev/null; then
    echo "STEP 9: FAIL - config server still answering after kill" >&2; exit 1
fi
echo "[step9] config server confirmed DOWN (port ${CONFIG_PORT})" >&2
# Sanity: the OS server is still up (so the image can still RAM-boot).
curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/server/images/custom/arch/x86_64/airootfs.sfs" 2>/dev/null \
    || { echo "STEP 9: FAIL - OS server unexpectedly down before boot 2" >&2; exit 1; }
echo "[step9] OS server still UP (port ${SERVER_PORT}) - image can RAM-boot" >&2

SERIAL2="${RUN}/step9.boot2.serial"
echo "[step9] === BOOT 2 (config server DOWN): expect MISSING tolerated + desktop still reached ===" >&2
boot_vm "${SERIAL2}" "${RUN}/step9.b2.pid" "${RUN}/step9.b2.qmp" "${BOOTURL_DOWN}"

b2_ready=0
wait_ready "${SERIAL2}" && b2_ready=1
echo "[step9] waiting for boot-2 VM to power off..." >&2
wait_poweroff

echo "----- boot2 serial tail -----" >&2
tr -d '\000' < "${SERIAL2}" 2>/dev/null | tail -50 >&2
echo "-----------------------------" >&2

if [ "${b2_ready}" -ne 1 ]; then
    echo "STEP 9: FAIL - boot 2 never reached desktop-ready (server-down boot must STILL reach desktop)" >&2; exit 1
fi

# --- boot 2 in-guest assertions: failure tolerated, desktop still reached ----
b2_missing=0;  ser_has "${SERIAL2}" "PARTYOS-STEP9-SERVER-SCRIPT-MISSING" && b2_missing=1
b2_noran=1;    ser_has "${SERIAL2}" "PARTYOS-STEP9-SERVER-SCRIPT-RAN" && b2_noran=0
b2_desktop=0;  ser_has "${SERIAL2}" "PARTYOS-STEP9-DESKTOP-READY" && b2_desktop=1
b2_session=0;  ser_has "${SERIAL2}" "PARTYOS-STEP9-SESSION-ACTIVE" && \
               ser_has "${SERIAL2}" "xfce4-session=yes" && b2_session=1

echo "================ STEP 9 BOOT-2 (SERVER DOWN) VERDICT ==============" >&2
echo "server script MISSING tolerated (no crash)      : ${b2_missing}" >&2
echo "server script did NOT run (server was down)      : ${b2_noran}" >&2
echo "headless XFCE DESKTOP-READY despite server down  : ${b2_desktop}" >&2
echo "active xfce4-session despite server down         : ${b2_session}" >&2

if [ "${b2_missing}" -eq 1 ] && [ "${b2_noran}" -eq 1 ] && \
   [ "${b2_desktop}" -eq 1 ] && [ "${b2_session}" -eq 1 ]; then
    echo "STEP 9: PASS" >&2
    exit 0
fi
echo "STEP 9: FAIL - boot 2 (server down) failure-tolerance assertions not all met" >&2
exit 1
