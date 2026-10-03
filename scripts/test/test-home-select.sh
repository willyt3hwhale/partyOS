#!/usr/bin/env bash
# test-home-select.sh - hardware-FREE unit test of the stick partition lookup:
# scripts/build/files/rootfs/usr/local/lib/partyos-usb-labels.sh.
#
# Each data partition of the player stick has an ORDERED label list. The venue
# label is first, the legacy label second:
#   home   PARTYOSHOME, LANPARTY_HOME
#   share  PARTYDATA, PARTYSHARE
# The kernel cmdline (usb_home_labels=, usb_share_labels=) can replace a list.
# The first label that is on a partition wins. With two sticks on the same label,
# the lowest partition UUID wins, so the pick is the same on every boot.
#
# This test sources the REAL helper, mocks blkid and the by-label directory, and
# asserts:
#   * one stick -> returned as-is, no WARN
#   * two sticks -> a UUID-driven pick, logged on stderr, stable across boots
#   * the venue labels are found; the legacy labels are still found
#   * with both labels present, the venue label wins, also when the old label
#     enumerates first and has the lower UUID
#   * the cmdline list replaces the default; invalid items are ignored
#   * a missing first label does not cause a blkid probe when a later label has a
#     by-label link (the poll loop calls this every few seconds)
#   * partyos-usbhome and the udev rule use the helper
# No VM, no network, no hardware, no root - pure shell.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

RFS="${REPO_ROOT}/scripts/build/files/rootfs"
LABELS_LIB="${RFS}/usr/local/lib/partyos-usb-labels.sh"
USBHOME="${RFS}/usr/local/bin/partyos-usbhome"
RULE="${RFS}/etc/udev/rules.d/99-partyos-usbhome.rules"
for f in "${LABELS_LIB}" "${USBHOME}" "${RULE}"; do
    [ -f "${f}" ] || { echo "FAIL: baked file not found at ${f}"; exit 1; }
done
bash -n "${LABELS_LIB}" && assert_true 0 "partyos-usb-labels.sh: bash -n syntax OK" \
    || assert_true 1 "partyos-usb-labels.sh: bash -n syntax OK"

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-homeseltest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT
CMDLINE="${TMPDIR_T}/cmdline"
BYL="${TMPDIR_T}/by-label"
PROBES="${TMPDIR_T}/probes"
export PARTYOS_CMDLINE="${CMDLINE}" PARTYOS_BY_LABEL="${BYL}"

# --- mocks --------------------------------------------------------------------
# MOCK_PARTS: one partition per line, "DEV LABEL UUID", in kernel enumeration order.
# blkid -t LABEL=X lists the partitions with label X (unsorted, enumeration order,
# the helper sorts). Every -t / -L call is logged to PROBES.
timeout() { shift; "$@"; }
blkid() {
    if [ "$1" = "-o" ] && [ "$2" = "device" ] && [ "$3" = "-t" ]; then
        local want="${4#LABEL=}"
        echo "t ${want}" >> "${PROBES}"
        awk -v l="${want}" '$2==l{print $1}' <<< "${MOCK_PARTS}"
        return 0
    fi
    if [ "$1" = "-L" ]; then
        echo "L $2" >> "${PROBES}"
        awk -v l="$2" '$2==l{print $1; exit}' <<< "${MOCK_PARTS}"
        return 0
    fi
    if [ "$1" = "-o" ] && [ "$2" = "value" ] && [ "$3" = "-s" ]; then
        local col=3; [ "$4" = LABEL ] && col=2
        awk -v d="$5" -v c="${col}" '$1==d{print $c}' <<< "${MOCK_PARTS}"
        return 0
    fi
    return 1
}
# setup PARTS [nolinks] -> the mock partitions, the by-label links (like udev:
# one link per label) and an empty probe log and cmdline. The /dev/sdX nodes do
# not exist here, so each link points at a stand-in node file (a live udev link
# resolves to an existing device node).
NODES="${TMPDIR_T}/nodes"
setup() {
    MOCK_PARTS="$1"
    rm -rf "${BYL}" "${NODES}"; mkdir -p "${BYL}" "${NODES}"; : > "${PROBES}"; : > "${CMDLINE}"
    if [ "${2:-}" != nolinks ]; then
        while read -r d l _; do
            [ -n "${l}" ] || continue
            : > "${NODES}/${d##*/}"
            ln -sfn "${NODES}/${d##*/}" "${BYL}/${l}"
        done <<< "${MOCK_PARTS}"
    fi
}
# shellcheck source=/dev/null
source "${LABELS_LIB}"
ERR="${TMPDIR_T}/err"

