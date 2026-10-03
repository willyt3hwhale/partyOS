#!/usr/bin/env bash
# mirror-pkgs.sh - add repo package(s) + their FULL dependency closure to the
# partyOS LAN mirror (server/lanmirror) so slim clients can install them offline.
#
# The mirror is a flat dir of *.pkg.tar.zst + each package's detached *.sig + a
# `partyos.db` repo db, pinned to the SAME 2025/09 snapshot as the client base (so
# versions match the ABI the client ships). We resolve+download into an EMPTY root
# inside a snapshot-pinned amd64 container (pulls the whole closure regardless of
# what the container has), fetch each package's .sig from the archive, copy both
# into the mirror, and repo-add them into partyos.db.
#
# WHY the .sig files: the client's [partyos] repo is SigLevel=Required (runtime sig
# verification - a rogue/tampered LAN mirror cannot inject a stock package). pacman
# verifies each *.pkg.tar.zst against its detached *.sig using the first-boot-
# populated archlinux-keyring. Without the .sig alongside, a Required install fails
# "missing required signature". These are Arch's OWN dev/master signatures (the
# archive serves them); we just mirror them - we never sign anything ourselves.
#
# Usage: mirror-pkgs.sh <pkg> [pkg...]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
MIRROR="${MIRROR:-${REPO_ROOT}/server/lanmirror}"
SNAPSHOT="${SNAPSHOT:-2025/09/01}"
IMAGE="${ARCH_IMAGE:-archlinux:latest}"

[ "$#" -ge 1 ] || { echo "usage: $0 <pkg> [pkg...]" >&2; exit 1; }
command -v docker >/dev/null || { echo "[mirror] ERROR docker required" >&2; exit 1; }
mkdir -p "${MIRROR}"
echo "[mirror] mirroring into ${MIRROR} (snapshot ${SNAPSHOT}): $*" >&2

