#!/usr/bin/env bash
# test-step4.sh - autonomous VM test for Step 4 (USB Home Directory Read).
#
# What it proves, with no hardware and no keystrokes:
#   1. A virtual USB HOME stick exists: a removable qcow2 with an ext4 filesystem
#      LABELLED 'LANPARTY_HOME', seeded with recognisable files (built by
#      create_usb.sh --image-home -> scripts/build/build-usbhome.sh, in Docker
#      since macOS has no mkfs.ext4). If missing, the test BUILDS it first.
#   2. A headless client VM auto-chains partyos-step4.ipxe (DHCP boot filename),
#      RAM-boots the SAME custom image as Step 3 (has the 'gamer' user) over HTTP
#      (copytoram), with the USB home stick attached as a removable USB drive.
#   3. The fetched step4-script.sh installs+starts a REAL systemd unit
#      (partyos-usbhome.service) that finds the stick by LABEL, mounts it at
#      /mnt/usbhome, and copies its contents into /home/gamer. Asserted via:
#        serial markers  PARTYOS-STEP4-USBHOME-MOUNTED
#                        PARTYOS-STEP4-HOME-POPULATED
#                        PARTYOS-STEP4-READY
#        HTTP callback   REPORT step=4 status=ok mounted=1 home=populated token=...
#   4. The partition STAYS mounted at /mnt/usbhome and the system stays up
#      (PARTYOS-STEP4-ALIVE heartbeats).
#
# TCG note: on Apple Silicon the x86_64 guest runs under TCG, so a full RAM boot
# of the ~1.6GB custom image is slow; the default timeout is generous and
# overridable via STEP4_TIMEOUT.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${STEP4_RAM_MB:-10240}"        # custom sfs + copytoram + cowspace + DE
T="${STEP4_TIMEOUT:-2700}"             # overall boot+verify timeout (seconds)
ALIVE_WAIT="${STEP4_ALIVE_WAIT:-30}"   # window to confirm system stays up
SEED_TAG="${STEP4_SEED_TAG:-partyos-step4}"
USB_MB="${STEP4_USB_MB:-256}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
USBHOME="${STEP4_USBHOME:-${REPO_ROOT}/server/images/usbhome.qcow2}"  # git-ignored (*.qcow2)
TMPL="${REPO_ROOT}/boot/partyos-step4.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-step4.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-step4.ipxe"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-step4.XXXXXX")"
SERIAL="${RUN}/step4.serial"
ACCESS="${RUN}/http_access.log"
QMP="${RUN}/step4.qmp"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ]; then rm -rf "${RUN}"; else
        echo "[step4] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

# --- 0. ensure the custom image exists (Step 3 dependency) -----------------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[step4] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "STEP 4: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "STEP 4: FAIL - no custom sfs" >&2; exit 1; }
echo "[step4] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

# --- 1. ensure the virtual USB HOME image exists (build if missing) ---------
if [ ! -f "${USBHOME}" ] || [ "${STEP4_FORCE_USB:-0}" = "1" ]; then
    echo "[step4] building virtual USB home image (home/ subdir layout) -> ${USBHOME} (Docker ext4)..." >&2
    # HOME_SUBDIR=1: the home tree lives under p2:/home (the BAKED partyos-home-pull
    # layout) so this test exercises the SHIPPED mount + pull, not a flat-root stick.
    HOME_SUBDIR=1 bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home "${USBHOME}" "${USB_MB}" "${SEED_TAG}" >&2 || {
        echo "STEP 4: FAIL - USB home image build failed" >&2; exit 1; }
fi
[ -f "${USBHOME}" ] || { echo "STEP 4: FAIL - no USB home image" >&2; exit 1; }
echo "[step4] USB home image: ${USBHOME} ($(du -h "${USBHOME}" | cut -f1))" >&2

# --- 2. render the Step 4 iPXE script --------------------------------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || {
    echo "STEP 4: FAIL - iPXE render" >&2; exit 1; }

# --- 3. start HTTP server --------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[step4] HTTP server up pid=${SRV_PID}" >&2

