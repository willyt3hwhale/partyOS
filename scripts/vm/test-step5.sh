#!/usr/bin/env bash
# test-step5.sh - autonomous VM test for Step 5 (Continuous Home Sync).
#
# What it proves, with no hardware and no keystrokes:
#   BOOT 1 (sync):
#     1. The custom image RAM-boots with the LANPARTY_HOME USB stick attached
#        (same machinery as Step 4), and step5-script.sh mounts it READ-WRITE.
#     2. A 45 s systemd timer (partyos-home-sync.timer) is ACTIVE -
#        the "continuous sync" requirement - and the rsync helper copies
#        /home/gamer -> the USB stick EXCLUDING cache/temp dirs.
#     3. A uniquely-tagged file written into /home/gamer reaches the USB mount,
#        while a .cache file is correctly EXCLUDED. Serial markers + a step=5
#        callback carry the token.
#     4. HOST-SIDE PROOF: after the VM powers off, the host reads the token out
#        of the USB qcow2 itself (debugfs in Docker; macOS cannot mount ext4) -
#        independent confirmation the RAM->USB sync actually landed on the stick.
#   BOOT 2 (persistence):
#     5. The SAME usbhome.qcow2 is re-booted; step5-script.sh in persist mode
#        mounts it, seeds /home/gamer, and asserts the token survived the reboot
#        (PARTYOS-STEP5-PERSISTED + persisted=1 callback).
#
# TCG note: on Apple Silicon the x86_64 guest runs under TCG, so each full RAM
# boot of the ~1.6GB custom image is slow; timeouts are generous and overridable
# (STEP5_TIMEOUT per boot). The persistence boot can be skipped with
# STEP5_SKIP_PERSIST=1 (the host-side qcow2 proof already shows the data is on
# the stick), but it runs by default.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${STEP5_RAM_MB:-10240}"
T="${STEP5_TIMEOUT:-2700}"              # per-boot boot+verify timeout (seconds)
ALIVE_WAIT="${STEP5_ALIVE_WAIT:-30}"
SEED_TAG="${STEP5_SEED_TAG:-partyos-step5}"
USB_MB="${STEP5_USB_MB:-256}"
SKIP_PERSIST="${STEP5_SKIP_PERSIST:-0}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
USBHOME="${STEP5_USBHOME:-${REPO_ROOT}/server/images/usbhome-step5.qcow2}"  # git-ignored
TMPL="${REPO_ROOT}/boot/partyos-step5.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-step5.ipxe"
PTMPL="${REPO_ROOT}/boot/partyos-step5-persist.ipxe.tmpl"
PRENDERED="${REPO_ROOT}/boot/partyos-step5-persist.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-step5.ipxe"
PBOOTURL="${SERVER_URL}/boot/partyos-step5-persist.ipxe"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-step5.XXXXXX")"
ACCESS="${RUN}/http_access.log"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ]; then rm -rf "${RUN}"; else
        echo "[step5] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

# --- 0. dependencies: custom image + a FRESH usb home stick -----------------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[step5] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "STEP 5: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "STEP 5: FAIL - no custom sfs" >&2; exit 1; }
echo "[step5] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

# Always build a fresh, dedicated usbhome image for this test (so prior runs do
# not leave a stale token on the stick and confuse the persistence check).
echo "[step5] building a fresh virtual USB home image (home/ subdir layout) -> ${USBHOME}..." >&2
# HOME_SUBDIR=1: lay the home tree under p2:/home (the BAKED partyos-home-pull /
# partyos-sync-home layout, USB_HOME=/mnt/usbhome/home), with .partyos-cache at the
# partition ROOT - so this test exercises the SHIPPED units, not a flat-root stick.
HOME_SUBDIR=1 bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home "${USBHOME}" "${USB_MB}" "${SEED_TAG}" >&2 || {
    echo "STEP 5: FAIL - USB home image build failed" >&2; exit 1; }
