#!/usr/bin/env bash
# test-appstore-unlock.sh - hardware-FREE unit tests for the app-store "Enter a Code"
# hidden-blob unlock feature in partyos-app (baked from
# scripts/build/files/rootfs/usr/local/bin/partyos-app). No VM, no network, no hardware.
#
# The feature: a hidden catalog row may carry a short "unlock_code". A guest enters that
# code in the store; every hidden blob whose unlock_code matches (case-INSENSITIVE,
# whitespace-TRIMMED) is REVEALED and the accepted code is PERSISTED to the player's USB
# home so the unlock survives reboot. A shared code reveals a group; a unique code reveals
# one blob. A wrong code reveals nothing.
#
# We carve the REAL norm_code / is_code_unlocked / cmd_unlock_code out of partyos-app
# and drive them the same carve-and-mock way test-cache-policy.sh / test-home-select.sh do:
# stub the catalog (load_catalog no-op + synthetic C_* arrays) + say + cmd_gen_launchers,
# point UNLOCK_FILE at a temp home, and assert the match / persist / reveal behaviour. The
# reveal filter is exercised through the REAL is_code_unlocked reading the REAL persisted
# file (not a pure mock).
#
# Covers:
#   * a hidden blob is EXCLUDED by default (reveal gate hides it, no persisted code),
#   * entering its unlock_code (case-insensitive, trimmed) ADDS it to the unlocked set and
#     the reveal gate now SHOWS it,
#   * a WRONG code reveals nothing and persists nothing,
#   * a SHARED code reveals ALL blobs carrying that code (group unlock),
#   * an EMPTY code is rejected,
#   * the persisted-set format round-trips (one normalized code per line, deduped),
#   * infra hidden rows (no unlock_code) stay invisible under every code,
#   * the build carries the wired reveal filter + install gate + tile + GUI + catalog code.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

