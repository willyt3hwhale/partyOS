#!/usr/bin/env bash
# test-metadata.sh - autonomous VM test for blob metadata.
#
# What it proves, with no hardware and no keystrokes:
#   1. The server hosts a game CATALOG (server/games/catalog.json, version 2) that
#      carries METADATA per blob: a stable id, ram_min, ram_max, size, version,
#      category. build-game-blobs.sh builds two tiny DUMMY games so the run is
#      fast + deterministic.
#   2. The custom image RAM-boots (same machinery as Steps 3-9); metadata-script.sh
#      installs the client-side helper (partyos-blob-meta) and READS each blob's
#      metadata from the catalog (PARTYOS-META-FIELDS ... ram_min=.. ram_max=..
#      size=.. version=.. category=..).
#   3. A blob PACKAGE is self-describing: each blob's embedded game.meta (read out
#      of the mounted squashfs) carries the same metadata (PARTYOS-META-EMBEDDED).
#   4. RAM-fit reasoning works over the metadata (PARTYOS-META-FIT verdict=ok|nofit).
#   5. A consolidated step=metadata status=ok callback carries games/with_meta/
#      embedded/fit_ok counts.
#   HOST PROOF: the harness independently confirms the catalog the server serves
#   really carries the metadata fields, AND the server served the catalog + both
#   blobs to the guest (GET lines in the HTTP access log).
#
# Tunables: STEPMETA_RAM_MB / METADATA_RAM_MB, STEPMETA_TIMEOUT / METADATA_TIMEOUT.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
# Accept both METADATA_* and the remote-test.sh-injected STEPMETADATA_* names.
RAM_MB="${METADATA_RAM_MB:-${STEPMETADATA_RAM_MB:-10240}}"
T="${METADATA_TIMEOUT:-${STEPMETADATA_TIMEOUT:-2700}}"   # boot+verify timeout (seconds)

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
GAMES_DIR="${REPO_ROOT}/server/games"
TMPL="${REPO_ROOT}/boot/partyos-metadata.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-metadata.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-metadata.ipxe"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-metadata.XXXXXX")"
SERIAL="${RUN}/metadata.serial"
ACCESS="${RUN}/http_access.log"
QMP="${RUN}/metadata.qmp"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[metadata] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

ser_has()  { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
log_has()  { grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive() { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }

# --- 0. dependencies: custom image + freshly-built game blobs ----------------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[metadata] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "METADATA: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "METADATA: FAIL - no custom sfs" >&2; exit 1; }
echo "[metadata] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

echo "[metadata] building game catalog + blobs (with metadata) -> ${GAMES_DIR}..." >&2
bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" "${GAMES_DIR}" >&2 || {
    echo "METADATA: FAIL - game blob build failed" >&2; exit 1; }
[ -f "${GAMES_DIR}/catalog.json" ] || { echo "METADATA: FAIL - no catalog.json" >&2; exit 1; }
NCAT="$(grep -c '"name":' "${GAMES_DIR}/catalog.json" 2>/dev/null || echo 0)"
echo "[metadata] catalog has ${NCAT} game(s); blobs: $(ls "${GAMES_DIR}"/*.squashfs 2>/dev/null | wc -l | tr -d ' ')" >&2
[ "${NCAT}" -ge 2 ] || { echo "METADATA: FAIL - catalog needs >=2 games" >&2; exit 1; }

# HOST PROOF (pre-boot): the catalog the server will serve really carries the
# metadata fields for every game - independent of what the guest later reports.
echo "[metadata] === HOST checking catalog carries metadata fields ===" >&2
host_meta_ok=1
for f in id ram_min ram_max size version category; do
    cnt="$(grep -cE "\"${f}\":" "${GAMES_DIR}/catalog.json" 2>/dev/null || echo 0)"
    echo "[metadata]   field ${f}: ${cnt} occurrence(s) (want >= ${NCAT})" >&2
    [ "${cnt}" -ge "${NCAT}" ] || host_meta_ok=0
done
[ "${host_meta_ok}" -eq 1 ] || { echo "METADATA: FAIL - catalog missing a metadata field" >&2; exit 1; }
echo "[metadata] HOST confirms catalog metadata complete" >&2

# --- render the metadata iPXE script ----------------------------------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || {
    echo "METADATA: FAIL - iPXE render" >&2; exit 1; }

# --- start HTTP server ------------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[metadata] HTTP server up pid=${SRV_PID}" >&2
curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/server/games/catalog.json" 2>/dev/null \
    || { echo "METADATA: FAIL - server does not serve catalog.json" >&2; exit 1; }
curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/boot/partyos-blob-meta" 2>/dev/null \
    || { echo "METADATA: FAIL - server does not serve the helper" >&2; exit 1; }
echo "[metadata] server serves catalog.json + helper OK (host check)" >&2

# --- launch client VM (no USB; catalog + blobs come from the server) ---------
export RUN_DIR="${RUN}"
bash "${SELF_DIR}/run-client.sh" --name metadata \
    --serial "${SERIAL}" --pidfile "${RUN}/metadata.pid" --qmp "${QMP}" \
    --background \
    --boot-rom --bootfile "${BOOTURL}" \
    --ram "${RAM_MB}" --timeout "${T}" >&2
