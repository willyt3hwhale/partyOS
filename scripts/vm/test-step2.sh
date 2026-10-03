#!/usr/bin/env bash
# test-step2.sh - autonomous VM test for Step 2 (RAM-Based Linux Boot).
#
# What it proves, with no hardware and no keystrokes:
#   1. A headless client VM boots the QEMU iPXE option ROM, AUTO-chains
#      partyos.ipxe (DHCP boot filename), which loads the Arch kernel+initramfs
#      over HTTP and brings the whole airootfs.sfs into RAM (archiso HTTP boot
#      forces copytoram). cms_verify=y validates the signed sfs.
#   2. The booted system reaches an (automated) shell over the serial console:
#        serial marker  PARTYOS-STEP2-LOGIN
#   3. It runs from RAM only - no physical root device - asserted by the guest
#      running `free -m` / findmnt and reporting:
#        serial marker  PARTYOS-STEP2-RAMONLY
#        HTTP callback   REPORT step=2 status=ok ramonly=1 ...   (access log)
#   4. DETACH TEST: once the step=2 callback has landed (sfs already in RAM),
#      the harness KILLS the HTTP server - the VM-equivalent of yanking the USB.
#      The guest must keep running, proven by post-kill serial heartbeats:
#        serial marker  PARTYOS-STEP2-ALIVE   (appearing AFTER server death)
#
# TCG note: on Apple Silicon the x86_64 guest runs under TCG emulation, so a full
# Arch boot + ~947MB sfs copytoram is slow. The default timeout is generous and
# overridable via STEP2_TIMEOUT.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ---------------------------------------------------------------
RAM_MB="${STEP2_RAM_MB:-8192}"
# Generous default: under TCG emulation on Apple Silicon a full archiso boot is
# slow (pacman-init GPG keygen + ldconfig are the long poles), and the 947MB sfs
# must be pulled over emulated HTTP. 30min headroom; override with STEP2_TIMEOUT.
T="${STEP2_TIMEOUT:-1800}"            # overall boot+verify timeout (seconds)
ALIVE_WAIT="${STEP2_ALIVE_WAIT:-25}"  # seconds to watch for post-kill heartbeat
BOOTURL="${VM_BOOT_URL}"   # VM-served boot script (never the prod boot/partyos.ipxe)

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-step2.XXXXXX")"
SERIAL="${RUN}/step2.serial"
ACCESS="${RUN}/http_access.log"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[step2] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

# --- render iPXE with the right SERVER_URL --------------------------------
bash "${SELF_DIR}/render-ipxe.sh" >&2 || { echo "FAIL: iPXE render"; exit 1; }

# --- start HTTP server ----------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[step2] HTTP server up pid=${SRV_PID}" >&2

# --- launch client VM (background) ----------------------------------------
# Boot from the iPXE option ROM; the DHCP bootfile auto-chains partyos.ipxe,
# which then loads the Arch kernel/initramfs and RAM-boots. Generous RAM so the
# httpspace tmpfs (75% default) + copytoram + cowspace all fit.
export RUN_DIR="${RUN}"
bash "${SELF_DIR}/run-client.sh" --name step2 \
    --serial "${SERIAL}" --pidfile "${RUN}/step2.pid" \
    --background \
    --boot-rom --bootfile "${BOOTURL}" --ram "${RAM_MB}" --timeout "${T}" >&2
VM_PID="$(cat "${RUN}/step2.pid" 2>/dev/null || true)"
echo "[step2] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

ser_has() { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
log_has() { [ -f "${ACCESS}" ] && grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive() { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
# Count matching lines as a clean single integer. `grep -c` exits 1 and still
# prints 0 on no match, so `grep -c ... || echo 0` yields "0\n0"; piping into a
# line-counter avoids that and always emits exactly one number.
count_ser() { tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -cF -- "$1"; }

# --- phase 1: wait for RAM-boot callback ----------------------------------
echo "[step2] waiting up to ${T}s for RAM-boot callback (REPORT step=2 status=ok)" >&2
deadline=$(( $(date +%s) + T ))
got_callback=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if log_has "REPORT step=2 status=ok"; then got_callback=1; break; fi
    if ser_has "PARTYOS-STEP2-RAMONLY"; then got_callback=1; break; fi
    if ! vm_alive; then echo "[step2] VM exited before callback" >&2; break; fi
    sleep 2
done

echo "----- serial tail (pre-detach) -----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -30 >&2
echo "------------------------------------" >&2
echo "----- access log (REPORT lines) ----" >&2
grep "REPORT" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "------------------------------------" >&2

if [ "${got_callback}" -ne 1 ]; then
    echo "STEP 2: FAIL - never reached RAM-boot callback" >&2
    exit 1
fi

# Assert RAM-only from the callback if present (ramonly=1).
if log_has "REPORT step=2 status=ok"; then
    if grep "REPORT step=2 status=ok" "${ACCESS}" | grep -q "ramonly=1"; then
        echo "[step2] RAM-only confirmed (ramonly=1) via callback" >&2
    else
        echo "STEP 2: FAIL - callback present but not RAM-only (ramonly!=1)" >&2
        grep "REPORT step=2" "${ACCESS}" >&2
        exit 1
    fi
fi

# --- phase 2: DETACH test - kill the server, assert the guest survives -----
# Record how many ALIVE heartbeats existed before we kill the server, then kill
# it, then require NEW heartbeats afterward (proving the guest runs without the
# server - the VM-equivalent of removing the USB).
alive_before="$(count_ser 'PARTYOS-STEP2-ALIVE')"
echo "[step2] DETACH: killing HTTP server pid=${SRV_PID} (alive_before=${alive_before})" >&2
kill "${SRV_PID}" 2>/dev/null || true
wait "${SRV_PID}" 2>/dev/null || true
SRV_PID=""
# Confirm the server is really gone.
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null; then
    echo "[step2] WARN: server still answering after kill" >&2
fi

echo "[step2] DETACH: watching ${ALIVE_WAIT}s for NEW heartbeats after server death" >&2
ddl=$(( $(date +%s) + ALIVE_WAIT ))
survived=0
while [ "$(date +%s)" -lt "${ddl}" ]; do
    now="$(count_ser 'PARTYOS-STEP2-ALIVE')"
    if [ "${now}" -gt "${alive_before}" ] && vm_alive; then survived=1; break; fi
    if ! vm_alive; then echo "[step2] VM died during detach window" >&2; break; fi
    sleep 2
done

echo "----- serial tail (post-detach) ----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -15 >&2
echo "------------------------------------" >&2

# --- verdict --------------------------------------------------------------
echo "================ STEP 2 VERDICT ==============================" >&2
ramonly_ok=0
ser_has "PARTYOS-STEP2-RAMONLY" && ramonly_ok=1
log_has "REPORT step=2 status=ok" && ramonly_ok=1
login_ok=0; ser_has "PARTYOS-STEP2-LOGIN" && login_ok=1
echo "login reached (PARTYOS-STEP2-LOGIN) : ${login_ok}" >&2
echo "RAM-only confirmed                  : ${ramonly_ok}" >&2
echo "survived server kill (new ALIVE)    : ${survived}" >&2

if [ "${login_ok}" -eq 1 ] && [ "${ramonly_ok}" -eq 1 ] && [ "${survived}" -eq 1 ]; then
    echo "STEP 2: PASS" >&2
    exit 0
fi
echo "STEP 2: FAIL" >&2
exit 1