PAPP="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-app"
[ -f "${PAPP}" ] || { echo "FAIL: partyos-app baked file not found at ${PAPP}"; exit 1; }
UNLOCK_GUI="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-unlock"
[ -f "${UNLOCK_GUI}" ] || { echo "FAIL: partyos-unlock baked file not found at ${UNLOCK_GUI}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-unlocktest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- point at the baked partyos-app -------------------------------------------
PAPP_BODY="${PAPP}"
[ -s "${PAPP_BODY}" ] || { echo "FAIL: partyos-app baked file is empty (${PAPP_BODY})"; exit 1; }

# --- carve the REAL unlock helpers (each def -> its col-0 closing brace) -------
UNLOCKLIB="${TMPDIR_T}/unlocklib.sh"
awk '/^norm_code\(\) \{/{g=1} g{print} g&&/^\}/{exit}'        "${PAPP_BODY}" >  "${UNLOCKLIB}"
awk '/^is_code_unlocked\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "${PAPP_BODY}" >> "${UNLOCKLIB}"
awk '/^cmd_unlock_code\(\) \{/{g=1} g{print} g&&/^\}/{exit}'  "${PAPP_BODY}" >> "${UNLOCKLIB}"
grep -q '^norm_code() {'        "${UNLOCKLIB}" || { echo "FAIL: norm_code not in carve"; exit 1; }
grep -q '^is_code_unlocked() {' "${UNLOCKLIB}" || { echo "FAIL: is_code_unlocked not in carve"; exit 1; }
grep -q '^cmd_unlock_code() {'  "${UNLOCKLIB}" || { echo "FAIL: cmd_unlock_code not in carve"; exit 1; }

# --- harness: temp home + stubs -----------------------------------------------
HOME_T="${TMPDIR_T}/home"; mkdir -p "${HOME_T}/.config"
UNLOCK_FILE="${HOME_T}/.config/partyos/unlocked-codes"
APP_USER="$(id -un)"
SAY_LOG=""
say() { SAY_LOG="${SAY_LOG}${SAY_LOG:+|}$*"; }
# load_catalog is a NO-OP that keeps our pre-set C_* arrays (the real one would refetch).
load_catalog() { return 0; }
# cmd_gen_launchers is stubbed to a marker file so we can assert it fires only on success.
GEN_MARK="${TMPDIR_T}/gen-called"
cmd_gen_launchers() { : > "${GEN_MARK}"; return 0; }
gen_reset() { rm -f "${GEN_MARK}"; }
GEN_CALLED() { if [ -e "${GEN_MARK}" ]; then echo 1; else echo 0; fi; }

# The reveal gate MIRRORS the gen-launchers hidden filter, but runs the REAL
# is_code_unlocked against the REAL persisted file - so it validates the actual
# membership logic, not a re-implementation. Returns 0 = show tile, 1 = hide.
reveal_gate() {
    local idx="$1"
    if [ "${C_HIDDEN[$idx]:-false}" = "true" ]; then
        if [ -n "${C_UNLOCK[$idx]:-}" ] && is_code_unlocked "${C_UNLOCK[$idx]}"; then
            return 0
        fi
        return 1
    fi
    return 0
}

declare -a C_NAME C_HIDDEN C_UNLOCK
# shellcheck disable=SC1090
source "${UNLOCKLIB}"

# =====================================================================
echo "================ A: norm_code (case-insensitive + trimmed) ===="
assert_eq "$(norm_code 'WC3')"      "wc3" "A: norm_code lowercases"
assert_eq "$(norm_code '  wc3  ')"  "wc3" "A: norm_code trims surrounding whitespace"
assert_eq "$(norm_code $'\t ViP\t')" "vip" "A: norm_code trims tabs + lowercases"
assert_eq "$(norm_code 'wc3')"      "wc3" "A: norm_code is idempotent on canonical form"

# =====================================================================
echo "================ B: is_code_unlocked membership =============="
rm -f "${UNLOCK_FILE}"; mkdir -p "${UNLOCK_FILE%/*}"
is_code_unlocked "wc3"; assert_false $? "B: missing set file -> nothing unlocked"
printf '%s\n' "wc3" > "${UNLOCK_FILE}"
is_code_unlocked "wc3";   assert_true  $? "B: exact stored code is unlocked"
is_code_unlocked "WC3";   assert_true  $? "B: stored code matches case-insensitively"
is_code_unlocked " wc3 "; assert_true  $? "B: stored code matches after trimming"
is_code_unlocked "xyz";   assert_false $? "B: unrelated code is NOT unlocked"
is_code_unlocked "";      assert_false $? "B: empty query is NOT unlocked"

# =====================================================================
echo "================ C: cmd_unlock_code match/persist/reveal ====="
# Synthetic catalog: a visible game, a uniquely-coded hidden game, a SHARED-code pair
# (one authored uppercase to prove catalog-side normalization), an infra hidden row with
# NO code, and a hidden game whose code is never entered.
#         idx: 0        1       2       3       4        5
C_NAME=(  "warsow" "wc3"   "vipA"  "vipB"  "infra"  "locked" )
C_HIDDEN=( "false" "true"  "true"  "true"  "true"   "true"   )
C_UNLOCK=( ""      "wc3"   "vip"   "VIP"   ""       "xyz"    )

# Baseline: nothing entered yet -> every hidden row is hidden, visible row is shown.
rm -f "${UNLOCK_FILE}"
reveal_gate 0; assert_true  $? "C: visible row (warsow) is always shown"
reveal_gate 1; assert_false $? "C: hidden wc3 is EXCLUDED by default"
reveal_gate 2; assert_false $? "C: hidden vipA is EXCLUDED by default"
reveal_gate 4; assert_false $? "C: infra hidden row is EXCLUDED by default"

# Empty code -> rejected, nothing persisted, launchers NOT regenerated.
gen_reset; SAY_LOG=""
cmd_unlock_code ""; rc=$?
assert_eq "${rc}" "2" "C: empty code is rejected (rc 2)"
assert_contains "${SAY_LOG}" "PARTYOS-APP-UNLOCK-INVALID" "C: empty code logs INVALID"
assert_eq "$(GEN_CALLED)" "0" "C: empty code does NOT regen launchers"
[ ! -f "${UNLOCK_FILE}" ]; assert_true $? "C: empty code persists nothing"

# Wrong code -> no match, rc 3, nothing persisted, no reveal.
gen_reset; SAY_LOG=""
cmd_unlock_code "nope"; rc=$?
assert_eq "${rc}" "3" "C: non-matching code returns rc 3"
assert_contains "${SAY_LOG}" "PARTYOS-APP-UNLOCK-INVALID" "C: wrong code logs INVALID"
assert_eq "$(GEN_CALLED)" "0" "C: wrong code does NOT regen launchers"
[ ! -s "${UNLOCK_FILE}" 2>/dev/null ] || [ ! -f "${UNLOCK_FILE}" ]
assert_true $? "C: wrong code persists nothing"

# Correct UNIQUE code (entered uppercase + padded) -> unlock wc3 only.
gen_reset; SAY_LOG=""
cmd_unlock_code "  WC3 "; rc=$?
assert_eq "${rc}" "0" "C: matching unique code returns rc 0"
assert_contains "${SAY_LOG}" "PARTYOS-APP-UNLOCK-OK" "C: match logs UNLOCK-OK"
assert_contains "${SAY_LOG}" "names=wc3" "C: unique code names exactly wc3"
assert_eq "$(GEN_CALLED)" "1" "C: a successful unlock regenerates launchers"
reveal_gate 1; assert_true  $? "C: wc3 is REVEALED after its code is entered"
reveal_gate 2; assert_false $? "C: an unrelated hidden row stays hidden"
reveal_gate 5; assert_false $? "C: a still-locked hidden row stays hidden"

# SHARED code -> reveal BOTH vipA and vipB (group unlock), catalog-side case-insensitive.
gen_reset; SAY_LOG=""
cmd_unlock_code "vip"; rc=$?
assert_eq "${rc}" "0" "C: shared code returns rc 0"
assert_contains "${SAY_LOG}" "names=vipA vipB" "C: shared code names BOTH group members"
reveal_gate 2; assert_true $? "C: vipA revealed by the shared code"
reveal_gate 3; assert_true $? "C: vipB (authored uppercase) revealed by the shared code"
reveal_gate 4; assert_false $? "C: infra hidden row (no code) is NEVER revealed"

# =====================================================================
echo "================ D: persisted-set format round-trips ========="
# Exactly two normalized codes, one per line, in entry order.
mapfile -t LINES < "${UNLOCK_FILE}"
assert_eq "${#LINES[@]}" "2" "D: persisted set holds exactly two codes"
assert_eq "${LINES[0]}" "wc3" "D: first persisted code is normalized (wc3)"
assert_eq "${LINES[1]}" "vip" "D: second persisted code is normalized (vip)"
# Re-entering an already-accepted code (different case) must NOT duplicate the line.
cmd_unlock_code "Wc3" >/dev/null 2>&1
assert_eq "$(grep -cxF 'wc3' "${UNLOCK_FILE}")" "1" "D: re-entering a code does not duplicate it"
# The persisted set is read back correctly by a FRESH is_code_unlocked call.
is_code_unlocked "VIP"; assert_true $? "D: persisted set round-trips (VIP resolves)"

# =====================================================================
echo "================ E: build-custom-image wiring is present ====="
# Parser passes unlock_code through (parallel array stays rectangular).
grep -q 'sval(obj,"unlock_code")' "${PAPP_BODY}" || _assert_bad "E: parser does not emit unlock_code"
grep -q 'C_UNLOCK+=' "${PAPP_BODY}" && _assert_ok "E: parser fills C_UNLOCK" \
    || _assert_bad "E: parser does not fill C_UNLOCK"

# gen-launchers reveal filter: a hidden row is revealed iff its code is unlocked.
awk '/^cmd_gen_launchers\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "${PAPP_BODY}" > "${TMPDIR_T}/gen.sh"
grep -q 'is_code_unlocked "${C_UNLOCK\[$i\]}"' "${TMPDIR_T}/gen.sh" \
    && _assert_ok "E: gen-launchers reveals unlocked hidden rows" \
    || _assert_bad "E: gen-launchers reveal filter missing"

# cmd_install gate: hidden rows still blocked, EXCEPT when unlocked by code.
awk '/^cmd_install\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "${PAPP_BODY}" > "${TMPDIR_T}/inst.sh"
grep -q 'PARTYOS-APP-HIDDEN-BLOCKED' "${TMPDIR_T}/inst.sh" \
    && _assert_ok "E: cmd_install keeps the hidden gate" \
    || _assert_bad "E: cmd_install lost the hidden gate"
grep -q 'is_code_unlocked' "${TMPDIR_T}/inst.sh" \
    && _assert_ok "E: cmd_install lets an unlocked hidden row install by name" \
    || _assert_bad "E: cmd_install gate ignores the unlock set"

# The store tile was REPLACED: Enter-a-Code in, Load-from-URL tile out. The tile is
# written by partyos-app's launcher generator (baked file).
grep -qF 'Enter a Code.desktop' "${PAPP}" && _assert_ok "E: 'Enter a Code' tile is written" \
    || _assert_bad "E: 'Enter a Code' tile missing"
grep -qF 'Exec=/usr/local/bin/partyos-unlock' "${PAPP}" && _assert_ok "E: tile execs partyos-unlock" \
    || _assert_bad "E: tile does not exec partyos-unlock"
if grep -qF 'Load from URL.desktop' "${PAPP}"; then
    _assert_bad "E: old 'Load from URL' tile still present (should be replaced)"
else
    _assert_ok "E: old 'Load from URL' tile is gone"
fi

# The GUI front door is a baked file that calls the backend (same path as a headless test).
[ -s "${UNLOCK_GUI}" ] && _assert_ok "E: partyos-unlock GUI is baked" \
    || _assert_bad "E: partyos-unlock GUI not baked"
grep -q 'partyos-app unlock-code' "${UNLOCK_GUI}" && _assert_ok "E: partyos-unlock calls the backend" \
    || _assert_bad "E: partyos-unlock does not call the backend"
grep -q 'unlock-code)' "${PAPP}" && _assert_ok "E: partyos-app dispatches unlock-code" \
    || _assert_bad "E: partyos-app has no unlock-code dispatch"

# The "Unlocked" dialog text must be valid Pango markup. If it is not, zenity shows its
# default text "All updates are complete.".
# Run partyos-unlock with stubs for zenity, notify-send and partyos-app.
GUI_BIN="${TMPDIR_T}/guibin"; mkdir -p "${GUI_BIN}"
ZEN_LOG="${TMPDIR_T}/zenity-info-text"
cat > "${GUI_BIN}/zenity" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --entry "*) echo NYET; exit 0;; esac
for a in "$@"; do case "$a" in --text=*) printf '%s' "${a#--text=}" > "${ZEN_LOG}";; esac; done
exit 0
EOF
cat > "${GUI_BIN}/partyos-app" <<'EOF'
#!/usr/bin/env bash
echo "PARTYOS-APP-UNLOCK-OK n=3 names=${SIM_NAMES}"
EOF
printf '#!/bin/sh\nexit 0\n' > "${GUI_BIN}/notify-send"
chmod +x "${GUI_BIN}"/*
markup_ok() { python3 -c 'import sys, xml.dom.minidom as m; m.parseString("<markup>" + sys.stdin.read() + "</markup>")' 2>/dev/null; }
for sim in "wc3 flatout2 haloce" "a&b <c>"; do
    rm -f "${ZEN_LOG}"
    ZEN_LOG="${ZEN_LOG}" SIM_NAMES="${sim}" PATH="${GUI_BIN}:${PATH}" bash "${UNLOCK_GUI}" >/dev/null 2>&1
    txt="$(cat "${ZEN_LOG}" 2>/dev/null)"
    markup_ok <<< "${txt}"; assert_true $? "E: unlock dialog text is valid markup (names: ${sim})"
    unesc="$(printf '%s' "${txt}" | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g')"
    assert_contains "${unesc}" "Unlocked: ${sim}" "E: unlock dialog shows the unlocked names (${sim})"
    assert_contains "${unesc}" "Apps & Games" "E: unlock dialog says where the games are (${sim})"
done

# The catalog carries a documented example: a hidden row gated behind an unlock_code.
grep -q '"unlock_code"' "${REPO_ROOT}/server/games/catalog.v2.json" \
    && _assert_ok "E: catalog.v2.json documents a gated hidden blob (unlock_code)" \
    || _assert_bad "E: catalog.v2.json has no unlock_code example"

assert_summary "test-appstore-unlock" || exit 1
echo "test-appstore-unlock: ALL PASS"