VM_PID="$(cat "${RUN}/metadata.pid" 2>/dev/null || true)"
echo "[metadata] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

# --- wait for ready ----------------------------------------------------------
echo "[metadata] === waiting up to ${T}s for metadata-ready ===" >&2
deadline=$(( $(date +%s) + T ))
got_ready=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if log_has "REPORT step=metadata status=ok"; then got_ready=1; break; fi
    if ser_has "PARTYOS-META-READY"; then got_ready=1; break; fi
    if ! vm_alive; then echo "[metadata] VM exited before ready" >&2; break; fi
    sleep 5
done

echo "----- metadata serial tail -----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -60 >&2
echo "--------------------------------" >&2
echo "----- access log (games + helper + REPORT) -----" >&2
grep -E "games/|partyos-blob-meta|REPORT step=metadata" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "------------------------------------------------" >&2

if [ "${got_ready}" -ne 1 ]; then
    echo "METADATA: FAIL - never reached metadata-ready" >&2
    exit 1
fi

# --- in-guest assertion roll-up ---------------------------------------------
g_helper=0;  ser_has "PARTYOS-META-HELPER-OK" && g_helper=1
g_catalog=0; ser_has "PARTYOS-META-CATALOG-OK" && g_catalog=1
# every game's full metadata was read from the catalog: the FIELDS line for each
# game must carry id+ram_min+ram_max+size+version+category (a complete read).
fields_complete() {
    tr -d '\000' < "${SERIAL}" | grep -F "PARTYOS-META-FIELDS name=$1" \
      | grep -q "id=" \
      && tr -d '\000' < "${SERIAL}" | grep -F "PARTYOS-META-FIELDS name=$1" | grep -q "ram_min=" \
      && tr -d '\000' < "${SERIAL}" | grep -F "PARTYOS-META-FIELDS name=$1" | grep -q "ram_max=" \
      && tr -d '\000' < "${SERIAL}" | grep -F "PARTYOS-META-FIELDS name=$1" | grep -q "size=" \
      && tr -d '\000' < "${SERIAL}" | grep -F "PARTYOS-META-FIELDS name=$1" | grep -q "version=" \
      && tr -d '\000' < "${SERIAL}" | grep -F "PARTYOS-META-FIELDS name=$1" | grep -q "category="
}
g_fld_hello=0; fields_complete hello && g_fld_hello=1
g_fld_pong=0;  fields_complete pong  && g_fld_pong=1
# each blob is self-describing (embedded game.meta read)
g_emb_hello=0; ser_has "PARTYOS-META-EMBEDDED name=hello" && g_emb_hello=1
g_emb_pong=0;  ser_has "PARTYOS-META-EMBEDDED name=pong"  && g_emb_pong=1
# RAM-fit reasoning ran for both, with DIFFERING verdicts (hello fits 300MB, pong does not)
g_fit_hello_ok=0;  tr -d '\000' < "${SERIAL}" | grep -F "PARTYOS-META-FIT name=hello" | grep -q "verdict=ok"    && g_fit_hello_ok=1
g_fit_pong_no=0;   tr -d '\000' < "${SERIAL}" | grep -F "PARTYOS-META-FIT name=pong"  | grep -q "verdict=nofit" && g_fit_pong_no=1

# HOST proof: the server served the catalog + both blobs (and the helper) to the guest.
h_catalog=0; log_has "GET /server/games/catalog.json"  && h_catalog=1
h_helper=0;  log_has "GET /boot/partyos-blob-meta"      && h_helper=1
h_hello=0;   log_has "GET /server/games/hello.squashfs" && h_hello=1
h_pong=0;    log_has "GET /server/games/pong.squashfs"  && h_pong=1

echo "==================== METADATA VERDICT =======================" >&2
echo "client helper installed + runnable             : ${g_helper}" >&2
echo "catalog fetched + parsed (guest)               : ${g_catalog}" >&2
echo "catalog metadata read: hello / pong            : ${g_fld_hello} / ${g_fld_pong}" >&2
echo "blob self-describing (embedded): hello / pong  : ${g_emb_hello} / ${g_emb_pong}" >&2
echo "RAM-fit reasoning: hello=ok / pong=nofit       : ${g_fit_hello_ok} / ${g_fit_pong_no}" >&2
echo "HOST served catalog / helper / hello / pong    : ${h_catalog} / ${h_helper} / ${h_hello} / ${h_pong}" >&2

if [ "${g_helper}" -eq 1 ] && [ "${g_catalog}" -eq 1 ] && \
   [ "${g_fld_hello}" -eq 1 ] && [ "${g_fld_pong}" -eq 1 ] && \
   [ "${g_emb_hello}" -eq 1 ] && [ "${g_emb_pong}" -eq 1 ] && \
   [ "${g_fit_hello_ok}" -eq 1 ] && [ "${g_fit_pong_no}" -eq 1 ] && \
   [ "${h_catalog}" -eq 1 ] && [ "${h_helper}" -eq 1 ] && \
   [ "${h_hello}" -eq 1 ] && [ "${h_pong}" -eq 1 ]; then
    echo "METADATA: PASS" >&2
    exit 0
fi
echo "METADATA: FAIL - not all metadata assertions met" >&2
exit 1