# --- 4. launch client VM with the USB home stick attached ------------------
export RUN_DIR="${RUN}"
bash "${SELF_DIR}/run-client.sh" --name step4 \
    --serial "${SERIAL}" --pidfile "${RUN}/step4.pid" --qmp "${QMP}" \
    --background \
    --boot-rom --bootfile "${BOOTURL}" \
    --usb "${USBHOME}" \
    --ram "${RAM_MB}" --timeout "${T}" >&2
VM_PID="$(cat "${RUN}/step4.pid" 2>/dev/null || true)"
echo "[step4] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

ser_has() { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
log_has() { [ -f "${ACCESS}" ] && grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive() { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
count_ser() { tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -cF -- "$1"; }

# --- 5. wait for the USB-home-ready proof ----------------------------------
echo "[step4] waiting up to ${T}s for usbhome-ready (serial marker or callback)" >&2
deadline=$(( $(date +%s) + T ))
got_ready=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if log_has "REPORT step=4 status=ok"; then got_ready=1; break; fi
    if ser_has "PARTYOS-STEP4-READY"; then got_ready=1; break; fi
    if ! vm_alive; then echo "[step4] VM exited before usbhome-ready" >&2; break; fi
    sleep 3
done

echo "----- serial tail -----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -40 >&2
echo "-----------------------" >&2
echo "----- access log (REPORT lines) -----" >&2
grep "REPORT" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "-------------------------------------" >&2

if [ "${got_ready}" -ne 1 ]; then
    echo "STEP 4: FAIL - never reached usbhome-ready" >&2
    exit 1
fi
echo "[step4] usbhome-ready reached" >&2

# --- 6. confirm the system STAYS up (heartbeats) ---------------------------
alive_before="$(count_ser 'PARTYOS-STEP4-ALIVE')"
echo "[step4] confirming system stays up (${ALIVE_WAIT}s, alive_before=${alive_before})" >&2
ddl=$(( $(date +%s) + ALIVE_WAIT ))
stayed=0
while [ "$(date +%s)" -lt "${ddl}" ]; do
    now="$(count_ser 'PARTYOS-STEP4-ALIVE')"
    if [ "${now:-0}" -gt "${alive_before:-0}" ] && vm_alive; then stayed=1; break; fi
    if ! vm_alive; then echo "[step4] VM died during stay-up window" >&2; break; fi
    sleep 3
done

# --- 7. assertions ---------------------------------------------------------
# mounted: LANPARTY_HOME mounted at /mnt/usbhome
mounted_ok=0
ser_has "PARTYOS-STEP4-USBHOME-MOUNTED" && mounted_ok=1
grep -F "REPORT step=4 status=ok" "${ACCESS}" 2>/dev/null | grep -q "mounted=1" && mounted_ok=1
# populated: seeded files copied into /home/gamer
populated_ok=0
ser_has "PARTYOS-STEP4-HOME-POPULATED" && populated_ok=1
grep -F "REPORT step=4 status=ok" "${ACCESS}" 2>/dev/null | grep -q "home=populated" && populated_ok=1
# seed tag present somewhere in the proof (ties /home/gamer data to THIS stick)
seed_ok=0
tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -q "${SEED_TAG}" && seed_ok=1
grep -F "REPORT step=4" "${ACCESS}" 2>/dev/null | grep -q "token=${SEED_TAG}" && seed_ok=1

# --- verdict ---------------------------------------------------------------
echo "================ STEP 4 VERDICT ==============================" >&2
echo "USB home LANPARTY_HOME mounted at /mnt/usbhome : ${mounted_ok}" >&2
echo "files appear in /home/gamer                    : ${populated_ok}" >&2
echo "seed tag '${SEED_TAG}' present in proof        : ${seed_ok}" >&2
echo "system stayed up (heartbeats)                  : ${stayed}" >&2

if [ "${mounted_ok}" -eq 1 ] && [ "${populated_ok}" -eq 1 ] && \
   [ "${seed_ok}" -eq 1 ] && [ "${stayed}" -eq 1 ]; then
    echo "STEP 4: PASS" >&2
    exit 0
fi
echo "STEP 4: FAIL" >&2
exit 1
