#!/usr/bin/env bash
# test-step1.sh - autonomous VM test for the network boot foundation,
# including the finished AUTOMATIC boot.
#
# What it proves, with no hardware and no keystrokes:
#   1. create_usb.sh's image mode builds a bootable iPXE USB IMAGE (no dd, no
#      device, no sudo).
#   2. A headless client VM boots that iPXE USB and AUTO-chains partyos.ipxe -
#      the DHCP boot filename (option 67, supplied here by SLIRP's bootfile, the
#      same role dnsmasq dhcp-boot plays on a real LAN) is consumed by iPXE with
#      NO typed command.
#   3. The boot reaches the network-boot success state, asserted on TWO channels:
#        - serial marker  PARTYOS-NETBOOT-OK
#        - HTTP callback   REPORT step=1 status=ok   in the server access log
#
# Also runs the ROM-only autoboot variant (QEMU's bundled iPXE option ROM) so
# both the USB-image and the ROM paths are exercised. Exit 0 only if both pass.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

MARKER="PARTYOS-NETBOOT-OK"
HTTP_MARKER="REPORT step=1 status=ok"
BOOTURL="${VM_BOOT_URL}"   # VM-served boot script (never the prod boot/partyos.ipxe)
T="${STEP1_TIMEOUT:-90}"

IMG="$(mktemp "${TMPDIR:-/tmp}/partyos-ipxe.XXXXXX.img")"
cleanup() { rm -f "${IMG}"; }
trap cleanup EXIT

echo "================ BUILD iPXE USB IMAGE ========================"
rm -f "${IMG}"
bash "${REPO_ROOT}/scripts/create_usb.sh" --image "${IMG}" >&2
[ -s "${IMG}" ] || { echo "FAIL: iPXE image not built"; exit 1; }

echo
echo "================ CASE A: boot from iPXE USB IMAGE ============="
env -u RUN_DIR bash "${SELF_DIR}/harness.sh" \
    --marker "${MARKER}" \
    --http-marker "${HTTP_MARKER}" \
    --timeout "${T}" \
    --name step1-usb \
    -- --ipxe-disk "${IMG}" --bootfile "${BOOTURL}" --ram 256 --timeout "${T}"
A_RC=$?
echo "CASE A exit code: ${A_RC}"

echo
echo "================ CASE B: boot from iPXE option ROM ==========="
env -u RUN_DIR bash "${SELF_DIR}/harness.sh" \
    --marker "${MARKER}" \
    --http-marker "${HTTP_MARKER}" \
    --timeout "${T}" \
    --name step1-rom \
    -- --boot-rom --bootfile "${BOOTURL}" --ram 256 --timeout "${T}"
B_RC=$?
echo "CASE B exit code: ${B_RC}"

echo
echo "================ STEP 1 VERDICT =============================="
echo "USB-image autoboot rc=${A_RC} (want 0)"
echo "option-ROM autoboot rc=${B_RC} (want 0)"
if [ "${A_RC}" -eq 0 ] && [ "${B_RC}" -eq 0 ]; then
    echo "STEP 1: PASS"
    exit 0
fi
echo "STEP 1: FAIL"
exit 1
