#!/usr/bin/env bash
# test-home-pull-gate.sh - hardware-FREE negative test for the home-sync
# data-loss fix. A partial boot pull could permanently wipe the player's stick:
#   partyos-home-pull captured the pull rsync's rc but never checked it before
#   writing the generation baseline and OPENING the push gate (PULL_DONE). A pull
#   that died mid-copy (SIGKILL / --timeout=20 stall) left a PARTIAL RAM home with
#   the gate open. Then the 45s push timer --delete-mirrored the partial RAM home
#   over the stick, deleting everything the pull never copied.
#
# The fix: write PULL_DONE/baseline only when the pull rc is 0 (clean) or 24 (benign
# vanished-source-files).
#
# This test COPIES the real baked partyos-home-pull + partyos-sync-home files and
# drives them against temp dirs with a STUBBED rsync that simulates a mid-copy kill,
# then asserts the push gate stayed closed and the "stick" (USB_HOME) was untouched.
# No VM, no network, no hardware - the same extractive style as test-gen-guard.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

# Copy partyos-home-pull, partyos-sync-home and the home-pull unit into the sandbox.
RFS="${REPO_ROOT}/scripts/build/files/rootfs"
[ -d "${RFS}" ] || { echo "FAIL: baked rootfs tree not found at ${RFS}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-pullgate.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- carve the two baked scripts out of their heredocs -------------------------
PULL_SH="${TMPDIR_T}/partyos-home-pull"
SYNC_SH="${TMPDIR_T}/partyos-sync-home"
cp "${RFS}/usr/local/bin/partyos-home-pull" "${PULL_SH}"
cp "${RFS}/usr/local/bin/partyos-sync-home" "${SYNC_SH}"
[ -s "${PULL_SH}" ] || { echo "FAIL: partyos-home-pull baked file is empty"; exit 1; }
[ -s "${SYNC_SH}" ] || { echo "FAIL: partyos-sync-home baked file is empty"; exit 1; }
# the fix must be present in the carved source (guard against a silent revert):
grep -q 'PARTYOS-HOME-PULL-INCOMPLETE' "${PULL_SH}" || { echo "FAIL: pull rc-gate (PARTYOS-HOME-PULL-INCOMPLETE) missing from carved script"; exit 1; }
# the boot pull MIRROR must be --delete-delay, not delete-during: a SIGTERM at the unit's
# TimeoutStartSec (slow-stick suspect-backup + mirror overrun) must not leave a gutted RAM
# home. Guard against a silent revert back to plain --delete.
grep -qE 'rsync -a --delete-delay --timeout' "${PULL_SH}" || { echo "FAIL: boot pull mirror is not '--delete-delay' (a SIGTERM mid-pull could gut the RAM home)"; exit 1; }

# --- fake environment the scripts source (common.sh) ---------------------------
MNT="${TMPDIR_T}/mnt";            install -d "${MNT}"
HOME_DIR="${TMPDIR_T}/ram-home";  install -d "${HOME_DIR}"
USB_HOME="${TMPDIR_T}/usb-home";  install -d "${USB_HOME}"       # the "stick"
SKEL="${TMPDIR_T}/skel";          install -d "${SKEL}"
RO_FLAG="${TMPDIR_T}/ro.flag"
PAUSE_FLAG="${TMPDIR_T}/pause.flag"
PULL_DONE="${TMPDIR_T}/pull-done"
STATE_FILE="${TMPDIR_T}/gen.state"
BASELINE_FILE="${TMPDIR_T}/gen.baseline"
PUSH_MARKER="${TMPDIR_T}/push-ran.marker"
export HOME_DIR USB_HOME PUSH_MARKER

# the stick carries several files + a generation counter. The partial pull will only
# copy ONE of them; if the push ever fired it would --delete-mirror the rest away.
printf 'savegameA\n' > "${USB_HOME}/save-a.dat"
printf 'savegameB\n' > "${USB_HOME}/save-b.dat"
printf 'configC\n'   > "${USB_HOME}/config-c.ini"
printf '7' > "${STATE_FILE}"
USB_SHA_BEFORE="$(cd "${USB_HOME}" && find . -type f -exec shasum {} + | sort | shasum | awk '{print $1}')"

COMMON_STUB="${TMPDIR_T}/common.sh"
cat > "${COMMON_STUB}" <<EOF
MNT="${MNT}"
HOME_DIR="${HOME_DIR}"
USB_HOME="${USB_HOME}"
SKEL="${SKEL}"
RO_FLAG="${RO_FLAG}"
PAUSE_FLAG="${PAUSE_FLAG}"
PULL_DONE="${PULL_DONE}"
PULL_RAN="${TMPDIR_T}/pull-ran"
PULL_INPROGRESS="${TMPDIR_T}/pull-inprogress"
STATE_FILE="${STATE_FILE}"
BASELINE_FILE="${BASELINE_FILE}"
PUSH_INPROGRESS="${TMPDIR_T}/push-inprogress"
UIDGID="\$(id -u)"
RSYNC_EX=(--exclude=.partyos)
is_rw() { return 0; }
dir_empty() { [ -z "\$(ls -A "\$1" 2>/dev/null)" ]; }
gen_read() { cat "${STATE_FILE}" 2>/dev/null || echo 0; }
gen_mine() { cat "${BASELINE_FILE}" 2>/dev/null || echo 0; }
gen_baseline() { printf '%s' "\$1" > "${BASELINE_FILE}"; }
EOF

# point the carved scripts at the stub instead of /usr/local/lib/partyos-sync-common.sh
sed -i.bak "s#\. /usr/local/lib/partyos-sync-common.sh#. ${COMMON_STUB}#" "${PULL_SH}" "${SYNC_SH}"

# --- stub external commands on PATH --------------------------------------------
BIN="${TMPDIR_T}/bin"; install -d "${BIN}"
cat > "${BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 0   # always "mounted"
EOF
cat > "${BIN}/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
echo none
EOF
# rsync stub: seed = full copy; pull (--delete into HOME_DIR) = PARTIAL copy then
# exit ${STUB_RC} (simulates a mid-copy SIGKILL/stall); push (--delete into USB_HOME)
# = record that it ran (must NEVER happen while the gate is closed).
cat > "${BIN}/rsync" <<'EOF'
#!/usr/bin/env bash
args=("$@"); delete=0
for a in "$@"; do case "$a" in --delete|--delete-delay) delete=1;; esac; done
src="${args[$(( ${#args[@]} - 2 ))]}"; dst="${args[$(( ${#args[@]} - 1 ))]}"
if [ "$delete" = 1 ] && [ "${dst%/}" = "${HOME_DIR%/}" ] && [ "${STUB_FULL:-0}" = 1 ]; then
    mkdir -p "$dst"; cp -a "${src%/}/." "${dst%/}/" 2>/dev/null; exit 0
