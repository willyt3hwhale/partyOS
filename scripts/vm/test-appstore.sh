#!/usr/bin/env bash
# test-appstore.sh - autonomous VM test for the App Store / Launcher UX.
#
# The LOGIC under test is BAKED into the custom image (scripts/build/files/rootfs/):
#   /usr/local/bin/partyos-app        the app-store BACKEND CLI
#   gen-launchers -> per-app menu + desktop (category-subdir) icons = the store
# There is no store window; the install-on-click icons ARE the store.
# The test DRIVES THE CLI BACKEND (not GUI clicks); a real click
# and this run share the same partyos-app path. The fetched appstore-script.sh
# runs the CLI and emits the proof from a REAL booted VM (serial markers + a
# step=appstore HTTP callback).
#
# One boot, with a FRESH LANPARTY_HOME stick (empty cache) so installs are genuine
# downloads. It proves:
#   1. partyos-app list shows the LAN catalog (>=1; the dummy present).
#   2. install <dummy> on a not-yet-local blob -> cache MISS -> DOWNLOAD -> overlay
#      mount (PARTYOS-APP-CACHE-MISS / -DOWNLOADED / -INSTALLED; mount live).
#   3. launch <dummy> runs it from the mount (PARTYOS-GAME-DUMMY-RAN).
#   4. installed reflects state: dummy present after install, gone after remove.
#   5. install-launch <hello> (the one-click GUI path) auto-downloads+mounts+runs.
#   6. the App Store .desktop launcher + per-blob shortcuts are PRESENT.
#   HOST PROOF: the server actually served the catalog + the dummy + hello blobs
#   (GET lines in the HTTP access log), independent of the guest's word.
#
# Heavy under TCG (Apple Silicon) - run on a KVM host via
# scripts/vm/remote-test.sh test-appstore. APPSTORE_RAM_MB / APPSTORE_TIMEOUT tune
# the boot.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${APPSTORE_RAM_MB:-10240}"
T="${APPSTORE_TIMEOUT:-2700}"
USB_MB="${APPSTORE_USB_MB:-256}"
SEED_TAG="${APPSTORE_SEED_TAG:-partyos-appstore}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
GAMES_DIR="${REPO_ROOT}/server/games"
USBHOME="${APPSTORE_USBHOME:-${REPO_ROOT}/server/images/usbhome-appstore.qcow2}"  # git-ignored
TMPL="${REPO_ROOT}/boot/partyos-appstore.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-appstore.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-appstore.ipxe"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-appstore.XXXXXX")"
ACCESS="${RUN}/http_access.log"
SERIAL="${RUN}/appstore.serial"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    rm -f "${USBHOME}" 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[appstore] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

