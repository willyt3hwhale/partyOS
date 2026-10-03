#!/usr/bin/env bash
# test-homeservices.sh - autonomous VM test for start-services-from-home:
# a participant hosts their OWN service that auto-starts on boot from their
# USB-backed HOME folder.
#
# The LOGIC under test is BAKED into the custom image (partyos-home-services.service
# -> /usr/local/bin/partyos-home-services, see scripts/build/files/rootfs/): a per-user
# boot hook that discovers ~/.partyos-services/ in the resolved user's home and
# starts each declared service AS THE USER, with state in the home. The fetched
# homeservices-script.sh brings the home up, runs that baked hook, and emits the
# proof from a REAL booted VM (serial markers + a step=homeservices HTTP callback).
#
# Two full boots:
#   (A) WITH a service: a LANPARTY_HOME stick seeded (USERNAME=svchost) with a
#       dummy home service ~/.partyos-services/partysvc.sh that binds a TCP port
#       and writes a marker file. Assert the service auto-started as svchost
#       (live pid owned by the user), is LISTENING on its port, and its state
#       (marker file) landed in the home owned by the user.
#   (B) WITHOUT a service: a plain LANPARTY_HOME stick (no services dir). Assert
#       the boot hook is a clean no-op (started=0) and nothing breaks - the system
#       still comes up healthy. SKIP with HOMESVC_SKIP_NONE=1.
#
# Heavy under TCG (Apple Silicon) - run on a KVM host via
# scripts/vm/remote-test.sh test-homeservices.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${HOMESVC_RAM_MB:-10240}"        # custom sfs + copytoram + cowspace + DE
T="${HOMESVC_TIMEOUT:-2700}"             # per-boot boot+verify timeout (seconds)
ALIVE_WAIT="${HOMESVC_ALIVE_WAIT:-30}"   # window to confirm system stays up
USB_MB="${HOMESVC_USB_MB:-256}"
SVC_NAME="${HOMESVC_SVC_NAME:-partysvc}"
SVC_PORT="${HOMESVC_SVC_PORT:-8099}"
USER_A="${HOMESVC_USER:-svchost}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
TMPL="${REPO_ROOT}/boot/partyos-homeservices.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-homeservices.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-homeservices.ipxe"

USB_SVC="${REPO_ROOT}/server/images/usbhome-homesvc-svc.qcow2"
USB_NONE="${REPO_ROOT}/server/images/usbhome-homesvc-none.qcow2"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-homesvc.XXXXXX")"
ACCESS="${RUN}/http_access.log"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    rm -f "${USB_SVC}" "${USB_NONE}" 2>/dev/null || true
    if [ "${rc}" -eq 0 ]; then rm -rf "${RUN}"; else
        echo "[homesvc] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

# --- 0. ensure the custom image exists (carries the baked home-services hook)-
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[homesvc] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "HOMESERVICES: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "HOMESERVICES: FAIL - no custom sfs" >&2; exit 1; }
echo "[homesvc] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

# --- 1. build the USB sticks -----------------------------------------------
# A: USERNAME=svchost + a seeded home service (binds port, writes marker).
echo "[homesvc] building USB (with service) -> ${USB_SVC##*/}" >&2
rm -f "${USB_SVC}"
USERNAME="${USER_A}" SEED_SERVICE=1 SVC_NAME="${SVC_NAME}" SVC_PORT="${SVC_PORT}" \
    bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home "${USB_SVC}" "${USB_MB}" "homesvc-svc" "${USER_A}" "" >&2 || {
    echo "HOMESERVICES: FAIL - USB(service) build failed" >&2; exit 1; }
[ -f "${USB_SVC}" ] || { echo "HOMESERVICES: FAIL - no USB(service) image" >&2; exit 1; }

if [ "${HOMESVC_SKIP_NONE:-0}" != "1" ]; then
    # B: plain stick, NO service (boots as gamer, no services dir).
    echo "[homesvc] building USB (no service) -> ${USB_NONE##*/}" >&2
    rm -f "${USB_NONE}"
    bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home "${USB_NONE}" "${USB_MB}" "homesvc-none" >&2 || {
        echo "HOMESERVICES: FAIL - USB(none) build failed" >&2; exit 1; }
    [ -f "${USB_NONE}" ] || { echo "HOMESERVICES: FAIL - no USB(none) image" >&2; exit 1; }