echo "================ 1. the label lists ==========================="
setup ""
assert_eq "$(partyos_usb_labels home | tr '\n' ' ')" "PARTYOSHOME LANPARTY_HOME " \
    "home default: PARTYOSHOME first, LANPARTY_HOME second"
assert_eq "$(partyos_usb_labels share | tr '\n' ' ')" "PARTYDATA PARTYSHARE " \
    "share default: PARTYDATA first, PARTYSHARE second"
echo "BOOT_IMAGE=/vmlinuz quiet usb_home_labels=MYHOME,LANPARTY_HOME usb_share_labels=MYSHARE splash" > "${CMDLINE}"
assert_eq "$(partyos_usb_labels home | tr '\n' ' ')" "MYHOME LANPARTY_HOME " "the cmdline list replaces the home default"
assert_eq "$(partyos_usb_labels share | tr '\n' ' ')" "MYSHARE " "the cmdline list replaces the share default"
echo "usb_home_labels=GOOD,bad\$(x),WAYTOOLONGLABEL_12345,,OK-2" > "${CMDLINE}"
assert_eq "$(partyos_usb_labels home | tr '\n' ' ')" "GOOD OK-2 " "invalid cmdline items are ignored, the order stays"
echo "usb_home_labels=\$(reboot)" > "${CMDLINE}"
assert_eq "$(partyos_usb_labels home | tr '\n' ' ')" "PARTYOSHOME LANPARTY_HOME " \
    "a cmdline list with no valid label falls back to the default"
: > "${CMDLINE}"
partyos_label_is home PARTYOSHOME; assert_true $? "PARTYOSHOME is a home label"
partyos_label_is home LANPARTY_HOME; assert_true $? "LANPARTY_HOME is a home label"
partyos_label_is home PARTYDATA; assert_false $? "PARTYDATA is not a home label"
partyos_label_is share PARTYDATA; assert_true $? "PARTYDATA is a share label"
partyos_label_is home ""; assert_false $? "an empty label is not a home label"
echo "usb_home_labels=MYHOME" > "${CMDLINE}"
partyos_label_is home PARTYOSHOME; assert_false $? "with a cmdline list, a default label that is not in it does not match"
partyos_label_is home MYHOME; assert_true $? "with a cmdline list, its label matches"

echo
echo "================ 2. venue labels, old labels, both ============="
setup "/dev/sda1 PARTYOS 1111-AAAA
/dev/sda3 PARTYDATA 2222-BBBB
/dev/sda2 PARTYOSHOME 3333-CCCC"
assert_eq "$(partyos_resolve_label_dev home 2>"${ERR}")" "/dev/sda2" "venue stick: home is PARTYOSHOME (/dev/sda2, last on the disk)"
assert_eq "$(partyos_resolve_label_dev share 2>>"${ERR}")" "/dev/sda3" "venue stick: share is PARTYDATA (/dev/sda3, in the middle)"
assert_not_contains "$(cat "${ERR}")" "WARN" "venue stick: no WARN"

