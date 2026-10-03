#!/usr/bin/env bash
# test-chicago95-assert.sh - hardware-FREE unit test for the Chicago95 theme
# FAIL-LOUD post-install assertion. The bug it guards: the Win95 theme was
# fetched by a LIVE `git clone` at build time and, on clone failure, the build
# SILENTLY continued and shipped a plain unthemed XFCE (you only found out at
# boot). The fix pins the upstream commit and adds chicago95_assert(), which the
# build calls after install - if the key theme artifacts are not in the rootfs the
# build now ERRORS OUT instead of shipping a half-themed image.
#
# chicago95_assert() is a function in scripts/build/phases/95-desktop-theme.sh,
# so this test sed/awk-carves the function body out of that phase, SOURCES it, and exercises the REAL assertion against synthetic
# rootfs trees. No VM, no network, no chroot - pure path checks.
#
# Asserts:
#   * a complete rootfs (theme gtk-3.0 + icon index.theme + xfconf naming the
#     theme) -> assertion PASSES (rc 0). Happy path is unchanged.
#   * each artifact missing in turn -> assertion FAILS (rc 1). This is the
#     fail-loud path: a missing artifact must NOT pass (was the silent ship).
#   * empty rootfs (clone produced nothing) -> FAILS.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

# chicago95_assert() lives in the 95-desktop-theme phase.
BUILD="${REPO_ROOT}/scripts/build/phases/95-desktop-theme.sh"
[ -f "${BUILD}" ] || { echo "FAIL: 95-desktop-theme.sh not found at ${BUILD}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-c95test.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- carve + source the chicago95_assert() function body ----------------------
# Grab from `chicago95_assert() {` up to the matching `}` at column 0 (the
# function closes with a `}` flush-left in the build script). The body only
# defines + reads locals, so sourcing it has no side effects.
FN_BODY="${TMPDIR_T}/chicago95_assert.sh"
awk '/^chicago95_assert\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${BUILD}" > "${FN_BODY}"
[ -s "${FN_BODY}" ] || { echo "FAIL: could not carve chicago95_assert() from ${BUILD}"; exit 1; }
grep -q 'chicago95_assert()' "${FN_BODY}" || { echo "FAIL: chicago95_assert() missing from carve"; exit 1; }
grep -q '^}$'                "${FN_BODY}" || { echo "FAIL: chicago95_assert() carve not closed"; exit 1; }
# shellcheck disable=SC1090
source "${FN_BODY}"

# Build a COMPLETE synthetic rootfs with all three required artifacts present.
make_complete_rootfs() {
  local rfs="$1"
  install -d "${rfs}/usr/share/themes/Chicago95/gtk-3.0"
  printf '/* gtk3 */\n' > "${rfs}/usr/share/themes/Chicago95/gtk-3.0/gtk.css"
  install -d "${rfs}/usr/share/icons/Chicago95"
  printf '[Icon Theme]\nName=Chicago95\n' > "${rfs}/usr/share/icons/Chicago95/index.theme"
  install -d "${rfs}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
  printf '<property name="ThemeName" type="string" value="Chicago95"/>\n' \
    > "${rfs}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
}

echo "================ happy path: complete rootfs PASSES ==========="
RFS_OK="${TMPDIR_T}/rootfs-ok"; make_complete_rootfs "${RFS_OK}"
chicago95_assert "${RFS_OK}" 2>/dev/null; assert_true "$?" "complete rootfs -> assertion passes (rc 0, theme present)"

echo
echo "================ fail-loud: each artifact missing -> FAILS ===="
# 1) theme dir gone (clone copied nothing / upstream moved the Theme/ dir)
RFS="${TMPDIR_T}/rootfs-no-theme"; make_complete_rootfs "${RFS}"; rm -rf "${RFS}/usr/share/themes/Chicago95"
chicago95_assert "${RFS}" 2>/dev/null; assert_false "$?" "missing gtk theme dir -> assertion FAILS (no silent ship)"

# 2) gtk-3.0 subdir gone (theme dir exists but is not a real GTK3 theme)
RFS="${TMPDIR_T}/rootfs-no-gtk3"; make_complete_rootfs "${RFS}"; rm -rf "${RFS}/usr/share/themes/Chicago95/gtk-3.0"
chicago95_assert "${RFS}" 2>/dev/null; assert_false "$?" "theme dir without gtk-3.0 -> assertion FAILS"

# 3) icon theme gone
RFS="${TMPDIR_T}/rootfs-no-icons"; make_complete_rootfs "${RFS}"; rm -rf "${RFS}/usr/share/icons/Chicago95"
chicago95_assert "${RFS}" 2>/dev/null; assert_false "$?" "missing icon theme -> assertion FAILS"

# 4) xfconf default gone (theme installed but nothing selects it)
RFS="${TMPDIR_T}/rootfs-no-xfconf"; make_complete_rootfs "${RFS}"
rm -f "${RFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
chicago95_assert "${RFS}" 2>/dev/null; assert_false "$?" "missing xfconf default -> assertion FAILS"

# 5) xfconf exists but does NOT name Chicago95 (e.g. clobbered to a different theme)
RFS="${TMPDIR_T}/rootfs-wrong-xfconf"; make_complete_rootfs "${RFS}"
printf '<property name="ThemeName" type="string" value="Adwaita"/>\n' \
  > "${RFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
chicago95_assert "${RFS}" 2>/dev/null; assert_false "$?" "xfconf names a different theme -> assertion FAILS"

# 6) totally empty rootfs (clone produced nothing at all - the original bug)
RFS="${TMPDIR_T}/rootfs-empty"; install -d "${RFS}"
chicago95_assert "${RFS}" 2>/dev/null; assert_false "$?" "empty rootfs (clone failed) -> assertion FAILS (was the silent unthemed ship)"

echo
echo "================ pin is recorded in the build script =========="
assert_true "$(grep -q 'C95_REF="11415b568e84795f7e0d6aa702b41a2cf23e9381"' "${BUILD}"; echo $?)" \
  "95-desktop-theme.sh pins Chicago95 to a specific commit (reproducible)"
assert_true "$(grep -q 'refusing to ship unthemed image' "${BUILD}"; echo $?)" \
  "95-desktop-theme.sh aborts loud (refuses to ship unthemed image)"

assert_summary "test-chicago95-assert" || exit 1
echo "test-chicago95-assert: ALL PASS"