# The container script below is one single-quoted string. Do not put a single quote
# (an apostrophe) anywhere in it, also not in a comment. A quote ends the string, and
# the rest of the script then runs on the host.
docker run --rm --platform linux/amd64 \
  -e SNAPSHOT="${SNAPSHOT}" -e PKGS="$*" \
  -v "${MIRROR}":/mirror \
  -v "${SELF_DIR}/mirror-quarantine.sh":/usr/local/bin/mirror-quarantine.sh:ro \
  "${IMAGE}" /bin/bash -euo pipefail -c '
  # Refresh the verification keyring from the rolling repos BEFORE the pin to the
  # snapshot. The image build does the same (phase 10-rootfs-base floats the LATEST
  # archlinux-keyring into the rootfs), so the verify below uses the keys the client
  # has. The snapshot keyring has dev keys that expired in 2026 and does not disable
  # later revoked keys, so it gives wrong results at the real clock.
  pacman -Sy --noconfirm --disable-sandbox --needed archlinux-keyring >/dev/null 2>&1 || true
  echo "[mirror] verify keyring: $(pacman -Q archlinux-keyring)" >&2
  printf "Server=https://archive.archlinux.org/repos/%s/\$repo/os/\$arch\n" "${SNAPSHOT}" > /etc/pacman.d/mirrorlist
  printf "[options]\nArchitecture = x86_64\nSigLevel = Never\nParallelDownloads = 5\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n" > /etc/pacman.conf
  pacman -Sy --noconfirm --disable-sandbox pacman-contrib >/dev/null 2>&1 || true
  # resolve + download the targets and their FULL closure into an empty root so
  # nothing is skipped as "already installed". Cache goes straight to /mirror.
  ROOT=/tmp/empty; mkdir -p "${ROOT}/var/lib/pacman"
  pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" -Sy --noconfirm --disable-sandbox >/dev/null
  # Snapshot the packages ALREADY published in the mirror BEFORE downloading, so the
  # verify/quarantine step below can be scoped to ONLY this run new closure and can
  # never touch (or gut) the existing mirror.
  (cd /mirror && ls *.pkg.tar.zst 2>/dev/null || true) | sort > /tmp/pre.list
  pacman --root "${ROOT}" --dbpath "${ROOT}/var/lib/pacman" --cachedir /mirror \
         -Sw --noconfirm --disable-sandbox ${PKGS}
  # Fetch the detached .sig for EVERY package now in the mirror (the client [partyos]
  # repo is SigLevel=Required). The snapshot archive serves <pkg>.sig next to <pkg>.
  # Try extra/ then core/ (a package lives in exactly one). Missing-sig is fatal: a
  # package with no sig would be rejected at the Required client, so flag it loudly.
  missing=0
  for pkg in /mirror/*.pkg.tar.zst; do
    bn="$(basename "${pkg}")"
    [ -f "/mirror/${bn}.sig" ] && continue
    got=0
    for repo in extra core; do
      url="https://archive.archlinux.org/repos/${SNAPSHOT}/${repo}/os/x86_64/${bn}.sig"
      if curl --retry 5 --retry-all-errors -fsSL "${url}" -o "/mirror/${bn}.sig" 2>/dev/null; then got=1; break; fi
    done
    if [ "${got}" -ne 1 ]; then echo "[mirror] WARN no .sig for ${bn}" >&2; missing=$((missing+1)); fi
  done
  [ "${missing}" -eq 0 ] || echo "[mirror] WARN ${missing} package(s) missing a .sig (would fail SigLevel=Required)" >&2
  # QUARANTINE genuinely revoked-signer packages, but ONLY among THIS run newly-added
  # closure - never re-verify or move packages already published in the mirror. Some
  # snapshot packages were signed by a key Arch REVOKED even as of the snapshot era; they
  # can never pass the client SigLevel=Required, so they go to [partyos-local] (Never) via
  # mirror-local-pkgs.sh. Verification uses the LATEST keyring (refreshed at the top), the
  # same keyring the image build puts in the client. Scoping fixes the whole-mirror nuke.
  (cd /mirror && ls *.pkg.tar.zst 2>/dev/null || true) | sort > /tmp/post.list
  comm -13 /tmp/pre.list /tmp/post.list > /tmp/new.list
  rm -rf /etc/pacman.d/gnupg; install -d -m700 /etc/pacman.d/gnupg
  pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1
  printf "[options]\nArchitecture = x86_64\nSigLevel = Required\nLocalFileSigLevel = Required\nDisableSandbox\n" > /tmp/verify.conf
  quarantined="$(mirror-quarantine.sh /mirror /tmp/new.list)"
  [ "${quarantined}" -eq 0 ] || echo "[mirror] ${quarantined} newly-added package(s) quarantined - add them to [partyos-local] via mirror-local-pkgs.sh" >&2
  # (re)build the repo db from every VERIFIED package now in the mirror. repo-add writes
  # partyos.db.tar.gz + the partyos.db -> partyos.db.tar.gz symlink clients fetch.
  # NO --sign: we deliberately build an UNSIGNED db (only the packages carry the Arch
  # sigs, not the db - we never sign anything ourselves). The client [partyos] repo is
  # SigLevel=Required DatabaseOptional, so a missing partyos.db.sig is a benign 404 probe,
  # not a fatal abort. EXPECTED: clients log GET partyos.db.sig -> 404 then continue.
  # Keep these two halves in sync - a bare Required client would demand the .sig and
  # abort every -Sy.
  rm -f /mirror/partyos.db* /mirror/partyos.files* 2>/dev/null || true
  repo-add /mirror/partyos.db.tar.gz /mirror/*.pkg.tar.zst >/dev/null 2>&1
  echo "[mirror] mirror now holds $(ls /mirror/*.pkg.tar.zst | wc -l) verified packages, $(ls /mirror/*.pkg.tar.zst.sig 2>/dev/null | wc -l) sigs" >&2
' 2>&1 | grep -vE "warning:|^\s*$" || { echo "[mirror] FAILED for: $*" >&2; exit 1; }
echo "[mirror] DONE: $*" >&2
