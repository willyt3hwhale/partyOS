#!/usr/bin/env bash
# test-hotplug-race.sh - hardware-FREE unit tests for the home-sync HOTPLUG-RACE fixes.
# These are timing/lifecycle races whose FULL behavior only shows on a booted client with
# real USB hotplug (that is the fleet-verify part); what is unit-testable here is the pure
# LOCK / MARKER / GATE / QUIESCENCE logic the fixes rest on. Same extractive, carve-and-mock
# style as test-gen-guard.sh / test-home-pull-gate.sh: copy the baked files from
# scripts/build/files/rootfs/ and drive their mechanics against temp dirs with stubbed externals.
#
# Sections:
#   1. coldplug reinsert pull gate - the push stands down while a pull is in
#      flight (PULL_INPROGRESS marker); reinsert DEFERs its gen-guard pull in the boot window.
#   2. removed/reinserted ordering - removed+reinserted serialize on the shared
#      hotplug lock (a second handler waits/skips while the lock is held).
#   3. safe-eject barrier - open-writers detection (/proc scan) + in-flight push quiescence.
#   4. reinsert timer start - the reinsert handler starts the
#      push timer with --no-block, so it does not wait for the boot pull.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

# Copy the sync-common lib and the sync/USB scripts into the sandbox.
RFS="${REPO_ROOT}/scripts/build/files/rootfs"
[ -d "${RFS}" ] || { echo "FAIL: baked rootfs tree not found at ${RFS}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-hotplug.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# --- carve the baked scripts out of their heredocs -----------------------------
COMMON_BODY="${TMP}/common-body.sh"
SYNC_SH="${TMP}/partyos-sync-home"
PULL_SH="${TMP}/partyos-home-pull"
REINS_SH="${TMP}/partyos-usb-reinserted"
REMOVED_SH="${TMP}/partyos-usb-removed"
EJECT_SH="${TMP}/partyos-safe-eject"
cp "${RFS}/usr/local/lib/partyos-sync-common.sh" "${COMMON_BODY}"
cp "${RFS}/usr/local/bin/partyos-sync-home"      "${SYNC_SH}"
cp "${RFS}/usr/local/bin/partyos-home-pull"      "${PULL_SH}"
cp "${RFS}/usr/local/bin/partyos-usb-reinserted" "${REINS_SH}"
cp "${RFS}/usr/local/bin/partyos-usb-removed"    "${REMOVED_SH}"
cp "${RFS}/usr/local/bin/partyos-safe-eject"     "${EJECT_SH}"
for f in COMMON_BODY SYNC_SH PULL_SH REINS_SH REMOVED_SH EJECT_SH; do
    [ -s "${!f}" ] || { echo "FAIL: carved ${f} is empty (heredoc marker moved?)"; exit 1; }
done

# =============================================================================
echo "================ 1. coldplug reinsert pull gate ================"
# --- 1a. revert-guards: the fix markers must be present in the carved source ----
grep -q 'PULL_INPROGRESS'                 "${COMMON_BODY}" || { echo "FAIL: PULL_INPROGRESS not defined in common.sh"; exit 1; }
grep -q 'home pull in progress'           "${SYNC_SH}"     || { echo "FAIL: push PULL_INPROGRESS gate missing from partyos-sync-home"; exit 1; }
grep -q 'PARTYOS-USB-REINSERT-DEFER'      "${REINS_SH}"    || { echo "FAIL: reinsert coldplug DEFER gate missing"; exit 1; }
grep -q '\[ ! -e "${PULL_RAN}" \]'        "${REINS_SH}"    || { echo "FAIL: reinsert defer does not gate on PULL_RAN"; exit 1; }
grep -q ': > "${PULL_INPROGRESS}"'        "${REINS_SH}"    || { echo "FAIL: reinsert does not set PULL_INPROGRESS around its pull"; exit 1; }
grep -q ': > "${PULL_INPROGRESS}"'        "${PULL_SH}"     || { echo "FAIL: boot pull does not set PULL_INPROGRESS around its pull"; exit 1; }
assert_true 0 "revert-guard: PULL_INPROGRESS marker + reinsert PULL_RAN DEFER gate present in the baked source"

# --- shared env + stubs the carved scripts source ------------------------------
MNT="${TMP}/mnt";           install -d "${MNT}"
HOME_DIR="${TMP}/ram-home"; install -d "${HOME_DIR}"
USB_HOME="${TMP}/usb-home"; install -d "${USB_HOME}"
SHARE="${TMP}/share";       install -d "${SHARE}"
RO_FLAG="${TMP}/ro.flag"
PAUSE_FLAG="${TMP}/pause.flag"
PULL_DONE="${TMP}/pull-done"
PULL_INPROGRESS="${TMP}/pull-inprogress"
STATE_FILE="${TMP}/gen.state"
GEN_FILE="${TMP}/gen.baseline"
PUSH_MARKER="${TMP}/push-ran.marker"
export HOME_DIR USB_HOME PUSH_MARKER

# stub common.sh: source the REAL carved COMMON body (for gen_*/dir_empty/etc), then
# override the mount paths + /run flags to temp files and force is_rw true.
COMMON_STUB="${TMP}/common-stub.sh"
cat > "${COMMON_STUB}" <<EOF
. "${COMMON_BODY}"
MNT="${MNT}"; HOME_DIR="${HOME_DIR}"; USB_HOME="${USB_HOME}"; SHARE="${SHARE}"
STATE_FILE="${STATE_FILE}"
PUSH_INPROGRESS="${TMP}/push-inprogress"; GEN_FILE="${GEN_FILE}"
RO_FLAG="${RO_FLAG}"; PAUSE_FLAG="${PAUSE_FLAG}"; PULL_DONE="${PULL_DONE}"
PULL_INPROGRESS="${PULL_INPROGRESS}"; PULL_RAN="${TMP}/pull-ran"
UIDGID="\$(id -u)"; RSYNC_EX=(--exclude=.partyos)
is_rw() { return 0; }
EOF
sed -i.bak "s#\. /usr/local/lib/partyos-sync-common.sh#. ${COMMON_STUB}#" "${SYNC_SH}"

BIN="${TMP}/bin"; install -d "${BIN}"
cat > "${BIN}/mountpoint"          <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${BIN}/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
echo none
EOF
cat > "${BIN}/timeout"             <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
cat > "${BIN}/rsync"               <<'EOF'
#!/usr/bin/env bash
args=("$@"); delete=0
for a in "$@"; do case "$a" in --delete*) delete=1;; esac; done
dst="${args[$(( ${#args[@]} - 1 ))]}"; src="${args[$(( ${#args[@]} - 2 ))]}"
if [ "$delete" = 1 ] && [ "${dst%/}" = "${USB_HOME%/}" ]; then
    echo "PUSH_RAN dst=${dst}" >> "${PUSH_MARKER}"
    mkdir -p "$dst"; cp -a "${src%/}/." "${dst%/}/" 2>/dev/null; exit 0
