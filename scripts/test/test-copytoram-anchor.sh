#!/usr/bin/env bash
# test-copytoram-anchor.sh - hardware-FREE unit test for the fatal-anchor fix: the copytoram
# curl-retry/watchdog override in scripts/build/phases/a5-eggs-splash-initramfs.sh is
# sed-anchored to archiso's EXACT `curl -L -f -o "/run/archiso/httpspace` fetch string.
# A future archiso
# bump that changes that line would make the anchor miss, silently shipping an initramfs
# with no copytoram retry/watchdog -> the original boot-wedge returns untested.
#
# The bug this guards: the not-applied branches used to WARN-and-continue, so a
# missed anchor (or a missing hook file) shipped a broken initramfs unnoticed. The fix
# makes BOTH not-applied paths FATAL (echo ERROR >&2; exit 1) so a future archiso change
# fails the build loudly instead of regressing the boot.
#
# This test carves the `if [ -f "${_PXE_HTTP}" ] ... fi` decision block out of the
# a5-eggs-splash-initramfs phase (the same heredoc/region-carve idiom as the other prod tests),
# drives it with a synthetic _PXE_HTTP file, and asserts:
#   * anchor PRESENT  -> exit 0  AND the retry/watchdog flags are injected into the file.
#   * anchor ABSENT   -> exit non-zero (FATAL), file NOT silently shipped unhardened.
#   * file MISSING    -> exit non-zero (FATAL).
#   * already-applied -> exit 0, idempotent skip (flags present, not double-injected).
# No VM, no network, no hardware - pure shell.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

