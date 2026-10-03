#!/usr/bin/env bash
# test-xauth-wild.sh - hardware-free test for the X cookie of the real-GPU path in
# boot/step3-script.sh.
#
# Bug: step3 wrote the MIT-MAGIC-COOKIE-1 for "$(uname -n)/unix:0" while the hostname
# was still "archiso". The identity step then set the real hostname. X clients looked
# for "<newhost>/unix:0", found no cookie, and XFCE failed with "Authorization required".
#
# Fix: convert the entries to FamilyWild (nlist family ffff), so they match all hosts.
#
# This carves the real cookie block from step3-script.sh and runs it with a stubbed
# uname (archiso). Then it checks the nlist family and that the cookie resolves for
# a different hostname. If xauth is not installed, the run part is skipped.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

STEP3="${REPO_ROOT}/boot/step3-script.sh"
[ -f "${STEP3}" ] || { echo "FAIL: boot/step3-script.sh not found at ${STEP3}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-xauthwild.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

echo "================ 1. static: the wild conversion is wired in ==========="
wild="$(awk '/# begin-xauth-wild/{c=1;next} /# end-xauth-wild/{c=0} c' "${STEP3}")"
assert_contains "${wild}" "nlist" "step3: the cookie block lists entries with nlist"
assert_contains "${wild}" "s/^..../ffff/" "step3: the family is rewritten to ffff (FamilyWild)"
assert_contains "${wild}" "nmerge -" "step3: the rewritten entries are merged back"
assert_contains "${wild}" "|| true" "step3: the conversion is best-effort"

echo
echo "================ 2. run the REAL carved cookie block ==================="
XAUTH_BIN="$(command -v xauth || true)"
if [ -z "${XAUTH_BIN}" ]; then
  echo "  SKIP: xauth not installed - run part skipped (static checks only)"
else
  # carve from the mcookie line to the closing fi of the cookie if-block.
  blk="${TMPDIR_T}/cookie.sh"
  awk '/COOKIE="\$\(mcookie/{c=1} c{print} c&&/^  fi$/{exit}' "${STEP3}" > "${blk}"
  assert_contains "$(cat "${blk}")" "end-xauth-wild" "carved block includes the wild conversion"
  mkdir -p "${TMPDIR_T}/bin"
  printf '#!/bin/sh\necho archiso\n' > "${TMPDIR_T}/bin/uname"
  printf '#!/bin/sh\necho 0123456789abcdef0123456789abcdef\n' > "${TMPDIR_T}/bin/mcookie"
  chmod +x "${TMPDIR_T}/bin/uname" "${TMPDIR_T}/bin/mcookie"
  XA="${TMPDIR_T}/partyos-Xauthority"
  : > "${XA}"
  ( PATH="${TMPDIR_T}/bin:${PATH}"; XAUTH_FILE="${XA}"; # shellcheck disable=SC1090
    source "${blk}" )
  nl="$(xauth -f "${XA}" nlist 2>/dev/null)"
  n="$(printf '%s\n' "${nl}" | grep -c . || true)"
  assert_true "$([ "${n}" -ge 1 ] && echo 0 || echo 1)" "the cookie file has entries (got ${n})"
  nonwild="$(printf '%s\n' "${nl}" | grep -v '^ffff' | grep -c . || true)"
  assert_eq "${nonwild}" "0" "every nlist entry has family ffff (FamilyWild)"
  assert_not_contains "$(xauth -f "${XA}" list 2>/dev/null)" "archiso" \
    "no entry is keyed to the stale hostname archiso"
  # FamilyWild matches the display on any host: look it up as the new hostname.
  got="$(xauth -f "${XA}" list "deck/unix:0" 2>/dev/null)"
  assert_contains "${got}" "0123456789abcdef0123456789abcdef" \
    "the cookie resolves for deck/unix:0 (hostname changed after Xorg start)"
fi

assert_summary
