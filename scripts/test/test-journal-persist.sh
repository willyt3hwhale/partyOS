#!/usr/bin/env bash
# test-journal-persist.sh - hardware-FREE unit test for the BAKED USB journal SNAPSHOT
# + the loosened runtime watchdog. Both are baked files under
# scripts/build/files/rootfs/ (partyos-journal-snapshot, its units, journald.conf and
# the watchdog confs). This test copies those files and asserts the contract that
# makes the PREVIOUS boot's journal readable after a reboot, plus the watchdog timing.
# No VM, no network, no hardware, no root - pure shell, runnable locally and in CI.
#
# The live journal and /etc/machine-id do not survive a reboot. partyos-journal-snapshot
# copies the live journal to /mnt/usbhome/.partyos-journal/boot-<ts>-<bootid>/ and keeps
# the last 5 boots. partyos-lastboot-log reads a saved boot with journalctl --directory.
# This test pins:
#   * journald.conf: Storage=volatile (live journal in /run, which we snapshot) + bounded
#     (RuntimeMaxUse/SystemMaxUse) + Compress
#   * the snapshot script: copies the live journal source (/run|/var/log .../*.journal) to a
#     timestamped per-boot USB dir, keyed on the boot id (one dir per boot), rsync/cp, prune to
#     last 5, best-effort guards (USB-not-mounted -> exit 0; bounded copy/prune)
#   * the lastboot-log helper: --directory read, default = previous boot, list/current/-n
#   * the units: timer (OnUnitActiveSec=60s, enabled) + shutdown oneshot (ExecStop, can't wedge)
#
# RuntimeWatchdogSec is 90s. The HW chip timeout (heartbeat/soft_margin) must be
# >= RuntimeWatchdogSec, and this test enforces that.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

