#!/usr/bin/env bash
# test-user-provision.sh - hardware-FREE unit test for the per-player provisioning
# tooling (scripts/deploy/gen-user-config.sh + scripts/deploy/flash-usb.sh --user).
# No VM, no real USB, no sudo, no docker. The config store + flash-usb are pointed at
# a TEMP users/ dir (PARTYOS_USERS_DIR) and flash-usb writes identity into a TEMP
# directory via its dry-run seam (PARTYOS_FLASH_HOME_DIR) instead of flashing+mounting
# a device - the same "fake the device" approach the other prod-path tests use.
#
# Asserts:
#   * gen-user-config writes no STATIC_IP by default (DHCP); --slot maps to the
#     expected address; --ip refuses a collision; an existing user folder is refused
#     without --force.
#   * flash-usb --user writes the RIGHT split: USERNAME/HOSTNAME -> .partyos and
#     NICK/STATIC_IP/GATEWAY -> user.conf (the pinned IP lands where the OS reads it),
#     and seeds users/<name>/home/ into the stick's home/.
#   * flash-usb --user on an UNKNOWN player WARNS and exits non-zero (writes nothing).
#   * --blank bypasses the miss and exits 0 (writes no identity).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

GEN="${REPO_ROOT}/scripts/deploy/gen-user-config.sh"
FLASH="${REPO_ROOT}/scripts/deploy/flash-usb.sh"
for f in "${GEN}" "${FLASH}"; do
    [ -f "${f}" ] || { echo "FAIL: missing ${f}"; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-userprov.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# Isolated config store - the tooling NEVER touches the real repo users/ dir.
export PARTYOS_USERS_DIR="${TMP}/users"
# small, deterministic player range so the assertions are exact.
export PARTYOS_IP_PREFIX="192.168.0" PARTYOS_IP_LO="200" PARTYOS_IP_HI="209"

# read one KEY from a config/.partyos/user.conf file (same parse the runtime uses).
getk() { grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -1 | cut -d= -f2- | tr -d '[:space:]'; }

echo "================ gen-user-config: DHCP default, opt-in static IP ================"

bash "${GEN}" erin >/dev/null 2>&1
assert_true "$?" "gen-user-config registers 'erin' with no flags"
assert_eq "$(getk "${PARTYOS_USERS_DIR}/erin/config" STATIC_IP)" "" "erin (no --ip/--slot) gets no STATIC_IP (DHCP)"

bash "${GEN}" alice --slot 1 >/dev/null 2>&1
assert_true "$?" "gen-user-config registers 'alice'"
assert_true "$([ -f "${PARTYOS_USERS_DIR}/alice/config" ]; echo $?)" "alice/config was created"
assert_true "$([ -d "${PARTYOS_USERS_DIR}/alice/home" ]; echo $?)" "alice/home/ was created"
ALICE_IP="$(getk "${PARTYOS_USERS_DIR}/alice/config" STATIC_IP)"
assert_eq "$(getk "${PARTYOS_USERS_DIR}/alice/config" USERNAME)" "alice" "alice config has USERNAME=alice"
assert_eq "${ALICE_IP}" "192.168.0.200/24" "alice --slot 1 got .200"

bash "${GEN}" bob --slot 2 >/dev/null 2>&1
BOB_IP="$(getk "${PARTYOS_USERS_DIR}/bob/config" STATIC_IP)"
assert_eq "${BOB_IP}" "192.168.0.201/24" "bob --slot 2 got .201"
bash "${GEN}" frank --slot 1 >/dev/null 2>&1
assert_false "$?" "gen-user-config REFUSES --slot 1 (alice already has .200)"
assert_true "$([ "${ALICE_IP}" != "${BOB_IP}" ]; echo $?)" "alice and bob have DIFFERENT static IPs"

echo
echo "================ gen-user-config: --slot, --ip collision, existing-folder ======"

bash "${GEN}" carol --slot 5 >/dev/null 2>&1
assert_eq "$(getk "${PARTYOS_USERS_DIR}/carol/config" STATIC_IP)" "192.168.0.204/24" "--slot 5 maps to .204 (slot 1 = .200)"

bash "${GEN}" dave --ip 192.168.0.200 >/dev/null 2>&1
assert_false "$?" "gen-user-config REFUSES --ip that collides with alice's .200"
assert_true "$([ ! -e "${PARTYOS_USERS_DIR}/dave" ]; echo $?)" "the refused --ip left no dave/ folder"

bash "${GEN}" alice >/dev/null 2>&1
assert_false "$?" "gen-user-config REFUSES an existing user without --force"
bash "${GEN}" alice --slot 1 --force >/dev/null 2>&1
assert_true "$?" "--force overwrites the existing user"
assert_eq "$(getk "${PARTYOS_USERS_DIR}/alice/config" STATIC_IP)" "${ALICE_IP}" "--force keeps alice's own IP (does not self-collide)"

echo
echo "================ flash-usb --user: writes the .partyos / user.conf split ======="

# give alice a gateway (must land in user.conf, guarded by STATIC_IP) + a hostname +
# a home skeleton file, then flash into a temp 'mounted home' via the dry-run seam.
printf 'GATEWAY=192.168.0.1\n' >> "${PARTYOS_USERS_DIR}/alice/config"
mkdir -p "${PARTYOS_USERS_DIR}/alice/home/.config"
echo "alice-marker" > "${PARTYOS_USERS_DIR}/alice/home/.config/marker.txt"

HOMEDIR="${TMP}/mnt-alice"
PARTYOS_FLASH_HOME_DIR="${HOMEDIR}" bash "${FLASH}" /dev/nulldev --user alice >/dev/null 2>&1
assert_true "$?" "flash-usb --user alice (dry-run) succeeds"

# identity split: USERNAME + HOSTNAME in .partyos ...
assert_eq "$(getk "${HOMEDIR}/.partyos" USERNAME)" "alice" ".partyos carries USERNAME=alice"
assert_eq "$(getk "${HOMEDIR}/.partyos" HOSTNAME)" "alice-pc" ".partyos carries HOSTNAME"
# ... and the pinned network in user.conf (where partyos-staticip actually reads it).
assert_eq "$(getk "${HOMEDIR}/user.conf" STATIC_IP)" "${ALICE_IP}" "user.conf carries the pinned STATIC_IP (survives reprovision)"
assert_eq "$(getk "${HOMEDIR}/user.conf" GATEWAY)" "192.168.0.1" "user.conf carries GATEWAY"
assert_eq "$(getk "${HOMEDIR}/user.conf" NICK)" "alice" "user.conf carries NICK"
# STATIC_IP must NOT leak into .partyos (the OS reads it from user.conf only).
assert_eq "$(getk "${HOMEDIR}/.partyos" STATIC_IP)" "" ".partyos does NOT carry STATIC_IP (correct split)"
# home skeleton seeded into the stick's home/ subdir.
assert_eq "$(cat "${HOMEDIR}/home/.config/marker.txt" 2>/dev/null)" "alice-marker" "home/ skeleton was seeded into the stick home"

echo
echo "================ flash-usb --user: unknown player warns + stops; --blank bypasses"

MISSDIR="${TMP}/mnt-miss"
PARTYOS_FLASH_HOME_DIR="${MISSDIR}" bash "${FLASH}" /dev/nulldev --user nobody >/dev/null 2>&1
RC=$?
assert_false "${RC}" "flash-usb --user on an UNKNOWN player exits non-zero"
assert_eq "${RC}" "2" "unknown-player exit code is 2 (distinct 'no such user')"
assert_true "$([ ! -f "${MISSDIR}/.partyos" ]; echo $?)" "unknown player wrote NO .partyos"

BLANKDIR="${TMP}/mnt-blank"
PARTYOS_FLASH_HOME_DIR="${BLANKDIR}" bash "${FLASH}" /dev/nulldev --user nobody --blank >/dev/null 2>&1
assert_true "$?" "--blank bypasses the miss and exits 0"
assert_true "$([ ! -f "${BLANKDIR}/.partyos" ]; echo $?)" "--blank wrote NO identity"

assert_summary "test-user-provision" || exit 1
echo "test-user-provision: ALL PASS"
