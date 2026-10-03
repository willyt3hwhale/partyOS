#!/usr/bin/env bash
# test-lock-policy.sh - hardware-free test for the screen-lock policy:
#
#   No password -> no lock.
#   A passwordless provisioned user (party kiosk) must NEVER get a screen lock: there
#   is no password to unlock with, so locking would strand them. But the screen must
#   STILL power-save (blank / DPMS-sleep) - it may not stay stuck-on. A user who DID
#   set a password keeps the idle auto-lock + the manual Win95 locker.
#
# This COPIES the two real baked files from scripts/build/files/rootfs/usr/local/bin/ -
# partyos-lock-setup (PLS, the per-session screensaver/lock arming) and partyos-lock
# (PLK, the manual lock supervisor) - rewrites their absolute /mnt + /usr/local paths at temp locations,
# and DRIVES them under stubbed X tooling (xset / xss-lock / pgrep / ...). It then asserts:
#   * passwordless: xss-lock is NEVER armed (no idle auto-lock) and the manual lock only
#     shows the saver - but DPMS is armed regardless, so the screen still power-saves;
#   * passworded:   xss-lock IS armed and the manual lock reaches the real locker.
# No VM, no network, no hardware - same extractive style as test-home-pull-gate.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

# Copy partyos-lock-setup (PLS) and partyos-lock (PLK) into the sandbox.
# The test rewrites their absolute paths in place.
RFS="${REPO_ROOT}/scripts/build/files/rootfs"
[ -d "${RFS}" ] || { echo "FAIL: baked rootfs tree not found at ${RFS}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-lockpolicy.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- carve the two baked scripts out of their heredocs -------------------------
PLS_SH="${TMPDIR_T}/partyos-lock-setup"
PLK_SH="${TMPDIR_T}/partyos-lock"
cp "${RFS}/usr/local/bin/partyos-lock-setup" "${PLS_SH}"
cp "${RFS}/usr/local/bin/partyos-lock" "${PLK_SH}"
[ -s "${PLS_SH}" ] || { echo "FAIL: partyos-lock-setup baked file is empty"; exit 1; }
[ -s "${PLK_SH}" ] || { echo "FAIL: partyos-lock baked file is empty"; exit 1; }

# the DPMS-power-save fix must be present in the carved source (guard against a silent
# revert that would leave a passwordless kiosk stuck-on with no blank).
grep -q 'xset +dpms'  "${PLS_SH}" || { echo "FAIL: 'xset +dpms' (DPMS enable) missing from carved partyos-lock-setup"; exit 1; }
grep -q 'xset dpms'   "${PLS_SH}" || { echo "FAIL: 'xset dpms <timers>' missing from carved partyos-lock-setup"; exit 1; }
# and the passwordless auto-lock gate must still be the password file (never force-armed).
grep -q '\[ -s /mnt/usbhome/.partyos-passwd \]' "${PLS_SH}" \
  || { echo "FAIL: passwordless xss-lock gate ([ -s .../.partyos-passwd ]) missing from carved partyos-lock-setup"; exit 1; }

# --- rewrite the absolute paths the scripts touch to temp locations -------------
PWF="${TMPDIR_T}/partyos-passwd"          # stands in for /mnt/usbhome/.partyos-passwd
STUB_LOCKER="${TMPDIR_T}/locker-stub"     # stands in for /usr/local/bin/partyos-lock-screen
sed -i.bak "s#/mnt/usbhome/.partyos-passwd#${PWF}#g" "${PLS_SH}" "${PLK_SH}"
sed -i.bak "s#/usr/local/bin/partyos-lock-screen#${STUB_LOCKER}#g" "${PLK_SH}"

# --- stub the X tooling on PATH ------------------------------------------------
BIN="${TMPDIR_T}/bin"; install -d "${BIN}"
XSET_LOG="${TMPDIR_T}/xset.log"
XSSLOCK_ARMED="${TMPDIR_T}/xss-lock.armed"
SAVER_ACTIVATED="${TMPDIR_T}/saver.activated"
LOCKER_RAN="${TMPDIR_T}/locker.ran"
export XSET_LOG XSSLOCK_ARMED SAVER_ACTIVATED LOCKER_RAN

cat > "${BIN}/xset" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${XSET_LOG}"
exit 0
EOF
# xss-lock stub: being invoked AT ALL means the idle auto-lock was armed. Record it
# synchronously so a bounded poll in the test can observe it (PLS backgrounds it with &).
cat > "${BIN}/xss-lock" <<'EOF'
#!/usr/bin/env bash
: > "${XSSLOCK_ARMED}"
exit 0
EOF
cat > "${BIN}/xscreensaver-command" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" -activate "*) : > "${SAVER_ACTIVATED}";; esac
exit 0
EOF
# the manual-lock stub locker: reaching it means we passed the passwordless gate.
cat > "${STUB_LOCKER}" <<'EOF'
#!/usr/bin/env bash
: > "${LOCKER_RAN}"
exit 0   # emulate a genuine PAM unlock so the supervisor loop breaks
EOF
# pgrep: nothing is ever "already running" -> PLS starts the saver + arms xss-lock,
# PLK is a fresh single instance. (exit 1 = no match.)
cat > "${BIN}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
# gdbus: report the panel dbus name as UNowned so PLS never tries xfce4-panel -r.
cat > "${BIN}/gdbus" <<'EOF'
#!/usr/bin/env bash
echo "(false,)"
exit 0
EOF
for noop in xscreensaver xfconf-query pkill xfce4-panel; do
  cat > "${BIN}/${noop}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
