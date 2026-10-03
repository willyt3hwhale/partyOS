#!/usr/bin/env bash
# build-proton-offline-image.sh - make the build image for an OFFLINE proton-blob build.
#
# build-proton-blob.sh installs its packages with pacman in an amd64 Arch container,
# and it gets dxvk-bin from the AUR. Both need the internet. An offline build host cannot do this.
# Run this script on a host with internet access. It runs no 32-bit x86 code, so an
# arm64 host works. It makes an amd64 image that holds a local package repo at /offline/pkgs:
#   - the full package set of build-proton-blob.sh at the pinned 2025/09/01 snapshot,
#   - a prebuilt dxvk-bin package,
#   - the docker, containerd and runc packages for the build host itself.
# One repo db is copied to the names core, extra and multilib, because the build
# writes those three sections into pacman.conf.
#
# Usage:
#   build-proton-offline-image.sh [--save FILE.tar.zst] [--host-pkgs DIR]
#     --save       also write the image as a zstd docker archive for the build host
#     --host-pkgs  also copy the docker, containerd and runc packages to DIR
#
# On the build host:
#   1. pacman -U --needed <host-pkgs>/*.pkg.tar.zst, then set the docker data-root
#      on the USB stick (the RAM root is too small) and start docker.
#   2. zstd -dc FILE.tar.zst | docker load
#   3. ARCH_IMAGE=partyos-protonbuild-offline:20250901 PB_MIRROR=file:///offline/pkgs \
#      bash scripts/build/build-proton-blob.sh <name> <game-src> <exe> ...
# See docs/CREATING-BLOBS.md.
set -euo pipefail

TAG="${TAG:-partyos-protonbuild-offline:20250901}"
SNAPSHOT="${SNAPSHOT:-2025/09/01}"
SAVE=""; HOST_PKGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --save) SAVE="$2"; shift 2 ;;
        --host-pkgs) HOST_PKGS="$2"; shift 2 ;;
        *) echo "usage: $0 [--save FILE.tar.zst] [--host-pkgs DIR]" >&2; exit 1 ;;
    esac
done
command -v docker >/dev/null || { echo "[offline-image] ERROR docker required" >&2; exit 1; }

CTX="$(mktemp -d)"; trap 'rm -rf "${CTX}"' EXIT

# The prep runs inside the image build. Keep WINE_PKGS the same as the list in
# build-proton-blob.sh. A package that is missing here fails the offline build.
cat > "${CTX}/prep.sh" <<'PREP'
#!/bin/bash
set -euxo pipefail
printf "Server=https://archive.archlinux.org/repos/%s/\$repo/os/\$arch\n" "${SNAPSHOT}" > /etc/pacman.d/mirrorlist
printf "[options]\nArchitecture = x86_64\nSigLevel = Never\nDisableSandbox\nParallelDownloads = 5\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" > /etc/pacman.conf
pacman -Syuu --noconfirm --disable-sandbox --overwrite "*"
pacman -S --noconfirm --disable-sandbox --needed --overwrite "*" base-devel git squashfs-tools unzip
useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
sudo -u builder git clone --depth 1 https://aur.archlinux.org/dxvk-bin.git /home/builder/dxvk-bin
cd /home/builder/dxvk-bin
sudo -u builder git log -1 --format="%H %ci"
sudo -u builder makepkg -s --noconfirm --skippgpcheck --skipchecksums
WINE_PKGS="wine-staging winetricks cabextract libunwind lib32-libunwind \
    lib32-mesa lib32-vulkan-icd-loader lib32-vulkan-intel lib32-vulkan-radeon \
    lib32-libpulse lib32-alsa-lib lib32-gnutls lib32-libgcrypt lib32-libxcomposite \
    mesa vulkan-icd-loader vulkan-intel vulkan-radeon \
    wine-mono wine-gecko"
# An empty root makes pacman fetch the WHOLE dependency closure, not only what this
# image does not have yet.
mkdir -p /offline/pkgs /tmp/er/var/lib/pacman
pacman -Syw --noconfirm --disable-sandbox --root /tmp/er --dbpath /tmp/er/var/lib/pacman \
    --cachedir /offline/pkgs base filesystem squashfs-tools unzip base-devel git sudo \
    ${WINE_PKGS} docker
cp /home/builder/dxvk-bin/*.pkg.tar.zst /offline/pkgs/
cd /offline/pkgs
repo-add -q core.db.tar.gz ./*.pkg.tar.zst
for r in extra multilib; do cp core.db.tar.gz "${r}.db.tar.gz"; ln -sf "${r}.db.tar.gz" "${r}.db"; done
du -sh /offline/pkgs
rm -rf /tmp/er /var/cache/pacman/pkg/* /home/builder/dxvk-bin/src /home/builder/dxvk-bin/pkg
PREP
cat > "${CTX}/Dockerfile" <<EOF
FROM --platform=linux/amd64 archlinux:latest
ENV SNAPSHOT=${SNAPSHOT}
COPY prep.sh /prep.sh
RUN bash /prep.sh
EOF

echo "[offline-image] building ${TAG} (snapshot ${SNAPSHOT})" >&2
docker pull --platform linux/amd64 archlinux:latest >/dev/null
docker build --platform linux/amd64 -t "${TAG}" "${CTX}"

# Test the repo with no network, the same way the offline build uses it.
docker run --rm --network none --platform linux/amd64 "${TAG}" bash -c '
  printf "Server=file:///offline/pkgs\n" > /etc/pacman.d/mirrorlist
  pacman -Sy >/dev/null && pacman -Si wine-staging dxvk-bin docker >/dev/null' \
  || { echo "[offline-image] ERROR the offline repo does not resolve" >&2; exit 1; }
echo "[offline-image] offline repo OK" >&2

if [ -n "${HOST_PKGS}" ]; then
    mkdir -p "${HOST_PKGS}"
    cid="$(docker create --platform linux/amd64 "${TAG}")"
    for p in docker containerd runc; do
        f="$(docker run --rm --platform linux/amd64 "${TAG}" bash -c \
            "ls /offline/pkgs | grep -E '^${p}-[0-9]' | grep -v '\.sig$' | head -1")"
        docker cp "${cid}:/offline/pkgs/${f}" "${HOST_PKGS}/"
    done
    docker rm "${cid}" >/dev/null
    echo "[offline-image] host packages in ${HOST_PKGS}" >&2
fi
if [ -n "${SAVE}" ]; then
    docker save "${TAG}" | zstd -T0 -6 > "${SAVE}"
    echo "[offline-image] saved to ${SAVE} ($(du -h "${SAVE}" | cut -f1))" >&2
fi
