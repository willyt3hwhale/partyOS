#!/usr/bin/env bash
# test-config-seed-gate.sh - hardware-FREE unit test for the FIRST-RUN config-seed gate
# (partyos-seed-config). The baked seeder renders a server template into
# ~/.config/<app>/<out> exactly ONCE and must never clobber it again.
#
# THE BUG: the never-clobber gate keyed on the config DIRECTORY's existence, not on the
# completion SENTINEL (.partyos-seeded) it writes. install -d creates the dir BEFORE the
# config file + sentinel are written, so a transient first-run failure (fetch/write dies
# after the dir exists but before the sentinel) left the dir present with NO sentinel -
# and the dir-gate then skipped the seed FOREVER on that player's persistent USB home
# (nick/IRC/game preconfig permanently half-applied).
#
# THE FIX: gate on the sentinel (written LAST, only after a fully successful seed), so an
# interrupted seed RE-RUNS next launch, while a genuinely completed seed is still skipped.
#
# This EXTRACTS the real baked partyos-seed-config heredoc and drives it against a temp
# HOME with a local template, asserting: interrupted seed (dir, no sentinel) re-seeds;
# completed seed (sentinel present) is skipped + untouched; a fresh home seeds. Same
# extractive style as test-gen-guard / test-home-pull-gate. No VM, no network, no hardware.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

