#!/usr/bin/env bash
# test-gen-guard.sh - hardware-FREE unit test for the BAKED home-sync GENERATION
# GUARD (regression guard). The guard is in the baked file
# scripts/build/files/rootfs/usr/local/lib/partyos-sync-common.sh. This test SOURCES
# the real gen_read_status / gen_decide helpers from that file, and exercises the verdict table
# against real temp dirs. No VM, no network, no hardware - pure shell.
#
# gen_decide emits one of these verdicts. It treats an absent gen as fresh and a corrupt gen as danger:
#   push       - stick older/fresh/EQUAL: normal --delete-delay push (FAST PATH).
#   standdown  - stick strictly newer: don't push (reinsert pulls the same-user newer stick).
#   corrupt    - stick gen unreadable: do NOT clobber; stand down (stick left untouched).
# The USERNAME mount gate mounts only this box's own stick, so an equal gen is a normal push.
#
# Asserts:
#   * newer-clobbers-older (NORMAL fast path): stick<mine -> push; stick>mine ->
#     standdown. The common case is a plain integer compare, no backup.
#   * corrupt gen -> verdict "corrupt" (NOT push); the push stands down (no backup).
#   * equal gen -> verdict "push" (our own steady state; NOT a distinct "tie" any more).
#   * absent gen (genuine first-ever use) -> verdict "push" (fresh), NOT "corrupt".
#   * the box-id machinery (box_mine/box_stick/box_write/.partyos-home-owner) stays REMOVED.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