ser_has()   { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
log_has()   { grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive()  { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
count_ser() { tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -cF -- "$1"; }

# --- 0. dependencies: custom image + game blobs + a FRESH usb stick ----------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[appstore] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "APPSTORE: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "APPSTORE: FAIL - no custom sfs" >&2; exit 1; }
echo "[appstore] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

echo "[appstore] building game catalog + blobs -> ${GAMES_DIR}..." >&2
bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" "${GAMES_DIR}" >&2 || {
    echo "APPSTORE: FAIL - game blob build failed" >&2; exit 1; }
NCAT="$(grep -c '"name":' "${GAMES_DIR}/catalog.json" 2>/dev/null || echo 0)"
[ "${NCAT}" -ge 1 ] || { echo "APPSTORE: FAIL - empty catalog" >&2; exit 1; }
grep -q '"name": "dummy"' "${GAMES_DIR}/catalog.json" || { echo "APPSTORE: FAIL - catalog missing the dummy app" >&2; exit 1; }
echo "[appstore] catalog has ${NCAT} app(s)" >&2

echo "[appstore] building a fresh virtual USB stick (empty cache) -> ${USBHOME}..." >&2
rm -f "${USBHOME}"
bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home "${USBHOME}" "${USB_MB}" "${SEED_TAG}" >&2 || {
    echo "APPSTORE: FAIL - USB image build failed" >&2; exit 1; }
[ -f "${USBHOME}" ] || { echo "APPSTORE: FAIL - no USB image" >&2; exit 1; }

# --- render the iPXE script -------------------------------------------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || { echo "APPSTORE: FAIL - iPXE render" >&2; exit 1; }

# --- start HTTP server ------------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[appstore] HTTP server up pid=${SRV_PID}" >&2
curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/server/games/catalog.json" 2>/dev/null \
    || { echo "APPSTORE: FAIL - server does not serve catalog.json" >&2; exit 1; }

# --- boot the VM ------------------------------------------------------------
echo "[appstore] === booting custom image with a fresh USB stick ===" >&2
export RUN_DIR="${RUN}"
bash "${SELF_DIR}/run-client.sh" --name appstore \
    --serial "${SERIAL}" --pidfile "${RUN}/appstore.pid" --qmp "${RUN}/appstore.qmp" \
    --background \
    --boot-rom --bootfile "${BOOTURL}" \
    --usb "${USBHOME}" \
    --ram "${RAM_MB}" --timeout "${T}" >&2
VM_PID="$(cat "${RUN}/appstore.pid" 2>/dev/null || true)"
echo "[appstore] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

# --- wait for the ready callback / marker -----------------------------------
echo "[appstore] waiting up to ${T}s for appstore-ready..." >&2
ready=0
deadline=$(( $(date +%s) + T ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if grep -qF "REPORT step=appstore status=ok" "${ACCESS}" 2>/dev/null; then ready=1; break; fi
    if ser_has "PARTYOS-APPSTORE-READY"; then ready=1; break; fi
    if ! vm_alive; then echo "[appstore] VM exited before ready" >&2; break; fi
    sleep 5
done

# wait for power-off so the run is quiescent
echo "[appstore] waiting for VM to power off..." >&2
qoff=$(( $(date +%s) + 120 ))
while vm_alive && [ "$(date +%s)" -lt "${qoff}" ]; do sleep 3; done
if vm_alive; then kill -9 "${VM_PID}" 2>/dev/null || true; sleep 2; fi
VM_PID=""

echo "----- appstore serial tail -----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -70 >&2
echo "--------------------------------" >&2
echo "----- access log (games + REPORT) -----" >&2
grep -E "games/|REPORT step=appstore" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "---------------------------------------" >&2

if [ "${ready}" -ne 1 ]; then
    echo "APPSTORE: FAIL - never reached appstore-ready" >&2; exit 1
fi

# --- in-guest assertions (serial markers) -----------------------------------
a_list=0;      ser_has "PARTYOS-APPSTORE-LIST-OK" && \
               tr -d '\000' < "${SERIAL}" | grep -E "PARTYOS-APPSTORE-LIST-OK n=[1-9]" | grep -q "dummy_in_list=1" && a_list=1
a_miss=0;      ser_has "PARTYOS-APP-CACHE-MISS name=dummy" && a_miss=1
a_dl=0;        ser_has "PARTYOS-APP-DOWNLOADED name=dummy" && a_dl=1
a_inst=0;      ser_has "PARTYOS-APP-INSTALLED name=dummy" && \
               tr -d '\000' < "${SERIAL}" | grep -q "PARTYOS-APPSTORE-DUMMY-INSTALL .*installed=1" && a_inst=1
a_run=0;       ser_has "PARTYOS-GAME-DUMMY-RAN" && a_run=1
a_state=0;     tr -d '\000' < "${SERIAL}" | grep -q "PARTYOS-APPSTORE-INSTALLED-AFTER apps=.*dummy" && \
               ser_has "PARTYOS-APP-REMOVED name=dummy" && a_state=1
a_removed_gone=0; if tr -d '\000' < "${SERIAL}" | grep "PARTYOS-APPSTORE-INSTALLED-AFTER-REMOVE" | grep -q "dummy"; then a_removed_gone=0; else a_removed_gone=1; fi
a_oneclick=0;  ser_has "PARTYOS-GAME-HELLO-RAN" && a_oneclick=1
a_store=0;     tr -d '\000' < "${SERIAL}" | grep -q "PARTYOS-APPSTORE-DESKTOP-OK store=1" && a_store=1
a_shortcuts=0; tr -d '\000' < "${SERIAL}" | grep -E "PARTYOS-APPSTORE-DESKTOP-OK .*shortcuts=[1-9]" >/dev/null && a_shortcuts=1
# host-side: the server actually served the catalog + the dummy + hello blobs
h_cat=0;       log_has "GET /server/games/catalog.json" && h_cat=1
h_dummy=0;     log_has "GET /server/games/dummy.squashfs" && h_dummy=1
h_hello=0;     log_has "GET /server/games/hello.squashfs" && h_hello=1
# callback carried the proof
cb_ok=0;       grep -qF "REPORT step=appstore status=ok" "${ACCESS}" && cb_ok=1

echo "================ APP-STORE VERDICT =========================" >&2
echo "list shows catalog incl. dummy                  : ${a_list}" >&2
echo "install dummy: CACHE MISS                       : ${a_miss}" >&2
echo "install dummy: DOWNLOADED (not-yet-local)       : ${a_dl}" >&2
echo "install dummy: MOUNTED (overlay live)           : ${a_inst}" >&2
echo "launch dummy: RAN (game marker)                 : ${a_run}" >&2
echo "installed reflects state (present then removed) : ${a_state} / gone=${a_removed_gone}" >&2
echo "one-click install-launch hello RAN              : ${a_oneclick}" >&2
echo "App Store .desktop launcher present             : ${a_store}" >&2
echo "per-blob shortcuts generated (>=1)              : ${a_shortcuts}" >&2
echo "HOST: server served catalog                     : ${h_cat}" >&2
echo "HOST: server served dummy.squashfs              : ${h_dummy}" >&2
echo "HOST: server served hello.squashfs              : ${h_hello}" >&2
echo "step=appstore status=ok callback                : ${cb_ok}" >&2
echo "===========================================================" >&2

PASS=1
for v in "${a_list}" "${a_miss}" "${a_dl}" "${a_inst}" "${a_run}" "${a_state}" \
         "${a_removed_gone}" "${a_oneclick}" "${a_store}" "${a_shortcuts}" \
         "${h_cat}" "${h_dummy}" "${h_hello}" "${cb_ok}"; do
    [ "${v}" = "1" ] || PASS=0
done

if [ "${PASS}" -eq 1 ]; then
    echo "APPSTORE: PASS" >&2
    exit 0
fi
echo "APPSTORE: FAIL - not all assertions met" >&2
exit 1