fi
if [ "$delete" = 1 ] && [ "${dst%/}" = "${HOME_DIR%/}" ]; then
    mkdir -p "$dst"
    first="$(ls -A "${src%/}" 2>/dev/null | head -1)"
    [ -n "$first" ] && cp -a "${src%/}/${first}" "${dst%/}/" 2>/dev/null
    echo "stub-rsync: PARTIAL pull (copied '${first}') then rc=${STUB_RC}" >&2
    exit "${STUB_RC:-0}"
fi
if [ "$delete" = 1 ] && [ "${dst%/}" = "${USB_HOME%/}" ]; then
    echo "PUSH_RAN dst=${dst}" >> "${PUSH_MARKER}"
    cp -a "${src%/}/." "${dst%/}/" 2>/dev/null
    exit 0
fi
mkdir -p "$dst"; cp -a "${src%/}/." "${dst%/}/" 2>/dev/null; exit 0
EOF
chmod +x "${BIN}/mountpoint" "${BIN}/systemd-detect-virt" "${BIN}/rsync"

run_pull() { STUB_RC="$1" PATH="${BIN}:${PATH}" bash "${PULL_SH}" >"${TMPDIR_T}/pull.out" 2>&1; }
reset_state() { rm -rf "${HOME_DIR}" "${PULL_DONE}" "${BASELINE_FILE}" "${PUSH_MARKER}"; install -d "${HOME_DIR}"; }

echo "================ 1. pull KILLED mid-copy -> gate stays CLOSED ="
reset_state
run_pull 137   # 137 = 128+SIGKILL: the pull was killed partway
assert_false "$([ -e "${PULL_DONE}" ]; echo $?)" "killed pull (rc=137): PULL_DONE NOT written (push gate stays closed)"
assert_false "$([ -e "${BASELINE_FILE}" ]; echo $?)" "killed pull (rc=137): generation baseline NOT written"
assert_contains "$(cat "${TMPDIR_T}/pull.out")" "PARTYOS-HOME-PULL-INCOMPLETE" "killed pull logs PARTYOS-HOME-PULL-INCOMPLETE"

