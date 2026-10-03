#!/usr/bin/env bash
# test-title-metachars.sh - hardware-FREE regression test that a PLAYER- or CATALOG-
# provided game TITLE carrying shell metacharacters ($ ` " ' ; & and ${...}) is written
# into the generated .desktop launchers as LITERAL text: never shell-expanded, never
# executed, and never aborting generation under `set -u`. Covers BOTH title embed points
# in the baked files under scripts/build/files/rootfs/usr/local/bin/:
#   * write_app_desktop  - partyos-app, catalog app/game launchers (title from the LAN catalog).
#   * cmd_gen_tiles       - partyos-proton-env, per-player wine-env "play" tiles (title from env.meta).
#
# Regression guard: a player title must not be shell-expanded in a heredoc. The fix
# writes every dynamic value via `printf '%s'` as data. This carves the REAL functions
# out of those files, feeds a hostile title through them, and asserts:
#   * generation returns 0 (a `${UNSET}` in the title does NOT trip set -u).
#   * the Name= line equals the title byte-for-byte ($USER etc. NOT expanded).
#   * no embedded $(...)/`...` command substitution ran (canary files never appear).
#   * a benign title still renders the EXACT Desktop Entry format (printf rewrite kept
#     the boot-critical launcher layout identical to the old heredoc).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