SEED_CONFIG="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-seed-config"
[ -f "${SEED_CONFIG}" ] || { echo "FAIL: partyos-seed-config baked file not found at ${SEED_CONFIG}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-seedgate.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- point at the baked partyos-seed-config -----------------------------------
SC_SH="${SEED_CONFIG}"
[ -s "${SC_SH}" ] || { echo "FAIL: partyos-seed-config baked file is empty (${SC_SH})"; exit 1; }
# the fix must be present in the carved source (guard against a silent revert to the
# dir-existence gate):
grep -q 'CONF_DIR}/.partyos-seeded' "${SC_SH}" \
    || { echo "FAIL: first-run gate is not keyed on the .partyos-seeded sentinel (reverted to the dir gate?)"; exit 1; }
grep -q '\[ -e "${CONF_DIR}" \]' "${SC_SH}" \
    && { echo "FAIL: carved seeder still gates on the bare CONF_DIR existence"; exit 1; }

# --- sandbox + stubs ------------------------------------------------------------
SHOME="${TMPDIR_T}/home"; install -d "${SHOME}"
SBIN="${TMPDIR_T}/bin";  install -d "${SBIN}"
cat > "${SBIN}/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
echo none   # -> SER=/dev/null; say() still echoes to stdout
EOF
chmod +x "${SBIN}/systemd-detect-virt"

# a local template with an @NICK@ placeholder (bare path -> the seeder cp's it, no curl).
TMPL="${TMPDIR_T}/servlist.conf.tmpl"
printf 'nick=@NICK@\nserver=@IRC_SERVER@\n' > "${TMPL}"

CDIR_NAME="openttd"                        # bare name -> ~/.config/openttd
CONF_DIR="${SHOME}/.config/${CDIR_NAME}"
OUT_REL="config.cfg"
DEST="${CONF_DIR}/${OUT_REL}"
SENTINEL="${CONF_DIR}/.partyos-seeded"
SEED_OUT="${TMPDIR_T}/seed.out"

# run the carved seeder. NICK is passed as a cmdline override so the render is
# deterministic regardless of any /run/partyos-* files on the host.
run_seed() {
    HOME="${SHOME}" PATH="${SBIN}:${PATH}" \
        bash "${SC_SH}" "${CDIR_NAME}" "${TMPL}" "${OUT_REL}" NICK=testnick IRC_SERVER=irc.party \
        >"${SEED_OUT}" 2>&1
}
reset_home() { rm -rf "${CONF_DIR}"; }

echo "================ 1. fresh home (no dir) -> SEEDS ================"
reset_home
run_seed
assert_true  "$([ -f "${DEST}" ]; echo $?)"      "fresh: config file rendered"
assert_true  "$([ -f "${SENTINEL}" ]; echo $?)"  "fresh: completion sentinel written"
assert_contains "$(cat "${DEST}")" "nick=testnick" "fresh: @NICK@ substituted"
assert_contains "$(cat "${SEED_OUT}")" "PARTYOS-SEED-OK" "fresh: logs PARTYOS-SEED-OK"
assert_not_contains "$(cat "${SEED_OUT}")" "PARTYOS-SEED-SKIP" "fresh: does NOT log SKIP"

echo
echo "================ 2. completed seed (sentinel present) -> SKIPPED ="
# a fully-seeded home carries the sentinel; a second launch must NOT touch the config.
reset_home
install -d "${CONF_DIR}"
printf 'USER-EDITED-DO-NOT-CLOBBER\n' > "${DEST}"   # the player's own edits
: > "${SENTINEL}"                                    # completion sentinel present
run_seed
assert_contains "$(cat "${SEED_OUT}")" "PARTYOS-SEED-SKIP" "completed: logs PARTYOS-SEED-SKIP (already configured)"
assert_not_contains "$(cat "${SEED_OUT}")" "PARTYOS-SEED-OK" "completed: does NOT re-seed"
assert_eq "$(cat "${DEST}")" "USER-EDITED-DO-NOT-CLOBBER" "completed: existing config left byte-untouched (never clobbered)"

echo
echo "================ 3. interrupted seed (dir, NO sentinel) -> RE-SEEDS ="
# THE POISON CASE: install -d created the dir on a failed first run, but the sentinel was
# never written. The OLD dir-gate skipped forever; the sentinel gate must re-run the seed.
reset_home
install -d "${CONF_DIR}"        # dir present (left by the interrupted first run)...
[ -e "${SENTINEL}" ] && { echo "FAIL: sentinel unexpectedly present in poison setup"; exit 1; }
run_seed
assert_true  "$([ -f "${DEST}" ]; echo $?)"     "poisoned: config file RE-rendered (not skipped forever)"
assert_true  "$([ -f "${SENTINEL}" ]; echo $?)" "poisoned: sentinel now written (seed completed on retry)"
assert_contains "$(cat "${SEED_OUT}")" "PARTYOS-SEED-OK" "poisoned: logs PARTYOS-SEED-OK on the retry"

echo
echo "================ 4. dir + STALE partial config, NO sentinel -> RE-SEEDS ="
# a half-written config file from the failed run + no sentinel: the retry must overwrite
# the partial and write the sentinel (not leave a half-config forever).
reset_home
install -d "${CONF_DIR}"
printf 'HALF-WRITTEN-@NICK@\n' > "${DEST}"    # partial render from the interrupted run
run_seed
assert_contains "$(cat "${SEED_OUT}")" "PARTYOS-SEED-OK" "stale-partial: re-seeds"
assert_eq "$(cat "${DEST}")" "$(printf 'nick=testnick\nserver=irc.party')" "stale-partial: partial config replaced by the full render"
assert_true  "$([ -f "${SENTINEL}" ]; echo $?)" "stale-partial: sentinel written after the successful retry"

echo
echo "================ 5. two templates -> BOTH files, then the sentinel ="
# config_template/config_out can be space-separated lists (SuperTuxKart needs
# players.xml and config.xml). Every file is rendered before the sentinel.
reset_home
TMPL2="${TMPDIR_T}/second.tmpl"
printf 'second=@NICK@\n' > "${TMPL2}"
HOME="${SHOME}" PATH="${SBIN}:${PATH}" \
    bash "${SC_SH}" "${CDIR_NAME}" "${TMPL} ${TMPL2}" "${OUT_REL} sub/second.cfg" NICK=testnick IRC_SERVER=irc.party \
    >"${SEED_OUT}" 2>&1
assert_contains "$(cat "${DEST}" 2>/dev/null)" "nick=testnick" "two: first file rendered"
assert_eq "$(cat "${CONF_DIR}/sub/second.cfg" 2>/dev/null)" "second=testnick" "two: second file rendered in its subdir"
assert_true "$([ -f "${SENTINEL}" ]; echo $?)" "two: sentinel written"

echo
echo "================ 6. one template missing -> NOTHING written, ERR logged ="
reset_home
HOME="${SHOME}" PATH="${SBIN}:${PATH}" \
    bash "${SC_SH}" "${CDIR_NAME}" "${TMPL} ${TMPDIR_T}/missing.tmpl" "${OUT_REL} second.cfg" NICK=testnick \
    >"${SEED_OUT}" 2>&1; rc=$?
assert_false "${rc}" "missing: seeder exits non-zero"
assert_contains "$(cat "${SEED_OUT}")" "PARTYOS-SEED-ERR" "missing: logs PARTYOS-SEED-ERR"
assert_false "$([ -f "${DEST}" ]; echo $?)" "missing: first file NOT written"
assert_false "$([ -f "${SENTINEL}" ]; echo $?)" "missing: no sentinel, so the next launch tries again"

assert_summary "test-config-seed-gate" || exit 1
echo "test-config-seed-gate: ALL PASS"