# Copy the sync-common lib and the home-sync/home-pull/usb-reinsert scripts into the sandbox.
RFS="${REPO_ROOT}/scripts/build/files/rootfs"
[ -d "${RFS}" ] || { echo "FAIL: baked rootfs tree not found at ${RFS}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-gentest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- extract + source the COMMON heredoc body ---------------------------------
# It defines the REAL gen_read_status / gen_decide we test. The body's only top-level
# side effects are var assignments + a best-effort read of /run/partyos-username, all
# safe to source here. We override STATE_FILE after.
COMMON_BODY="${TMPDIR_T}/common.sh"
cp "${RFS}/usr/local/lib/partyos-sync-common.sh" "${COMMON_BODY}"
[ -s "${COMMON_BODY}" ] || { echo "FAIL: partyos-sync-common.sh baked file is empty"; exit 1; }
grep -q 'gen_read_status()'    "${COMMON_BODY}" || { echo "FAIL: gen_read_status missing from COMMON carve"; exit 1; }
grep -q 'gen_decide()'         "${COMMON_BODY}" || { echo "FAIL: gen_decide missing from COMMON carve"; exit 1; }
# the .partyos-conflict backup machinery was REMOVED - guard against a silent re-introduction:
grep -q 'gen_conflict_backup' "${COMMON_BODY}" && { echo "FAIL: gen_conflict_backup reappeared in COMMON (backup machinery must stay removed)"; exit 1; }
grep -q 'partyos-conflict'    "${COMMON_BODY}" && { echo "FAIL: .partyos-conflict reappeared in COMMON (backup machinery must stay removed)"; exit 1; }
# shellcheck disable=SC1090
source "${COMMON_BODY}"

# --- helpers -------------------------------------------------------------------
# put STR into a STATE_FILE and echo the "STATUS VALUE" gen_read_status returns.
read_status_for() {
    local content="$1" f
    f="${TMPDIR_T}/state.$$"
    if [ "${content}" = "__ABSENT__" ]; then rm -f "${f}"
    else printf '%s' "${content}" > "${f}"; fi
    STATE_FILE="${f}" gen_read_status "${f}"
}

echo "================ gen_read_status: absent vs ok vs corrupt ====="
assert_eq "$(read_status_for __ABSENT__)" "absent 0" "missing STATE_FILE -> absent 0 (fresh, NOT corrupt)"
assert_eq "$(read_status_for '')"         "absent 0" "empty STATE_FILE   -> absent 0 (fresh)"
assert_eq "$(read_status_for '7')"        "ok 7"     "plain integer      -> ok 7"
assert_eq "$(read_status_for $'12\n')"    "ok 12"    "trailing newline    -> ok 12"
assert_eq "$(read_status_for 'xx-not-a-number-yy')" "corrupt 0" "no-digit garbage -> corrupt 0 (NOT absent, NOT 0-as-ok)"

echo
echo "================ gen_decide: NORMAL fast path (newer/older/EQUAL) ==="
# my_gen=5. stick older (3) -> push; stick newer (9) -> standdown; EQUAL -> push (own steady state).
assert_eq "$(gen_decide 5 ok 3)" "push"      "stick gen 3 < mine 5 -> push (ours newer, FAST PATH)"
assert_eq "$(gen_decide 5 ok 9)" "standdown" "stick gen 9 > mine 5 -> standdown (same-user newer stick)"
assert_eq "$(gen_decide 0 ok 0)" "push"      "both 0 (equal) -> push (our own steady state, no 'tie' verdict)"
assert_eq "$(gen_decide 5 absent 0)" "push"  "absent stick gen (fresh) -> push (NOT corrupt)"

echo
echo "================ corrupt gen -> verdict 'corrupt' (no-clobber) ="
# corrupt stick gen -> stand down (do NOT push over it). The backup that used to run here was
# REMOVED; the stick is preserved simply by NOT pushing (--delete-delay + rc-gates are the safety).
assert_eq "$(gen_decide 5 corrupt 0)" "corrupt" "corrupt stick gen -> verdict 'corrupt' (NOT push - was the clobber bug)"

echo
echo "================ equal gen -> verdict 'push' (own steady state, no cross-box tie) ="
# With the username mount gate a mounted stick is always THIS box's own, so an equal gen is
# just our own last push re-mirrored -> a normal push. The old 'tie' verdict + per-boot box-id
# that split same-box from cross-box are gone (no shared-stick case to disambiguate).
assert_eq "$(gen_decide 4 ok 4)" "push" "equal gens (4==4) -> verdict 'push' (folds into normal push, was 'tie')"

echo
echo "################ USERNAME MOUNT GATE: stick_username + home_stick_gate ##########"
# The identity of a home stick is its PROVISIONED USERNAME (.partyos USERNAME=, the same key
# identity-setup reads for autologin/static-IP), NOT a per-boot box-id. stick_username parses
# it; home_stick_gate decides mount (own stick) / foreign (refuse) / blank (adoptable).
GATE_CFG="${TMPDIR_T}/dot-partyos"
printf 'HOSTNAME=rig1\nUSERNAME=alice\n# USERNAME=commented\n' > "${GATE_CFG}"
assert_eq "$(stick_username "${GATE_CFG}")" "alice" "stick_username reads USERNAME= from .partyos (ignores # comments)"
printf 'HOSTNAME=rig1\n' > "${GATE_CFG}"
assert_eq "$(stick_username "${GATE_CFG}")" "" "stick_username: no USERNAME= key -> empty (blank/unprovisioned)"
assert_eq "$(stick_username "${TMPDIR_T}/no-such-partyos")" "" "stick_username: absent .partyos -> empty"
printf '  USERNAME=  spacey  \n' > "${GATE_CFG}"
assert_eq "$(stick_username "${GATE_CFG}")" "spacey" "stick_username: surrounding whitespace stripped"

assert_eq "$(home_stick_gate alice alice)"  "mount"   "gate: stick user == login user -> mount (the box's own stick)"
assert_eq "$(home_stick_gate bob   alice)"  "foreign" "gate: DIFFERENT named user -> foreign (refuse, do not mount)"
assert_eq "$(home_stick_gate ''    alice)"  "blank"   "gate: blank/unprovisioned stick -> blank (adoptable, not refused)"
assert_eq "$(home_stick_gate gamer gamer)"  "mount"   "gate: default gamer stick on a gamer login -> mount"

echo
echo "########## SAME-BOX STEADY-STATE PUSH LOOP (carved partyos-sync-home) ##########"
# Everything above unit-tests the cross-box DECISION table in isolation. The push-side
# data-integrity bugs hid in the SAME-BOX steady-state loop that was never modeled: the
# every-45s push that captures the rsync rc, resolves the generation verdict, and bumps
# the counter. Carve the REAL partyos-sync-home heredoc and drive it against temp dirs
# with a stub rsync whose rc + effect we control (same extractive style as
# test-home-pull-gate), so the actual production push logic is exercised, not a re-impl.
SYNC_SH="${TMPDIR_T}/partyos-sync-home"
cp "${RFS}/usr/local/bin/partyos-sync-home" "${SYNC_SH}"
[ -s "${SYNC_SH}" ] || { echo "FAIL: partyos-sync-home baked file is empty"; exit 1; }
# guard against a silent revert of the push rc-gate:
grep -q 'PARTYOS-HOME-PUSH-INCOMPLETE' "${SYNC_SH}" || { echo "FAIL: push rc-gate (PARTYOS-HOME-PUSH-INCOMPLETE) missing from carved sync-home"; exit 1; }

# sandbox the sync script sources + writes into.
SBOX="${TMPDIR_T}/sync-box";      install -d "${SBOX}"
S_MNT="${SBOX}/mnt";              install -d "${S_MNT}"
S_HOME="${SBOX}/ram-home";        install -d "${S_HOME}"
S_USB="${S_MNT}/home";            install -d "${S_USB}"        # the "stick" (p2:/home)
S_PULL_DONE="${SBOX}/pull-done";  : > "${S_PULL_DONE}"         # push gate OPEN
S_STATE="${S_MNT}/.partyos-home-state"                          # stick generation
S_BASE="${SBOX}/gen.baseline"                                   # this box's baseline
S_INPROG="${S_MNT}/.partyos-home-pushing"                       # push-in-progress marker
S_PUSHMARK="${SBOX}/push.marker"                                # stub rsync logs pushes here
S_BOOTID="${SBOX}/boot_id"                                      # this boot's id (stub /proc)
S_SYNCLOG="${TMPDIR_T}/sync-calls.log"                          # stub sync logs its args here
MY_BOOT="0123abcd-4567-89ef-0123-456789abcdef"
OTHER_BOOT="fedcba98-7654-3210-fedc-ba9876543210"
echo "${MY_BOOT}" > "${S_BOOTID}"

# the stub common: REAL COMMON body (real gen_*/box_*/conflict helpers) with the
# mountpoints/flags re-pointed at the sandbox and is_rw forced true.
SYNC_COMMON="${TMPDIR_T}/sync-common.sh"
cp "${COMMON_BODY}" "${SYNC_COMMON}"
cat >> "${SYNC_COMMON}" <<EOF
MNT="${S_MNT}"
USB_HOME="${S_USB}"
HOME_DIR="${S_HOME}"
STATE_FILE="${S_STATE}"
GEN_FILE="${S_BASE}"
PULL_DONE="${S_PULL_DONE}"
PAUSE_FLAG="${SBOX}/pause.flag"
RO_FLAG="${SBOX}/ro.flag"
PUSH_INPROGRESS="${S_INPROG}"
PARTYOS_BOOT_ID_FILE="${S_BOOTID}"
UIDGID="\$(id -u)"
is_rw() { return 0; }
EOF
sed -i.bak "s#\. /usr/local/lib/partyos-sync-common.sh#. ${SYNC_COMMON}#" "${SYNC_SH}"

# PATH stubs the carved sync needs: a controllable rsync, plus mountpoint / date /
# timeout shims that work on a bare dev host.
SBIN="${TMPDIR_T}/sbin"; install -d "${SBIN}"
cat > "${SBIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${SBIN}/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
echo none
EOF
cat > "${SBIN}/timeout" <<'EOF'
#!/usr/bin/env bash
# HONOR the duration when a real bounding tool exists (the carved push wraps its chown -R in
# `timeout 20`); fall back to unbounded only if neither gtimeout nor a real timeout is present.
if command -v gtimeout >/dev/null 2>&1; then exec gtimeout "$@"; fi
[ -x /usr/bin/timeout ] && exec /usr/bin/timeout "$@"
shift; exec "$@"
EOF
# rsync stub. A real transfer (-a --delete[-delay] into the stick) records that it ran +
# honors STUB_RC: a COMPLETE push (rc 0/24) mirrors src->dst; an INTERRUPTED push (any other
# rc) leaves the destination UNTOUCHED - modelling --delete-delay's guarantee that no
# deletion lands before the transfer completes (no rsync-in-rsync, so the stub can't recurse).
# The .partyos-conflict backup machinery was removed, so there is no backup-copy branch here.
cat > "${SBIN}/rsync" <<EOF
#!/usr/bin/env bash
s="\${@: -2:1}"; s="\${s%/}"; d="\${@: -1}"; d="\${d%/}"
echo "PUSH rc=\${STUB_RC:-0} -> \${d}" >> "${S_PUSHMARK}"
if [ "\${STUB_RC:-0}" = 0 ] || [ "\${STUB_RC:-0}" = 24 ]; then
    find "\${d}" -mindepth 1 -delete 2>/dev/null || true    # --delete: clear dst extras
    [ -d "\${s}" ] && cp -R "\${s}/." "\${d}/" 2>/dev/null || true   # then copy src -> dst
fi
exit "\${STUB_RC:-0}"
EOF
# sync stub. It records its arguments (one line per call, "ARGC:ARGS"), so the test can
# prove that the push never runs a GLOBAL sync (a bare `sync` flushes every dirty page of
# the box and was the multi-minute stall behind the killed push). STUB_KILL_ON_DIRSYNC=1
# SIGKILLs the caller at the directory fsync that ends gen_write: that is the exact kill
# point of the deadlock (stick counter renamed into place, RAM counter not yet written).
cat > "${SBIN}/sync" <<EOF
#!/usr/bin/env bash
echo "\$#:\$*" >> "${S_SYNCLOG}"
if [ "\${STUB_KILL_ON_DIRSYNC:-0}" = 1 ] && [ \$# -eq 1 ] && [ -d "\$1" ]; then
    kill -KILL \$PPID
fi
exit 0
EOF
chmod +x "${SBIN}/mountpoint" "${SBIN}/systemd-detect-virt" "${SBIN}/timeout" "${SBIN}/rsync" "${SBIN}/sync"

# run the carved sync with a given push rc; returns its stdout in ${SYNC_OUT}.
SYNC_OUT="${TMPDIR_T}/sync.out"
run_sync() { STUB_RC="$1" PATH="${SBIN}:${PATH}" bash "${SYNC_SH}" >"${SYNC_OUT}" 2>&1; }
# reset the sandbox to a known steady state: stick gen ${1}, my baseline ${2}.
# Clears prior push markers + any stale .partyos-conflict dir.
seed_sync() {
    rm -rf "${S_USB}" "${S_HOME}" "${S_PUSHMARK}" "${S_INPROG}" "${S_MNT}/.partyos-conflict"
    install -d "${S_USB}" "${S_HOME}"
    printf 'stickfile\n' > "${S_USB}/onstick.dat"
    printf 'ramfile\n'   > "${S_HOME}/inram.dat"
    printf '%s' "$1" > "${S_STATE}"
    printf '%s' "$2" > "${S_BASE}"
}

echo
echo "================ (1) failed push does NOT advance the generation ="
# stick gen 3 < my baseline 5 -> verdict 'push' (fast path, no tie backup). A failed
# push must leave BOTH counters where they were and log PARTYOS-HOME-PUSH-INCOMPLETE.
seed_sync 3 5
run_sync 30    # rc 30 = rsync timeout/partial (NOT 0, NOT 24)
assert_eq "$(cat "${S_STATE}")" "3" "failed push (rc=30): stick generation UNCHANGED (not stamped newest)"
assert_eq "$(cat "${S_BASE}")"  "5" "failed push (rc=30): this box's baseline UNCHANGED"
assert_contains "$(cat "${SYNC_OUT}")" "PARTYOS-HOME-PUSH-INCOMPLETE" "failed push logs PARTYOS-HOME-PUSH-INCOMPLETE"

echo
echo "================ (1) successful push DOES advance the generation ="
seed_sync 3 5
run_sync 0
assert_eq "$(cat "${S_STATE}")" "6" "clean push (rc=0): stick generation advanced to my_gen+1 (6)"
assert_eq "$(cat "${S_BASE}")"  "6" "clean push (rc=0): baseline advanced in lockstep (6)"
assert_not_contains "$(cat "${SYNC_OUT}")" "PARTYOS-HOME-PUSH-INCOMPLETE" "clean push does NOT log the incomplete marker"

echo
echo "================ (1) rc=24 (vanished source files) still advances ="
seed_sync 3 5
run_sync 24
assert_eq "$(cat "${S_STATE}")" "6" "rc=24 push: benign vanished-files tolerated -> generation advances (6)"

echo
echo "########## EQUAL-GEN steady-state push (box-id + tie branch REMOVED) ##########"
# revert-guard: the per-boot box-id machinery MUST stay removed (the username mount gate
# replaces it), and the cross-box GEN-TIE branch with it:
grep -qE 'box_stick|box_mine|box_write' "${SYNC_SH}" && { echo "FAIL: box-id machinery reappeared in carved sync-home (must stay removed - username gate replaces it)"; exit 1; }
grep -q 'partyos-home-owner' "${SYNC_SH}" && { echo "FAIL: .partyos-home-owner reappeared in carved sync-home (box-id owner file must stay removed)"; exit 1; }
grep -q 'PARTYOS-SYNC-GEN-TIE' "${SYNC_SH}" && { echo "FAIL: cross-box GEN-TIE branch reappeared in carved sync-home (must stay removed)"; exit 1; }

echo
echo "================ (2) equal-gen tick -> normal push, generation advances ="
# stick gen 5 == my baseline 5 (the NORMAL state after our own last push). With the username
# mount gate the stick is always ours, so this is just our own next 45s tick -> a normal push
# (no box-id, no tie, no backup). The generation advances in lockstep.
seed_sync 5 5
run_sync 0
assert_false "$([ -d "${S_MNT}/.partyos-conflict" ]; echo $?)" "equal-gen push: NO .partyos-conflict backup taken"
assert_not_contains "$(cat "${SYNC_OUT}")" "PARTYOS-SYNC-GEN-TIE" "equal-gen push: no cross-box tie log (machinery removed)"
assert_eq "$(cat "${S_STATE}")" "6" "equal-gen push: generation advances (6)"
assert_eq "$(cat "${S_BASE}")"  "6" "equal-gen push: baseline advances in lockstep (6)"

echo
echo "########## SHUTDOWN-SIGKILL PROTECTION (--delete-delay + push marker) ##########"
# guard against a silent revert of the SIGKILL protection (--delete-delay + push marker):
grep -q -- '--delete-delay' "${SYNC_SH}" || { echo "FAIL: push does not use --delete-delay in carved sync-home"; exit 1; }

echo
echo "================ (3) interrupted push LEAVES marker + stick intact ="
# an interrupted push (rc not 0/24 - the SIGKILL/stall case) must NOT clear the marker,
# and --delete-delay means it deleted NOTHING from the stick yet (stub leaves dst intact).
seed_sync 3 5
usb_before="$(cd "${S_USB}" && find . -type f | sort)"
run_sync 30
assert_true  "$([ -e "${S_INPROG}" ]; echo $?)" "interrupted push (rc=30): push-in-progress marker LEFT on the stick"
assert_eq "$(cd "${S_USB}" && find . -type f | sort)" "${usb_before}" "interrupted push: stick file set UNTOUCHED (no premature delete)"
assert_true  "$([ -f "${S_USB}/onstick.dat" ]; echo $?)" "interrupted push: the stick file the push would mirror away is still present"

echo
echo "================ (3) completed push CLEARS the marker ==========="
seed_sync 3 5
run_sync 0
assert_false "$([ -e "${S_INPROG}" ]; echo $?)" "clean push (rc=0): push-in-progress marker cleared"

echo
echo "########## KILLED PUSH AFTER THE COUNTER WRITE ##########"
# The field fault: a push was killed after it wrote the
# stick counter (N+1) and before it wrote the RAM counter (N). Every later push then read the
# stick as "a newer home from another machine" and stood down for the rest of the boot.
grep -q 'gen_own_pending' "${SYNC_SH}" || { echo "FAIL: sync-home does not check for its own interrupted commit (gen_own_pending)"; exit 1; }
grep -q -- '--fsync' "${SYNC_SH}" || { echo "FAIL: the push rsync does not flush its files (--fsync) before the counter commit"; exit 1; }

echo
echo "================ (4) the real push, SIGKILLed right after the stick counter write ="
seed_sync 48 48
rm -f "${S_SYNCLOG}"
STUB_KILL_ON_DIRSYNC=1 run_sync 0
assert_eq "$(cat "${S_STATE}")" "49" "killed push: the stick counter was written (49), as seen on real hardware"
assert_eq "$(cat "${S_BASE}")"  "48" "killed push: the RAM counter is still 48 (the kill came first)"
assert_true "$([ -e "${S_INPROG}" ]; echo $?)" "killed push: the push-in-progress marker is left on the stick"
assert_eq "$(cat "${S_INPROG}")" "${MY_BOOT} 49" "killed push: the marker names this boot and the pending generation 49"
assert_false "$([ -e "${S_STATE}.new" ]; echo $?)" "killed push: no temp counter file is left (atomic rename)"
assert_true "$([ -f "${S_USB}/inram.dat" ]; echo $?)" "killed push: the rsync had completed (the RAM file is on the stick)"

echo
echo "================ (4) the next push RECOVERS (no stand-down) ="
printf 'new-save\n' > "${S_HOME}/after-kill.sav"   # a change made after the killed push
run_sync 0
assert_contains "$(cat "${SYNC_OUT}")" "PARTYOS-HOME-PUSH-RESUME" "recovery: logs PARTYOS-HOME-PUSH-RESUME (own interrupted push recognised)"
assert_not_contains "$(cat "${SYNC_OUT}")" "standing down" "recovery: does NOT stand down"
assert_eq "$(cat "${S_STATE}")" "50" "recovery: stick generation advances to 50"
assert_eq "$(cat "${S_BASE}")"  "50" "recovery: RAM generation advances to 50 (counters converge)"
assert_false "$([ -e "${S_INPROG}" ]; echo $?)" "recovery: push-in-progress marker cleared"
assert_true "$([ -f "${S_USB}/after-kill.sav" ]; echo $?)" "recovery: the change made after the kill reaches the stick"
run_sync 0
assert_eq "$(cat "${S_STATE}")" "51" "recovery: the following tick is a normal push again (51)"
assert_not_contains "$(cat "${SYNC_OUT}")" "PARTYOS-HOME-PUSH-RESUME" "recovery: the following tick needs no resume"

echo
echo "================ (4) the exact field state (stick 49, RAM 48, own marker) recovers ="
# The state found on real hardware, seeded directly: this does not depend on the kill point.
seed_sync 49 48
printf '%s 49\n' "${MY_BOOT}" > "${S_INPROG}"
run_sync 0
assert_not_contains "$(cat "${SYNC_OUT}")" "standing down" "field state: does NOT stand down"
assert_eq "$(cat "${S_STATE}")" "50" "field state: stick generation advances to 50"
assert_eq "$(cat "${S_BASE}")"  "50" "field state: RAM generation advances to 50"
assert_true "$([ -f "${S_USB}/inram.dat" ]; echo $?)" "field state: the RAM home reaches the stick"
assert_false "$([ -e "${S_INPROG}" ]; echo $?)" "field state: marker cleared"

echo
echo "================ (4) cross-machine protection is KEPT ="
# stick one ahead, marker from ANOTHER boot (another rig pushed and was interrupted) -> not ours.
seed_sync 49 48
printf '%s 49\n' "${OTHER_BOOT}" > "${S_INPROG}"
run_sync 0
assert_contains "$(cat "${SYNC_OUT}")" "standing down" "stick ahead + marker of ANOTHER boot -> standdown"
assert_eq "$(cat "${S_STATE}")" "49" "other-boot marker: stick generation untouched"
assert_eq "$(cat "${S_BASE}")"  "48" "other-boot marker: RAM generation untouched"
assert_false "$([ -e "${S_PUSHMARK}" ]; echo $?)" "other-boot marker: no push ran"
assert_true "$([ -f "${S_USB}/onstick.dat" ]; echo $?)" "other-boot marker: the newer stick home is left intact"
# stick newer, no marker (the other rig completed its push) -> standdown.
seed_sync 49 48
run_sync 0
assert_contains "$(cat "${SYNC_OUT}")" "standing down" "stick ahead + no marker -> standdown (newer home from another rig)"
assert_false "$([ -e "${S_PUSHMARK}" ]; echo $?)" "no marker: no push ran"
# own boot, but the marker names another generation -> not provably ours -> standdown.
seed_sync 50 48
printf '%s 49\n' "${MY_BOOT}" > "${S_INPROG}"
run_sync 0
assert_contains "$(cat "${SYNC_OUT}")" "standing down" "own-boot marker for a DIFFERENT generation -> standdown"
# legacy empty marker (written by the old image) -> no owner -> standdown.
seed_sync 49 48
: > "${S_INPROG}"
run_sync 0
assert_contains "$(cat "${SYNC_OUT}")" "standing down" "legacy empty marker -> standdown (owner unknown)"
# no boot id readable -> never claim ownership.
seed_sync 49 48
printf '%s 49\n' "${MY_BOOT}" > "${S_INPROG}"
mv "${S_BOOTID}" "${S_BOOTID}.off"
run_sync 0
mv "${S_BOOTID}.off" "${S_BOOTID}"
assert_contains "$(cat "${SYNC_OUT}")" "standing down" "boot id unreadable -> standdown (no ownership claim)"

echo
echo "================ (4) a push killed MID-rsync is redone by the next tick ="
seed_sync 48 48
run_sync 30                     # the stall / SIGTERM mid-transfer: rc not 0/24
assert_eq "$(cat "${S_STATE}")" "48" "mid-rsync kill: stick counter NOT advanced"
assert_eq "$(cat "${S_INPROG}")" "${MY_BOOT} 49" "mid-rsync kill: marker names this boot and the pending generation"
run_sync 0
assert_eq "$(cat "${S_STATE}")" "49" "next tick: the push completes (equal generations push again)"
assert_eq "$(cat "${S_BASE}")"  "49" "next tick: counters converge"
assert_false "$([ -e "${S_INPROG}" ]; echo $?)" "next tick: marker cleared"

echo
echo "================ (4) the push runs NO global sync ="
# Every sync call in the push must name a file or directory. A bare `sync` waits for every
# dirty page of the box (game downloads on the same stick) - the multi-minute stall.
seed_sync 5 5
rm -f "${S_SYNCLOG}"
run_sync 0
assert_true "$([ -s "${S_SYNCLOG}" ]; echo $?)" "the push flushes its marker and counter (sync called with a path)"
assert_false "$(grep -q '^0:' "${S_SYNCLOG}"; echo $?)" "the push never calls a bare (global) sync"
assert_false "$(grep -qE '^[[:space:]]*sync[[:space:]]*(2>|;|$)' "${SYNC_SH}"; echo $?)" "sync-home source holds no bare sync line"
assert_false "$([ -e "${S_STATE}.new" ]; echo $?)" "clean push: no temp counter file left"

echo
echo "================ (4) the push unit is not killed mid-write ="
SVC="${RFS}/etc/systemd/system/partyos-home-sync.service"
svc_to="$(sed -n 's/^TimeoutStartSec=\([0-9]*\)min$/\1/p' "${SVC}")"
assert_true "$([ -n "${svc_to}" ] && [ "${svc_to}" -ge 15 ]; echo $?)" "partyos-home-sync.service TimeoutStartSec >= 15min (was 90s: killed slow pushes)"

echo
echo "########## boot PULL treats a marked (suspect) stick defensively (carved pull) ##########"
PULL_SH="${TMPDIR_T}/partyos-home-pull"
cp "${RFS}/usr/local/bin/partyos-home-pull" "${PULL_SH}"
[ -s "${PULL_SH}" ] || { echo "FAIL: partyos-home-pull baked file is empty"; exit 1; }
grep -q 'PARTYOS-HOME-PUSH-INPROGRESS' "${PULL_SH}" || { echo "FAIL: pull-side suspect guard (PARTYOS-HOME-PUSH-INPROGRESS) missing from carved pull"; exit 1; }
# the boot pull MIRROR must defer deletions (--delete-delay), so a SIGTERM at the unit's
# TimeoutStartSec leaves the RAM home un-gutted. Guard against a revert to delete-during:
grep -qE 'rsync -a --delete-delay --timeout' "${PULL_SH}" || { echo "FAIL: boot pull mirror is not '--delete-delay' (revert to delete-during would gut a half-pulled RAM home)"; exit 1; }

PBOX="${TMPDIR_T}/pull-box"; install -d "${PBOX}"
P_MNT="${PBOX}/mnt";        install -d "${P_MNT}"
P_HOME="${PBOX}/ram-home"
P_USB="${P_MNT}/home"
P_SKEL="${PBOX}/skel-absent"                 # deliberately absent -> seed/re-assert skipped
P_STATE="${P_MNT}/.partyos-home-state"
P_BASE="${PBOX}/gen.baseline"
P_INPROG="${P_MNT}/.partyos-home-pushing"
P_PULLDONE="${PBOX}/pull-done"

PULL_COMMON="${TMPDIR_T}/pull-common.sh"
cp "${COMMON_BODY}" "${PULL_COMMON}"
cat >> "${PULL_COMMON}" <<EOF
MNT="${P_MNT}"
USB_HOME="${P_USB}"
HOME_DIR="${P_HOME}"
SKEL="${P_SKEL}"
STATE_FILE="${P_STATE}"
GEN_FILE="${P_BASE}"
PULL_DONE="${P_PULLDONE}"
PULL_RAN="${PBOX}/pull-ran"
RO_FLAG="${PBOX}/ro"
PUSH_INPROGRESS="${P_INPROG}"
UIDGID="\$(id -u)"
is_rw() { return 0; }
EOF
sed -i.bak "s#\. /usr/local/lib/partyos-sync-common.sh#. ${PULL_COMMON}#" "${PULL_SH}"
PULL_OUT="${TMPDIR_T}/pull.out"
run_pull() { STUB_RC="${1:-0}" PATH="${SBIN}:${PATH}" bash "${PULL_SH}" >"${PULL_OUT}" 2>&1; }
seed_pull() {   # reset the pull sandbox: stick gen 7 + one save file; ${1}=drop marker?
    rm -rf "${P_USB}" "${P_HOME}" "${P_MNT}/.partyos-conflict" "${P_PULLDONE}"
    install -d "${P_USB}" "${P_HOME}"
    printf 'savedata\n' > "${P_USB}/save.dat"
    printf '7' > "${P_STATE}"
    if [ "${1:-0}" = 1 ]; then : > "${P_INPROG}"; else rm -f "${P_INPROG}"; fi
}

echo
echo "================ (3) marked stick -> pull LOGS + proceeds, NO backup ="
# The suspect-backup was REMOVED: with --delete-delay the pull is already non-destructive on
# a marked stick, so the boot pull now just logs the breadcrumb and pulls (no .partyos-conflict).
seed_pull 1
run_pull 0
assert_false "$(ls -d "${P_MNT}/.partyos-conflict/stick-suspect-"* >/dev/null 2>&1; echo $?)" "suspect pull: NO .partyos-conflict/stick-suspect backup taken (backup mechanism removed)"
assert_contains "$(cat "${PULL_OUT}")" "PARTYOS-HOME-PUSH-INPROGRESS" "suspect pull logs the PARTYOS-HOME-PUSH-INPROGRESS breadcrumb"
assert_true  "$([ -e "${P_PULLDONE}" ]; echo $?)" "suspect pull still completes (--delete-delay pull is safe on a marked stick)"

echo
echo "================ (3) unmarked stick -> pull trusts it (no backup) ="
seed_pull 0
run_pull 0
assert_false "$(ls -d "${P_MNT}/.partyos-conflict/stick-suspect-"* >/dev/null 2>&1; echo $?)" "clean stick (no marker): NO suspect backup taken"
assert_not_contains "$(cat "${PULL_OUT}")" "PARTYOS-HOME-PUSH-INPROGRESS" "clean stick pull does not log the suspect marker"

echo
echo "########## boot PULL is fail-safe under a SIGTERM (--delete-delay defers deletes) ##########"
# The stub models --delete-delay: an interrupted transfer (rc not 0/24) leaves the
# DESTINATION untouched (no deletion landed); a clean one (rc 0) find-deletes extras
# then copies. Prove the boot pull never guts a half-pulled RAM home on a timeout.
echo
echo "================ (1) SIGTERMed pull leaves the RAM home un-gutted ="
seed_pull 0
printf 'ram-only\n' > "${P_HOME}/ram-only.dat"   # a RAM-home file the stick lacks
run_pull 30                                        # rc=30 = the TimeoutStartSec SIGTERM / stall
assert_true  "$([ -f "${P_HOME}/ram-only.dat" ]; echo $?)" "SIGTERMed pull (rc=30): pre-existing RAM file NOT prematurely deleted (delete-delay deferred it)"
assert_false "$([ -e "${P_PULLDONE}" ]; echo $?)" "SIGTERMed pull: push gate stays CLOSED (rc-gate holds)"
echo
echo "================ (1) clean pull completes the mirror + opens gate ="
seed_pull 0
run_pull 0
assert_true  "$([ -f "${P_HOME}/save.dat" ]; echo $?)" "clean pull (rc=0): stick home mirrored into RAM"
assert_true  "$([ -e "${P_PULLDONE}" ]; echo $?)" "clean pull: push gate opens normally"

echo
echo "########## is_rw: PRECISE ro-detection (findmnt OPTIONS, not a mount|grep) ##########"
# The real is_rw lives in the COMMON body sourced at the top. Drive it with a mocked
# findmnt whose OPTIONS we control, proving the benign `errors=remount-ro` FS option
# reads as rw and only a genuine standalone `ro` VFS field reads as ro (the old
# `mount | grep -qw ro` false-matched errors=remount-ro and disabled a HEALTHY stick).
grep -q 'findmnt -rno OPTIONS' "${COMMON_BODY}" || { echo "FAIL: is_rw no longer uses findmnt OPTIONS (precise ro test reverted?)"; exit 1; }
FMBIN="${TMPDIR_T}/fmbin"; install -d "${FMBIN}"
cat > "${FMBIN}/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FINDMNT_OPTS:-}"   # ignore args; echo the simulated mount options
EOF
chmod +x "${FMBIN}/findmnt"
# probe_rw OPTS -> is_rw's rc (0 = rw, 1 = ro) using the mocked findmnt.
probe_rw() ( export FINDMNT_OPTS="$1"; PATH="${FMBIN}:${PATH}"; MNT="/dummy"; is_rw; )

probe_rw 'rw,noatime,errors=remount-ro'; assert_true  $? "errors=remount-ro on an rw mount -> is_rw TRUE (benign FS option, NOT ro)"
probe_rw 'rw,relatime';                  assert_true  $? "plain rw mount -> is_rw TRUE"
probe_rw 'ro,noatime';                   assert_false $? "genuine ro mount -> is_rw FALSE"
probe_rw 'ro,relatime,errors=remount-ro'; assert_false $? "real ro mount that ALSO carries errors=remount-ro -> is_rw FALSE (ro field wins)"
probe_rw '';                             assert_true  $? "empty options (not mounted / findmnt absent) -> is_rw TRUE (probe failure never wedges sync off)"

echo
echo "########## REINSERT resume: carve the generation-guard/resume TAIL (real logic) ##########"
# The mount/udev/block-device PREAMBLE of partyos-usb-reinserted needs a real labelled
# block device (untestable hardware-free), so carve the generation-guard-through-resume
# TAIL - the REAL decision + resume code - and drive it with mounted=1, a controllable
# is_rw and the same stubbed rsync. Same extractive style as the SYNC/PULL carves above.
REINS_FULL="${TMPDIR_T}/reins-full.sh"
REINS_SH="${TMPDIR_T}/reins-tail.sh"
cp "${RFS}/usr/local/bin/partyos-usb-reinserted" "${REINS_FULL}"
[ -s "${REINS_FULL}" ] || { echo "FAIL: partyos-usb-reinserted baked file is empty"; exit 1; }
awk '/^resumed_pulled=0$/{g=1} g' "${REINS_FULL}" > "${REINS_SH}"
[ -s "${REINS_SH}" ] || { echo "FAIL: could not carve reinsert generation-guard/resume tail"; exit 1; }
# guard against a silent revert of the RO_FLAG clear:
grep -q 'clearing stale RO_FLAG' "${REINS_SH}" || { echo "FAIL: RO_FLAG-clear missing from carved reinsert resume"; exit 1; }
# USERNAME MOUNT GATE wiring lives in the reinsert PREAMBLE (before the carved tail) - it needs
# a real block device, so it is untestable hardware-free; static-guard its presence instead:
grep -q 'PARTYOS-HOME-FOREIGN-STICK' "${REINS_FULL}" || { echo "FAIL: username mount gate refusal (PARTYOS-HOME-FOREIGN-STICK) missing from the reinsert handler"; exit 1; }
grep -q 'home_stick_gate' "${REINS_FULL}"            || { echo "FAIL: reinsert handler does not call home_stick_gate (username mount gate wiring missing)"; exit 1; }
grep -q 'LOGIN_RESOLVED'  "${REINS_FULL}"            || { echo "FAIL: reinsert mount gate not gated on LOGIN_RESOLVED (would refuse the box's OWN stick at pre-identity coldplug)"; exit 1; }

RBOX="${TMPDIR_T}/reins-box"; install -d "${RBOX}"
R_MNT="${RBOX}/mnt";   install -d "${R_MNT}"
R_HOME="${RBOX}/ram-home"
R_USB="${R_MNT}/home"
R_STATE="${R_MNT}/.partyos-home-state"
R_BASE="${RBOX}/gen.baseline"
R_PAUSE="${RBOX}/pause.flag"
R_RO="${RBOX}/ro.flag"
R_PULLRAN="${RBOX}/pull-ran"          # boot pull FINISHED (post-boot state; the coldplug
                                     # DEFER gate lets the gen-guard pull run only then)
R_PULLINPROG="${RBOX}/pull-inprogress"
R_PUSHMARK="${RBOX}/resume-push.marker"
R_NOTIFY="${RBOX}/notify.log"
R_OUT="${TMPDIR_T}/reins.out"

# common the fragment sources: REAL COMMON helpers repointed at the sandbox.
REINS_COMMON="${TMPDIR_T}/reins-common.sh"
cp "${COMMON_BODY}" "${REINS_COMMON}"
cat >> "${REINS_COMMON}" <<EOF
MNT="${R_MNT}"
USB_HOME="${R_USB}"
HOME_DIR="${R_HOME}"
STATE_FILE="${R_STATE}"
GEN_FILE="${R_BASE}"
PAUSE_FLAG="${R_PAUSE}"
RO_FLAG="${R_RO}"
PULL_RAN="${R_PULLRAN}"
PULL_INPROGRESS="${R_PULLINPROG}"
PUSH_INPROGRESS="${R_MNT}/.partyos-home-pushing"
PARTYOS_BOOT_ID_FILE="${S_BOOTID}"
UIDGID="\$(id -u)"
EOF

# absolute-path helpers the resume block calls -> point at sandbox stubs (the suites
# sed-swap the common source line the same way). partyos-sync-home = the resume
# "delete-push"; if it runs it appends RESUME-PUSH-RAN (our "delete-push opened" signal).
RSTUB="${TMPDIR_T}/reins-stub"; install -d "${RSTUB}"
cat > "${RSTUB}/partyos-sync-home" <<EOF
#!/usr/bin/env bash
echo "RESUME-PUSH-RAN" >> "${R_PUSHMARK}"
EOF
cat > "${RSTUB}/partyos-usb-notify" <<EOF
#!/usr/bin/env bash
echo "NOTIFY \$*" >> "${R_NOTIFY}"
EOF
chmod +x "${RSTUB}/partyos-sync-home" "${RSTUB}/partyos-usb-notify"
sed -i.bak \
    -e "s#/usr/local/bin/partyos-sync-home#${RSTUB}/partyos-sync-home#g" \
    -e "s#/usr/local/bin/partyos-usb-notify#${RSTUB}/partyos-usb-notify#g" \
    "${REINS_SH}"
# systemctl stub (SBIN already carries rsync/mountpoint/systemd-detect-virt/timeout).
cat > "${SBIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${SBIN}/systemctl"

# seed the reinsert sandbox. $1 stick_gen $2 my_baseline $3 ro_present
seed_reins() {
    rm -rf "${R_USB}" "${R_HOME}" "${R_PUSHMARK}" "${R_NOTIFY}" "${R_MNT}/.partyos-conflict" "${RBOX}/.partyos-conflict"
    install -d "${R_USB}" "${R_HOME}"
    printf 'stickcontent\n' > "${R_USB}/save.dat"
    printf 'ramcontent\n'   > "${R_HOME}/ram.dat"   # differs from stick -> an equal gen sees a diff
    printf '%s' "$1" > "${R_STATE}"
    printf '%s' "$2" > "${R_BASE}"
    : > "${R_PAUSE}"    # the removal handler set the pause flag (normal pre-reinsert state)
    : > "${R_PULLRAN}"  # boot pull already ran (post-boot reinsert); clears the coldplug DEFER
    rm -f "${R_PULLINPROG}" "${R_MNT}/.partyos-home-pushing"
    [ "${3:-0}" = 1 ] && : > "${R_RO}" || rm -f "${R_RO}"
}
# run the carved reinsert tail: $1 stub rsync rc, $2 is_rw (1 rw / 0 ro). stdout -> R_OUT.
run_reins() {
    STUB_RC="$1" REINS_IS_RW="$2" PATH="${SBIN}:${PATH}" bash -c '
        set -u
        say() { echo "$*"; }
        . "'"${REINS_COMMON}"'"
        is_rw() { [ "${REINS_IS_RW:-1}" = 1 ]; }
        mounted=1
        . "'"${REINS_SH}"'"
    ' >"${R_OUT}" 2>&1
}

echo
echo "================ (1) stale RO_FLAG cleared on a clean rw remount ="
seed_reins 3 5 1     # stick gen 3 < baseline 5 -> verdict push; RO_FLAG stale-present
run_reins 0 1              # clean rw remount
assert_false "$([ -e "${R_RO}" ]; echo $?)" "clean rw remount: stale RO_FLAG CLEARED (persistence re-enabled)"
assert_false "$([ -e "${R_PAUSE}" ]; echo $?)" "clean rw remount: pause flag cleared (sync resumed)"
assert_contains "$(cat "${R_OUT}")" "clearing stale RO_FLAG" "the RO_FLAG clear is logged"

echo
echo "================ (1) RO_FLAG KEPT when the remount is still read-only ="
seed_reins 3 5 1     # RO_FLAG present
run_reins 0 0              # remount still ro (is_rw false)
assert_true "$([ -e "${R_RO}" ]; echo $?)" "still-ro remount: RO_FLAG NOT cleared (persistence stays disabled)"

echo
echo "########## REINSERT PULL rc-gate (a failed same-user-newer pull must NOT advance) ##########"
# guard against a silent revert of the reinsert rc-gate:
grep -q 'PARTYOS-USB-REINSERT-PULL-INCOMPLETE' "${REINS_SH}" || { echo "FAIL: reinsert pull rc-gate marker (PARTYOS-USB-REINSERT-PULL-INCOMPLETE) missing from carved tail"; exit 1; }
# the newer-stick reinsert pull must use --delete-delay (not plain --delete): with the
# ram-tie backup gone this is the sole safety, so an interrupted pull leaves RAM un-gutted.
grep -qE 'rsync -a --delete-delay --timeout' "${REINS_SH}" || { echo "FAIL: reinsert newer-stick pull is not '--delete-delay' (a SIGTERM mid-pull could gut the RAM home)"; exit 1; }
grep -qE 'rsync -a --delete --timeout' "${REINS_SH}" && { echo "FAIL: reinsert tail still uses a plain '--delete' pull (should be --delete-delay)"; exit 1; }
# revert-guard: the cross-box tie branch must stay REMOVED from the reinsert tail too:
grep -q 'PARTYOS-SYNC-GEN-TIE' "${REINS_SH}" && { echo "FAIL: the cross-box GEN-TIE branch reappeared in the reinsert tail (must stay removed)"; exit 1; }
# revert-guard: the synchronous resume-push must be gated on was_paused (a genuine removal), so
# a normal boot of the box's OWN stick does NO synchronous re-push (the degraded-boot fix):
grep -q 'was_paused' "${REINS_SH}" || { echo "FAIL: resume-push not gated on was_paused (a normal boot would re-push synchronously -> degraded boot)"; exit 1; }

echo
echo "================ (2) same-user-newer pull FAILS -> no adopt, no delete-push ="
# stick gen 9 > baseline 5 -> standdown/PULL. A mid-copy failure (rc=30) must leave the
# baseline where it was, leave the pause set (sync stays paused), NOT run the resume-push
# (delete-push), and log the incomplete marker.
seed_reins 9 5
run_reins 30 1
assert_eq "$(cat "${R_BASE}")" "5" "failed newer-pull (rc=30): baseline UNCHANGED (stick generation NOT adopted)"
assert_false "$([ -e "${R_PUSHMARK}" ]; echo $?)" "failed newer-pull: resume-push (delete-push) did NOT run"
assert_true  "$([ -e "${R_PAUSE}" ]; echo $?)"    "failed newer-pull: pause flag LEFT set (sync stays paused)"
assert_contains "$(cat "${R_OUT}")" "PARTYOS-USB-REINSERT-PULL-INCOMPLETE" "failed newer-pull logs PARTYOS-USB-REINSERT-PULL-INCOMPLETE"

echo
echo "================ (2) same-user-newer pull SUCCEEDS -> adopts + resumes ="
# same setup, clean pull (rc=0): baseline adopts the stick gen (9), pause clears, and the
# resume-push is skipped BECAUSE we just pulled a newer home (resumed_pulled=1).
seed_reins 9 5
run_reins 0 1
assert_eq "$(cat "${R_BASE}")" "9" "clean newer-pull (rc=0): baseline ADOPTS the stick generation (9)"
assert_false "$([ -e "${R_PAUSE}" ]; echo $?)" "clean newer-pull: pause cleared (sync resumed)"
assert_true  "$([ -f "${R_HOME}/save.dat" ]; echo $?)" "clean newer-pull: the stick's home was pulled into RAM"

echo
echo "================ (4) reinsert after this boot's own killed push -> NO pull, push again ="
# The stick is one ahead of RAM because THIS boot's push was killed after the counter write
# (then the stick was pulled out). Pulling it would throw away every RAM change made since.
seed_reins 49 48
printf '%s 49\n' "${MY_BOOT}" > "${R_MNT}/.partyos-home-pushing"
run_reins 0 1
assert_contains "$(cat "${R_OUT}")" "PARTYOS-HOME-PUSH-RESUME" "own killed push on reinsert: logs PARTYOS-HOME-PUSH-RESUME"
assert_not_contains "$(cat "${R_OUT}")" "PULLING" "own killed push on reinsert: the stick is NOT pulled over RAM"
assert_true "$([ -f "${R_HOME}/ram.dat" ] && ! [ -f "${R_HOME}/save.dat" ]; echo $?)" "own killed push on reinsert: the RAM home is unchanged"
assert_eq "$(cat "${R_BASE}")" "49" "own killed push on reinsert: RAM generation adopts the stick's (49)"
assert_true "$([ -e "${R_PUSHMARK}" ]; echo $?)" "own killed push on reinsert: the resume-push runs"

echo
echo "================ (4) reinsert, stick ahead with ANOTHER boot's marker -> pull (kept) ="
seed_reins 49 48
printf '%s 49\n' "${OTHER_BOOT}" > "${R_MNT}/.partyos-home-pushing"
run_reins 0 1
assert_contains "$(cat "${R_OUT}")" "PULLING" "other boot's marker on reinsert: the newer stick is pulled (cross-machine kept)"
assert_eq "$(cat "${R_BASE}")" "49" "other boot's marker on reinsert: baseline adopts after the pull"
assert_false "$([ -e "${R_PUSHMARK}" ]; echo $?)" "other boot's marker on reinsert: no push over the newer stick"

echo
echo "================ (2) equal-gen reinsert -> NO pull, resume-push runs (no cross-box tie) ="
# equal gen 5==5: with the username mount gate the stick is always ours, so an equal gen is
# just our own steady state (verdict push, no 'tie'). The reinsert does NOT pull; it falls
# through to the resume-push (normal RAM -> stick flush). No pull attempted, pause cleared.
seed_reins 5 5
run_reins 0 1
assert_eq "$(cat "${R_BASE}")" "5" "equal-gen reinsert: baseline UNCHANGED (5)"
assert_true  "$([ -e "${R_PUSHMARK}" ]; echo $?)" "equal-gen reinsert: resume-push DID run (normal flush)"
assert_false "$([ -e "${R_PAUSE}" ]; echo $?)"    "equal-gen reinsert: pause cleared (sync resumed)"
assert_not_contains "$(cat "${R_OUT}")" "PARTYOS-USB-REINSERT-PULL-INCOMPLETE" "equal-gen reinsert: no pull attempted -> no PULL-INCOMPLETE"

echo
echo "================ (2) GENUINE reinsert (PAUSE set) -> resume-push flushes ="
# stick gen 3 < baseline 5 -> verdict push: no pull, resumed_pulled=0. A REMOVAL set PAUSE
# (seed_reins does), so was_paused=1 -> the resume-push (delete-push) DOES run to flush any RAM
# divergence that happened while the stick was out (the normal 'good pull proceeds' resume path).
seed_reins 3 5
run_reins 0 1
assert_true  "$([ -e "${R_PUSHMARK}" ]; echo $?)" "genuine reinsert: resume-push DID run (flushes our home)"
assert_false "$([ -e "${R_PAUSE}" ]; echo $?)" "genuine reinsert: pause cleared"

echo
echo "########## OWN-STICK NORMAL BOOT: no PAUSE -> NO synchronous re-push (degraded-boot fix) ##########"
echo
echo "================ (3) coldplug/poll-kick (no prior removal) -> resume-push SKIPPED ="
# The degraded-boot cause: a boot coldplug / poll-kick reinsert of the box's OWN stick where the
# stick was NEVER removed (PAUSE absent -> was_paused=0). The boot pull already synced this same
# stick and the 45s timer owns steady state, so the reinsert must NOT run a synchronous RAM ->
# slow-stick re-push inside its TimeoutStartSec. verdict push (older/equal), resumed_pulled=0,
# but was_paused=0 -> the resume-push is SKIPPED (no re-push), and the timer still (re)starts.
seed_reins 3 5
rm -f "${R_PAUSE}"          # no removal preceded this reinsert (coldplug / poll-kick)
run_reins 0 1
assert_false "$([ -e "${R_PUSHMARK}" ]; echo $?)" "own-stick normal boot (no PAUSE): resume-push SKIPPED (no synchronous re-push -> no degraded boot)"
assert_contains "$(cat "${R_OUT}")" "PARTYOS-USB-SYNC-RESUMED" "own-stick normal boot: sync still RESUMED (timer restarted) even though no re-push ran"

# equal-gen own-stick normal boot: same skip (an equal gen is our own steady state, no pull).
seed_reins 5 5
rm -f "${R_PAUSE}"
run_reins 0 1
assert_false "$([ -e "${R_PUSHMARK}" ]; echo $?)" "own-stick normal boot, equal gen: resume-push SKIPPED (no re-push)"

assert_summary "test-gen-guard" || exit 1
echo "test-gen-guard: ALL PASS"
