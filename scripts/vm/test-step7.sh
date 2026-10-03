#!/usr/bin/env bash
# test-step7.sh - autonomous VM test for Step 7 (Game Blob Distribution).
#
# What it proves, with no hardware and no keystrokes:
#   1. The server hosts a game CATALOG (server/games/catalog.json) + compressed
#      game BLOBS (squashfs). build-game-blobs.sh builds two tiny DUMMY games (a
#      run.sh printing a unique marker) so the run is fast + deterministic.
#   2. The custom image RAM-boots (same machinery as Steps 3-6); step7-script.sh
#      fetches the catalog (PARTYOS-STEP7-CATALOG-OK), downloads each blob
#      (PARTYOS-STEP7-BLOB-DOWNLOADED, sha-verified), and MOUNTS each via
#      squashfs+overlayfs to /home/gamer/games/<name> (PARTYOS-STEP7-MOUNTED).
#   3. Each dummy game RUNS from its mounted blob and emits its marker
#      (PARTYOS-STEP7-GAME-RAN + the game's own PARTYOS-GAME-*-RAN marker).
#   4. BOTH games are mounted SIMULTANEOUSLY (PARTYOS-STEP7-MULTI-MOUNT n>=2).
#   5. A consolidated step=7 status=ok callback carries games/mounted/ran counts.
#   HOST PROOF: the harness independently confirms the server actually served the
#   catalog + both blobs (GET lines in the HTTP access log).
#
# Timing: with KEEP_RUNDIR the http_access.log epoch timestamps give boot/
# transfer windows. On a KVM host a full custom-image RAM boot is ~1-3 min.
#
# Tunables: STEP7_RAM_MB, STEP7_TIMEOUT.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${STEP7_RAM_MB:-10240}"
T="${STEP7_TIMEOUT:-2700}"               # boot+verify timeout (seconds)

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
GAMES_DIR="${REPO_ROOT}/server/games"
TMPL="${REPO_ROOT}/boot/partyos-step7.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-step7.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-step7.ipxe"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-step7.XXXXXX")"
SERIAL="${RUN}/step7.serial"
ACCESS="${RUN}/http_access.log"
QMP="${RUN}/step7.qmp"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[step7] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

ser_has()  { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
log_has()  { grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive() { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }

# --- 0. dependencies: custom image + freshly-built game blobs ----------------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[step7] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "STEP 7: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "STEP 7: FAIL - no custom sfs" >&2; exit 1; }
echo "[step7] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

echo "[step7] building game catalog + blobs -> ${GAMES_DIR}..." >&2
bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" "${GAMES_DIR}" >&2 || {
    echo "STEP 7: FAIL - game blob build failed" >&2; exit 1; }
[ -f "${GAMES_DIR}/catalog.json" ] || { echo "STEP 7: FAIL - no catalog.json" >&2; exit 1; }
NCAT="$(grep -c '"name":' "${GAMES_DIR}/catalog.json" 2>/dev/null || echo 0)"
echo "[step7] catalog has ${NCAT} game(s); blobs: $(ls "${GAMES_DIR}"/*.squashfs 2>/dev/null | wc -l | tr -d ' ')" >&2
[ "${NCAT}" -ge 2 ] || { echo "STEP 7: FAIL - catalog needs >=2 games" >&2; exit 1; }

# --- render the Step 7 iPXE script ------------------------------------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || {
    echo "STEP 7: FAIL - iPXE render" >&2; exit 1; }

# --- start HTTP server ------------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[step7] HTTP server up pid=${SRV_PID}" >&2

# Sanity: the server actually serves the catalog + blobs from the host side.
curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/server/games/catalog.json" 2>/dev/null \
    || { echo "STEP 7: FAIL - server does not serve catalog.json" >&2; exit 1; }
echo "[step7] server serves catalog.json OK (host check)" >&2

# --- launch client VM (no USB; games come from the server) -------------------
export RUN_DIR="${RUN}"
bash "${SELF_DIR}/run-client.sh" --name step7 \
    --serial "${SERIAL}" --pidfile "${RUN}/step7.pid" --qmp "${QMP}" \
    --background \
    --boot-rom --bootfile "${BOOTURL}" \
    --ram "${RAM_MB}" --timeout "${T}" >&2
