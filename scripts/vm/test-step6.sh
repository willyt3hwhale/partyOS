#!/usr/bin/env bash
# test-step6.sh - autonomous VM test for Step 6 (Hot-Plug USB Support).
#
# What it proves, with no hardware and no keystrokes - QMP device_del/device_add
# are the autonomous stand-in for physically yanking and reinserting the stick:
#   BASELINE:
#     1. The custom image RAM-boots with the LANPARTY_HOME USB stick attached
#        (same machinery as Steps 4/5); step6-script.sh mounts it READ-WRITE,
#        installs udev rules + add/remove handlers, starts the 45 s sync
#        timer, and signals PARTYOS-STEP6-READY (+ status=baseline callback).
#   REMOVE (host issues QMP device_del usb0):
#     2. The system KEEPS RUNNING (heartbeats continue) - removing the stick does
#        not crash the guest.
#     3. udev fires the removal handler: sync is PAUSED (timer stopped + pause
#        flag) and a NOTIFICATION fires (serial marker + status file + best-effort
#        notify-send). Markers PARTYOS-STEP6-USB-REMOVED / -SYNC-PAUSED /
#        -NOTIFY-REMOVED, callback status=removed paused=1 notified=1.
#     4. The guest writes a file (offline-while-removed.txt) WHILE the USB is gone.
#   REINSERT (host issues QMP drive_add + device_add usb0):
#     5. udev fires the add handler: the stick is remounted, sync RESUMES (timer
#        restarted + pause cleared), and the offline file is FLUSHED to the USB.
#        Markers PARTYOS-STEP6-USB-REINSERTED / -SYNC-RESUMED / -OFFLINE-FLUSHED,
#        callback status=ok resumed=1 flushed=1.
#   HOST PROOF:
#     6. After power-off the HOST mounts the USB qcow2 (debugfs) and confirms the
#        offline file's token is on the stick - independent proof the resume flush
#        landed, not just the guest's word for it.
#
# Timing: with KEEP_RUNDIR the http_access.log epoch timestamps give boot/transfer
# windows. On a KVM host a full custom-image RAM boot is ~1-3 min.
#
# Tunables: STEP6_RAM_MB, STEP6_TIMEOUT (per-boot), STEP6_USB_MB.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${STEP6_RAM_MB:-10240}"
T="${STEP6_TIMEOUT:-2700}"               # boot+baseline-ready timeout (seconds)
EVENT_T="${STEP6_EVENT_TIMEOUT:-300}"    # per hot-plug phase wait (seconds)
SEED_TAG="${STEP6_SEED_TAG:-partyos-step6}"
USB_MB="${STEP6_USB_MB:-256}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
USBHOME="${STEP6_USBHOME:-${REPO_ROOT}/server/images/usbhome-step6.qcow2}"  # git-ignored
TMPL="${REPO_ROOT}/boot/partyos-step6.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-step6.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-step6.ipxe"

# QMP qdev / drive ids must match how run-client.sh wires the FIRST USB stick:
#   -drive ...,if=none,id=usbdrv0  -device usb-storage,bus=xhci.0,drive=usbdrv0,id=usb0
USB_QDEV="usb0"
USB_DRIVE="usbdrv0"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-step6.XXXXXX")"
SERIAL="${RUN}/step6.serial"
ACCESS="${RUN}/http_access.log"
QMP="${RUN}/step6.qmp"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[step6] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

qmp() { bash "${SELF_DIR}/qmp.sh" "${QMP}" "$1"; }