echo
echo "================ 2. push is a NO-OP while gated + stick intact ="
# with the gate closed (from the killed pull above), the runtime push must skip and
# the stick (USB_HOME) must be byte-for-byte untouched (no --delete mirror).
PATH="${BIN}:${PATH}" bash "${SYNC_SH}" >"${TMPDIR_T}/sync.out" 2>&1 || true
assert_false "$([ -e "${PUSH_MARKER}" ]; echo $?)" "push did NOT run the --delete mirror (gate held)"
assert_contains "$(cat "${TMPDIR_T}/sync.out")" "boot pull not done yet" "push logged the gate skip"
USB_SHA_AFTER="$(cd "${USB_HOME}" && find . -type f -exec shasum {} + | sort | shasum | awk '{print $1}')"
assert_eq "${USB_SHA_AFTER}" "${USB_SHA_BEFORE}" "stick contents byte-identical (nothing deleted/overwritten)"
assert_true "$([ -f "${USB_HOME}/save-b.dat" ] && [ -f "${USB_HOME}/config-c.ini" ]; echo $?)" "stick files the partial pull MISSED are still present"

echo
echo "================ 3. clean pull (rc=0) DOES open the gate ======="
reset_state
run_pull 0
assert_true "$([ -e "${PULL_DONE}" ]; echo $?)" "clean pull (rc=0): PULL_DONE written (gate opens normally)"
assert_eq "$(cat "${BASELINE_FILE}" 2>/dev/null)" "7" "clean pull records the stick generation (7) as baseline"

echo
echo "================ 4. rc=24 (vanished source files) is tolerated ="
reset_state
run_pull 24
assert_true "$([ -e "${PULL_DONE}" ]; echo $?)" "rc=24 pull: PULL_DONE written (benign vanished-files tolerated)"

echo
echo "================ 6. home-pull.service start-timeout sized for a plain slow-stick pull ="
# The slow suspect-backup was REMOVED, so the old 300s (which existed to cover it) is retuned
# to 120s: enough for a full --delete-delay mirror of a realistic home on a slow (~4-5 MB/s)
# stick with headroom, but not effectively-infinite (rsync's own --timeout=20 catches a hung
# stick). Guard the retuned budget so a revert to a too-small OR back-to-300s value is caught.
UNIT_BODY="$(cat "${RFS}/etc/systemd/system/partyos-home-pull.service")"
UNIT_TSEC="$(printf '%s\n' "${UNIT_BODY}" | grep -oE 'TimeoutStartSec=[0-9]+' | head -1 | cut -d= -f2)"
assert_true "$([ -n "${UNIT_TSEC}" ]; echo $?)" "partyos-home-pull.service declares a numeric TimeoutStartSec"
assert_eq "${UNIT_TSEC}" "120" "partyos-home-pull.service TimeoutStartSec retuned to 120s (plain --delete-delay pull, no backup)"
assert_true "$([ "${UNIT_TSEC:-0}" -ge 90 ] && [ "${UNIT_TSEC:-0}" -le 180 ]; echo $?)" "TimeoutStartSec is a moderate slow-stick budget (90-180s), not the old too-small 60s nor the backup-era 300s"

echo
echo "================ 7. EMPTY venue home partition: first and second boot ="
# A venue stick has an ext4 PARTYOSHOME partition that holds only lost+found. The
# first boot must create the layout (partyos-usbhome), seed home/ from the skel and
# open the push gate (partyos-home-pull), with no error and no data loss. The second
# boot must be a normal boot: no layout marker, no seed, the player data kept.
M7="${TMPDIR_T}/venue-home"; install -d "${M7}/lost+found"
H7="${TMPDIR_T}/ram-home7"; install -d "${H7}"
S7="${TMPDIR_T}/skel7"; install -d "${S7}/.config/xfce4/panel" "${S7}/Desktop"
printf 'panel\n' > "${S7}/.config/xfce4/panel/whiskermenu-1.rc"
printf '[Desktop Entry]\n' > "${S7}/Desktop/Games.desktop"
printf 'rc\n' > "${S7}/.bashrc"
# The layout block of partyos-usbhome runs after a successful mount. Carve it (from the
# empty-partition check to the home/ dir) and run it on the sandbox partition.
LAYOUT="${TMPDIR_T}/usbhome-layout.sh"
awk '/A new venue stick has an EMPTY home partition/{g=1} g{print} g&&/install -d "\$\{MNT\}\/home"/{exit}' \
    "${RFS}/usr/local/bin/partyos-usbhome" > "${LAYOUT}"
