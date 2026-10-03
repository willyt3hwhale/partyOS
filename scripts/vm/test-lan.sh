#!/usr/bin/env bash
# test-lan.sh - multi-client LAN realism: launch N client VMs sharing ONE server
# and assert ALL of them reach the headless XFCE desktop. This is the VM proxy for
# "many PCs plugged in at the party, all booting off the one server".
#
# Each client is the Step 9 boot (server boot script + headless desktop): one
# OS/report HTTP server + one boot-script server feed all N VMs over the SAME
# virtual network (SLIRP, each VM gets its own 10.0.2.x via QEMU's user net). All
# N fetch the server boot script, run it, and bring up XFCE; the harness asserts
# every VM emitted PARTYOS-STEP9-DESKTOP-READY on its own serial log.
#
# HOST RAM LIMIT: each client copies the ~1.6GB sfs into RAM and needs several GB.
# This script computes how many clients fit at STEP_LAN_RAM_MB each. If it must
# run fewer than requested, it logs the limit.
# Override: STEP_LAN_N (requested clients), STEP_LAN_RAM_MB (per client),
# STEP_LAN_TIMEOUT, STEP_LAN_CONFIG_PORT.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

REQ_N="${STEP_LAN_N:-2}"
RAM_MB="${STEP_LAN_RAM_MB:-5120}"
T="${STEP_LAN_TIMEOUT:-3000}"
CONFIG_PORT="${STEP_LAN_CONFIG_PORT:-8090}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
BOOT_CONFIG="${REPO_ROOT}/server/boot-config.sh"
TMPL="${REPO_ROOT}/boot/partyos-step9.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-step9-lan.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-step9-lan.ipxe"
CONFIG_URL="http://${SERVER_IP}:${CONFIG_PORT}/server/boot-config.sh"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-lan.XXXXXX")"
ACCESS="${RUN}/http_access.log"
CFGLOG="${RUN}/config_access.log"
SRV_PID=""
CFG_PID=""
declare -a VM_PIDS=() SERIALS=()

