#!/usr/bin/env bash
# test-usb-removed-same-stick.sh - hardware-free tests for the same-stick gate of the
# home stick removal.
#
# Two triggers unmounted a home stick that was still present:
#   A. A stacked mount (two layers of /dev/sda2 at /mnt/usbhome). partyos-usb-poll read
#      two SOURCE lines from findmnt, the text was not a block device, and the poll
#      started the removed handler.
#   B. A second stick with a home label was removed. The udev remove rule started the
#      removed handler, and the handler unmounted the home stick without a check.
# The tests use a fake mountinfo file (PARTYOS_MOUNTINFO) and a fake sysfs root
# (PARTYOS_SYSFS). They run the baked scripts with stubbed commands.
#
# Sections:
#   1. mount_majmins and mounted_dev_present (sync-common helpers).
#   2. partyos-usb-removed: the same-stick gate (with and without MAJ:MIN).
#   3. partyos-usb-poll: the reconcile uses sysfs and needs two gone checks.
#   4. the udev rule and the units pass the MAJ:MIN.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

RFS="${REPO_ROOT}/scripts/build/files/rootfs"
COMMON="${RFS}/usr/local/lib/partyos-sync-common.sh"
REMOVED="${RFS}/usr/local/bin/partyos-usb-removed"
POLL="${RFS}/usr/local/bin/partyos-usb-poll"
RULE="${RFS}/etc/udev/rules.d/99-partyos-usbhome.rules"
TUNIT="${RFS}/etc/systemd/system/partyos-usb-removed@.service"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-samestick.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

MNT="${TMP}/mnt/usbhome"; SHARE="${TMP}/mnt/share"
install -d "${MNT}" "${SHARE}"
MI="${TMP}/mountinfo"; SYS="${TMP}/sys"
export PARTYOS_MOUNTINFO="${MI}" PARTYOS_SYSFS="${SYS}"

# mi_line ID MAJ:MIN MOUNTPOINT SOURCE -> one mountinfo line.
mi_line() { echo "$1 38 $2 / $3 rw,noatime shared:1 - ext4 $4 rw"; }
# sys_dev MAJ:MIN -> the device exists in the fake sysfs.
sys_dev() { install -d "${SYS}/dev/block/$1"; }
sys_reset() { rm -rf "${SYS}"; install -d "${SYS}/dev/block"; }

# =============================================================================
echo "================ 1. sync-common helpers ==="
HELP="${TMP}/help.sh"
cat > "${HELP}" <<EOF
. "${COMMON}"
"\$@"
EOF

{ mi_line 20 0:24 /run tmpfs; mi_line 445 8:2 "${MNT}" /dev/sda2; mi_line 446 8:2 "${MNT}" /dev/sda2; mi_line 457 8:3 "${SHARE}" /dev/sda3; } > "${MI}"
assert_eq "$(bash "${HELP}" mount_majmins "${MNT}")" "8:2" "mount_majmins: a stacked mount gives one MAJ:MIN"
assert_eq "$(bash "${HELP}" mount_majmins "${TMP}/none")" "" "mount_majmins: no mount gives no output"

sys_reset; sys_dev 8:2
bash "${HELP}" mounted_dev_present "${MNT}"; rc=$?
assert_eq "${rc}" "0" "mounted_dev_present: stacked mount of a present device is present (exit 0)"
sys_reset
bash "${HELP}" mounted_dev_present "${MNT}"; rc=$?
assert_eq "${rc}" "1" "mounted_dev_present: device gone from sysfs is gone (exit 1)"
bash "${HELP}" mounted_dev_present "${TMP}/none"; rc=$?
assert_eq "${rc}" "2" "mounted_dev_present: nothing mounted gives exit 2"

# =============================================================================
echo
echo "================ 2. partyos-usb-removed same-stick gate ==="
BIN="${TMP}/bin"; install -d "${BIN}"
CALLS="${TMP}/calls.log"
# umount and systemctl record the call. mountpoint says "mounted" while the
# fake mountinfo has the mountpoint. umount drops the mountpoint from mountinfo.
cat > "${BIN}/umount" <<EOF
#!/usr/bin/env bash
mp="\${@: -1}"
echo "umount \${mp}" >> "${CALLS}"
awk -v mp="\${mp}" '\$5 != mp' "${MI}" > "${MI}.new" && mv "${MI}.new" "${MI}"
EOF
cat > "${BIN}/mountpoint" <<EOF
#!/usr/bin/env bash
mp="\${@: -1}"
awk -v mp="\${mp}" '\$5 == mp { f=1 } END { exit f ? 0 : 1 }' "${MI}"
EOF
for c in systemctl pkill partyos-usb-notify; do
    cat > "${BIN}/${c}" <<EOF