fi

# --- 2. start the HTTP server (shared across the boots) ---------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[homesvc] HTTP server up pid=${SRV_PID}" >&2

# --- helpers ---------------------------------------------------------------
SERIAL=""
ser_has()   { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
vm_alive()  { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
count_ser() { tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -cF -- "$1"; }
report_line() { tail -c +"${LOG_OFFSET:-1}" "${ACCESS}" 2>/dev/null | grep -F "REPORT step=homeservices status=ok" | tail -1; }

# Boot ONE case: render the ipxe with the given expect mode, boot with the given
# USB, wait for the ready callback/marker, confirm it stays up. Sets globals:
# GOT_READY, STAYED, SERIAL, and the report line for the caller to inspect.
run_case() {
    local name="$1" usb="$2" expect="$3"
    SERIAL="${RUN}/${name}.serial"
    local qmp="${RUN}/${name}.qmp" pidf="${RUN}/${name}.pid"
    LOG_OFFSET=$(( $(wc -c < "${ACCESS}" 2>/dev/null || echo 0) + 1 ))

    HOMESVC_EXPECT="${expect}" HOMESVC_NAME="${SVC_NAME}" HOMESVC_PORT="${SVC_PORT}" \
        bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || {
        echo "HOMESERVICES: FAIL - iPXE render" >&2; exit 1; }

    echo "[homesvc] === case ${name} (expect=${expect}): booting with ${usb##*/} ===" >&2
    export RUN_DIR="${RUN}"
    bash "${SELF_DIR}/run-client.sh" --name "${name}" \
        --serial "${SERIAL}" --pidfile "${pidf}" --qmp "${qmp}" \
        --background \
        --boot-rom --bootfile "${BOOTURL}" \
        --usb "${usb}" \
        --ram "${RAM_MB}" --timeout "${T}" >&2
    VM_PID="$(cat "${pidf}" 2>/dev/null || true)"
    echo "[homesvc] case ${name} VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

    echo "[homesvc] case ${name}: waiting up to ${T}s for homeservices-ready" >&2
    local deadline; deadline=$(( $(date +%s) + T ))
    GOT_READY=0
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if tail -c +"${LOG_OFFSET}" "${ACCESS}" 2>/dev/null | grep -qF "REPORT step=homeservices status=ok"; then GOT_READY=1; break; fi
        if ser_has "PARTYOS-HOMESVC-READY"; then GOT_READY=1; break; fi
        if ! vm_alive; then echo "[homesvc] case ${name} VM exited before ready" >&2; break; fi
        sleep 3
    done

    echo "----- case ${name} serial tail -----" >&2
    tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -45 >&2
    echo "----- case ${name} REPORT lines -----" >&2
    tail -c +"${LOG_OFFSET}" "${ACCESS}" 2>/dev/null | grep "REPORT step=homeservices" >&2 || echo "(none)" >&2
    echo "-------------------------------------" >&2

    local alive_before; alive_before="$(count_ser 'PARTYOS-HOMESVC-ALIVE')"
    STAYED=0
    local ddl; ddl=$(( $(date +%s) + ALIVE_WAIT ))
    while [ "$(date +%s)" -lt "${ddl}" ]; do
        local now; now="$(count_ser 'PARTYOS-HOMESVC-ALIVE')"
        if [ "${now:-0}" -gt "${alive_before:-0}" ] && vm_alive; then STAYED=1; break; fi
        if ! vm_alive; then break; fi
        sleep 3
    done

    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    wait "${VM_PID}" 2>/dev/null || true
    VM_PID=""
}

# --- 3. case A: a service auto-starts from home -----------------------------
run_case "homesvc-svc" "${USB_SVC}" "service"
RL="$(report_line)"
a_ready=$(( GOT_READY )); a_stayed=$(( STAYED ))
a_user="$(printf '%s' "${RL}" | grep -oE 'user=[^ ]+' | head -1 | cut -d= -f2)"
a_started="$(printf '%s' "${RL}" | grep -oE 'started=[^ ]+' | head -1 | cut -d= -f2)"
a_listen="$(printf '%s' "${RL}" | grep -oE 'listen=[^ ]+' | head -1 | cut -d= -f2)"
a_state="$(printf '%s' "${RL}" | grep -oE 'state=[^ ]+' | head -1 | cut -d= -f2)"
a_owner="$(printf '%s' "${RL}" | grep -oE 'owner=[^ ]+' | head -1 | cut -d= -f2)"
a_token="$(printf '%s' "${RL}" | grep -oE 'token=[^ ]+' | head -1 | cut -d= -f2)"
a_user_ok=0;    [ "${a_user}" = "${USER_A}" ] && a_user_ok=1
a_started_ok=0; [ "${a_started}" = "1" ] && a_started_ok=1
a_listen_ok=0;  [ "${a_listen}" = "1" ] && a_listen_ok=1
a_state_ok=0;   [ "${a_state}" = "ok" ] && a_state_ok=1
a_owner_ok=0;   [ "${a_owner}" = "${USER_A}" ] && a_owner_ok=1
a_token_ok=0;   [ -n "${a_token}" ] && a_token_ok=1
# Also confirm the service-started marker fired on serial (ran as the user).
a_marker_ok=0;  ser_has "PARTYOS-HOMESVC-STARTED" && a_marker_ok=1

# --- 4. case B: no service -> clean no-op -----------------------------------
b_ready=1; b_stayed=1; b_none_ok=1
if [ "${HOMESVC_SKIP_NONE:-0}" != "1" ]; then
    run_case "homesvc-none" "${USB_NONE}" "none"
    RLB="$(report_line)"
    b_ready=$(( GOT_READY )); b_stayed=$(( STAYED ))
    b_mode="$(printf '%s' "${RLB}" | grep -oE 'mode=[^ ]+' | head -1 | cut -d= -f2)"
    b_started="$(printf '%s' "${RLB}" | grep -oE 'started=[^ ]+' | head -1 | cut -d= -f2)"
    b_none_ok=0
    [ "${b_mode}" = "none" ] && [ "${b_started}" = "0" ] && ser_has "PARTYOS-HOMESVC-NONE-OK" && b_none_ok=1
fi

# --- 5. verdict ------------------------------------------------------------
echo "================ HOMESERVICES VERDICT =======================" >&2
echo "(A) service auto-starts from home: ready=${a_ready} stayed=${a_stayed}" >&2
echo "    user '${a_user}' = ${USER_A}                 : ${a_user_ok}" >&2
echo "    hook started a service (started=1)           : ${a_started_ok}" >&2
echo "    -STARTED marker (launched as the user)       : ${a_marker_ok}" >&2
echo "    service LISTENING on port ${SVC_PORT}        : ${a_listen_ok}" >&2
echo "    state marker in home (state=ok)              : ${a_state_ok}" >&2
echo "    pid owned by '${USER_A}' (owner=${a_owner})  : ${a_owner_ok}" >&2
echo "    service token present (token=${a_token})     : ${a_token_ok}" >&2
echo "(B) no service -> clean no-op: ready=${b_ready} stayed=${b_stayed} none_ok=${b_none_ok}" >&2
echo "=============================================================" >&2

PASS=1
for v in "${a_ready}" "${a_stayed}" "${a_user_ok}" "${a_started_ok}" "${a_marker_ok}" \
         "${a_listen_ok}" "${a_state_ok}" "${a_owner_ok}" "${a_token_ok}" \
         "${b_ready}" "${b_stayed}" "${b_none_ok}"; do
    [ "${v}" = "1" ] || PASS=0
done

if [ "${PASS}" -eq 1 ]; then
    echo "HOMESERVICES: PASS" >&2
    exit 0
fi
echo "HOMESERVICES: FAIL" >&2
exit 1
