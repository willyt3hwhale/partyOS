#!/usr/bin/env bash
# test-eviction.sh - autonomous VM test for RAM lifecycle / eviction.
#
# The LOGIC under test is BAKED into the custom image (scripts/build/files/rootfs/):
#   /usr/local/bin/partyos-ram   the RAM lifecycle / eviction manager (projects a
#                                blob's RAM need from ram_min/ram_max metadata vs
#                                free RAM; prompts/decides what to unmount; safe
#                                unmount = drop overlay + free squashfs from RAM;
#                                refcounts idle vs in-use; non-interactive mode)
#   /usr/local/bin/partyos-app   the app-store backend (install gate calls
#                                partyos-ram ensure-room; launch brackets the run
#                                with mark-busy/mark-idle)
# The test DRIVES THE CLI BACKEND (not GUI clicks); a real click
# and this run share the same code path. The fetched eviction-script.sh runs the
# CLI and emits the proof from a REAL booted VM (serial markers + a step=eviction
# HTTP callback).
#
# One boot, with a FRESH LANPARTY_HOME stick. It proves:
#   1. blobs load (hello + dummy mounted); hello is marked IN USE.
#   2. launching pong under a TIGHT free-RAM budget (PARTYOS_FREE_MB, deterministic)
#      below pong.ram_min triggers a SHORTFALL detected FROM THE METADATA.
#   3. the manager evicts an IDLE blob (dummy) to make room - freeing RAM
#      (free_before -> free_after in the callback) - and pong then mounts.
#   4. the IN-USE blob (hello) is PROTECTED: it is NOT evicted and stays mounted.
#   HOST PROOF: the server actually served the catalog + the blobs (GET lines in
#   the HTTP access log) and the step=eviction status=ok callback carries the
#   before/after free-RAM figures.
#
# Heavy under TCG (Apple Silicon) - run on a KVM host via
# scripts/vm/remote-test.sh test-eviction. EVICTION_RAM_MB / EVICTION_TIMEOUT tune
# the boot.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${EVICTION_RAM_MB:-10240}"
T="${EVICTION_TIMEOUT:-2700}"
USB_MB="${EVICTION_USB_MB:-256}"
SEED_TAG="${EVICTION_SEED_TAG:-partyos-eviction}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
GAMES_DIR="${REPO_ROOT}/server/games"
USBHOME="${EVICTION_USBHOME:-${REPO_ROOT}/server/images/usbhome-eviction.qcow2}"  # git-ignored
TMPL="${REPO_ROOT}/boot/partyos-eviction.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-eviction.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-eviction.ipxe"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-eviction.XXXXXX")"
ACCESS="${RUN}/http_access.log"
SERIAL="${RUN}/eviction.serial"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    rm -f "${USBHOME}" 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[eviction] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