setup "/dev/sdb1 PARTYOS 1111-AAAA
/dev/sdb3 PARTYSHARE 2222-BBBB
/dev/sdb2 LANPARTY_HOME 3333-CCCC"
assert_eq "$(partyos_resolve_label_dev home 2>/dev/null)" "/dev/sdb2" "legacy stick: home LANPARTY_HOME is still found"
assert_eq "$(partyos_resolve_label_dev share 2>/dev/null)" "/dev/sdb3" "legacy stick: share PARTYSHARE is still found"
setup "/dev/sdb1 PARTYOS 1111-AAAA
/dev/sdb3 PARTYSHARE 2222-BBBB
/dev/sdb2 LANPARTY_HOME 3333-CCCC" nolinks
assert_eq "$(partyos_resolve_label_dev home 2>/dev/null)" "/dev/sdb2" "legacy stick, no by-label links yet: blkid still finds LANPARTY_HOME"

# The legacy stick enumerates first AND has the lower UUIDs. The venue label must still win.
setup "/dev/sda2 LANPARTY_HOME 0000-0001
/dev/sda3 PARTYSHARE 0000-0002
/dev/sdb2 PARTYOSHOME ffff-0001
/dev/sdb3 PARTYDATA ffff-0002"
assert_eq "$(partyos_resolve_label_dev home 2>"${ERR}")" "/dev/sdb2" "both present: the venue home label wins over the old one"
assert_eq "$(partyos_resolve_label_dev share 2>>"${ERR}")" "/dev/sdb3" "both present: the venue share label wins over the old one"
assert_not_contains "$(cat "${ERR}")" "WARN" "both present: one partition per label, so no WARN"
setup "/dev/sda2 LANPARTY_HOME 0000-0001
/dev/sdb2 PARTYOSHOME ffff-0001" nolinks
assert_eq "$(partyos_resolve_label_dev home 2>/dev/null)" "/dev/sdb2" "both present, no by-label links: the venue label still wins"
setup "/dev/sda2 LANPARTY_HOME 0000-0001
/dev/sdb2 PARTYOSHOME ffff-0001"
echo "usb_home_labels=LANPARTY_HOME,PARTYOSHOME" > "${CMDLINE}"
assert_eq "$(partyos_resolve_label_dev home 2>/dev/null)" "/dev/sda2" "a cmdline list with the old label first makes the old label win"
echo "usb_home_labels=PARTYOSHOME" > "${CMDLINE}"
setup "/dev/sda2 LANPARTY_HOME 0000-0001"
echo "usb_home_labels=PARTYOSHOME" > "${CMDLINE}"
assert_eq "$(partyos_resolve_label_dev home 2>/dev/null)" "" "a label that is not in the cmdline list is not used"
setup "/dev/sda1 PARTYOS 1111-AAAA"
assert_eq "$(partyos_resolve_label_dev home 2>/dev/null)" "" "no home partition: empty result"
bash "${LABELS_LIB}" resolve home >/dev/null 2>&1; assert_false $? "the CLI 'resolve home' exits non-zero without a home partition"

echo
echo "================ 3. no probe for a missing first label ========"
# Case: an old stick. The by-label link of LANPARTY_HOME exists. The
# lookup must not run a blkid -t / -L for PARTYOSHOME: with no match, blkid probes
# every block device, and partyos-usb-poll runs the lookup every few seconds.
setup "/dev/sdb2 LANPARTY_HOME 3333-CCCC"
partyos_resolve_label_dev home >/dev/null 2>&1
assert_not_contains "$(cat "${PROBES}")" "PARTYOSHOME" "no blkid call for the missing PARTYOSHOME when LANPARTY_HOME has a link"
assert_contains "$(cat "${PROBES}")" "t LANPARTY_HOME" "blkid -t runs for the linked LANPARTY_HOME (finds every stick with it)"

