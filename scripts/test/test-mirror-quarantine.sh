#!/usr/bin/env bash
# test-mirror-quarantine.sh - regression test for the LAN-mirror quarantine step
# (scripts/build/mirror-quarantine.sh). A keyring drift must never wipe the
# whole published mirror.
#
# The quarantine checks only the packages this run added, and keeps each moved .sig.
#
# This test drives the REAL helper with an injected mock verifier that simulates a
# keyring drift (it would reject a pre-existing package too) and asserts:
#   - a pre-existing package that the verifier would reject survives, because it is
#     not in the new-list.
#   - a newly-added package that passes stays in the mirror.
#   - a newly-added package that fails is moved to .revoked-signer/ WITH its .sig kept
#     (not deleted) so the move is reversible.
# Hardware-free, off-Arch: no docker, no pacman, no network.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

HELPER="${REPO_ROOT}/scripts/build/mirror-quarantine.sh"
[ -f "${HELPER}" ] || { echo "FAIL: helper not found at ${HELPER}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-mirrorq-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

MIRROR="${TMP}/lanmirror"
mkdir -p "${MIRROR}"

# --- fixture mirror -----------------------------------------------------------
# Two pre-existing (already-published) packages + two newly-added ones. Each has a
# matching detached .sig, like the real mirror. The mock verifier below rejects any
# path whose name contains "REVOKED".
mk() { : > "${MIRROR}/$1"; : > "${MIRROR}/$1.sig"; }
mk "existing-good-1.0-1-x86_64.pkg.tar.zst"      # pre-existing, would verify fine
mk "existing-REVOKED-1.0-1-x86_64.pkg.tar.zst"   # pre-existing, drift makes it "fail"
mk "new-good-2.0-1-x86_64.pkg.tar.zst"           # newly added, verifies fine
mk "new-REVOKED-2.0-1-x86_64.pkg.tar.zst"        # newly added, genuinely unverifiable

# the newly-added closure for THIS run (never lists the pre-existing packages).
cat > "${TMP}/new.list" <<'EOF'
new-good-2.0-1-x86_64.pkg.tar.zst
new-REVOKED-2.0-1-x86_64.pkg.tar.zst
EOF

# mock verifier: rejects anything with REVOKED in its name (simulates a signer the
# keyring rejects). It WOULD reject existing-REVOKED too - proving the survival of that
# file is purely due to scoping, not the verifier being lenient.
MOCK="${TMP}/mock-verify.sh"
cat > "${MOCK}" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *REVOKED*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${MOCK}"

# --- run the REAL helper with the mock verifier -------------------------------
count="$(VERIFY_CMD="${MOCK}" bash "${HELPER}" "${MIRROR}" "${TMP}/new.list")"; rc=$?
assert_eq "${rc}" "0" "helper exits 0"
assert_eq "${count}" "1" "helper reports exactly 1 quarantined (only the failing NEW package)"

present() { [ -f "${MIRROR}/$1" ]; }
revoked() { [ -f "${MIRROR}/.revoked-signer/$1" ]; }

# THE regression guard: a pre-existing package the verifier would reject is NEVER
# touched, because it is not in the new-list. The old whole-mirror loop quarantined it.
assert_true "$(present 'existing-REVOKED-1.0-1-x86_64.pkg.tar.zst'; echo $?)" \
  "pre-existing 'REVOKED' package SURVIVES (scoped out, never re-verified) - the whole-mirror nuke is gone"
assert_true "$(present 'existing-REVOKED-1.0-1-x86_64.pkg.tar.zst.sig'; echo $?)" \
  "pre-existing package .sig is untouched"
assert_true "$(present 'existing-good-1.0-1-x86_64.pkg.tar.zst'; echo $?)" \
  "other pre-existing package is untouched"

# a passing newly-added package stays.
assert_true "$(present 'new-good-2.0-1-x86_64.pkg.tar.zst'; echo $?)" \
  "newly-added verifiable package stays in the mirror"
assert_true "$(present 'new-good-2.0-1-x86_64.pkg.tar.zst.sig'; echo $?)" \
  "newly-added verifiable package keeps its .sig"

# a failing newly-added package is quarantined WITH its .sig kept (reversible).
assert_false "$(present 'new-REVOKED-2.0-1-x86_64.pkg.tar.zst'; echo $?)" \
  "genuinely-unverifiable newly-added package is removed from the served mirror"
assert_true "$(revoked 'new-REVOKED-2.0-1-x86_64.pkg.tar.zst'; echo $?)" \
  "quarantined package is moved to .revoked-signer/"
assert_true "$(revoked 'new-REVOKED-2.0-1-x86_64.pkg.tar.zst.sig'; echo $?)" \
  "quarantined package .sig is KEPT (moved, not deleted) so the move is reversible"

# --- empty new-list: nothing to do, mirror untouched --------------------------
: > "${TMP}/empty.list"
count2="$(VERIFY_CMD="${MOCK}" bash "${HELPER}" "${MIRROR}" "${TMP}/empty.list")"
assert_eq "${count2}" "0" "empty new-list quarantines nothing"
assert_true "$(present 'existing-good-1.0-1-x86_64.pkg.tar.zst'; echo $?)" \
  "empty new-list leaves the mirror fully intact"

# --- default VERIFY_CMD: a missing dependency is not a bad signature -----------
# The default verifier once stopped at the dependency check (the container does not
# have the deps of new packages installed) and quarantined correctly signed packages. This fake pacman acts like the real one:
# without --nodeps --nodeps it fails on the missing deps, before the signature check.
# With -dd it checks only the signature and rejects a REVOKED name.
FAKEBIN="${TMP}/fakebin"
mkdir -p "${FAKEBIN}"
cat > "${FAKEBIN}/pacman" <<'EOF2'
#!/usr/bin/env bash
nd=0; pr=0
for a in "$@"; do
  case "${a}" in --nodeps) nd=$((nd+1)) ;; --print) pr=1 ;; esac
