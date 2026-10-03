#!/usr/bin/env bash
# test-service-churn.sh - hardware-FREE unit test for the two churn fixes in the baked
# files under scripts/build/files/rootfs/:
#
#   FIX A - partyos-usb-poll is a LONG-LIVED loop, not a Type=oneshot fired by an ~8s timer.
#           The old oneshot+timer racked up a SERVICE_START/STOP + kernel-audit pair every
#           tick (~1/3 of the journal on a quiet box). A single process with an internal
#           sleep runs the SAME reconcile at the SAME cadence with zero per-tick churn.
#   FIX B - partyos-journal-snapshot SERIALIZES with a non-blocking flock, so on a slow stick
#           a still-running snapshot makes the next timer tick SKIP instead of stacking a
#           second concurrent rsync into the same dir (that drove the load to 19).
#
# Both are baked files (partyos-usb-poll + its unit, partyos-journal-snapshot), so this
# copies them and asserts the contract. No VM, no network, no hardware, no root - pure shell.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

# Map each tag to its baked file and copy it into the sandbox.
RFS="${REPO_ROOT}/scripts/build/files/rootfs"
[ -d "${RFS}" ] || { echo "FAIL: baked rootfs tree not found at ${RFS}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-churntest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# Map each old heredoc TAG to the baked rootfs file that replaced it, then copy it in.
declare -A BAKED=(
  [POLL]="${RFS}/usr/local/bin/partyos-usb-poll"
  [JSNAP]="${RFS}/usr/local/bin/partyos-journal-snapshot"
)
carve() {
    local tag="$1" out="$2" src
    src="${BAKED[$tag]:-}"
    [ -n "${src}" ] && [ -f "${src}" ] || { echo "FAIL: no baked file mapped for tag ${tag}"; exit 1; }
    cp "${src}" "${out}"
    [ -s "${out}" ] || { echo "FAIL: baked file for ${tag} is empty (${src})"; exit 1; }
}

POLL_SH="${TMPDIR_T}/usb-poll.sh"; carve POLL "${POLL_SH}"
SNAP_SH="${TMPDIR_T}/journal-snapshot.sh"; carve JSNAP "${SNAP_SH}"

echo "================ FIX A: partyos-usb-poll is a long-lived loop ==="
POLL_BODY="$(cat "${POLL_SH}")"
bash -n "${POLL_SH}" && assert_true 0 "usb-poll: bash -n syntax OK" || assert_true 1 "usb-poll: bash -n syntax OK"
# The reconcile logic is a function driven by an infinite sleep-loop (no per-tick restart).
assert_contains "${POLL_BODY}" "reconcile()"  "usb-poll: reconcile logic lives in a function"
assert_contains "${POLL_BODY}" "while :; do"  "usb-poll: runs an infinite loop (single long-lived process)"
assert_contains "${POLL_BODY}" 'sleep "${INTERVAL}"' "usb-poll: paces itself with an internal sleep (no timer)"
# The stand-down gate must RETURN from reconcile (loop continues), NOT exit the process (which
# would kill the loop after one tick and re-introduce the churn if paired with a restart).
assert_contains "${POLL_BODY}" '[ -e "${PULL_DONE}" ] || return 0' "usb-poll: pull-gate returns (keeps looping), does not exit"
assert_not_contains "${POLL_BODY}" '[ -e "${PULL_DONE}" ] || exit 0' "usb-poll: no early process-exit gate (old oneshot behaviour gone)"

echo
echo "================ FIX A: the unit is Type=simple, no timer ======="
# Carve JUST the partyos-usb-poll.service block (its heredoc uses the shared 'UNIT' tag, so
# match on the device path to isolate it from the reinserted/removed service blocks).
POLL_UNIT="${TMPDIR_T}/usb-poll.service"
cp "${RFS}/etc/systemd/system/partyos-usb-poll.service" "${POLL_UNIT}"
[ -s "${POLL_UNIT}" ] || { echo "FAIL: partyos-usb-poll.service baked unit is empty"; exit 1; }
POLL_UNIT_BODY="$(cat "${POLL_UNIT}")"
assert_contains "${POLL_UNIT_BODY}" "Type=simple"   "usb-poll.service: Type=simple (long-lived), not oneshot"
assert_not_contains "${POLL_UNIT_BODY}" "Type=oneshot" "usb-poll.service: the churny oneshot type is gone"
assert_contains "${POLL_UNIT_BODY}" "Restart="      "usb-poll.service: restarts if the loop ever dies"
assert_contains "${POLL_UNIT_BODY}" "WantedBy=multi-user.target" "usb-poll.service: enabled as a service, not a timer"
# The usb-poll unit + its enable symlink are set up by the 45-usbhome-sync phase; it must no
# longer generate a partyos-usb-poll.timer at all (the churn source).
USBSYNC_PHASE="${REPO_ROOT}/scripts/build/phases/45-usbhome-sync.sh"
[ -f "${USBSYNC_PHASE}" ] || { echo "FAIL: 45-usbhome-sync.sh not found at ${USBSYNC_PHASE}"; exit 1; }
POLL_TIMER_REFS="$(grep -c 'partyos-usb-poll\.timer' "${USBSYNC_PHASE}" || true)"
assert_eq "${POLL_TIMER_REFS}" "0" "build: no partyos-usb-poll.timer is generated anymore (churn source removed)"
# And it is enabled via a service wants symlink, not a timers.target.wants one.
grep -q 'multi-user.target.wants/partyos-usb-poll.service' "${USBSYNC_PHASE}" \
    && _assert_ok "build: usb-poll enabled via multi-user.target.wants/partyos-usb-poll.service" \
    || _assert_bad "build: usb-poll service enable symlink missing"

echo
echo "================ FIX B: journal-snapshot flock serialization ===="
SNAP_BODY="$(cat "${SNAP_SH}")"
bash -n "${SNAP_SH}" && assert_true 0 "journal-snapshot: bash -n syntax OK" || assert_true 1 "journal-snapshot: bash -n syntax OK"
# The serialization guard: a non-blocking flock that SKIPS (exit 0) when a prior run holds it.
assert_contains "${SNAP_BODY}" "flock -n 9"                       "snapshot: non-blocking flock guard present"
assert_contains "${SNAP_BODY}" "skipping this tick"              "snapshot: an overlapping tick logs the skip, does not stack"
assert_contains "${SNAP_BODY}" "command -v flock"               "snapshot: flock is guarded so a host without it runs unserialized"
# Regression: the existing best-effort/no-wedge behaviour must survive the added lock.
assert_contains "${SNAP_BODY}" "timeout 30 rsync"                "snapshot: bounded rsync still present (no-wedge intact)"
assert_contains "${SNAP_BODY}" "mountpoint -q /mnt/usbhome"      "snapshot: USB-mounted gate still present"

echo
echo "================ FIX B: flock actually blocks a stacked run ====="
if ! command -v flock >/dev/null 2>&1; then
    echo "  SKIP: flock unavailable on this host (macOS/CI) - behavioural serialization test skipped;"
    echo "        the grep contract above pins the guard, and it exercises on the Arch target + Linux CI."
else
    # Drive the REAL snapshot script with a held lock and prove the second run SKIPS.
    (
        FAKE="${TMPDIR_T}/flockbe"; mkdir -p "${FAKE}/bin"
        SHIM="${FAKE}/bin"
        cat > "${SHIM}/mountpoint" <<'M'
#!/usr/bin/env bash
exit 0
M
        chmod +x "${SHIM}/mountpoint"
        LIVE="${FAKE}/run/log/journal/aabb"; mkdir -p "${LIVE}"; echo bytes > "${LIVE}/system.journal"
        mkdir -p "${FAKE}/mnt/usbhome"
        BID="${FAKE}/boot_id"; echo "0123abcd-4567-89ef-0123-456789abcdef" > "${BID}"
        LOCK="${FAKE}/snap.lock"
        SCRIPT2="${FAKE}/snap.sh"
        sed -e "s#/run/log/journal#${FAKE}/run/log/journal#g" \
            -e "s#/var/log/journal#${FAKE}/var/log/journal#g" \
            -e "s#/mnt/usbhome#${FAKE}/mnt/usbhome#g" \
            -e "s#/proc/sys/kernel/random/boot_id#${BID}#g" \
            -e "s#/run/partyos-journal-snapshot.lock#${LOCK}#g" \
            "${SNAP_SH}" > "${SCRIPT2}"
        # Hold the lock for the duration of the run in a background flock, then invoke the script.
        ( flock -n 200 || exit 0; sleep 3 ) 200>"${LOCK}" &
        HOLDER=$!
        sleep 0.3   # let the holder acquire
        OUT="${FAKE}/out"
        PATH="${SHIM}:${PATH}" bash "${SCRIPT2}" > "${OUT}" 2>&1; rc=$?
        kill "${HOLDER}" 2>/dev/null || true; wait "${HOLDER}" 2>/dev/null || true
        BODY="$(cat "${OUT}")"
        assert_true "${rc}" "snapshot: a locked-out run still exits 0 (best-effort)"
        assert_contains "${BODY}" "skipping this tick" "snapshot: the locked-out run SKIPS instead of stacking a second rsync"
        # It must NOT have written a boot-* snapshot dir (proof no concurrent copy happened).
        if ls "${FAKE}"/mnt/usbhome/.partyos-journal/boot-*/system.journal >/dev/null 2>&1; then
            _assert_bad "snapshot: locked-out run wrote a snapshot anyway (stacking not prevented)"
        else
            _assert_ok "snapshot: locked-out run wrote NO snapshot dir (stacking prevented)"
        fi
    )
fi

assert_summary "test-service-churn" || exit 1
echo "test-service-churn: ALL PASS"