#!/usr/bin/env bash
echo "${c} \$*" >> "${CALLS}"
EOF
done
printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/flock"
printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/sync"
printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/findmnt"
printf '#!/usr/bin/env bash\necho none\n' > "${BIN}/systemd-detect-virt"
chmod +x "${BIN}"/*

COMMON_STUB="${TMP}/common-stub.sh"
cat > "${COMMON_STUB}" <<EOF
. "${COMMON}"
MNT="${MNT}"; SHARE="${SHARE}"; USB_HOME="${MNT}/home"
PAUSE_FLAG="${TMP}/pause.flag"; HOTPLUG_LOCK="${TMP}/hotplug.lock"
EOF
REMOVED_SH="${TMP}/partyos-usb-removed"
sed -e "s#\. /usr/local/lib/partyos-sync-common.sh#. ${COMMON_STUB}#" \
    -e "s#/usr/local/bin/partyos-usb-notify#partyos-usb-notify#" \
    -e "s#/run/partyos-hotplug.log#${TMP}/hotplug.log#" "${REMOVED}" > "${REMOVED_SH}"

# run_removed [MAJ:MIN] -> run the handler; the output is in ${TMP}/removed.out.
run_removed() { rm -f "${CALLS}" "${TMP}/pause.flag"; : > "${CALLS}"
    PATH="${BIN}:${PATH}" bash "${REMOVED_SH}" "$@" > "${TMP}/removed.out" 2>&1; }
home_mi() { { mi_line 445 8:2 "${MNT}" /dev/sda2; [ "${1:-}" = stacked ] && mi_line 446 8:2 "${MNT}" /dev/sda2; mi_line 457 8:3 "${SHARE}" /dev/sda3; } > "${MI}"; }

echo "--- 2a. trigger B: a second stick (8:18) is removed; the home stick 8:2 stays ---"
home_mi; sys_reset; sys_dev 8:2; sys_dev 8:3
run_removed 8:18
assert_contains "$(cat "${TMP}/removed.out")" "PARTYOS-USB-REMOVED-IGNORED removed device 8:18 is not the home stick" "removed@8:18: logs IGNORED"
assert_not_contains "$(cat "${CALLS}")" "umount" "removed@8:18: does not unmount anything"
assert_false "$([ -e "${TMP}/pause.flag" ]; echo $?)" "removed@8:18: does not pause the sync"

echo "--- 2b. trigger A: poll path, stacked mount, device present ---"
home_mi stacked; sys_reset; sys_dev 8:2; sys_dev 8:3
run_removed
assert_contains "$(cat "${TMP}/removed.out")" "PARTYOS-USB-REMOVED-IGNORED the home stick" "removed (no arg), device present: logs IGNORED"
assert_not_contains "$(cat "${CALLS}")" "umount" "removed (no arg), device present: does not unmount"

echo "--- 2c. real removal of the home stick: udev path (8:2) ---"
home_mi; sys_reset
run_removed 8:2
assert_contains "$(cat "${TMP}/removed.out")" "PARTYOS-USB-REMOVED home stick removed" "removed@8:2: logs the removal"
assert_contains "$(cat "${CALLS}")" "umount ${MNT}" "removed@8:2: unmounts the home"
assert_contains "$(cat "${CALLS}")" "umount ${SHARE}" "removed@8:2: unmounts the share"
assert_true "$([ -e "${TMP}/pause.flag" ]; echo $?)" "removed@8:2: pauses the sync"

echo "--- 2d. udev path when the number came back (fast replug gave 8:2 again) ---"
home_mi; sys_reset; sys_dev 8:2
run_removed 8:2
assert_contains "$(cat "${CALLS}")" "umount ${MNT}" "removed@8:2 with 8:2 in sysfs again: still unmounts (the kernel removed that device)"

echo "--- 2e. real removal: poll path, device gone from sysfs ---"
home_mi stacked; sys_reset
run_removed
assert_contains "$(cat "${CALLS}")" "umount ${MNT}" "removed (no arg), device gone: unmounts the home"
assert_true "$([ -e "${TMP}/pause.flag" ]; echo $?)" "removed (no arg), device gone: pauses the sync"

echo "--- 2f. nothing mounted: the handler pauses as before ---"
: > "${MI}"; sys_reset
run_removed 8:2
assert_true "$([ -e "${TMP}/pause.flag" ]; echo $?)" "removed with no home mount: pauses the sync (unchanged)"

# =============================================================================
echo
echo "================ 3. partyos-usb-poll reconcile ==="
POLL_SH="${TMP}/poll-reconcile.sh"
LABELS_STUB="${TMP}/labels-stub.sh"
echo 'partyos_resolve_label_dev() { echo /dev/sda2; }' > "${LABELS_STUB}"
: > "${TMP}/pull-done"
{
    echo "PATH=\"${BIN}:\${PATH}\""
    sed -e '/^while :; do/,$d' \
        -e "s#\. /usr/local/lib/partyos-sync-common.sh#. ${COMMON_STUB}#" \
        -e "s#\. /usr/local/lib/partyos-usb-labels.sh#. ${LABELS_STUB}#" "${POLL}"
    echo "PULL_DONE=\"${TMP}/pull-done\""
    echo 'for _ in $(seq 1 "${TICKS:-1}"); do reconcile; done'
} > "${POLL_SH}"
run_poll() { rm -f "${CALLS}"; : > "${CALLS}"; TICKS="$1" bash "${POLL_SH}" > "${TMP}/poll.out" 2>&1; }

echo "--- 3a. trigger A: stacked mount, device present, 3 checks ---"
home_mi stacked; sys_reset; sys_dev 8:2; sys_dev 8:3
run_poll 3
assert_not_contains "$(cat "${CALLS}")" "partyos-usb-removed" "poll: a stacked mount of a present stick does not start the removed handler"

echo "--- 3b. device gone: one check does not start the handler ---"
home_mi; sys_reset
run_poll 1
assert_not_contains "$(cat "${CALLS}")" "partyos-usb-removed" "poll: one gone check does not start the removed handler"
assert_contains "$(cat "${TMP}/poll.out")" "confirming on the next check" "poll: one gone check logs that it waits for a second check"

echo "--- 3c. device gone: two checks start the handler ---"
home_mi; sys_reset
run_poll 2
assert_contains "$(cat "${CALLS}")" "systemctl --no-block start partyos-usb-removed.service" "poll: two gone checks start the removed handler"

echo "--- 3d. a present check between two gone checks resets the count ---"
# tick 1 gone, tick 2 present, tick 3 gone -> no handler.
cat > "${TMP}/poll-flap.sh" <<EOF
$(sed '$d' "${POLL_SH}")
rm -rf "${SYS}/dev/block/8:2"; reconcile
install -d "${SYS}/dev/block/8:2"; reconcile
rm -rf "${SYS}/dev/block/8:2"; reconcile
EOF
home_mi; sys_reset; rm -f "${CALLS}"; : > "${CALLS}"
bash "${TMP}/poll-flap.sh" > "${TMP}/poll.out" 2>&1
assert_not_contains "$(cat "${CALLS}")" "partyos-usb-removed" "poll: gone, present, gone does not start the removed handler"

# =============================================================================
echo
echo "================ 4. udev rule and units ==="
assert_contains "$(cat "${RULE}")" 'start partyos-usb-removed@%M:%m.service' "udev rule: the remove action passes MAJ:MIN to the template unit"
assert_true "$([ -s "${TUNIT}" ]; echo $?)" "partyos-usb-removed@.service exists"
assert_contains "$(cat "${TUNIT}")" 'ExecStart=/usr/local/bin/partyos-usb-removed %i' "template unit passes the instance (MAJ:MIN) to the handler"
assert_contains "$(cat "${REPO_ROOT}/scripts/build/files/rootfs.manifest")" 'etc/systemd/system/partyos-usb-removed@.service' "manifest lists the template unit"
assert_contains "$(cat "${REPO_ROOT}/scripts/build/phases/45-usbhome-sync.sh")" 'bake "etc/systemd/system/partyos-usb-removed@.service"' "build phase bakes the template unit"
assert_not_contains "$(cat "${POLL}")" '[ ! -b "${src}" ]' "poll: the findmnt SOURCE text test is gone"

assert_summary "test-usb-removed-same-stick"