ser_has()   { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
log_has()   { grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive()  { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
count_ser() { tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -cF -- "$1"; }

# --- 0. dependencies: custom image + a FRESH usb home stick -----------------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[step6] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "STEP 6: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "STEP 6: FAIL - no custom sfs" >&2; exit 1; }
echo "[step6] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

echo "[step6] building a fresh virtual USB home image (home/ subdir layout) -> ${USBHOME}..." >&2
# HOME_SUBDIR=1: the home tree lives under p2:/home (the BAKED partyos-home-pull /
# partyos-sync-home layout) so this test exercises the SHIPPED hot-plug + sync units.
HOME_SUBDIR=1 bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home "${USBHOME}" "${USB_MB}" "${SEED_TAG}" >&2 || {
    echo "STEP 6: FAIL - USB home image build failed" >&2; exit 1; }
[ -f "${USBHOME}" ] || { echo "STEP 6: FAIL - no USB home image" >&2; exit 1; }
echo "[step6] USB home image: ${USBHOME} ($(du -h "${USBHOME}" | cut -f1))" >&2

# Absolute path to the qcow2 for the QMP re-add (QEMU runs with this cwd anyway,
# but be explicit so device_add's blockdev finds the file).
USBHOME_ABS="$(cd "$(dirname "${USBHOME}")" && pwd)/$(basename "${USBHOME}")"

# --- render the Step 6 iPXE script ------------------------------------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || {
    echo "STEP 6: FAIL - iPXE render" >&2; exit 1; }

# --- start HTTP server ------------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[step6] HTTP server up pid=${SRV_PID}" >&2

# --- launch client VM with the USB home stick attached ----------------------
export RUN_DIR="${RUN}"
bash "${SELF_DIR}/run-client.sh" --name step6 \
    --serial "${SERIAL}" --pidfile "${RUN}/step6.pid" --qmp "${QMP}" \
    --background \
    --boot-rom --bootfile "${BOOTURL}" \
    --usb "${USBHOME}" \
    --ram "${RAM_MB}" --timeout "${T}" >&2
VM_PID="$(cat "${RUN}/step6.pid" 2>/dev/null || true)"
echo "[step6] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

# ============================ BASELINE ======================================
echo "[step6] === waiting up to ${T}s for baseline-ready ===" >&2
deadline=$(( $(date +%s) + T ))
baseline=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if log_has "REPORT step=6 status=baseline"; then baseline=1; break; fi
    if ser_has "PARTYOS-STEP6-READY"; then baseline=1; break; fi
    if ! vm_alive; then echo "[step6] VM exited before baseline-ready" >&2; break; fi
    sleep 5
done

echo "----- baseline serial tail -----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -40 >&2
echo "--------------------------------" >&2

if [ "${baseline}" -ne 1 ]; then
    echo "STEP 6: FAIL - never reached baseline-ready" >&2
    exit 1
fi
echo "[step6] baseline-ready reached" >&2

# Wait for the QMP socket to be live (it is created at launch but be safe).
for _ in $(seq 1 20); do [ -S "${QMP}" ] && break; sleep 0.5; done
[ -S "${QMP}" ] || { echo "STEP 6: FAIL - no QMP socket ${QMP}" >&2; exit 1; }

# Record a baseline heartbeat count so we can prove the system stays alive THROUGH
# the removal (not just that it was alive before).
alive_before_remove="$(count_ser 'PARTYOS-STEP6-ALIVE')"

# ============================ REMOVE (device_del) ===========================
echo "[step6] === QMP device_del ${USB_QDEV} (yank the stick) ===" >&2
DEL_OUT="$(qmp "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"${USB_QDEV}\"}}" 2>&1 || true)"
echo "${DEL_OUT}" | sed 's/^/[qmp-del] /' >&2
echo "${DEL_OUT}" | grep -q '"error"' && { echo "STEP 6: FAIL - device_del errored" >&2; exit 1; }

echo "[step6] waiting up to ${EVENT_T}s for removal reaction (pause + notify)" >&2
removed_ok=0
ddl=$(( $(date +%s) + EVENT_T ))
while [ "$(date +%s)" -lt "${ddl}" ]; do
    if log_has "REPORT step=6 status=removed"; then removed_ok=1; break; fi
    if ser_has "PARTYOS-STEP6-SYNC-PAUSED" && ser_has "PARTYOS-STEP6-NOTIFY-REMOVED"; then removed_ok=1; break; fi
    if ! vm_alive; then echo "[step6] VM DIED after removal (must keep running!)" >&2; break; fi
    sleep 3
done

# System-keeps-running proof: the VM is still alive AND its heartbeat counter
# advances AFTER the removal (the stick being pulled did not crash the guest).
# Poll a short window so a slow heartbeat tick (2s) is given time to land.
echo "[step6] confirming the system keeps running through the removal" >&2
kept_running=0
ddl=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "${ddl}" ]; do
    alive_after_remove="$(count_ser 'PARTYOS-STEP6-ALIVE')"
    if vm_alive && [ "${alive_after_remove:-0}" -gt "${alive_before_remove:-0}" ]; then
        kept_running=1; break
    fi
    if ! vm_alive; then echo "[step6] VM DIED after removal (must keep running!)" >&2; break; fi
    sleep 2