VM_PID="$(cat "${RUN}/step7.pid" 2>/dev/null || true)"
echo "[step7] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

# --- wait for ready ----------------------------------------------------------
echo "[step7] === waiting up to ${T}s for game-blobs-ready ===" >&2
deadline=$(( $(date +%s) + T ))
got_ready=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if log_has "REPORT step=7 status=ok"; then got_ready=1; break; fi
    if ser_has "PARTYOS-STEP7-READY"; then got_ready=1; break; fi
    if ! vm_alive; then echo "[step7] VM exited before ready" >&2; break; fi
    sleep 5
done

echo "----- step7 serial tail -----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -55 >&2
echo "-----------------------------" >&2
echo "----- access log (games + REPORT) -----" >&2
grep -E "games/|REPORT step=7" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "---------------------------------------" >&2

if [ "${got_ready}" -ne 1 ]; then
    echo "STEP 7: FAIL - never reached game-blobs-ready" >&2
    exit 1
fi

# --- in-guest assertion roll-up ---------------------------------------------
g_catalog=0; ser_has "PARTYOS-STEP7-CATALOG-OK"   && g_catalog=1
g_dl_hello=0; ser_has "PARTYOS-STEP7-BLOB-DOWNLOADED name=hello" && g_dl_hello=1
g_dl_pong=0;  ser_has "PARTYOS-STEP7-BLOB-DOWNLOADED name=pong"  && g_dl_pong=1
g_mnt_hello=0; ser_has "PARTYOS-STEP7-MOUNTED name=hello" && g_mnt_hello=1
g_mnt_pong=0;  ser_has "PARTYOS-STEP7-MOUNTED name=pong"  && g_mnt_pong=1
g_ran_hello=0; ser_has "PARTYOS-GAME-HELLO-RAN" && g_ran_hello=1
g_ran_pong=0;  ser_has "PARTYOS-GAME-PONG-RAN"  && g_ran_pong=1
g_multi=0;     ser_has "PARTYOS-STEP7-MULTI-MOUNT" && g_multi=1

# HOST proof: the server actually served the catalog + both blobs to the guest.
h_catalog=0; log_has "GET /server/games/catalog.json"  && h_catalog=1
h_hello=0;   log_has "GET /server/games/hello.squashfs" && h_hello=1
h_pong=0;    log_has "GET /server/games/pong.squashfs"  && h_pong=1

echo "==================== STEP 7 VERDICT =========================" >&2
echo "catalog fetched + parsed (guest)               : ${g_catalog}" >&2
echo "blob downloaded: hello / pong                  : ${g_dl_hello} / ${g_dl_pong}" >&2
echo "blob mounted (squashfs+overlay): hello / pong  : ${g_mnt_hello} / ${g_mnt_pong}" >&2
echo "game ran from mount: hello / pong              : ${g_ran_hello} / ${g_ran_pong}" >&2
echo "TWO games mounted SIMULTANEOUSLY               : ${g_multi}" >&2
echo "HOST served catalog / hello.squashfs / pong    : ${h_catalog} / ${h_hello} / ${h_pong}" >&2

if [ "${g_catalog}" -eq 1 ] && \
   [ "${g_dl_hello}" -eq 1 ] && [ "${g_dl_pong}" -eq 1 ] && \
   [ "${g_mnt_hello}" -eq 1 ] && [ "${g_mnt_pong}" -eq 1 ] && \
   [ "${g_ran_hello}" -eq 1 ] && [ "${g_ran_pong}" -eq 1 ] && \
   [ "${g_multi}" -eq 1 ] && \
   [ "${h_catalog}" -eq 1 ] && [ "${h_hello}" -eq 1 ] && [ "${h_pong}" -eq 1 ]; then
    echo "STEP 7: PASS" >&2
    exit 0
fi
echo "STEP 7: FAIL - not all game-blob assertions met" >&2
exit 1