# Map each tag to its baked file.
RFS="${REPO_ROOT}/scripts/build/files/rootfs"
[ -d "${RFS}" ] || { echo "FAIL: baked rootfs tree not found at ${RFS}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-journaltest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# Map each old heredoc TAG to the baked rootfs file that replaced it.
declare -A BAKED=(
  [JRN]="${RFS}/etc/systemd/journald.conf"
  [JSNAP]="${RFS}/usr/local/bin/partyos-journal-snapshot"
  [LBL]="${RFS}/usr/local/bin/partyos-lastboot-log"
  [JSU]="${RFS}/etc/systemd/system/partyos-journal-snapshot.service"
  [JST]="${RFS}/etc/systemd/system/partyos-journal-snapshot.timer"
  [JSS]="${RFS}/etc/systemd/system/partyos-journal-snapshot-shutdown.service"
  [WDP]="${RFS}/etc/modprobe.d/partyos-watchdog.conf"
  [WDG]="${RFS}/etc/systemd/system.conf.d/20-partyos-reboot-watchdog.conf"
)
# Copy the baked rootfs file that replaced the <<'TAG' heredoc into the sandbox.
carve() {
    local tag="$1" out="$2" src
    src="${BAKED[$tag]:-}"
    [ -n "${src}" ] && [ -f "${src}" ] || { echo "FAIL: no baked file mapped for tag ${tag}"; exit 1; }
    cp "${src}" "${out}"
    [ -s "${out}" ] || { echo "FAIL: baked file for ${tag} is empty (${src})"; exit 1; }
}

JRN_CONF="${TMPDIR_T}/journald.conf";  carve JRN  "${JRN_CONF}"
SNAP_SH="${TMPDIR_T}/journal-snapshot.sh"; carve JSNAP "${SNAP_SH}"
LBL_SH="${TMPDIR_T}/lastboot-log.sh";  carve LBL  "${LBL_SH}"
SU_UNIT="${TMPDIR_T}/snapshot.service"; carve JSU "${SU_UNIT}"
ST_UNIT="${TMPDIR_T}/snapshot.timer";   carve JST "${ST_UNIT}"
SS_UNIT="${TMPDIR_T}/snapshot-shutdown.service"; carve JSS "${SS_UNIT}"
WDP_CONF="${TMPDIR_T}/watchdog.modprobe"; carve WDP "${WDP_CONF}"
WDG_CONF="${TMPDIR_T}/watchdog.systemd";  carve WDG "${WDG_CONF}"

echo "================ SNAPSHOT: journald.conf - volatile + bounded ="
JRN_BODY="$(cat "${JRN_CONF}")"
assert_contains "${JRN_BODY}" "Storage=volatile"     "journald: Storage=volatile (live journal in /run; snapshot copies it - no machine-id minefield)"
assert_not_contains "${JRN_BODY}" "Storage=persistent" "journald: NOT Storage=persistent (the old bind approach is gone)"
assert_contains "${JRN_BODY}" "Compress=yes"         "journald: Compress=yes (slow USB - keep the snapshot small)"
assert_contains "${JRN_BODY}" "RuntimeMaxUse=64M"    "journald: live /run journal capped at 64M (snapshot stays small)"
assert_contains "${JRN_BODY}" "SystemMaxUse=64M"     "journald: persistent ceiling kept at 64M (defensive)"

echo
echo "================ SNAPSHOT: snapshot script - copy contract ===="
SNAP_BODY="$(cat "${SNAP_SH}")"
bash -n "${SNAP_SH}" && assert_true 0 "snapshot script: bash -n syntax OK" || assert_true 1 "snapshot script: bash -n syntax OK"
assert_contains "${SNAP_BODY}" "/mnt/usbhome/.partyos-journal" "snapshot: destination is the USB .partyos-journal dir (p2 root, outside /home)"
assert_contains "${SNAP_BODY}" "/run/log/journal"             "snapshot: looks for the live journal under /run (volatile RAM OS)"
assert_contains "${SNAP_BODY}" "/var/log/journal"             "snapshot: also looks under /var/log (if journald ever persists)"
assert_contains "${SNAP_BODY}" "boot-"                        "snapshot: per-boot dir is named boot-<ts>-<bootid> (timestamped)"
assert_contains "${SNAP_BODY}" "boot_id"                      "snapshot: keys the dest on the systemd boot id (one dir per boot, not per tick)"
assert_contains "${SNAP_BODY}" "KEEP=5"                       "snapshot: retains the last 5 per-boot snapshots (bounded disk)"
assert_contains "${SNAP_BODY}" "rm -rf"                       "snapshot: prunes older snapshots beyond KEEP"
# best-effort: a missing/slow stick must NEVER wedge boot OR shutdown.
assert_contains "${SNAP_BODY}" "mountpoint -q /mnt/usbhome"   "snapshot: gates on the USB being mounted (defensive)"
assert_contains "${SNAP_BODY}" "timeout 30 rsync"             "snapshot: rsync copy is bounded by timeout (a wedged stick can't freeze us)"
assert_contains "${SNAP_BODY}" "timeout 30 cp"               "snapshot: cp fallback is bounded too"
assert_contains "${SNAP_BODY}" "exit 0"                       "snapshot: bails best-effort (exit 0) when the stick is absent / no journal yet"
# The prune MUST sort chronologically so the OLDEST is dropped, not the newest.
assert_contains "${SNAP_BODY}" "sort"                         "snapshot: sorts snapshot dirs chronologically before pruning (drops oldest)"

echo
echo "================ SNAPSHOT: snapshot script - end-to-end on fakes"
# Drive the REAL snapshot logic against a faked /run journal + a faked USB mount, with shims
# for mountpoint (always mounted) and the boot id. Prove a *.journal is copied to a boot-* dir.
RUN_OUT="${TMPDIR_T}/snap.out"
(
    FAKE_ROOT="${TMPDIR_T}/e2e"; mkdir -p "${FAKE_ROOT}"
    SHIM="${FAKE_ROOT}/bin"; mkdir -p "${SHIM}"
    # mountpoint -> always "mounted" (rc 0) for /mnt/usbhome.
    cat > "${SHIM}/mountpoint" <<'SHIM1'
#!/usr/bin/env bash
exit 0
SHIM1
    chmod +x "${SHIM}/mountpoint"
    # `timeout` is a Linux coreutil; macOS/CI build hosts may lack it (gtimeout only). The
    # snapshot script correctly uses `timeout` for the real Arch target - shim it to a plain
    # passthrough here so the e2e exercises the real copy path regardless of the host.
    if ! command -v timeout >/dev/null 2>&1; then
        cat > "${SHIM}/timeout" <<'SHIMT'
#!/usr/bin/env bash
shift; exec "$@"
SHIMT
        chmod +x "${SHIM}/timeout"
    fi
    # A fake live journal under /run and a fake USB dest. We cannot write to the real
    # /run or /mnt, so run a COPY of the script with those paths rewritten to the sandbox.
    LIVE="${FAKE_ROOT}/run/log/journal/aabbccdd"; mkdir -p "${LIVE}"
    echo "FAKEJOURNALBYTES" > "${LIVE}/system.journal"
    USB="${FAKE_ROOT}/mnt/usbhome/.partyos-journal"; mkdir -p "${FAKE_ROOT}/mnt/usbhome"
    BID="${FAKE_ROOT}/boot_id"; echo "0123abcd-4567-89ef-0123-456789abcdef" > "${BID}"
    SCRIPT2="${FAKE_ROOT}/snap.sh"
    sed -e "s#/run/log/journal#${FAKE_ROOT}/run/log/journal#g" \
        -e "s#/var/log/journal#${FAKE_ROOT}/var/log/journal#g" \
        -e "s#/mnt/usbhome#${FAKE_ROOT}/mnt/usbhome#g" \
        -e "s#/proc/sys/kernel/random/boot_id#${BID}#g" \
        "${SNAP_SH}" > "${SCRIPT2}"
    PATH="${SHIM}:${PATH}" bash "${SCRIPT2}" > "${RUN_OUT}" 2>&1
    echo "rc=$?" >> "${RUN_OUT}"
    # Did a boot-* dir get a copy of the fake journal?
    if ls "${USB}"/boot-*/system.journal >/dev/null 2>&1; then
        echo "COPIED_OK" >> "${RUN_OUT}"
        grep -q FAKEJOURNALBYTES "${USB}"/boot-*/system.journal 2>/dev/null && echo "BYTES_MATCH" >> "${RUN_OUT}"
    fi
)
RUN_BODY="$(cat "${RUN_OUT}")"
assert_contains "${RUN_BODY}" "rc=0"        "snapshot e2e: run exits 0"
assert_contains "${RUN_BODY}" "COPIED_OK"   "snapshot e2e: the live *.journal was copied into a boot-* dir on the (fake) USB"
assert_contains "${RUN_BODY}" "BYTES_MATCH" "snapshot e2e: the copied journal bytes match the source"

echo
echo "================ SNAPSHOT: snapshot script - USB-absent is a no-op"
NOMNT_OUT="${TMPDIR_T}/nomnt.out"
(
    SHIM="${TMPDIR_T}/binnomnt"; mkdir -p "${SHIM}"
    cat > "${SHIM}/mountpoint" <<'SHIM2'
#!/usr/bin/env bash
exit 1
SHIM2
    chmod +x "${SHIM}/mountpoint"
    PATH="${SHIM}:${PATH}" bash "${SNAP_SH}" > "${NOMNT_OUT}" 2>&1
    echo "rc=$?" >> "${NOMNT_OUT}"
)
assert_contains "$(cat "${NOMNT_OUT}")" "rc=0"                    "snapshot: USB-not-mounted run exits 0 (best-effort, no boot wedge)"
assert_contains "$(cat "${NOMNT_OUT}")" "cannot snapshot"        "snapshot: USB-not-mounted run logs the degraded path"
assert_not_contains "$(cat "${NOMNT_OUT}")" "snapshotted "       "snapshot: USB-not-mounted run does NOT attempt a copy"

echo
echo "================ SNAPSHOT: partyos-lastboot-log helper contract"
LBL_BODY="$(cat "${LBL_SH}")"
bash -n "${LBL_SH}" && assert_true 0 "lastboot-log: bash -n syntax OK" || assert_true 1 "lastboot-log: bash -n syntax OK"
assert_contains "${LBL_BODY}" "journalctl --directory" "lastboot-log: reads a saved snapshot via journalctl --directory (machine-id irrelevant)"
assert_contains "${LBL_BODY}" "/mnt/usbhome/.partyos-journal" "lastboot-log: reads from the USB snapshot dir"
assert_contains "${LBL_BODY}" "previous boot"          "lastboot-log: default target is the PREVIOUS boot"
assert_contains "${LBL_BODY}" "--list"                 "lastboot-log: supports --list to enumerate saved boots"
# Default (no-arg) must pick the SECOND-newest (previous boot), not the newest (current).
LBL_OUT="${TMPDIR_T}/lbl.out"
(
    FAKE="${TMPDIR_T}/lbl"; USB="${FAKE}/mnt/usbhome/.partyos-journal"; mkdir -p "${USB}"
    # Three fake boots; the helper default should read boot-2 (the previous), not boot-3.
    for b in 1 2 3; do mkdir -p "${USB}/boot-2026010${b}-000000-id${b}"; echo x > "${USB}/boot-2026010${b}-000000-id${b}/system.journal"; done
    # Shim journalctl to just echo which directory it was asked to read.
    SHIM="${FAKE}/bin"; mkdir -p "${SHIM}"
    cat > "${SHIM}/journalctl" <<'JCSHIM'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in --directory=*) echo "JOURNALCTL_DIR=${a#--directory=}";; esac; done
JCSHIM
    chmod +x "${SHIM}/journalctl"
    SCRIPT2="${FAKE}/lbl.sh"
    sed "s#/mnt/usbhome#${FAKE}/mnt/usbhome#g" "${LBL_SH}" > "${SCRIPT2}"
    PATH="${SHIM}:${PATH}" bash "${SCRIPT2}" > "${LBL_OUT}" 2>&1
    echo "rc=$?" >> "${LBL_OUT}"
)
assert_contains "$(cat "${LBL_OUT}")" "id2" "lastboot-log: no-arg default reads the PREVIOUS boot (second-newest), not the current"
assert_not_contains "$(cat "${LBL_OUT}")" "JOURNALCTL_DIR=${TMPDIR_T}/lbl/mnt/usbhome/.partyos-journal/boot-20260103-000000-id3" \
    "lastboot-log: no-arg default does NOT read the current boot (newest)"

