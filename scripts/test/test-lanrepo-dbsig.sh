#!/usr/bin/env bash
# test-lanrepo-dbsig.sh - the LAN repo db is unsigned, so the client .sig 404 is expected.
#   server side: repo-add builds partyos.db without --sign, so no partyos.db.sig exists.
#   client side: [partyos] uses SigLevel = Required DatabaseOptional, so pacman accepts
#                the 404. A bare "Required" makes every -Sy abort.
#   [partyos-local] uses SigLevel = Never, so pacman does not request its .db.sig.
# This test reads mirror-pkgs.sh, mirror-local-pkgs.sh and 85-repo-runtime.sh.
# Hardware-free, off-Arch: pure shell, no docker, no pacman, no network.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

MIRROR_PKGS="${REPO_ROOT}/scripts/build/mirror-pkgs.sh"
LOCAL_PKGS="${REPO_ROOT}/scripts/build/mirror-local-pkgs.sh"
BUILD="${REPO_ROOT}/scripts/build/phases/85-repo-runtime.sh"
for f in "${MIRROR_PKGS}" "${LOCAL_PKGS}" "${BUILD}"; do
  [ -f "${f}" ] || { echo "FAIL: expected script not found at ${f}"; exit 1; }
done

# --- server half: the repo db is built sign-less, so no .db.sig is ever emitted ----
pkgs_repoadd="$(grep -E 'repo-add .*/partyos\.db\.tar\.gz' "${MIRROR_PKGS}" || true)"
assert_contains "${pkgs_repoadd}" "repo-add" "mirror-pkgs.sh builds the [partyos] db with repo-add"
assert_not_contains "${pkgs_repoadd}" "--sign" \
  "mirror-pkgs.sh repo-add is sign-less - no partyos.db.sig is ever produced (so the client 404 is expected)"

local_repoadd="$(grep -E 'repo-add .*/partyos-local\.db\.tar\.gz' "${LOCAL_PKGS}" || true)"
assert_contains "${local_repoadd}" "repo-add" "mirror-local-pkgs.sh builds the [partyos-local] db with repo-add"
assert_not_contains "${local_repoadd}" "--sign" \
  "mirror-local-pkgs.sh repo-add is sign-less - no partyos-local.db.sig is ever produced"

# Evidence guard: when the mirror is populated in the working tree, the served db exists
# but its .sig does not - that absence IS the 404 clients see. Skipped on a bare checkout.
if [ -f "${REPO_ROOT}/server/lanmirror/partyos.db" ]; then
  assert_false "$([ -f "${REPO_ROOT}/server/lanmirror/partyos.db.sig" ]; echo $?)" \
    "served partyos.db has no partyos.db.sig alongside it (this absence is the client's 404)"
fi

# --- client half: DatabaseOptional accepts the missing db.sig ----
build_content="$(cat "${BUILD}")"
assert_contains "${build_content}" "[partyos]" "85-repo-runtime.sh defines the client [partyos] repo"
# Without DatabaseOptional, every client -Sy aborts on the missing partyos.db.sig.
assert_contains "${build_content}" "SigLevel = Required DatabaseOptional" \
  "client [partyos] SigLevel keeps DatabaseOptional - a missing partyos.db.sig is accepted"
# [partyos-local] is Never: pacman never even probes partyos-local.db.sig (log shows 0 such GETs).
assert_contains "${build_content}" "[partyos-local]" "85-repo-runtime.sh defines the client [partyos-local] repo"
assert_contains "${build_content}" "SigLevel = Never" \
  "client [partyos-local] SigLevel is Never - it never probes partyos-local.db.sig"

assert_summary "test-lanrepo-dbsig"
