#!/usr/bin/env bash
# test-mirror-pkgs-real.sh - run the REAL mirror-pkgs.sh (docker, real pacman, real Arch
# signatures) into a scratch mirror. Guards against the quarantine false positive on
# packages whose dependencies the container does not have.
#
# Targets:
#   - iperf3: validly signed. Its deps (lksctp-tools, openssl, ...) are not installed in
#     the container. It must stay in the mirror and be in partyos.db.
#   - libsigc++-3.0 3.6.0-1: signed by a key that Arch revoked (heftig). A real client
#     rejects it ("invalid or corrupted package (PGP signature)"). It must go to
#     .revoked-signer/ and must not be in partyos.db.
# Also checks that partyos.db is rebuilt and that the script exits 0.
#
# Needs docker and internet (archive.archlinux.org). It is not part of test-prod.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

command -v docker >/dev/null || { echo "SKIP: docker not found"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-mirrorreal-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
M="${TMP}/lanmirror"

out="$(MIRROR="${M}" bash "${REPO_ROOT}/scripts/build/mirror-pkgs.sh" iperf3 libsigc++-3.0 2>&1)"; rc=$?
printf '%s\n' "${out}" | grep -E '^\[mirror\]' | sed 's/^/    /'
assert_eq "${rc}" "0" "mirror-pkgs.sh exits 0"
assert_contains "${out}" "[mirror] 1 newly-added package(s) quarantined" "exactly 1 package quarantined"
assert_contains "${out}" "[mirror] mirror now holds" "the repo-add step ran in the container"

assert_true "$([ -f "${M}/iperf3-3.19.1-1-x86_64.pkg.tar.zst" ]; echo $?)" "validly signed iperf3 (deps not installed) is kept"
assert_true "$([ -f "${M}/.revoked-signer/libsigc++-3.0-3.6.0-1-x86_64.pkg.tar.zst" ]; echo $?)" "revoked-signer libsigc++-3.0 is quarantined"
assert_true "$([ -f "${M}/.revoked-signer/libsigc++-3.0-3.6.0-1-x86_64.pkg.tar.zst.sig" ]; echo $?)" "quarantined package keeps its .sig"

assert_true "$([ -f "${M}/partyos.db.tar.gz" ]; echo $?)" "partyos.db.tar.gz is rebuilt"
db="$(tar -tzf "${M}/partyos.db.tar.gz" 2>/dev/null || true)"
assert_contains "${db}" "iperf3-3.19.1-1/" "partyos.db lists iperf3"
assert_not_contains "${db}" "libsigc++-3.0-" "partyos.db does not list the quarantined package"
npkg="$(ls "${M}"/*.pkg.tar.zst | wc -l | tr -d ' ')"
ndb="$(printf '%s\n' "${db}" | grep -c '/desc$')"
assert_eq "${ndb}" "${npkg}" "partyos.db has one entry per package in the mirror"

assert_summary "test-mirror-pkgs-real"