assert_contains "$(cat "${LAYOUT}")" 'install -d "${MNT}/.partyos-cache/games"' "the carved layout block creates the blob cache dir"
run_layout() { MNT="${M7}" DEV=/dev/sdz2 bash -c "set -u; . '${LAYOUT}'" 2>&1; }
OUT7="$(run_layout)"
assert_contains "${OUT7}" "PARTYOS-USBHOME-FRESH /dev/sdz2 is empty (only lost+found)" "first boot: partyos-usbhome logs the empty partition"
for d in .partyos-cache/games .partyos-runcache .partyos-proton-envs home lost+found; do
    assert_true "$([ -d "${M7}/${d}" ]; echo $?)" "first boot: ${d}/ exists on the home partition"
done
COMMON7="${TMPDIR_T}/common7.sh"
sed -e "s#^MNT=.*#MNT=\"${M7}\"#" -e "s#^HOME_DIR=.*#HOME_DIR=\"${H7}\"#" \
    -e "s#^USB_HOME=.*#USB_HOME=\"${M7}/home\"#" -e "s#^SKEL=.*#SKEL=\"${S7}\"#" \
    -e "s#^STATE_FILE=.*#STATE_FILE=\"${M7}/.partyos-home-state\"#" \
    -e "s#^PULL_DONE=.*#PULL_DONE=\"${TMPDIR_T}/pull-done7\"#" \
    -e "s#^BASELINE_FILE=.*#BASELINE_FILE=\"${TMPDIR_T}/gen.baseline7\"#" \
    -e "s#cat \"${STATE_FILE}\"#cat \"${M7}/.partyos-home-state\"#" \
    -e "s#\"${BASELINE_FILE}\"#\"${TMPDIR_T}/gen.baseline7\"#g" \
    "${COMMON_STUB}" > "${COMMON7}"
PULL7="${TMPDIR_T}/partyos-home-pull7"
sed "s#\. ${COMMON_STUB}#. ${COMMON7}#" "${PULL_SH}" > "${PULL7}"
run_pull7() { HOME_DIR="${H7}" USB_HOME="${M7}/home" STUB_FULL=1 PATH="${BIN}:${PATH}" bash "${PULL7}" 2>&1; }
OUT7="$(run_pull7)"
assert_contains "${OUT7}" "first boot: seeding empty ${M7}/home" "first boot: home-pull seeds the empty home/ from the skel"
assert_not_contains "${OUT7}" "ERROR" "first boot: home-pull logs no ERROR"
assert_true "$([ -f "${M7}/home/Desktop/Games.desktop" ] && [ -f "${M7}/home/.bashrc" ]; echo $?)" "first boot: the stick home/ has the skel files"
assert_true "$([ -f "${H7}/.bashrc" ] && [ -f "${H7}/Desktop/Games.desktop" ]; echo $?)" "first boot: the RAM home has the skel files"
assert_true "$([ -e "${TMPDIR_T}/pull-done7" ]; echo $?)" "first boot: the push gate opens (PULL_DONE)"
assert_eq "$(cat "${TMPDIR_T}/gen.baseline7" 2>/dev/null)" "0" "first boot: the generation baseline is 0 (no state file yet)"
# The first push decides on the REAL generation helpers: an absent state file is a fresh stick -> push.
eval "$(sed -n '/^gen_read_status() {/,/^}/p;/^gen_decide() {/,/^}/p' "${RFS}/usr/local/lib/partyos-sync-common.sh")"
read -r st7 gv7 <<<"$(gen_read_status "${M7}/.partyos-home-state")"
assert_eq "${st7}" "absent" "first boot: the generation file is absent (not corrupt)"
assert_eq "$(gen_decide 0 "${st7}" "${gv7}")" "push" "first boot: the first push writes the fresh stick (verdict push)"
# Second boot: the player saved a file, the push wrote generation 1.
printf 'save\n' > "${M7}/home/player-save.dat"; printf '1' > "${M7}/.partyos-home-state"
rm -rf "${H7}" "${TMPDIR_T}/pull-done7"; install -d "${H7}"
OUT7="$(run_layout)"
assert_not_contains "${OUT7}" "PARTYOS-USBHOME-FRESH" "second boot: no empty-partition marker"
OUT7="$(run_pull7)"
assert_not_contains "${OUT7}" "first boot: seeding" "second boot: no seed (a normal pull)"
assert_true "$([ -f "${H7}/player-save.dat" ]; echo $?)" "second boot: the player data comes back into the RAM home"
assert_true "$([ -f "${M7}/home/player-save.dat" ] && [ -d "${M7}/lost+found" ]; echo $?)" "second boot: the stick keeps the player data and lost+found"
assert_eq "$(cat "${TMPDIR_T}/gen.baseline7" 2>/dev/null)" "1" "second boot: the baseline is the stick generation (1)"

assert_summary "test-home-pull-gate" || exit 1
echo "test-home-pull-gate: ALL PASS"