done

# Wait for the guest to write the offline file WHILE the USB is gone. The guest
# does this from its heartbeat loop on observing the removal; we must not reinsert
# until it has happened, otherwise there is nothing to flush on resume.
echo "[step6] waiting up to 60s for the offline-while-removed file to be written" >&2
offline_written=0
ddl=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "${ddl}" ]; do
    if ser_has "PARTYOS-STEP6-OFFLINE-FILE-WRITTEN"; then offline_written=1; break; fi
    if ! vm_alive; then break; fi
    sleep 2
done

echo "----- post-removal serial tail -----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -25 >&2
echo "------------------------------------" >&2

# ============================ REINSERT (device_add) =========================
# Re-add the backing drive first (it was freed when the device went away), then
# re-create the usb-storage device on the same xHCI bus with the same ids so the
# guest sees the SAME LANPARTY_HOME stick reappear and udev fires the add rule.
echo "[step6] === QMP re-add drive + device_add ${USB_QDEV} (reinsert the stick) ===" >&2

# drive_add (HMP-via-QMP human-monitor-command is the most portable way to bring
# back an if=none drive node across QEMU versions).
ADD_DRV_OUT="$(qmp "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"drive_add 0 file=${USBHOME_ABS},format=qcow2,if=none,id=${USB_DRIVE}\"}}" 2>&1 || true)"
echo "${ADD_DRV_OUT}" | sed 's/^/[qmp-drvadd] /' >&2

ADD_DEV_OUT="$(qmp "{\"execute\":\"device_add\",\"arguments\":{\"driver\":\"usb-storage\",\"id\":\"${USB_QDEV}\",\"bus\":\"xhci.0\",\"drive\":\"${USB_DRIVE}\",\"removable\":true}}" 2>&1 || true)"
echo "${ADD_DEV_OUT}" | sed 's/^/[qmp-devadd] /' >&2
echo "${ADD_DEV_OUT}" | grep -q '"error"' && { echo "STEP 6: WARN device_add reply had error (continuing to check guest)" >&2; }

echo "[step6] waiting up to ${EVENT_T}s for reinsertion reaction (resume + flush)" >&2
reinserted_ok=0
ddl=$(( $(date +%s) + EVENT_T ))
while [ "$(date +%s)" -lt "${ddl}" ]; do
    if log_has "REPORT step=6 status=ok"; then reinserted_ok=1; break; fi
    if ser_has "PARTYOS-STEP6-SYNC-RESUMED" && ser_has "PARTYOS-STEP6-OFFLINE-FLUSHED"; then reinserted_ok=1; break; fi
    if ! vm_alive; then echo "[step6] VM exited during reinsertion wait" >&2; break; fi
    sleep 3
done

echo "----- post-reinsert serial tail -----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -30 >&2
echo "-------------------------------------" >&2
echo "----- access log (REPORT lines) -----" >&2
grep "REPORT step=6" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "-------------------------------------" >&2

# Capture the offline token so the host can confirm it landed on the stick.
OFFLINE_TOKEN="$(tr -d '\000\r' < "${SERIAL}" 2>/dev/null | grep -F 'PARTYOS-STEP6-OFFLINE-FILE-WRITTEN' | tail -1 | grep -oE 'token=offline-[0-9]+-[0-9]+' | cut -d= -f2)"
[ -n "${OFFLINE_TOKEN}" ] || OFFLINE_TOKEN="$(grep -oE 'offline_token=offline-[0-9]+-[0-9]+' "${ACCESS}" 2>/dev/null | tail -1 | cut -d= -f2)"
echo "[step6] offline token: ${OFFLINE_TOKEN:-<none>}" >&2