[ -f "${USBHOME}" ] || { echo "STEP 5: FAIL - no USB home image" >&2; exit 1; }
echo "[step5] USB home image: ${USBHOME} ($(du -h "${USBHOME}" | cut -f1))" >&2

# --- render the Step 5 iPXE script (sync boot) ------------------------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || {
    echo "STEP 5: FAIL - iPXE render" >&2; exit 1; }

# --- start HTTP server ------------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[step5] HTTP server up pid=${SRV_PID}" >&2

ser_has()   { [ -f "$1" ] && grep -qF -- "$2" "$1" 2>/dev/null; }
log_has()   { grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive()  { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
count_ser() { tr -d '\000' < "$1" 2>/dev/null | grep -cF -- "$2"; }

# boot_vm SERIAL PIDFILE QMP BOOTURL  -> sets VM_PID
boot_vm() {
    local serial="$1" pidfile="$2" qmp="$3" booturl="$4"
    export RUN_DIR="${RUN}"
    bash "${SELF_DIR}/run-client.sh" --name step5 \
        --serial "${serial}" --pidfile "${pidfile}" --qmp "${qmp}" \
        --background \
        --boot-rom --bootfile "${booturl}" \
        --usb "${USBHOME}" \
        --ram "${RAM_MB}" --timeout "${T}" >&2
    VM_PID="$(cat "${pidfile}" 2>/dev/null || true)"
    echo "[step5] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2
}

# wait_for SERIAL  -> waits up to T for STEP5-READY (serial or callback)
wait_for_ready() {
    local serial="$1" deadline
    deadline=$(( $(date +%s) + T ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if log_has "REPORT step=5 status=ok"; then return 0; fi
        if ser_has "${serial}" "PARTYOS-STEP5-READY"; then return 0; fi
        if ! vm_alive; then echo "[step5] VM exited before ready" >&2; return 1; fi
        sleep 5
    done
    return 1
}

# ============================ BOOT 1: SYNC ==================================
SERIAL1="${RUN}/step5.boot1.serial"
echo "[step5] === BOOT 1 (sync): waiting up to ${T}s for sync-ready ===" >&2
boot_vm "${SERIAL1}" "${RUN}/step5.b1.pid" "${RUN}/step5.b1.qmp" "${BOOTURL}"

got_ready=0
wait_for_ready "${SERIAL1}" && got_ready=1

echo "----- boot1 serial tail -----" >&2
tr -d '\000' < "${SERIAL1}" 2>/dev/null | tail -45 >&2
echo "-----------------------------" >&2
echo "----- access log (REPORT) -----" >&2
grep "REPORT" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "-------------------------------" >&2

if [ "${got_ready}" -ne 1 ]; then
    echo "STEP 5: FAIL - boot 1 never reached sync-ready" >&2
    exit 1
fi
echo "[step5] boot 1 sync-ready reached" >&2

# Capture the token (from serial PARTYOS-STEP5-TOKEN or the callback). Strip the
# serial console's trailing CR/whitespace (\r\n) so the token matches the bytes
# stored verbatim on the USB qcow2.
TOKEN="$(tr -d '\000\r' < "${SERIAL1}" 2>/dev/null | grep -F 'PARTYOS-STEP5-TOKEN' | tail -1 | awk '{print $NF}' | tr -d '[:space:]')"
[ -n "${TOKEN}" ] || TOKEN="$(grep -oE 'token=step5-[0-9]+-[0-9]+-[0-9]+' "${ACCESS}" 2>/dev/null | tail -1 | cut -d= -f2)"
echo "[step5] captured sync token: ${TOKEN:-<none>}" >&2
[ -n "${TOKEN}" ] || { echo "STEP 5: FAIL - could not capture sync token" >&2; exit 1; }

# Confirm system stayed up (heartbeats) during boot 1.
alive_before="$(count_ser "${SERIAL1}" 'PARTYOS-STEP5-ALIVE')"
ddl=$(( $(date +%s) + ALIVE_WAIT )); stayed=0
while [ "$(date +%s)" -lt "${ddl}" ]; do
    now="$(count_ser "${SERIAL1}" 'PARTYOS-STEP5-ALIVE')"
    if [ "${now:-0}" -gt "${alive_before:-0}" ]; then stayed=1; break; fi
    if ! vm_alive; then break; fi
    sleep 3
done

# Wait for the VM to power off so the qcow2 is quiescent before host inspection.
echo "[step5] waiting for boot-1 VM to power off (final sync runs on shutdown)..." >&2
qoff_ddl=$(( $(date +%s) + 180 ))
while vm_alive && [ "$(date +%s)" -lt "${qoff_ddl}" ]; do sleep 3; done
if vm_alive; then kill -9 "${VM_PID}" 2>/dev/null || true; sleep 2; fi
VM_PID=""

# --- in-guest assertions (boot 1) ------------------------------------------
mounted_rw=0; synced_g=0; excluded_g=0; timer_ok=0
ser_has "${SERIAL1}" "PARTYOS-STEP5-USBHOME-MOUNTED-RW" && mounted_rw=1
ser_has "${SERIAL1}" "PARTYOS-STEP5-TIMER-ACTIVE"       && timer_ok=1
ser_has "${SERIAL1}" "PARTYOS-STEP5-SYNCED-TO-USB"      && synced_g=1
ser_has "${SERIAL1}" "PARTYOS-STEP5-EXCLUDED-OK"        && excluded_g=1
grep -F "REPORT step=5 status=ok" "${ACCESS}" 2>/dev/null | grep -q "mounted_rw=1" && mounted_rw=1
grep -F "REPORT step=5 status=ok" "${ACCESS}" 2>/dev/null | grep -q "synced=1"     && synced_g=1
grep -F "REPORT step=5 status=ok" "${ACCESS}" 2>/dev/null | grep -q "excluded=1"   && excluded_g=1

# Guest also asserts the p2 ROOT (config/.partyos-cache) survived the --delete mirror.
root_g=0
ser_has "${SERIAL1}" "PARTYOS-STEP5-ROOT-PRESERVED" && root_g=1
grep -F "REPORT step=5 status=ok" "${ACCESS}" 2>/dev/null | grep -q "root_ok=1" && root_g=1

# --- HOST-SIDE PROOF: read the token off the USB qcow2 itself ---------------
# The BAKED units push the home tree to the p2:/home SUBDIR (USB_HOME=/mnt/usbhome/home),
# so the token lives at home/.partyos-sync-token on the stick - NOT the partition root.
echo "[step5] === HOST inspecting USB qcow2 for the synced token (home/ subdir) ===" >&2
host_synced=0
INSPECT_OUT="$(bash "${SELF_DIR}/inspect-usbhome.sh" "${USBHOME}" "home/.partyos-sync-token" 2>&1 || true)"
echo "${INSPECT_OUT}" | sed 's/^/[inspect] /' >&2
echo "${INSPECT_OUT}" | grep -qF "${TOKEN}" && host_synced=1
# Also confirm the excluded cache marker is ABSENT under p2:/home (host-side).
host_excluded=0
EXC_OUT="$(bash "${SELF_DIR}/inspect-usbhome.sh" "${USBHOME}" "home/.cache/excluded-marker" 2>&1 || true)"
echo "${EXC_OUT}" | grep -q "INSPECT-MISSING" && host_excluded=1
# Independently confirm the p2 ROOT cache (.partyos-cache, seeded at the partition
# ROOT by HOME_SUBDIR=1) was NOT deleted by the home --delete mirror (it lives
# outside p2:/home). The .partyos-cache/games dir always exists on this fixture;
# .partyos itself is only present when the fixture is seeded with a USERNAME.
host_root=0
ROOT_OUT="$(bash "${SELF_DIR}/inspect-usbhome.sh" "${USBHOME}" ".partyos-cache/.partyos-cache-token" 2>&1 || true)"
echo "${ROOT_OUT}" | grep -q "INSPECT-FOUND" && host_root=1

echo "================ STEP 5 BOOT-1 VERDICT ======================" >&2
echo "LANPARTY_HOME mounted READ-WRITE (baked svc)    : ${mounted_rw}" >&2
echo "baked every-45s sync timer ACTIVE               : ${timer_ok}" >&2
echo "guest saw token synced to p2:/home (baked push) : ${synced_g}" >&2
echo "guest saw .cache EXCLUDED                        : ${excluded_g}" >&2
echo "guest saw p2 ROOT config/cache PRESERVED        : ${root_g}" >&2
echo "HOST read token off USB qcow2 home/ (independent): ${host_synced}" >&2
echo "HOST confirmed .cache NOT on USB qcow2           : ${host_excluded}" >&2
echo "HOST confirmed .partyos at p2 ROOT survived     : ${host_root}" >&2
echo "system stayed up (heartbeats)                   : ${stayed}" >&2

boot1_ok=0
if [ "${mounted_rw}" -eq 1 ] && [ "${timer_ok}" -eq 1 ] && [ "${synced_g}" -eq 1 ] && \
   [ "${excluded_g}" -eq 1 ] && [ "${root_g}" -eq 1 ] && \
   [ "${host_synced}" -eq 1 ] && [ "${host_excluded}" -eq 1 ] && [ "${host_root}" -eq 1 ] && \
   [ "${stayed}" -eq 1 ]; then
    boot1_ok=1
fi
if [ "${boot1_ok}" -ne 1 ]; then
    echo "STEP 5: FAIL - boot 1 (sync) assertions not all met" >&2
    exit 1
fi
echo "[step5] BOOT 1 (sync) PASS" >&2

# ====================== BOOT 2: PERSISTENCE ================================
if [ "${SKIP_PERSIST}" = "1" ]; then
    echo "[step5] STEP5_SKIP_PERSIST=1 - skipping reboot/persistence boot" >&2
    echo "STEP 5: PASS (sync proven; persistence boot skipped by request)" >&2
    exit 0
fi

# Render the persistence template, then substitute the captured token.
bash "${SELF_DIR}/render-ipxe.sh" "${PTMPL}" "${PRENDERED}" >&2 || {
    echo "STEP 5: FAIL - persist iPXE render" >&2; exit 1; }
# {{PERSIST_TOKEN}} -> the token from boot 1.
tmpf="$(mktemp)"; sed "s|{{PERSIST_TOKEN}}|${TOKEN}|g" "${PRENDERED}" > "${tmpf}" && mv "${tmpf}" "${PRENDERED}"
echo "[step5] persistence iPXE rendered with token=${TOKEN}" >&2

SERIAL2="${RUN}/step5.boot2.serial"
echo "[step5] === BOOT 2 (persistence): re-booting the SAME USB stick ===" >&2
boot_vm "${SERIAL2}" "${RUN}/step5.b2.pid" "${RUN}/step5.b2.qmp" "${PBOOTURL}"

persisted=0
deadline=$(( $(date +%s) + T ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if log_has "REPORT step=5 status=ok" && grep -F "REPORT step=5 status=ok" "${ACCESS}" | grep -q "persisted=1"; then persisted=1; break; fi
    if ser_has "${SERIAL2}" "PARTYOS-STEP5-PERSISTED"; then persisted=1; break; fi
    if ! vm_alive; then echo "[step5] persist VM exited" >&2; break; fi
    sleep 5
done

echo "----- boot2 serial tail -----" >&2
tr -d '\000' < "${SERIAL2}" 2>/dev/null | tail -40 >&2
echo "-----------------------------" >&2

echo "================ STEP 5 BOOT-2 VERDICT ======================" >&2
echo "token persisted across reboot (USB + /home)     : ${persisted}" >&2

if [ "${persisted}" -ne 1 ]; then
    echo "STEP 5: FAIL - token did not persist across reboot" >&2
    exit 1
fi

echo "STEP 5: PASS" >&2
exit 0