# The two title embed points: write_app_desktop in partyos-app (catalog launchers)
# and meta_get + cmd_gen_tiles in partyos-proton-env (wine-env play tiles).
APP="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-app"
PROTON="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-proton-env"
[ -f "${APP}" ]    || { echo "FAIL: partyos-app baked file not found at ${APP}"; exit 1; }
[ -f "${PROTON}" ] || { echo "FAIL: partyos-proton-env baked file not found at ${PROTON}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-title.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# --- carve the REAL generator functions out of the baked files ----------------
# One function each: print from `<fn>() {` to the first column-0 `}` (the `{ } > file`
# blocks inside use INDENTED braces, so the terminator is unambiguous).
carve_fn() {  # carve_fn FILE FN
    awk -v FN="$2" '$0 ~ "^"FN"\\(\\) \\{"{f=1} f{print; if(/^\}/) exit}' "$1"
}
CARVE="${TMP}/carve.sh"
{ carve_fn "${PROTON}" meta_get; echo; carve_fn "${APP}" write_app_desktop; echo; carve_fn "${PROTON}" cmd_gen_tiles; } > "${CARVE}"
grep -q 'write_app_desktop()' "${CARVE}" || { echo "FAIL: write_app_desktop not carved"; exit 1; }
grep -q 'cmd_gen_tiles()'      "${CARVE}" || { echo "FAIL: cmd_gen_tiles not carved"; exit 1; }
grep -q 'meta_get()'           "${CARVE}" || { echo "FAIL: meta_get not carved"; exit 1; }
# say() is a status-marker sink in the real script; stub it so the carved code is quiet.
say() { :; }
# shellcheck disable=SC1090
source "${CARVE}"

# --- the hostile title --------------------------------------------------------
# Single-quoted so it is stored LITERALLY here (nothing expands at test-authoring time).
# It packs every hazard: a bare $var, "double" and 'single' quotes, a ; command
# separator, a & background op, a $(...) and a `...` command substitution that would
# create a canary file if ever executed, and a ${NOPE} that would abort under set -u
# if ever expanded.
HOSTILE='Super $mash "dq" '"'"'sq'"'"' ; rm -rf zz & $(touch PWNED_SUB) `touch PWNED_BT` ${NOPE} end'
# Run generation from a known cwd so a leaked relative `touch PWNED_*` is detectable.
CWD="${TMP}/cwd"; install -d "${CWD}"

# read the Name= value back out of a generated .desktop (everything after "Name=").
name_line() { sed -n 's/^Name=//p' "$1" | head -1; }

echo "================ write_app_desktop: catalog title with metachars ============"
HOME_DIR="${TMP}/home"; install -d "${HOME_DIR}"
WAD="${TMP}/app-hostile.desktop"
( cd "${CWD}" && write_app_desktop "${WAD}" "${HOSTILE}" "someid" "Game" "myicon" "myapp" ); rc=$?
assert_true "${rc}" "write_app_desktop returns 0 on a metachar title (no set -u abort)"
assert_true "$([ -f "${WAD}" ]; echo $?)" "write_app_desktop wrote the launcher file"
assert_eq "$(name_line "${WAD}")" "${HOSTILE}" "catalog Name= is the title VERBATIM (no expansion/injection)"
assert_contains "$(head -1 "${WAD}")" "[Desktop Entry]" "catalog launcher is a valid Desktop Entry"
assert_true "$([ ! -e "${CWD}/PWNED_SUB" ] && [ ! -e "${CWD}/PWNED_BT" ]; echo $?)" \
    "catalog path: no embedded command substitution executed (no canary)"

echo
echo "================ cmd_gen_tiles: player env.meta title with metachars ========"
ENVROOT="${TMP}/envroot"; install -d "${ENVROOT}/smash"
{
    printf 'name=%s\n'    'smash'
    printf 'title=%s\n'   "${HOSTILE}"
    printf 'exe=%s\n'     'drive_c/game.exe'
    printf 'created=%s\n' '123'
} > "${ENVROOT}/smash/env.meta"
install -d "${HOME_DIR}/Desktop/.apps/Games"
( cd "${CWD}" && cmd_gen_tiles ); rc=$?
assert_true "${rc}" "cmd_gen_tiles returns 0 on a metachar title (no set -u abort mid-gen)"
# the tile is named by the (metachar-laden but slash-free) title.
TILE="$(find "${HOME_DIR}/Desktop/.apps/Games" -maxdepth 1 -name '*.desktop' | head -1)"
assert_true "$([ -n "${TILE}" ] && [ -f "${TILE}" ]; echo $?)" "cmd_gen_tiles wrote a play tile"
assert_eq "$(name_line "${TILE}")" "${HOSTILE}" "tile Name= is the title VERBATIM (no expansion/injection)"
assert_contains "$(head -1 "${TILE}")" "[Desktop Entry]" "play tile is a valid Desktop Entry"
assert_true "$([ ! -e "${CWD}/PWNED_SUB" ] && [ ! -e "${CWD}/PWNED_BT" ]; echo $?)" \
    "tile path: no embedded command substitution executed (no canary)"

echo
echo "================ benign title: exact Desktop Entry format preserved ========="
# The printf rewrite must produce byte-identical launchers to the old heredoc for
# normal titles - these are boot-critical, so pin the full expected content.
HOME_DIR="${TMP}/home2"; install -d "${HOME_DIR}"
BAPP="${TMP}/app-benign.desktop"
write_app_desktop "${BAPP}" "My App" "someid" "Game" "myicon" "myapp"
read -r -d '' EXP_APP <<'EXP' || true
[Desktop Entry]
Type=Application
Name=My App
Comment=partyOS app store - install + launch My App
Exec=/usr/local/bin/partyos-launch myapp
Path=HOMEDIR
Terminal=false
Categories=Game;partyOS;
Icon=myicon
X-PartyOS-App=myapp
Actions=Share;

[Desktop Action Share]
Name=Share this Game
Exec=/usr/local/bin/partyos-share-game myapp
Icon=myicon
EXP
assert_eq "$(cat "${BAPP}")" "${EXP_APP//HOMEDIR/${HOME_DIR}}" "catalog launcher: exact Desktop Entry layout unchanged"

install -d "${ENVROOT}/mygame" "${HOME_DIR}/Desktop/.apps/Games"
{ printf 'name=%s\n' 'mygame'; printf 'title=%s\n' 'My Game'; printf 'exe=%s\n' 'g.exe'; } > "${ENVROOT}/mygame/env.meta"
rm -rf "${ENVROOT}/smash"   # only the benign env remains
cmd_gen_tiles
read -r -d '' EXP_TILE <<'EXP' || true
[Desktop Entry]
Type=Application
Name=My Game
Comment=partyOS - play your Windows game (mygame)
Exec=/usr/local/bin/partyos-proton-env play mygame
Path=HOMEDIR
Terminal=false
Icon=applications-other
Categories=Game;partyOS;
EXP
assert_eq "$(cat "${HOME_DIR}/Desktop/.apps/Games/My Game.desktop")" "${EXP_TILE//HOMEDIR/${HOME_DIR}}" \
    "play tile: exact Desktop Entry layout unchanged"

assert_summary "test-title-metachars" || exit 1
echo "test-title-metachars: ALL PASS"
