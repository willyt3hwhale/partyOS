#!/usr/bin/env bash
# fetch-avp2-installers.sh - download the four AvP2 installer archives.
#
# Aliens versus Predator 2 is abandonware: no publisher sells it and the community
# at avpunknown.com hosts the installers. This script downloads them and checks them
# against the checksums recorded when this recipe was written. It runs on ANY host
# (it only downloads; nothing here executes x86 code), so an arm64 host can fill the
# cache and the build host can rsync it.
#
# The archives are NOT in the repo. They are game binaries, so they live in the cache
# directory below, which is outside the working tree.
#
# Usage: fetch-avp2-installers.sh [dest-dir]      (default ~/Downloads/avp2-installers)
# Next:  stage-avp2.sh, on a native x86_64 Linux box with wine and a display.
set -euo pipefail

DEST="${1:-${HOME}/Downloads/avp2-installers}"
mkdir -p "${DEST}"

# name|url|bytes|sha256. Recorded 2026-09-21. Total ~690 MB, nearly all of it the
# all-in-one archive.
FILES="
avp2_avp2ph_aio.exe.zip|https://avpunknown.com/avp2aio/avp2game/avp2_avp2ph_aio.exe.zip|657884469|3b96e7609e86578e2606045bc5f5af43a007d123283acce3e9d39352561c8496
avp2_en_096.zip|http://avpunknown.com/updates/avp2_en_096.zip|7207376|b1d8b4b1f00d23b4f8fa5c74465ff0c10f67e46d90904eb8b18ab0787604bab3
avp2_en_sp1.zip|http://avpunknown.com/updates/avp2_en_sp1.zip|12521374|b1e87afa53f8822e7f6efbfbeb257235880daecddec133f8bfe1094592e8e5ba
avp2_en_mp1.zip|http://avpunknown.com/updates/avp2_en_mp1.zip|13146959|c0fbadd8e2a779488a6946d5c01beeb1dec926da639013f4aac22c6aed992ead
avp2linux_096.gz|http://avpunknown.com/avp2master/lx/avp2linux_096.gz|2118534|cc278d2ca914d4b4e5fde371f45141f54e53a12dfe1e4ec31bc0c9dc01cf21b5
"

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

rc=0
while IFS='|' read -r name url want_size want_sha; do
    [ -n "${name}" ] || continue
    out="${DEST}/${name}"
    if [ -f "${out}" ] && [ "$(sha_of "${out}")" = "${want_sha}" ]; then
        echo "[avp2] ${name}: already cached and verified" >&2
        continue
    fi
    echo "[avp2] ${name}: downloading ${want_size} bytes" >&2
    curl -fL --retry 3 -C - -A "Mozilla/5.0" -o "${out}" "${url}" || {
        echo "[avp2] ${name}: DOWNLOAD FAILED" >&2; rc=1; continue; }
    got="$(sha_of "${out}")"
    if [ "${got}" != "${want_sha}" ]; then
        echo "[avp2] ${name}: SHA256 MISMATCH (got ${got}, want ${want_sha})" >&2
        echo "[avp2] ${name}: upstream re-packed the archive. Verify it by hand before you use it." >&2
        rc=1
    else
        echo "[avp2] ${name}: OK" >&2
    fi
done <<< "${FILES}"

echo "[avp2] cache: ${DEST}" >&2
[ "${rc}" = 0 ] && echo "[avp2] all archives verified. Next: stage-avp2.sh on an x86_64 Linux box." >&2
exit "${rc}"
