#!/usr/bin/env bash
# test-desktop-bringup.sh - hardware-FREE regression guard for the real-HW XFCE
# "Unable to load a failsafe session" fix.
#
# Root cause on real hardware: the redundant systemd-udev-settle deps burned their
# ~90-120s timeout, disordering late userspace, AND partyos-xfce-launch committed the
# session to the systemd --user bus the instant the socket FILE existed (before the bus
# served activations) -> xfce4-session queried an xfconfd that could not activate ->
# the failsafe dialog. The fix: (a) a CLEAN drop of the udev-settle
# deps from the 3 units, (b) a launcher guard that adopts the user bus ONLY once it
# actually answers a ListNames probe and otherwise falls back to dbus-run-session (which
# always brings an activatable xfconfd), (c) honoring the home-pull wait so xfconfd never
# reads a half-seeded home, and (d) guarding the panel reload on NameHasOwner.
#
# Only a real boot can CONFIRM the desktop actually comes up; this
# test STATICALLY asserts the wiring (so a future edit can't silently reintroduce the
# stall or drop the guards) and BEHAVIOURALLY proves the bus-not-answering fallback fires.
# Same extractive style as test-home-pull-gate / test-lock-policy.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

PHASES="${REPO_ROOT}/scripts/build/phases"
RFS="${REPO_ROOT}/scripts/build/files/rootfs"
SYSTEMD="${RFS}/etc/systemd/system"
XFCE_LAUNCH="${RFS}/usr/local/bin/partyos-xfce-launch"
LOCK_SETUP="${RFS}/usr/local/bin/partyos-lock-setup"
[ -f "${XFCE_LAUNCH}" ] || { echo "FAIL: partyos-xfce-launch not found at ${XFCE_LAUNCH}"; exit 1; }
[ -f "${LOCK_SETUP}" ]  || { echo "FAIL: partyos-lock-setup not found at ${LOCK_SETUP}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-bringup.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

echo "================ 1. NO systemd-udev-settle dep survives anywhere ======"
# The whole point of the fix: not a single unit may Wants=/After=/Requires= the
# deprecated settle gate (on real HW it never drains -> the boot stall + disorder).
# Scan the baked unit files AND the phase modules that write/patch units - no unit anywhere
# in the build may Wants=/After=/Requires=/BindsTo= the settle gate.
settle_deps="$(grep -rniE '(Wants|After|Requires|BindsTo)=.*udev.?settle' "${SYSTEMD}" "${PHASES}" || true)"
assert_eq "${settle_deps}" "" "no unit declares a systemd-udev-settle dependency (drop is clean)"
# the three formerly-offending units still exist as baked unit files (guard against the test
# passing because the units were deleted rather than de-depped).
for u in partyos-identity.service partyos-usbhome.service partyos-home-services.service; do
  assert_true "$([ -f "${SYSTEMD}/${u}" ]; echo $?)" "unit ${u} still defined"
done

echo
echo "================ 2. load partyos-xfce-launch + assert D-Bus race guard ="
XL_SH="${XFCE_LAUNCH}"
[ -s "${XL_SH}" ] || { echo "FAIL: partyos-xfce-launch baked file is empty (${XL_SH})"; exit 1; }
bash -n "${XL_SH}" && assert_true 0 "carved partyos-xfce-launch parses (bash -n)" || assert_true 1 "carved partyos-xfce-launch parses (bash -n)"
# (a) the bus is PROBED with a bounded ListNames before it is trusted
assert_true "$(grep -q 'ListNames' "${XL_SH}"; echo $?)" "launcher probes the user bus with a ListNames call before adopting it"
assert_true "$(grep -q 'bus_ok=1' "${XL_SH}"; echo $?)" "launcher tracks a bus_ok=1 'the bus actually answered' state"
# (b) the systemd --user bus is adopted ONLY inside the bus_ok branch
assert_true "$(grep -q 'if \[ "\${bus_ok}" = 1 \]' "${XL_SH}"; echo $?)" "adopt is gated on bus_ok (never adopt a half-up bus)"
assert_true "$(grep -q 'DBUS_SESSION_BUS_ADDRESS="unix:path=\${UBUS}"' "${XL_SH}"; echo $?)" "adopt exports DBUS_SESSION_BUS_ADDRESS to the probed bus"
# (c) the fallback path is a guaranteed-clean dbus-run-session (activatable xfconfd)
assert_true "$(grep -q 'dbus-run-session' "${XL_SH}"; echo $?)" "fallback launches via dbus-run-session (guaranteed activatable xfconfd)"
# (d) the home-pull wait is honored so xfconfd never reads a half-seeded home
assert_true "$(grep -q '/run/partyos-home-pull-ran' "${XL_SH}"; echo $?)" "launcher waits on the boot home-pull (PULL_RAN) before starting the session"

echo
echo "================ 3. panel reload + session ordering wiring ============"
# the panel -r reload is guarded on the org.xfce.Panel dbus name being OWNED, so it can
# never dbus-ACTIVATE the panel and pop the 'Failed to restart the panel' GTK dialog. The
# guarded reload lives in the baked partyos-lock-setup script now.
assert_true "$(grep -q 'NameHasOwner' "${LOCK_SETUP}" && grep -q 'org.xfce.Panel' "${LOCK_SETUP}"; echo $?)" "panel reload is guarded on NameHasOwner org.xfce.Panel"
# identity + home-pull + home-services are ordered Before the display manager, so the
# desktop only starts once the account + home are resolved (no XDG_CONFIG_DIRS race).
#   unit-file : friendly-name
for spec in "partyos-identity.service:partyos-identity" "partyos-home-pull.service:partyos-home-pull" "partyos-home-services.service:partyos-home-services"; do
  unit="${spec%%:*}"; name="${spec#*:}"
  block="$(cat "${SYSTEMD}/${unit}" 2>/dev/null)"
  assert_true    "$([ -n "${block}" ]; echo $?)" "${name}: baked unit file present (${unit})"
  assert_contains "${block}" "Before=display-manager.service" "${name}: ordered Before=display-manager.service"
done

echo
echo "================ 4/5. BEHAVIOUR: probe decides adopt vs dbus-run-session ="
# Drive the carved launcher for real. The launcher hardcodes XDG_RUNTIME_DIR=/run/user/UID
# (which we cannot write to under test), so rewrite that one line to a temp runtime dir we
# control; then vary the user-bus state and assert the launcher's adopt-vs-fallback choice.
XL_RUN="${TMPDIR_T}/xl-run"; cp "${XL_SH}" "${XL_RUN}"
PULLRAN="${TMPDIR_T}/pull-ran"; : > "${PULLRAN}"          # pull already done -> wait returns at once
RT="${TMPDIR_T}/runtime"; install -d "${RT}"
sed -i.bak "s#/run/partyos-home-pull-ran#${PULLRAN}#g" "${XL_RUN}"
sed -i.bak2 's#export XDG_RUNTIME_DIR="/run/user/${UID_N}"#export XDG_RUNTIME_DIR="'"${RT}"'"#' "${XL_RUN}"
grep -q "export XDG_RUNTIME_DIR=\"${RT}\"" "${XL_RUN}" \
  || { echo "FAIL: could not repoint XDG_RUNTIME_DIR in carved launcher (line drifted)"; exit 1; }

BIN="${TMPDIR_T}/bin"; install -d "${BIN}"
RUNMARK="${TMPDIR_T}/launch.mark"; export RUNMARK
cat > "${BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# the launcher wraps the probe in `timeout 2 dbus-send ...`; macOS has no `timeout`, so
# provide one that just drops the duration and runs the command (its rc = dbus-send's rc).
cat > "${BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
shift        # drop the duration argument
exec "$@"
EOF
cat > "${BIN}/startxfce4" <<'EOF'
#!/usr/bin/env bash
echo "STARTXFCE4-DIRECT bus=${DBUS_SESSION_BUS_ADDRESS:-none}" >> "${RUNMARK}"
exit 0
EOF
cat > "${BIN}/dbus-run-session" <<'EOF'
#!/usr/bin/env bash
echo "DBUS-RUN-SESSION-FALLBACK args=$*" >> "${RUNMARK}"
exit 0
EOF
for noop in systemctl dbus-update-activation-environment loginctl; do
  cat > "${BIN}/${noop}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
set_dbus_send() {  # $1 = exit code the stub returns (0 answers, non-0 = bus not serving)
  printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "${BIN}/dbus-send"
}
chmod +x "${BIN}"/* 2>/dev/null || true

# Mint a REAL unix socket at ${RT}/bus so `[ -S ${UBUS} ]` passes - this reproduces the
# EXACT failsafe scenario: the systemd --user socket FILE exists, but whether the bus
# actually SERVES is what the ListNames probe must decide. python3 mints the socket file.
sock_ok=0
if command -v python3 >/dev/null 2>&1 && \
   python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "${RT}/bus" 2>/dev/null && \
   [ -S "${RT}/bus" ]; then
  sock_ok=1
fi

echo
echo "  -- 4. socket present but bus NOT serving (ListNames fails) -> fallback --"
set_dbus_send 1; chmod +x "${BIN}/dbus-send"; : > "${RUNMARK}"
DISPLAY=:0 HOME="${TMPDIR_T}" PATH="${BIN}:${PATH}" bash "${XL_RUN}" >/dev/null 2>&1 || true
out1="$(cat "${RUNMARK}")"
assert_contains "${out1}" "DBUS-RUN-SESSION-FALLBACK" "bus not serving: launcher falls back to dbus-run-session (avoids the failsafe race)"
assert_not_contains "${out1}" "STARTXFCE4-DIRECT" "bus not serving: launcher does NOT commit startxfce4 to the half-up bus"

echo
echo "  -- 5. socket present and bus ANSWERS (ListNames ok) -> adopt --"
if [ "${sock_ok}" = 1 ]; then
  set_dbus_send 0; chmod +x "${BIN}/dbus-send"; : > "${RUNMARK}"
  DISPLAY=:0 HOME="${TMPDIR_T}" PATH="${BIN}:${PATH}" bash "${XL_RUN}" >/dev/null 2>&1 || true
  out2="$(cat "${RUNMARK}")"
  assert_contains "${out2}" "STARTXFCE4-DIRECT" "bus answers: launcher adopts the user bus + runs startxfce4"
  assert_contains "${out2}" "unix:path=${RT}/bus" "bus answers: DBUS_SESSION_BUS_ADDRESS points at the probed bus"
else
  echo "  SKIP: no python3 unix-socket support - static asserts already cover the adopt branch"
fi

assert_summary "test-desktop-bringup" || exit 1
echo "test-desktop-bringup: ALL PASS"