fi
mkdir -p "$dst"; cp -a "${src%/}/." "${dst%/}/" 2>/dev/null; exit 0
EOF
chmod +x "${BIN}"/*

# baseline: gate open, RAM home non-empty, fresh stick (absent gen -> verdict push).
: > "${PULL_DONE}"
printf 'ram-save\n' > "${HOME_DIR}/save.dat"
run_sync() { PATH="${BIN}:${PATH}" bash "${SYNC_SH}" >"${TMP}/sync.out" 2>&1; }

echo "--- 1b. push STANDS DOWN while a pull is in progress ---"
rm -f "${PUSH_MARKER}"; : > "${PULL_INPROGRESS}"
run_sync || true
assert_contains "$(cat "${TMP}/sync.out")" "home pull in progress" "push logs the pull-in-progress stand-down"
assert_false "$([ -e "${PUSH_MARKER}" ]; echo $?)" "push did NOT run the --delete mirror while PULL_INPROGRESS was set"

echo "--- 1c. push PROCEEDS once the pull marker clears ---"
rm -f "${PUSH_MARKER}" "${PULL_INPROGRESS}"
run_sync || true
assert_not_contains "$(cat "${TMP}/sync.out")" "home pull in progress" "no pull-in-progress skip once the marker is cleared"
assert_true "$([ -e "${PUSH_MARKER}" ]; echo $?)" "push ran the --delete mirror after the pull marker cleared"

# =============================================================================
echo
echo "================ 2. removed/reinserted ordering ================"
# --- 2a. revert-guards: both handlers flock the SHARED hotplug lock (fd 7) ------
grep -q 'HOTPLUG_LOCK' "${COMMON_BODY}" || { echo "FAIL: HOTPLUG_LOCK not defined in common.sh"; exit 1; }
grep -q 'exec 7>"${HOTPLUG_LOCK}"' "${REMOVED_SH}" || { echo "FAIL: partyos-usb-removed does not take the mutual hotplug lock"; exit 1; }
grep -q 'exec 7>"${HOTPLUG_LOCK}"' "${REINS_SH}"    || { echo "FAIL: partyos-usb-reinserted does not take the mutual hotplug lock"; exit 1; }
grep -q 'flock -w 20 7' "${REMOVED_SH}" || { echo "FAIL: removed hotplug flock is not a bounded -w wait"; exit 1; }
grep -q 'flock -w 25 7' "${REINS_SH}"   || { echo "FAIL: reinsert hotplug flock is not a bounded -w wait"; exit 1; }
assert_true 0 "revert-guard: BOTH removed + reinserted flock the shared hotplug lock on fd 7 (bounded)"

# --- 2b. ordering: the lock WRAPS the state-transition body (removed) and is taken
#         AFTER the udev-dedup (reinsert) so duplicate adds still exit free -----
rm_lock="$(grep -n 'exec 7>"${HOTPLUG_LOCK}"' "${REMOVED_SH}" | head -1 | cut -d: -f1)"
rm_pause="$(grep -n ': > "${PAUSE_FLAG}"'      "${REMOVED_SH}" | head -1 | cut -d: -f1)"
assert_true "$([ -n "${rm_lock}" ] && [ -n "${rm_pause}" ] && [ "${rm_lock}" -lt "${rm_pause}" ]; echo $?)" \
    "removed: hotplug lock acquired BEFORE it sets PAUSE_FLAG / umounts (wraps the body)"
re_dedup="$(grep -n 'flock -n 9'               "${REINS_SH}" | head -1 | cut -d: -f1)"
re_mutex="$(grep -n 'exec 7>"${HOTPLUG_LOCK}"' "${REINS_SH}" | head -1 | cut -d: -f1)"
assert_true "$([ -n "${re_dedup}" ] && [ -n "${re_mutex}" ] && [ "${re_dedup}" -lt "${re_mutex}" ]; echo $?)" \
    "reinsert: mutual lock taken AFTER the fd9 udev-dedup (duplicate adds exit without contending)"

# --- 2c. the flock primitive actually SERIALIZES with a bounded wait (Linux/CI). On
#         hosts without util-linux flock (e.g. macOS) this runtime check is
#         deferred to a real boot; the revert-guards above still pin the mechanism. ----
if command -v flock >/dev/null 2>&1; then
    LK="${TMP}/hotplug-serialize.lock"; : > "${LK}"
    flock "${LK}" sleep 2 &   # hold the lock ~2s (models a running handler)
    holder=$!
    sleep 0.4                 # let the holder win the lock first
    flock -w 1 "${LK}" true; rc_held=$?
    assert_false "${rc_held}" "a SECOND handler blocks (flock -w times out) while the hotplug lock is held"
    wait "${holder}" 2>/dev/null || true
    flock -w 1 "${LK}" true; rc_free=$?
    assert_true "${rc_free}" "the lock is re-acquirable once the holder releases (serialized, not deadlocked)"
else
    echo "  SKIP: util-linux flock absent on this host - lock serialization runtime check deferred to Linux/real boot"
fi

# =============================================================================
echo
echo "================ 3. safe-eject barrier (writers + in-flight push) ="
# --- 3a. revert-guards: the barrier + writer gate must be present --------------
grep -q 'mount_writers()' "${COMMON_BODY}" || { echo "FAIL: mount_writers helper missing from common.sh"; exit 1; }
grep -q 'systemctl stop partyos-home-sync.service' "${EJECT_SH}" || { echo "FAIL: safe-eject does not stop a RUNNING push service (in-flight barrier missing)"; exit 1; }
grep -q '\[ -e "${PUSH_INPROGRESS}" \]' "${EJECT_SH}" || { echo "FAIL: safe-eject does not gate on the .partyos-home-pushing marker (fully-synced gate missing)"; exit 1; }
grep -q 'mount_writers' "${EJECT_SH}" || { echo "FAIL: safe-eject does not check open writers before unmount"; exit 1; }
grep -q 'refusing to yank' "${EJECT_SH}" || { echo "FAIL: safe-eject open-writers refuse path missing"; exit 1; }
assert_true 0 "revert-guard: safe-eject barrier (stop running push + .partyos-home-pushing gate + mount_writers) present"

# --- 3b. structural ordering: the writer gate + synced gate come BEFORE unmount --
ej_synced="$(grep -n '\[ -e "${PUSH_INPROGRESS}" \]' "${EJECT_SH}" | head -1 | cut -d: -f1)"
ej_writer="$(grep -n 'mount_writers "${_m}"'         "${EJECT_SH}" | head -1 | cut -d: -f1)"
ej_umount="$(grep -n 'umount -l "${MNT}"'            "${EJECT_SH}" | head -1 | cut -d: -f1)"
assert_true "$([ -n "${ej_synced}" ] && [ "${ej_synced}" -lt "${ej_umount}" ]; echo $?)" "safe-eject: fully-synced (.partyos-home-pushing) gate is BEFORE the home unmount"
assert_true "$([ -n "${ej_writer}" ] && [ "${ej_writer}" -lt "${ej_umount}" ]; echo $?)" "safe-eject: open-writers gate is BEFORE the home unmount"

# --- 3c. mount_writers actually detects open fds + cwd under a mount (synthetic /proc) --
MW_RUN="${TMP}/mw-run.sh"
cat > "${MW_RUN}" <<EOF
. "${COMMON_BODY}"
mount_writers "\$1" "\${2:-0}"
EOF
run_mw() { PROCROOT="$1" bash "${MW_RUN}" "$2" "${3:-0}"; }

SHARE_MP="${TMP}/share-mp"; PR="${TMP}/proc-sim"
install -d "${PR}/4001/fd" "${PR}/4002/fd" "${PR}/4003/fd"
ln -s "${SHARE_MP}/big.iso"  "${PR}/4001/fd/7"   # 4001: fd open under the mount (a copy)
ln -s /dev/null              "${PR}/4001/fd/0"
ln -s /home/gamer            "${PR}/4001/cwd"
ln -s /dev/null              "${PR}/4002/fd/0"    # 4002: cwd under the mount (a file manager)
ln -s "${SHARE_MP}/sub"      "${PR}/4002/cwd"
ln -s /tmp/elsewhere.dat     "${PR}/4003/fd/3"    # 4003: unrelated writer, NOT under the mount
ln -s /home/gamer            "${PR}/4003/cwd"

res_all="$(run_mw "${PR}" "${SHARE_MP}")"
assert_contains " ${res_all} " " 4001 " "mount_writers detects a process with an open fd under the mount (a copy in flight)"
assert_contains " ${res_all} " " 4002 " "mount_writers detects a process whose cwd is under the mount (file manager)"
assert_not_contains " ${res_all} " " 4003 " "mount_writers ignores an unrelated writer NOT under the mount"

res_self="$(run_mw "${PR}" "${SHARE_MP}" 4001)"
assert_not_contains " ${res_self} " " 4001 " "mount_writers excludes the SELF pid (eject's own process is not a false writer)"

QUIET_MP="${TMP}/quiet-mp"; res_none="$(run_mw "${PR}" "${QUIET_MP}")"
assert_eq "$(printf '%s' "${res_none}" | tr -d '[:space:]')" "" "mount_writers returns EMPTY for a quiescent mount (nothing open) -> eject proceeds"

# =============================================================================
echo
echo "================ 4. reinsert timer start ======================="
# partyos-home-pull.service has Before=partyos-home-sync.timer. A blocking
# `systemctl start` of the timer from the coldplug reinsert handler waits for the whole
# boot pull, so a slow pull kills the handler at its TimeoutStartSec. Every start in the
# handler must use --no-block.
blocking="$(grep -nE '^[^#]*systemctl +(start|restart)' "${REINS_SH}" | grep -v -- '--no-block' || true)"
assert_eq "${blocking}" "" "revert-guard: every systemctl start/restart in partyos-usb-reinserted uses --no-block"

# Run the real timer-start line against a stub systemctl. The stub hangs unless the call
# has --no-block, like a start job queued behind the boot pull.
timer_line="$(grep -E '^[^#]*systemctl .*start partyos-home-sync\.timer' "${REINS_SH}" | head -1)"
assert_contains "${timer_line}" "partyos-home-sync.timer" "the reinsert handler still starts partyos-home-sync.timer"
STUB_BIN="${TMP}/stub-bin"; install -d "${STUB_BIN}"
cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --no-block "*) exit 0;; esac
sleep 30
EOF
chmod +x "${STUB_BIN}/systemctl"
PATH="${STUB_BIN}:${PATH}" bash -c "${timer_line}" &
tpid=$!
waited=0
while kill -0 "${tpid}" 2>/dev/null && [ "${waited}" -lt 30 ]; do sleep 0.1; waited=$((waited+1)); done
if kill -0 "${tpid}" 2>/dev/null; then
    pkill -P "${tpid}" 2>/dev/null; kill "${tpid}" 2>/dev/null; wait "${tpid}" 2>/dev/null
    assert_true 1 "the timer start returns at once while its start job waits behind the boot pull"
else
    wait "${tpid}" 2>/dev/null
    assert_true 0 "the timer start returns at once while its start job waits behind the boot pull"
fi

assert_summary "test-hotplug-race" || exit 1
echo "test-hotplug-race: ALL PASS"