echo
echo "================ SNAPSHOT: snapshot timer - every 60s, enabled ="
ST_BODY="$(cat "${ST_UNIT}")"
assert_contains "${ST_BODY}" "OnUnitActiveSec=60s" "timer: fires every 60s (snapshot is current to within ~60s on a hard-reset)"
assert_contains "${ST_BODY}" "OnBootSec="          "timer: first snapshot a short while into boot"
assert_contains "${ST_BODY}" "WantedBy=timers.target" "timer: enabled in timers.target"
SU_BODY="$(cat "${SU_UNIT}")"
assert_contains "${SU_BODY}" "Type=oneshot"          "snapshot.service: oneshot"
assert_contains "${SU_BODY}" "After=partyos-usbhome.service" "snapshot.service: ordered After the USB-home mount (dest must exist)"
assert_contains "${SU_BODY}" "TimeoutStartSec="      "snapshot.service: bounded start (a slow stick can't hang the timer)"

echo
echo "================ SNAPSHOT: shutdown oneshot - final snapshot ==="
SS_BODY="$(cat "${SS_UNIT}")"
assert_contains "${SS_BODY}" "ExecStop=/usr/local/bin/partyos-journal-snapshot" "shutdown: snapshots one last time on the way down (captures the last ~60s)"
assert_contains "${SS_BODY}" "Conflicts=shutdown.target" "shutdown: pulled out of the shutdown transaction (can't wedge reboot)"
assert_contains "${SS_BODY}" "Before=shutdown.target"    "shutdown: ordered before shutdown.target"
assert_contains "${SS_BODY}" "TimeoutStopSec="           "shutdown: ExecStop is bounded (a stuck stick can't hang reboot)"

