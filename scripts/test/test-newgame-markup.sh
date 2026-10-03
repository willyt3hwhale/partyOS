#!/usr/bin/env bash
# test-newgame-markup.sh - hardware-FREE tests for the zenity text of partyos-newgame.
# No VM, no network, no hardware.
#
# zenity reads --text as Pango markup. If the markup is not valid, zenity shows its
# default text (for example "All updates are complete."). A bare & in "Apps & Games",
# or a game name or engine message with &, < or >, makes the markup not valid.
#
# The test loads the functions of the REAL partyos-newgame (all lines before the main
# loop). It replaces zenity and the engine with stubs, runs each dialog path and
# parses the text of each dialog as markup.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

NEWGAME="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-newgame"
[ -f "${NEWGAME}" ] || { echo "FAIL: partyos-newgame baked file not found at ${NEWGAME}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-newgametest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- load the functions (all lines before the main loop) -------------------------
LIB="${TMPDIR_T}/newgame-lib.sh"
awk '/^while :; do/{exit} {print}' "${NEWGAME}" > "${LIB}"
grep -q '^do_choose() {' "${LIB}" || { echo "FAIL: do_choose not in the loaded part"; exit 1; }
# shellcheck disable=SC1090
source "${LIB}"

# --- stubs ------------------------------------------------------------------------
# The zenity stub writes the --text of each call to its own file ZDIR/<n>.<mode>.
# It answers a file selection with /tmp/x.exe and a list with ZEN_LIST_ANSWER.
ZDIR="${TMPDIR_T}/zen"
zenity() {
    local mode="" text="" a n
    for a in "$@"; do
        case "$a" in
            --text=*) text="${a#--text=}" ;;
            --error|--info|--question|--list|--progress|--entry|--file-selection) [ -n "${mode}" ] || mode="${a#--}" ;;
        esac
    done
    [ "${mode}" = "progress" ] && cat >/dev/null
    n="$(ls "${ZDIR}" | wc -l | tr -d ' ')"
    printf '%s' "${text}" > "${ZDIR}/$(printf '%03d' "${n}").${mode}"
    case "${mode}" in
        file-selection) echo "/tmp/x.exe" ;;
        list) printf '%s' "${ZEN_LIST_ANSWER:-}" ;;
        question) return 1 ;;
    esac
    return 0
}
# The engine stub: ENG_FAIL_MSG makes set-exe, create and import fail with that message.
ENGSTUB="${TMPDIR_T}/engine"
cat > "${ENGSTUB}" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    list) printf 'tom-jerry\tTom & Jerry\tready\n' ;;
    import) [ -z "${ENG_FAIL_MSG:-}" ] || { echo "PARTYOS-PENV ERROR ${ENG_FAIL_MSG}" >&2; exit 1; }
            echo "/tmp/imported/x.exe" ;;
    set-exe|create|remove)
            [ -z "${ENG_FAIL_MSG:-}" ] || { echo "PARTYOS-PENV ERROR ${ENG_FAIL_MSG}" >&2; exit 1; } ;;
esac
exit 0
EOF
chmod +x "${ENGSTUB}"
ENG="${ENGSTUB}"
export ENG_FAIL_MSG=""

markup_ok() { python3 -c 'import sys, xml.dom.minidom as m; m.parseString("<markup>" + sys.stdin.read() + "</markup>")' 2>/dev/null; }
unescape() { printf '%s' "$1" | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g'; }

# check_dialog LABEL MODE EXPECTED - the last dialog of MODE is valid markup and shows EXPECTED.
check_dialog() {
    local label="$1" mode="$2" want="$3" f txt
    f="$(ls "${ZDIR}"/*."${mode}" 2>/dev/null | tail -1)"
    [ -n "${f}" ] || { _assert_bad "${label}: no ${mode} dialog"; return; }
    txt="$(cat "${f}")"
    markup_ok <<< "${txt}"; assert_true $? "${label}: ${mode} text is valid markup"
    assert_contains "$(unescape "${txt}")" "${want}" "${label}: ${mode} text shows \"${want}\""
}
reset_zen() { rm -rf "${ZDIR}"; mkdir -p "${ZDIR}"; }

# --- the "Play now?" question after the choice of a program -----------------------
reset_zen; do_choose tom-jerry >/dev/null 2>&1
check_dialog "do_choose" question "A play tile was added to Apps & Games."

# --- the same question on the ready-to-run path -----------------------------------
reset_zen; ZEN_LIST_ANSWER="A single program (.exe)" do_portable tom-jerry >/dev/null 2>&1
check_dialog "do_portable" question "A play tile was added to Apps & Games."

# --- the packaging list shows the typed game name ---------------------------------
# The entry stub gives the name through ZEN_ENTRY; the list answer is empty (cancel).
zenity_entry_name='Tom & Jerry <2>'
eval "$(declare -f zenity | sed '1s/zenity/zenity_base/')"
zenity() { case " $* " in *" --entry "*) zenity_base "$@" >/dev/null; printf '%s' "${zenity_entry_name}"; return 0;; esac; zenity_base "$@"; }
reset_zen; ZEN_LIST_ANSWER="" do_create >/dev/null 2>&1
check_dialog "do_create" list "Env \"${zenity_entry_name}\" is ready."

# --- an engine error with &, < and > ----------------------------------------------
reset_zen; ENG_FAIL_MSG='bad path </x> & more' do_choose tom-jerry >/dev/null 2>&1
check_dialog "run_engine error" error "bad path </x> & more"
reset_zen; ENG_FAIL_MSG='no space <USB> & more' ZEN_LIST_ANSWER="" do_create >/dev/null 2>&1
check_dialog "do_create error" error "no space <USB> & more"

# --- the remove question and the "Removed" info -----------------------------------
reset_zen; ZEN_LIST_ANSWER="tom-jerry" do_manage >/dev/null 2>&1
check_dialog "do_manage" question "Remove the env \"tom-jerry\"?"

assert_summary "test-newgame-markup" || exit 1
echo "test-newgame-markup: ALL PASS"
