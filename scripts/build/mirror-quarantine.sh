#!/usr/bin/env bash
# mirror-quarantine.sh - move NEWLY-ADDED mirror packages that fail signature
# verification into <mirror>/.revoked-signer/, keeping their .sig so the move stays
# reversible. ONLY the packages listed in <new-list> are ever considered - packages
# already published in the mirror are NEVER re-verified or touched, so a keyring drift
# can no longer quarantine hundreds of still-valid packages and gut the whole mirror.
#
# A newly-fetched package that fails is one Arch signed with a key that even the
# snapshot-era keyring rejects (a genuine revoked-signer); the operator serves those
# from [partyos-local] (SigLevel=Never) via mirror-local-pkgs.sh instead.
#
# The verifier is injected via VERIFY_CMD so this is testable off-Arch: VERIFY_CMD gets
# the package path as its last arg and returns 0=verified / non-zero=quarantine. The
# default is pacman's Required-level --print check against /tmp/verify.conf (set up by
# mirror-pkgs.sh inside the snapshot-pinned container). The default has --nodeps twice
# (-dd): the container does not have the dependencies of the new packages installed,
# and without -dd pacman stops at the dependency check before the signature check.
#
# Usage: mirror-quarantine.sh <mirror-dir> <new-list-file>   (prints the quarantine count)
set -euo pipefail
MIRROR="${1:?usage: mirror-quarantine.sh <mirror-dir> <new-list-file>}"
NEWLIST="${2:?usage: mirror-quarantine.sh <mirror-dir> <new-list-file>}"
VERIFY_CMD="${VERIFY_CMD:-pacman -U --config /tmp/verify.conf --noconfirm --disable-sandbox --nodeps --nodeps --print}"

mkdir -p "${MIRROR}/.revoked-signer"
quarantined=0
while IFS= read -r bn; do
  [ -n "${bn}" ] || continue
  pkg="${MIRROR}/${bn}"
  [ -f "${pkg}" ] || continue
  if ${VERIFY_CMD} "${pkg}" >/dev/null 2>&1; then
    continue
  fi
  echo "[mirror] QUARANTINE revoked-signer / unverifiable: ${bn} (-> [partyos-local])" >&2
  mv -f "${pkg}" "${MIRROR}/.revoked-signer/${bn}" 2>/dev/null || true
  # keep the .sig alongside the quarantined package (do NOT delete it) so a move-back
  # restores a complete, verifiable package without re-fetching it from the archive.
  if [ -f "${MIRROR}/${bn}.sig" ]; then
    mv -f "${MIRROR}/${bn}.sig" "${MIRROR}/.revoked-signer/${bn}.sig" 2>/dev/null || true
  fi
  quarantined=$((quarantined+1))
done < "${NEWLIST}"
echo "${quarantined}"