echo
echo "================ WATCHDOG: RuntimeWatchdogSec loosened 30s -> 90s"
WDG_BODY="$(cat "${WDG_CONF}")"
assert_contains "${WDG_BODY}"     "RuntimeWatchdogSec=90s" "watchdog: RuntimeWatchdogSec=90s (less spurious reset, still self-recovers)"
assert_not_contains "${WDG_BODY}" "RuntimeWatchdogSec=30s" "watchdog: the old tight 30s value is gone"
assert_contains "${WDG_BODY}"     "RebootWatchdogSec=60s"  "watchdog: RebootWatchdogSec kept (tighter final-phase bound)"

echo
echo "================ WATCHDOG: HW chip timeout >= RuntimeWatchdogSec"
# Invariant: the module heartbeat/soft_margin (the chip's own timeout) MUST be >= the
# RuntimeWatchdogSec PID 1 pets at, or the chip fires before the pet and resets a healthy box.
WDP_BODY="$(cat "${WDP_CONF}")"
ITCO_HB="$(grep -oE 'heartbeat=[0-9]+'   "${WDP_CONF}" | head -1 | cut -d= -f2)"
SOFT_MG="$(grep -oE 'soft_margin=[0-9]+' "${WDP_CONF}" | head -1 | cut -d= -f2)"
RTW_SEC="$(grep -oE 'RuntimeWatchdogSec=[0-9]+' "${WDG_CONF}" | head -1 | cut -d= -f2)"
assert_true "$([ -n "${ITCO_HB}" ]; echo $?)" "modprobe: iTCO heartbeat= is set"
assert_true "$([ -n "${SOFT_MG}" ]; echo $?)" "modprobe: softdog soft_margin= is set"
assert_true "$([ "${ITCO_HB:-0}" -ge "${RTW_SEC:-0}" ]; echo $?)" "iTCO heartbeat (${ITCO_HB}) >= RuntimeWatchdogSec (${RTW_SEC})"
assert_true "$([ "${SOFT_MG:-0}" -ge "${RTW_SEC:-0}" ]; echo $?)" "softdog soft_margin (${SOFT_MG}) >= RuntimeWatchdogSec (${RTW_SEC})"
assert_not_contains "${WDP_BODY}" "heartbeat=30"   "modprobe: stale 30s iTCO heartbeat is gone"
assert_not_contains "${WDP_BODY}" "soft_margin=30" "modprobe: stale 30s softdog margin is gone"

assert_summary "test-journal-persist" || exit 1
echo "test-journal-persist: ALL PASS"
