#!/usr/bin/env bash
# mirror-local-pkgs.sh - add a genuinely-UNSIGNED custom package (our own makepkg
# build, e.g. thunar-patched) to the partyOS LAN local mirror (server/lanmirror-local)
# so slim clients can install it at runtime from the [partyos-local] repo.
#
# This is the SigLevel=Never half of the repo split. [partyos-local] holds ONLY the
# custom packages we build ourselves and cannot Arch-sign (thunar-patched + any other
# makepkg output). They are operator-trusted via the pinned-CA HTTPS transport - the
# one transport-trusted package class - so this repo carries NO .sig files and its db
# is built unsigned. Keep it minimal: only put genuinely-unsigned custom packages here;
# everything Arch-signed belongs in [partyos] (Required) via mirror-pkgs.sh.
#
# Usage: mirror-local-pkgs.sh <path-to-pkg.tar.zst> [<path>...]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
LOCAL="${REPO_ROOT}/server/lanmirror-local"
IMAGE="${ARCH_IMAGE:-archlinux:latest}"

[ "$#" -ge 1 ] || { echo "usage: $0 <path-to-pkg.tar.zst> [...]" >&2; exit 1; }
command -v docker >/dev/null || { echo "[local] ERROR docker required" >&2; exit 1; }
mkdir -p "${LOCAL}"

for p in "$@"; do
  [ -f "${p}" ] || { echo "[local] ERROR not a file: ${p}" >&2; exit 1; }
  cp -f "${p}" "${LOCAL}/"
  echo "[local] added $(basename "${p}")" >&2
done

# (re)build the partyos-local.db from every custom package in the dir. repo-add in a
# pinned amd64 container so the db format matches the client's pacman. NO --sign: this
# db is unsigned by design and the client [partyos-local] repo is SigLevel=Never, so
# pacman never even probes partyos-local.db.sig.
docker run --rm --platform linux/amd64 -v "${LOCAL}":/local "${IMAGE}" /bin/bash -euo pipefail -c '
  pacman -Sy --noconfirm --disable-sandbox pacman-contrib >/dev/null 2>&1 || true
  rm -f /local/partyos-local.db* /local/partyos-local.files* 2>/dev/null || true
  repo-add /local/partyos-local.db.tar.gz /local/*.pkg.tar.zst >/dev/null 2>&1
  echo "[local] partyos-local repo now holds $(ls /local/*.pkg.tar.zst | wc -l) custom package(s)" >&2
' 2>&1 | grep -vE "warning:|^\s*$" || { echo "[local] FAILED" >&2; exit 1; }
echo "[local] DONE" >&2