echo
echo "================ 4. two sticks: deterministic UUID-driven pick ="
# sda2 enumerates FIRST but has the HIGHER UUID; sdb2 has the LOWER UUID.
setup "/dev/sda2 PARTYOSHOME ZZZZ-9999
/dev/sdb2 PARTYOSHOME AAAA-0001"
OUT="$(partyos_resolve_label_dev home 2>"${ERR}")"
ERRBODY="$(cat "${ERR}")"
assert_eq "${OUT}" "/dev/sdb2" "two sticks: picks the LOWEST-UUID device (not the first-enumerated)"
assert_contains "${ERRBODY}" "WARN" "two sticks: logs a WARN about the ambiguity"
assert_contains "${ERRBODY}" "PARTYOSHOME" "two sticks: WARN names the label"
assert_contains "${ERRBODY}" "ignoring:" "two sticks: WARN names the ignored device(s)"
assert_contains "${ERRBODY}" "/dev/sda2" "two sticks: WARN lists the ignored /dev/sda2"
setup "/dev/sdb2 PARTYOSHOME AAAA-0001
/dev/sda2 PARTYOSHOME ZZZZ-9999"
assert_eq "$(partyos_resolve_label_dev home 2>/dev/null)" "/dev/sdb2" "reversed enumeration still picks /dev/sdb2 (boot-stable)"
setup "/dev/sda2 PARTYOSHOME AAAA-0001
/dev/sdb2 PARTYOSHOME ZZZZ-9999"
assert_eq "$(partyos_resolve_label_dev home 2>/dev/null)" "/dev/sda2" "the lower UUID on sda2 moves the pick to sda2 (UUID-driven)"
setup "/dev/sda2 LANPARTY_HOME ZZZZ-9999
/dev/sdb2 LANPARTY_HOME AAAA-0001"
assert_eq "$(partyos_resolve_label_dev home 2>/dev/null)" "/dev/sdb2" "two legacy sticks: the same UUID tie-break"

echo
echo "================ 5. the device check (reinsert) ==============="
setup "/dev/sdc2 PARTYOSHOME 1
/dev/sdd2 LANPARTY_HOME 2
/dev/sde1 RANDOMSTICK 3"
partyos_dev_is home /dev/sdc2; assert_true $? "a PARTYOSHOME device is a home device"
partyos_dev_is home /dev/sdd2; assert_true $? "a LANPARTY_HOME device is a home device"
partyos_dev_is home /dev/sde1; assert_false $? "a foreign stick is not a home device"

echo
echo "================ 6. the consumers use the helper =============="
UH="$(cat "${USBHOME}")"
assert_contains "${UH}" ". /usr/local/lib/partyos-usb-labels.sh" "partyos-usbhome sources the helper"
assert_contains "${UH}" "partyos_resolve_label_dev home" "partyos-usbhome resolves the home through the helper"
assert_contains "${UH}" "partyos_resolve_label_dev share" "partyos-usbhome resolves the share through the helper"
RULE_BODY="$(grep -v '^#' "${RULE}")"
assert_contains "${RULE_BODY}" 'PROGRAM="/usr/bin/bash /usr/local/lib/partyos-usb-labels.sh is home %E{ID_FS_LABEL}"' \
    "the udev add rule asks the helper about the label"
assert_not_contains "${RULE_BODY}" "LANPARTY_HOME" "the udev rule has no fixed label"
assert_not_contains "${RULE_BODY}" 'ID_FS_TYPE' "the udev rule does not match any ext4 partition (a random stick must not pause sync)"
# Drive the rule's PROGRAM exactly as udev runs it.
: > "${CMDLINE}"
bash "${LABELS_LIB}" is home PARTYOSHOME; assert_true $? "udev PROGRAM: PARTYOSHOME matches"
bash "${LABELS_LIB}" is home LANPARTY_HOME; assert_true $? "udev PROGRAM: LANPARTY_HOME matches"
bash "${LABELS_LIB}" is home PARTYDATA; assert_false $? "udev PROGRAM: the share label does not match home"
bash "${LABELS_LIB}" is home MY_USB; assert_false $? "udev PROGRAM: a random label does not match"
echo "usb_home_labels=MYHOME" > "${CMDLINE}"
bash "${LABELS_LIB}" is home MYHOME; assert_true $? "udev PROGRAM: a label from the cmdline list matches"

assert_summary "test-home-select" || exit 1
echo "test-home-select: ALL PASS"