# The copytoram retry override lives in the a5-eggs-splash-initramfs phase.
PHASE="${REPO_ROOT}/scripts/build/phases/a5-eggs-splash-initramfs.sh"
[ -f "${PHASE}" ] || { echo "FAIL: a5-eggs-splash-initramfs.sh not found at ${PHASE}"; exit 1; }
CA_CONF="${REPO_ROOT}/scripts/build/files/rootfs/etc/mkinitcpio.conf.d/partyos-ca.conf"
[ -f "${CA_CONF}" ] || { echo "FAIL: partyos-ca.conf not found at ${CA_CONF}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-anchor-test.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- carve the copytoram anchor-application decision block ---------------------------
# The block starts at the `if [ -f "${_PXE_HTTP}" ]; then` line and ends at the matching
# top-level `fi`. We extract that exact region; the test supplies _PXE_HTTP + _RETRY_FLAGS.
BLOCK="${TMPDIR_T}/anchor-block.sh"
awk '/^if \[ -f "\$\{_PXE_HTTP\}" \]; then$/{f=1} f{print} f&&/^fi$/{exit}' "${PHASE}" > "${BLOCK}"
[ -s "${BLOCK}" ] || { echo "FAIL: could not carve the copytoram anchor block from a5-eggs-splash-initramfs.sh"; exit 1; }
# sanity: the carved block must contain the sed override + the fatal exits.
grep -q 'speed-time' "${BLOCK}"  || { echo "FAIL: carved block missing the retry-flags sed"; exit 1; }
grep -q 'exit 1'     "${BLOCK}"  || { echo "FAIL: carved block missing the fatal exit (already-WARN path?)"; exit 1; }

# The retry flags the real build uses (kept identical to build-custom-image.sh; the test
# only checks they LAND, not their exact values). --cacert makes the HTTPS
# copytoram sfs fetch validate the CA bundled into the initramfs at /etc/partyos/ca.pem.
RFLAGS='--retry 5 --retry-connrefused --retry-delay 2 --connect-timeout 20 --speed-limit 1024 --speed-time 120 --cacert /etc/partyos/ca.pem'

# The carved block uses GNU `sed -i "EXPR" FILE` (the real build runs on Linux/arch-chroot).
# BSD sed (macOS test host) reads `-i` as a backup-suffix and chokes. So when the host sed
# is NOT GNU, drop a tiny GNU-compatible `sed` shim on PATH for the block - it rewrites the
# `-i EXPR` invocation into the BSD `-i '' EXPR` form. The carved code stays byte-for-byte
# the real build code; only the host tool is adapted. On a Linux/GNU host this is a no-op.
SHIM_BIN="${TMPDIR_T}/bin"
if ! sed --version >/dev/null 2>&1; then
    install -d "${SHIM_BIN}"
    cat > "${SHIM_BIN}/sed" <<'SHIM'
#!/usr/bin/env bash
# GNU-sed -i shim over BSD sed: turn `sed -i EXPR ...` into `sed -i '' EXPR ...`.
if [ "${1:-}" = "-i" ] && [ -n "${2:-}" ] && [ "${2:0:1}" != "-" ] && [ ! -f "${2}" ]; then
    expr="$2"; shift 2
    exec /usr/bin/sed -i '' "${expr}" "$@"
fi
exec /usr/bin/sed "$@"
SHIM
    chmod +x "${SHIM_BIN}/sed"
fi

# run_block PXE_HTTP_PATH -> runs the carved block with the given _PXE_HTTP; echoes the
# exit code on the LAST line, stdout/err above it. Isolated subshell so its `exit` only
# leaves the subshell, never this test. PATH carries the GNU-sed shim first (if needed).
run_block() {
    local rc
    ( set +e; [ -d "${SHIM_BIN}" ] && PATH="${SHIM_BIN}:${PATH}"
      _PXE_HTTP="$1"; _RETRY_FLAGS="${RFLAGS}"; . "${BLOCK}" ) >/dev/null 2>&1
    rc=$?
    echo "${rc}"
}

# --- archiso stock hook FIXTURE (the real anchor line) ------------------------
ANCHOR_LINE='    _curl_get() { curl -L -f -o "/run/archiso/httpspace/${1##*/}" "$1"; }'
make_stock() { printf '#!/bin/bash\n# fake archiso_pxe_http\n%s\n' "${ANCHOR_LINE}" > "$1"; }

# 1) ANCHOR PRESENT -> succeeds + flags injected ------------------------------
GOOD="${TMPDIR_T}/hook-good"
make_stock "${GOOD}"
rc="$(run_block "${GOOD}")"
assert_eq "${rc}" "0" "anchor present: build block exits 0 (override applied)"
assert_contains "$(cat "${GOOD}")" "--speed-time 120" "anchor present: retry/watchdog flags injected into the hook"
assert_contains "$(cat "${GOOD}")" "--retry 5"         "anchor present: --retry baked in"
# The sfs _curl_get must validate the pinned CA bundled into the initramfs.
assert_contains "$(cat "${GOOD}")" "--cacert /etc/partyos/ca.pem" "anchor present: --cacert pins the bundled CA on the HTTPS sfs fetch"

# 2) ALREADY APPLIED -> idempotent skip, still exit 0, no double-inject --------
rc="$(run_block "${GOOD}")"   # GOOD now already has the flags from step 1
assert_eq "${rc}" "0" "already-applied: idempotent re-run exits 0 (skip)"
inject_count="$(grep -o -- '--speed-time' "${GOOD}" | wc -l | tr -d ' ')"
assert_eq "${inject_count}" "1" "already-applied: flags present exactly once (no double-inject)"

# 3) ANCHOR ABSENT -> FATAL ---------------------------------------------------
# A plausible future archiso: same hook, but the fetch line no longer matches the anchor.
BAD="${TMPDIR_T}/hook-bad"
printf '#!/bin/bash\n# future archiso_pxe_http with a CHANGED fetch line\n    _curl_get() { curl --location --fail --output "/run/archiso/httpspace/${1##*/}" "$1"; }\n' > "${BAD}"
rc="$(run_block "${BAD}")"
assert_false "${rc}" "anchor ABSENT: build block FAILS HARD (no silent WARN-and-ship)"
assert_not_contains "$(cat "${BAD}")" "--speed-time" "anchor ABSENT: the unhardened hook was NOT mutated"

# 4) HOOK FILE MISSING -> FATAL -----------------------------------------------
rc="$(run_block "${TMPDIR_T}/does-not-exist")"
assert_false "${rc}" "hook MISSING: build block FAILS HARD"

# 5) CA-into-initramfs mechanism (static source assertions) -----------
# The HTTPS sfs fetch needs the pinned CA present in the INITRAMFS (archiso_pxe_http
# runs pre-rootfs), at the SAME path --cacert points at. The build must
# (a) emit a FILES+= drop-in adding /etc/partyos/ca.pem to the initramfs, AND that
# path must MATCH the --cacert path the _curl_get override uses. The drop-in is now a
# baked rootfs file (partyos-ca.conf) that the a5 phase installs via `bake`; assert the
# FILES+= line from the baked conf and the retry flags + bake reference from the phase,
# so a future edit that drifts the path (CA bundled at X, curl pins Y) is caught here,
# not by a dead cold-boot.
CA_CONF_SRC="$(cat "${CA_CONF}")"
PHASE_SRC="$(cat "${PHASE}")"
assert_contains "${CA_CONF_SRC}" "FILES+=(/etc/partyos/ca.pem)" "CA bundle: baked drop-in bundles the CA into the initramfs (FILES+=)"
assert_contains "${PHASE_SRC}" "mkinitcpio.conf.d/partyos-ca.conf" "CA bundle: CA drop-in is a dedicated conf.d snippet baked by the a5 phase (orthogonal to archiso config)"
assert_contains "${PHASE_SRC}" "_RETRY_FLAGS='--retry 5 --retry-connrefused --retry-delay 2 --connect-timeout 20 --speed-limit 1024 --speed-time 120 --cacert /etc/partyos/ca.pem'" "CA bundle: --cacert path in _curl_get MATCHES the bundled CA path (/etc/partyos/ca.pem)"

assert_summary "test-copytoram-anchor"