cleanup() {
    local rc=$?
    for p in "${VM_PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true; done
    [ -n "${CFG_PID}" ] && kill "${CFG_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[test-lan] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

ser_has() { [ -f "$1" ] && grep -qF -- "$2" "$1" 2>/dev/null; }

# --- 0. dependencies --------------------------------------------------------
[ -f "${CUSTOM_SFS}" ] || { echo "[test-lan] custom image missing - building..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || { echo "TEST-LAN: FAIL - image build" >&2; exit 1; }; }
[ -f "${CUSTOM_SFS}" ] || { echo "TEST-LAN: FAIL - no custom sfs" >&2; exit 1; }
[ -f "${BOOT_CONFIG}" ] || { echo "TEST-LAN: FAIL - no server boot script" >&2; exit 1; }

# --- compute how many clients actually FIT in host RAM ----------------------
avail_mb=0
if command -v free >/dev/null 2>&1; then
    avail_mb="$(free -m | awk '/^Mem:/{print $2}')"          # total RAM on Linux
elif [ "$(uname)" = "Darwin" ]; then
    avail_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
fi
# Leave ~1.5GB headroom for the host + the two python servers + qemu overhead.
headroom_mb=1536
usable_mb=$(( avail_mb > headroom_mb ? avail_mb - headroom_mb : avail_mb ))
fit_n=$(( usable_mb / RAM_MB ))
[ "${fit_n}" -lt 1 ] && fit_n=1

N="${REQ_N}"
if [ "${fit_n}" -lt "${REQ_N}" ]; then
    echo "[test-lan] LIMITATION: host has ${avail_mb}MB RAM; at ${RAM_MB}MB/client only" >&2
    echo "[test-lan]   ${fit_n} concurrent client(s) fit (requested ${REQ_N}). Running ${fit_n}" >&2
    echo "[test-lan]   to avoid OOM. This is a host-RAM limit, NOT a product limit:" >&2
    echo "[test-lan]   the server feeds all clients over the one shared virtual net;" >&2
    echo "[test-lan]   concurrency is bounded only by how many VMs fit in RAM." >&2
    N="${fit_n}"
else
    echo "[test-lan] host ${avail_mb}MB RAM fits the requested ${REQ_N} client(s) at ${RAM_MB}MB each" >&2
fi
echo "[test-lan] launching ${N} client VM(s) sharing one server (ram=${RAM_MB}MB each, timeout=${T}s, accel=${ACCEL})" >&2

# --- render the LAN iPXE script ---------------------------------------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || { echo "TEST-LAN: FAIL - iPXE render" >&2; exit 1; }
tmpf="$(mktemp)"; sed -e "s|{{CONFIG_URL}}|${CONFIG_URL}|g" -e "s|{{BOOT_LABEL}}|lan|g" "${RENDERED}" > "${tmpf}" && mv "${tmpf}" "${RENDERED}"

# --- start the shared OS/report + boot-script servers -----------------------
: > "${ACCESS}"; : > "${CFGLOG}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
python3 -u "${REPO_ROOT}/server/http_server.py" "${CONFIG_PORT}" >"${CFGLOG}" 2>&1 &
CFG_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && \
    curl -s -o /dev/null "http://127.0.0.1:${CONFIG_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[test-lan] shared servers up: OS pid=${SRV_PID} port=${SERVER_PORT}, config pid=${CFG_PID} port=${CONFIG_PORT}" >&2

# --- launch the N clients ----------------------------------------------------
export RUN_DIR="${RUN}"
START="$(date +%s)"
for i in $(seq 1 "${N}"); do
    serial="${RUN}/lan.client${i}.serial"
    pidf="${RUN}/lan.client${i}.pid"
    qmp="${RUN}/lan.client${i}.qmp"
    bash "${SELF_DIR}/run-client.sh" --name "lan-c${i}" \
        --serial "${serial}" --pidfile "${pidf}" --qmp "${qmp}" \
        --background \
        --boot-rom --bootfile "${BOOTURL}" \
        --ram "${RAM_MB}" --timeout "${T}" >&2
    VM_PIDS+=("$(cat "${pidf}" 2>/dev/null || true)")
    SERIALS+=("${serial}")
    echo "[test-lan] client ${i} launched pid=${VM_PIDS[-1]} serial=${serial}" >&2
done

# --- wait for ALL clients to reach the desktop ------------------------------
echo "[test-lan] === waiting up to ${T}s for ALL ${N} client(s) to reach desktop ===" >&2
deadline=$(( $(date +%s) + T ))
declare -a READY=()
for _ in $(seq 1 "${N}"); do READY+=(0); done
all_ready=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
    done_n=0
    for idx in $(seq 0 $((N-1))); do
        if [ "${READY[$idx]}" -eq 0 ] && ser_has "${SERIALS[$idx]}" "PARTYOS-STEP9-DESKTOP-READY"; then
            READY[$idx]=1
            echo "[test-lan] client $((idx+1)) reached DESKTOP-READY ($(( $(date +%s) - START ))s)" >&2
        fi
        [ "${READY[$idx]}" -eq 1 ] && done_n=$((done_n+1))
    done
    if [ "${done_n}" -eq "${N}" ]; then all_ready=1; break; fi
    sleep 5
done
LAN_DUR=$(( $(date +%s) - START ))

# --- verdict ----------------------------------------------------------------
ready_n=0
echo "==================== TEST-LAN VERDICT =========================" >&2
for idx in $(seq 0 $((N-1))); do
    if [ "${READY[$idx]}" -eq 1 ]; then
        ready_n=$((ready_n+1)); st=READY
    else
        st="NOT-READY"
        echo "----- client $((idx+1)) serial tail (NOT ready) -----" >&2
        tr -d '\000' < "${SERIALS[$idx]}" 2>/dev/null | tail -25 >&2
    fi
    echo "client $((idx+1)): ${st}" >&2
done
echo "clients reached desktop: ${ready_n}/${N}   wall-clock: ${LAN_DUR}s" >&2
echo "(requested ${REQ_N}; ran ${N} due to host RAM)" >&2

if [ "${all_ready}" -eq 1 ] && [ "${ready_n}" -eq "${N}" ]; then
    if [ "${N}" -lt "${REQ_N}" ]; then
        echo "TEST-LAN: PASS (${N}/${N} clients reached desktop; ran ${N}<${REQ_N} requested due to host RAM - logged above)" >&2
    else
        echo "TEST-LAN: PASS (${N}/${N} clients reached desktop on the shared server)" >&2
    fi
    exit 0
fi
echo "TEST-LAN: FAIL - only ${ready_n}/${N} client(s) reached desktop" >&2
exit 1