ser_has()   { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
log_has()   { grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive()  { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }

# --- 0. dependencies: custom image + game blobs + a FRESH usb stick ----------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[eviction] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "EVICTION: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "EVICTION: FAIL - no custom sfs" >&2; exit 1; }
echo "[eviction] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

echo "[eviction] building game catalog + blobs -> ${GAMES_DIR}..." >&2
bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" "${GAMES_DIR}" >&2 || {
    echo "EVICTION: FAIL - game blob build failed" >&2; exit 1; }
NCAT="$(grep -c '"name":' "${GAMES_DIR}/catalog.json" 2>/dev/null || echo 0)"
[ "${NCAT}" -ge 3 ] || { echo "EVICTION: FAIL - need >=3 apps (hello/pong/dummy)" >&2; exit 1; }
for g in hello pong dummy; do
    grep -q "\"name\": \"${g}\"" "${GAMES_DIR}/catalog.json" || { echo "EVICTION: FAIL - catalog missing ${g}" >&2; exit 1; }
done
echo "[eviction] catalog has ${NCAT} app(s) incl. hello/pong/dummy" >&2

echo "[eviction] building a fresh virtual USB stick -> ${USBHOME}..." >&2
rm -f "${USBHOME}"
bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home "${USBHOME}" "${USB_MB}" "${SEED_TAG}" >&2 || {
    echo "EVICTION: FAIL - USB image build failed" >&2; exit 1; }
[ -f "${USBHOME}" ] || { echo "EVICTION: FAIL - no USB image" >&2; exit 1; }

# --- render the iPXE script -------------------------------------------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || { echo "EVICTION: FAIL - iPXE render" >&2; exit 1; }

# --- start HTTP server ------------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[eviction] HTTP server up pid=${SRV_PID}" >&2
curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/server/games/catalog.json" 2>/dev/null \
    || { echo "EVICTION: FAIL - server does not serve catalog.json" >&2; exit 1; }

# --- boot the VM ------------------------------------------------------------
echo "[eviction] === booting custom image with a fresh USB stick ===" >&2
export RUN_DIR="${RUN}"
bash "${SELF_DIR}/run-client.sh" --name eviction \
    --serial "${SERIAL}" --pidfile "${RUN}/eviction.pid" --qmp "${RUN}/eviction.qmp" \
    --background \
    --boot-rom --bootfile "${BOOTURL}" \
    --usb "${USBHOME}" \
    --ram "${RAM_MB}" --timeout "${T}" >&2
VM_PID="$(cat "${RUN}/eviction.pid" 2>/dev/null || true)"
echo "[eviction] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

# --- wait for the ready callback / marker -----------------------------------
echo "[eviction] waiting up to ${T}s for eviction-ready..." >&2
ready=0
deadline=$(( $(date +%s) + T ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if grep -qF "REPORT step=eviction status=ok" "${ACCESS}" 2>/dev/null; then ready=1; break; fi
    if ser_has "PARTYOS-EVICT-READY"; then ready=1; break; fi
    if ! vm_alive; then echo "[eviction] VM exited before ready" >&2; break; fi
    sleep 5
done

# wait for power-off so the run is quiescent (QEMU flushes the serial file fully
# only as it exits - reading mid-flush would miss late markers)
echo "[eviction] waiting for VM to power off..." >&2
qoff=$(( $(date +%s) + 150 ))
while vm_alive && [ "$(date +%s)" -lt "${qoff}" ]; do sleep 3; done
if vm_alive; then kill -9 "${VM_PID}" 2>/dev/null || true; sleep 2; fi
VM_PID=""
sync; sleep 3   # let the serial file finish flushing to disk before we read it

# Read a CLEAN snapshot of the serial (NULs + CRs stripped) into a temp file, and
# assert against THAT file (not a captured var) so greps are stable. Retry the
# snapshot until the terminal marker is present - QEMU flushes the serial file
# lazily, so a read taken the instant the VM exits can miss late markers even
# though the access-log callback (HTTP, instant) already arrived.
CLEAN="${RUN}/eviction.clean"
snapshot() { tr -d '\000\r' < "${SERIAL}" 2>/dev/null > "${CLEAN}"; }
for _ in $(seq 1 30); do
    snapshot
    if grep -qF "PARTYOS-EVICT-READY" "${CLEAN}" || grep -qF "PARTYOS-EVICT NOT ready" "${CLEAN}"; then
        # require the EARLY markers too, so we never assert on a partial snapshot
        grep -qF "PARTYOS-EVICT-SETUP" "${CLEAN}" && grep -qF "PARTYOS-EVICT-FREED-OK" "${CLEAN}" && break
    fi
    sleep 1
done

echo "----- eviction serial tail -----" >&2
tail -80 "${CLEAN}" 2>/dev/null >&2
echo "--------------------------------" >&2
echo "----- access log (games + REPORT) -----" >&2
grep -E "games/|REPORT step=eviction" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "---------------------------------------" >&2

if [ "${ready}" -ne 1 ]; then
    echo "EVICTION: FAIL - never reached eviction-ready" >&2; exit 1
fi

# --- in-guest assertions (serial markers, grepped from the clean snapshot) ----
m() { grep -qF -- "$1" "${CLEAN}" 2>/dev/null; }
a_setup=0;     m "PARTYOS-EVICT-SETUP hello_mounted=1 dummy_mounted=1" && a_setup=1
a_short=0;     m "PARTYOS-RAM-SHORTFALL name=pong" && a_short=1
a_offer=0;     m "PARTYOS-RAM-OFFER idle=dummy in_use=hello" && a_offer=1
a_evdummy=0;   m "PARTYOS-RAM-EVICTED name=dummy" && a_evdummy=1
a_noevhello=0; m "PARTYOS-RAM-EVICTED name=hello" || a_noevhello=1
# protection proof: a direct evict of the RUNNING blob is refused (PROTECT) and it
# stays mounted - the manager never auto-evicts an in-use blob.
a_protect=0;   m "PARTYOS-RAM-PROTECT name=hello" && m "PARTYOS-EVICT-PROTECT-PROBE protected=1 hello_still_mounted=1" && a_protect=1
a_protok=0;    m "PARTYOS-EVICT-PROTECTED-OK hello_survives=1 dummy_gone=1" && a_protok=1
a_instok=0;    m "PARTYOS-EVICT-INSTALLED-OK name=pong mounted=1" && a_instok=1
a_freed=0;     m "PARTYOS-EVICT-FREED-OK before=" && a_freed=1
# free-RAM rose: parse before/after from the freed marker and assert after > before
free_before="$(grep -oE 'PARTYOS-EVICT-FREED-OK before=[0-9]+ after=[0-9]+' "${CLEAN}" | head -1 | grep -oE 'before=[0-9]+' | cut -d= -f2)"
free_after="$(grep -oE 'PARTYOS-EVICT-FREED-OK before=[0-9]+ after=[0-9]+' "${CLEAN}" | head -1 | grep -oE 'after=[0-9]+'  | cut -d= -f2)"
a_rose=0;      [ -n "${free_before}" ] && [ -n "${free_after}" ] && [ "${free_after}" -gt "${free_before}" ] && a_rose=1
# host-side: the server actually served the catalog + the blobs
h_cat=0;       log_has "GET /server/games/catalog.json" && h_cat=1
h_pong=0;      log_has "GET /server/games/pong.squashfs" && h_pong=1
# callback carried the proof
cb_ok=0;       grep -qF "REPORT step=eviction status=ok" "${ACCESS}" && cb_ok=1

echo "================ EVICTION VERDICT ==========================" >&2
echo "blobs pre-loaded (hello+dummy mounted)          : ${a_setup}" >&2
echo "shortfall detected FROM METADATA (pong)         : ${a_short}" >&2
echo "manager offered idle=dummy + in_use=hello       : ${a_offer}" >&2
echo "IDLE blob (dummy) evicted to free RAM           : ${a_evdummy}" >&2
echo "IN-USE blob (hello) NOT evicted                 : ${a_noevhello}" >&2
echo "IN-USE blob (hello) PROTECTED marker            : ${a_protect}" >&2
echo "post: hello survives + dummy gone               : ${a_protok}" >&2
echo "new blob (pong) MOUNTED after room made         : ${a_instok}" >&2
echo "RAM freed (before/after marker present)         : ${a_freed} (before=${free_before:-?} after=${free_after:-?})" >&2
echo "free RAM ROSE after eviction (after>before)     : ${a_rose}" >&2
echo "HOST: server served catalog                     : ${h_cat}" >&2
echo "HOST: server served pong.squashfs               : ${h_pong}" >&2
echo "step=eviction status=ok callback                : ${cb_ok}" >&2
echo "===========================================================" >&2

PASS=1
for v in "${a_setup}" "${a_short}" "${a_offer}" "${a_evdummy}" "${a_noevhello}" \
         "${a_protect}" "${a_protok}" "${a_instok}" "${a_freed}" "${a_rose}" \
         "${h_cat}" "${h_pong}" "${cb_ok}"; do
    [ "${v}" = "1" ] || PASS=0
done

if [ "${PASS}" -eq 1 ]; then
    echo "EVICTION: PASS" >&2
    exit 0
fi
echo "EVICTION: FAIL - not all assertions met" >&2
exit 1