# sleep stub: keep the PLK 0.6s grab-race delay from slowing the test.
cat > "${BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${BIN}"/* "${STUB_LOCKER}"

HOME_T="${TMPDIR_T}/home"; install -d "${HOME_T}"
run_setup() { HOME="${HOME_T}" PATH="${BIN}:${PATH}" bash "${PLS_SH}" >"${TMPDIR_T}/pls.out" 2>&1; }
run_lock()  { HOME="${HOME_T}" PATH="${BIN}:${PATH}" bash "${PLK_SH}" >"${TMPDIR_T}/plk.out" 2>&1; }
reset_marks(){ rm -f "${XSET_LOG}" "${XSSLOCK_ARMED}" "${SAVER_ACTIVATED}" "${LOCKER_RAN}" "${HOME_T}/.xscreensaver"; }
# xss-lock is armed via `&`; poll briefly for the marker so the assert isn't racy.
poll_armed(){ local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "${XSSLOCK_ARMED}" ] && return 0; sleep 0.1 2>/dev/null || true; done; [ -e "${XSSLOCK_ARMED}" ]; }

echo "================ 1. PASSWORDLESS session: NO lock, but DPMS still armed ="
reset_marks
rm -f "${PWF}"                       # no password file at all
run_setup
sleep 0.3 2>/dev/null || true        # give the (never-launched) xss-lock & a chance
assert_false "$([ -e "${XSSLOCK_ARMED}" ]; echo $?)" "passwordless: idle auto-lock (xss-lock) is NEVER armed"
assert_true  "$([ -s "${XSET_LOG}" ] && grep -q 'dpms' "${XSET_LOG}"; echo $?)" "passwordless: DPMS is armed anyway (xset dpms) -> screen still power-saves"
assert_true  "$([ -f "${HOME_T}/.xscreensaver" ]; echo $?)" "passwordless: ~/.xscreensaver written (saver configured)"
assert_contains "$(cat "${HOME_T}/.xscreensaver" 2>/dev/null)" "lock:" ".xscreensaver carries a lock: setting"
assert_true  "$(grep -Eq 'lock:[[:space:]]*False' "${HOME_T}/.xscreensaver"; echo $?)" "passwordless: the saver itself never locks (lock:False)"
assert_true  "$(grep -Eq 'dpmsEnabled:[[:space:]]*True' "${HOME_T}/.xscreensaver"; echo $?)" "passwordless: DPMS/blank IS configured (dpmsEnabled:True)"

echo
echo "================ 2. PASSWORDED session: idle auto-lock IS armed ========"
reset_marks
printf '%s\n' '$6$abc$deffromtest' > "${PWF}"   # a non-empty crypt-ish hash
run_setup
assert_true  "$(poll_armed; echo $?)" "passworded: idle auto-lock (xss-lock) IS armed"
assert_true  "$([ -s "${XSET_LOG}" ] && grep -q 'dpms' "${XSET_LOG}"; echo $?)" "passworded: DPMS armed too (unchanged)"

echo
echo "================ 3. MANUAL lock (Win+L) - passwordless -> saver only ==="
reset_marks
rm -f "${PWF}"
run_lock
assert_true  "$([ -e "${SAVER_ACTIVATED}" ]; echo $?)" "passwordless manual lock: shows the saver (xscreensaver -activate)"
assert_false "$([ -e "${LOCKER_RAN}" ]; echo $?)" "passwordless manual lock: the PAM locker is NEVER reached (cannot lock itself out)"

echo
echo "================ 4. MANUAL lock (Win+L) - passworded -> real locker ===="
reset_marks
printf '%s\n' '$6$abc$deffromtest' > "${PWF}"
run_lock
assert_true  "$([ -e "${LOCKER_RAN}" ]; echo $?)" "passworded manual lock: reaches the real Win95 PAM locker"
assert_false "$([ -e "${SAVER_ACTIVATED}" ]; echo $?)" "passworded manual lock: does NOT fall through to the saver-only path"

assert_summary "test-lock-policy" || exit 1
echo "test-lock-policy: ALL PASS"
