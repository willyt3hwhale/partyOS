#!/usr/bin/env bash
# test-vm-render-isolation.sh - hardware-FREE guard for the VM iPXE renderer's
# output isolation.
#
# The build host can also be the party server. The VM renderer writes
# boot/partyos.ipxe.vm (VM_IPXE_OUT) and must never write the prod boot/partyos.ipxe.
#
# This test plants a SENTINEL on the prod path, runs a NO-ARG VM render, and
# asserts: the prod boot/partyos.ipxe is byte-for-byte UNCHANGED, and the VM
# render instead wrote boot/partyos.ipxe.vm carrying the rendered SERVER_URL. It
# also statically pins the end-to-end wiring (config VM_IPXE_OUT/VM_BOOT_URL off
# the prod path; the no-arg callers serve VM_BOOT_URL). Pure shell - no VM, no
# network, no hardware (ACCEL=tcg skips config.sh's qemu accel probe).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

RENDER="${REPO_ROOT}/scripts/vm/render-ipxe.sh"
TMPL="${REPO_ROOT}/boot/partyos.ipxe.tmpl"
PROD_OUT="${REPO_ROOT}/boot/partyos.ipxe"       # the LIVE served prod boot script
VM_OUT="${REPO_ROOT}/boot/partyos.ipxe.vm"      # the VM renderer's isolated output
TEST_IP="10.7.7.7"                              # distinct IP so we can prove the render ran

[ -f "${RENDER}" ] || { echo "FAIL: render-ipxe.sh not found at ${RENDER}"; exit 1; }
[ -f "${TMPL}" ]   || { echo "FAIL: VM iPXE template not found at ${TMPL}"; exit 1; }

sha_of() { [ -f "$1" ] && shasum -a 256 "$1" | cut -d' ' -f1 || echo "MISSING"; }

# --- snapshot the two outputs we touch, restore them on exit -------------------
# boot/partyos.ipxe may be the operator's LIVE served file; boot/partyos.ipxe.vm may
# exist from a prior VM run. Both are snapshot+restored so the test is side-effect free.
TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-vmiso.XXXXXX")"
SNAP_PROD="${TMPDIR_T}/prod.snap"; HAD_PROD=0
SNAP_VM="${TMPDIR_T}/vm.snap";     HAD_VM=0
[ -f "${PROD_OUT}" ] && { cp -p "${PROD_OUT}" "${SNAP_PROD}"; HAD_PROD=1; }
[ -f "${VM_OUT}" ]   && { cp -p "${VM_OUT}"   "${SNAP_VM}";   HAD_VM=1; }
restore() {
    if [ "${HAD_PROD}" -eq 1 ]; then cp -p "${SNAP_PROD}" "${PROD_OUT}"; else rm -f "${PROD_OUT}"; fi
    if [ "${HAD_VM}" -eq 1 ];   then cp -p "${SNAP_VM}"   "${VM_OUT}";   else rm -f "${VM_OUT}"; fi
    rm -rf "${TMPDIR_T}"
}
trap restore EXIT

# --- plant a SENTINEL on the prod path, then run a NO-ARG VM render ------------
SENTINEL="PARTYOS-PROD-SENTINEL-DO-NOT-CLOBBER-$$"
printf '#!ipxe\n# %s\n' "${SENTINEL}" > "${PROD_OUT}"
PROD_SHA_BEFORE="$(sha_of "${PROD_OUT}")"
rm -f "${VM_OUT}"

# No-arg VM render (exactly what harness.sh / test-step2.sh do). ACCEL=tcg skips
# the qemu accel probe; SERVER_IP is a distinct test IP so we can prove the render
# ran AND that its output landed off the prod path.
( cd "${REPO_ROOT}" && ACCEL=tcg SERVER_IP="${TEST_IP}" bash "${RENDER}" ) >/dev/null 2>&1
RC=$?

echo "================ VM render isolation (no prod clobber) ========"
assert_true "${RC}" "no-arg VM render exits 0"

# (a) the prod boot script is byte-for-byte UNTOUCHED (the actual bug this guards)
assert_eq "$(sha_of "${PROD_OUT}")" "${PROD_SHA_BEFORE}" "prod boot/partyos.ipxe sha UNCHANGED by the VM render"
assert_contains     "$(cat "${PROD_OUT}")" "${SENTINEL}" "prod boot script still holds the sentinel (not overwritten)"
assert_not_contains "$(cat "${PROD_OUT}")" "${TEST_IP}"  "prod boot script did NOT get the VM test IP (no clobber)"

# (b) the VM render instead wrote its OWN isolated path, carrying the test IP
assert_true     "$( [ -f "${VM_OUT}" ]; echo $? )"    "VM render WROTE its isolated boot/partyos.ipxe.vm"
assert_contains "$(cat "${VM_OUT}")" "${TEST_IP}"     "VM test IP ${TEST_IP} landed in the VM boot script (render ran)"
assert_contains "$(cat "${VM_OUT}")" "#!ipxe"         "VM boot script is a valid-looking iPXE script"

# --- structural guards: the isolation is wired end to end ---------------------
echo
echo "================ end-to-end wiring (served == rendered) ======="
# config.sh must resolve the VM output OFF the prod path and the VM boot URL must
# reference the VM name, so the no-arg callers serve exactly what the renderer wrote.
read_cfg() {
    ACCEL=tcg SERVER_IP="${TEST_IP}" bash -c '
        source "$1"
        printf "%s\n%s\n%s\n" "${VM_IPXE_OUT}" "${VM_BOOT_URL}" "${VM_IPXE_NAME}"
    ' _ "${REPO_ROOT}/scripts/vm/config.sh" 2>/dev/null
}
CFG="$(read_cfg)"
VM_IPXE_OUT_V="$(printf '%s\n' "${CFG}" | sed -n 1p)"
VM_BOOT_URL_V="$(printf '%s\n' "${CFG}" | sed -n 2p)"
VM_IPXE_NAME_V="$(printf '%s\n' "${CFG}" | sed -n 3p)"

assert_eq   "${VM_IPXE_OUT_V}" "${REPO_ROOT}/boot/${VM_IPXE_NAME_V}" "config VM_IPXE_OUT = boot/<VM_IPXE_NAME>"
assert_true "$( [ "${VM_IPXE_OUT_V}" != "${PROD_OUT}" ]; echo $? )"  "config VM_IPXE_OUT differs from the prod boot/partyos.ipxe path"
assert_contains "${VM_BOOT_URL_V}" "/boot/${VM_IPXE_NAME_V}"         "VM_BOOT_URL points at the VM boot script name"

# The NO-ARG callers must serve VM_BOOT_URL (so the boot URL matches the renderer's
# default output - otherwise a client would 404 or fall back to the prod path).
assert_contains "$(cat "${REPO_ROOT}/scripts/vm/test-step2.sh")" 'BOOTURL="${VM_BOOT_URL}"' "test-step2 serves the VM boot URL (matches renderer default)"
assert_contains "$(cat "${REPO_ROOT}/scripts/vm/test-step1.sh")" 'BOOTURL="${VM_BOOT_URL}"' "test-step1 serves the VM boot URL (matches renderer default)"

assert_summary "test-vm-render-isolation" || exit 1
echo "test-vm-render-isolation: ALL PASS"