# Let the guest power off so the qcow2 is quiescent before host inspection.
echo "[step6] waiting for VM to power off (final sync runs on shutdown)..." >&2
qoff_ddl=$(( $(date +%s) + 200 ))
while vm_alive && [ "$(date +%s)" -lt "${qoff_ddl}" ]; do sleep 3; done
if vm_alive; then kill -9 "${VM_PID}" 2>/dev/null || true; sleep 2; fi
VM_PID=""

# ============================ HOST PROOF ====================================
echo "[step6] === HOST inspecting USB qcow2 for the flushed offline file (home/ subdir) ===" >&2
host_flushed=0
if [ -n "${OFFLINE_TOKEN}" ]; then
    # The BAKED push mirrors the home tree to p2:/home, so the offline file lands at
    # home/offline-while-removed.txt on the stick - NOT the partition root.
    INSPECT_OUT="$(bash "${SELF_DIR}/inspect-usbhome.sh" "${USBHOME}" "home/offline-while-removed.txt" 2>&1 || true)"
    echo "${INSPECT_OUT}" | sed 's/^/[inspect] /' >&2
    echo "${INSPECT_OUT}" | grep -qF "${OFFLINE_TOKEN}" && host_flushed=1
else
    echo "[step6] WARN no offline token captured - skipping host flush proof" >&2
fi

# --- in-guest assertion roll-up ---------------------------------------------
g_removed=0;  ser_has "PARTYOS-STEP6-USB-REMOVED"      && g_removed=1
g_paused=0;   ser_has "PARTYOS-STEP6-SYNC-PAUSED"      && g_paused=1
g_notifyr=0;  ser_has "PARTYOS-STEP6-NOTIFY-REMOVED"   && g_notifyr=1
g_reins=0;    ser_has "PARTYOS-STEP6-USB-REINSERTED"   && g_reins=1
g_resumed=0;  ser_has "PARTYOS-STEP6-SYNC-RESUMED"     && g_resumed=1
g_flushed=0;  ser_has "PARTYOS-STEP6-OFFLINE-FLUSHED"  && g_flushed=1
g_notifyi=0;  ser_has "PARTYOS-STEP6-NOTIFY-REINSERTED" && g_notifyi=1

echo "==================== STEP 6 VERDICT =========================" >&2
echo "baseline mounted/timer/udev ready              : ${baseline}" >&2
echo "system KEPT RUNNING through removal (heartbeats): ${kept_running}" >&2
echo "udev saw removal                               : ${g_removed}" >&2
echo "sync PAUSED on removal                         : ${g_paused}" >&2
echo "removal NOTIFICATION fired                     : ${g_notifyr}" >&2
echo "offline file written while USB gone            : ${offline_written}" >&2
echo "udev saw reinsertion                           : ${g_reins}" >&2
echo "sync RESUMED on reinsertion                    : ${g_resumed}" >&2
echo "reinsertion NOTIFICATION fired                 : ${g_notifyi}" >&2
echo "offline file FLUSHED to USB (guest)            : ${g_flushed}" >&2
echo "HOST read offline file off USB qcow2           : ${host_flushed}" >&2
echo "(token=${OFFLINE_TOKEN:-none})" >&2

if [ "${baseline}" -eq 1 ] && [ "${kept_running}" -eq 1 ] && \
   [ "${g_removed}" -eq 1 ] && [ "${g_paused}" -eq 1 ] && [ "${g_notifyr}" -eq 1 ] && \
   [ "${offline_written}" -eq 1 ] && \
   [ "${g_reins}" -eq 1 ] && [ "${g_resumed}" -eq 1 ] && [ "${g_flushed}" -eq 1 ] && \
   [ "${host_flushed}" -eq 1 ]; then
    echo "STEP 6: PASS" >&2
    exit 0
fi
echo "STEP 6: FAIL - not all hot-plug assertions met" >&2
exit 1