done
[ "${pr}" -eq 1 ] || { echo "fake pacman: expected --print" >&2; exit 2; }
if [ "${nd}" -lt 2 ]; then
  echo "error: failed to prepare transaction (could not satisfy dependencies)" >&2; exit 1
fi
case "${*: -1}" in *REVOKED*) echo "error: invalid or corrupted package (PGP signature)" >&2; exit 1 ;; esac
exit 0
EOF2
chmod +x "${FAKEBIN}/pacman"
M2="${TMP}/lanmirror2"; mkdir -p "${M2}"
: > "${M2}/gdb-16.3-1-x86_64.pkg.tar.zst"; : > "${M2}/gdb-16.3-1-x86_64.pkg.tar.zst.sig"
: > "${M2}/old-REVOKED-1-x86_64.pkg.tar.zst"; : > "${M2}/old-REVOKED-1-x86_64.pkg.tar.zst.sig"
printf 'gdb-16.3-1-x86_64.pkg.tar.zst\nold-REVOKED-1-x86_64.pkg.tar.zst\n' > "${TMP}/new2.list"
count3="$(unset VERIFY_CMD; PATH="${FAKEBIN}:${PATH}" bash "${HELPER}" "${M2}" "${TMP}/new2.list")"
assert_eq "${count3}" "1" "default verifier quarantines only the bad signature, not the package with missing deps"
assert_true "$([ -f "${M2}/gdb-16.3-1-x86_64.pkg.tar.zst" ]; echo $?)" \
  "validly signed package with deps that are not installed stays in the mirror"
assert_true "$([ -f "${M2}/.revoked-signer/old-REVOKED-1-x86_64.pkg.tar.zst" ]; echo $?)" \
  "package with a bad signature is still quarantined by the default verifier"

# --- mirror-pkgs.sh: the whole container script runs in the container ------------
# An apostrophe in a comment once closed the single-quoted container script. The repo-add step then ran on the host (exit 127),
# and partyos.db was never rebuilt. A fake docker records the script it gets.
PKGS_SH="${REPO_ROOT}/scripts/build/mirror-pkgs.sh"
bash -n "${PKGS_SH}" 2>/dev/null; assert_true "$?" "mirror-pkgs.sh parses (bash -n)"
bash -n "${REPO_ROOT}/scripts/build/mirror-local-pkgs.sh" 2>/dev/null
assert_true "$?" "mirror-local-pkgs.sh parses (bash -n)"
cat > "${FAKEBIN}/docker" <<'EOF2'
#!/usr/bin/env bash
printf '%s' "${@: -1}" > "${DOCKER_SCRIPT_OUT}"
echo "[mirror] fake docker ran"
exit 0
EOF2
chmod +x "${FAKEBIN}/docker"
DS="${TMP}/docker-script"
( cd "${TMP}" && DOCKER_SCRIPT_OUT="${DS}" MIRROR="${TMP}/lanmirror3" PATH="${FAKEBIN}:${PATH}" \
    bash "${PKGS_SH}" iperf3 >"${TMP}/pkgs.out" 2>&1 ); rc=$?
assert_eq "${rc}" "0" "mirror-pkgs.sh exits 0 (no step of the container script runs on the host)"
script="$(cat "${DS}" 2>/dev/null || true)"
assert_contains "${script}" "mirror-quarantine.sh /mirror /tmp/new.list" "container script runs the quarantine"
assert_contains "${script}" "repo-add /mirror/partyos.db.tar.gz" "container script rebuilds partyos.db (repo-add is in the container, not on the host)"
assert_contains "${script}" "mirror now holds" "container script is complete up to the last line"
# The verify keyring is the LATEST one (what the image build floats into the client),
# refreshed before the snapshot pin. A snapshot keyring has expired dev keys in 2026.
kr_line="$(printf '%s\n' "${script}" | grep -n 'Sy --noconfirm --disable-sandbox --needed archlinux-keyring' | head -1 | cut -d: -f1)"
snap_line="$(printf '%s\n' "${script}" | grep -n '/etc/pacman.d/mirrorlist$' | head -1 | cut -d: -f1)"
assert_true "$([ -n "${kr_line}" ] && [ -n "${snap_line}" ] && [ "${kr_line}" -lt "${snap_line}" ]; echo $?)" \
  "latest keyring refresh runs before the snapshot mirrorlist pin"
assert_not_contains "${script}" "pacman -Sp --noconfirm archlinux-keyring" "no snapshot-era keyring pin"

assert_summary "test-mirror-quarantine"
