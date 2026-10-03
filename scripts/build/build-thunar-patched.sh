#!/usr/bin/env bash
# build-thunar-patched.sh - build a patched Thunar package for partyOS.
#
# Thunar 4.20 only shows a .desktop launcher's Name= (instead of "Foo.desktop")
# when the file is "trusted" via gvfs metadata::xfce-exe-checksum. partyOS runs
# from a RAM/overlay home where gvfs metadata is unsupported, so launchers in the
# category folders always show the raw filename. thunar-trusted-local.patch makes
# Thunar trust any LOCAL .desktop (g_file_is_native), fixing the display + the
# untrusted-launcher warning. Built pinned to the SAME 2025/09 snapshot as the
# client so the ABI matches the stock thunar it replaces.
#
# Output: scripts/build/thunar-patched/thunar-*.pkg.tar.zst  (installed over stock
# thunar by build-custom-image.sh).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="${SNAPSHOT:-2025/09/01}"
IMAGE="${ARCH_IMAGE:-archlinux:latest}"
VER="${THUNAR_VER:-4.20.4}"
OUT="${SELF_DIR}/thunar-patched"

command -v docker >/dev/null || { echo "[thunar] ERROR docker required" >&2; exit 1; }
[ -f "${SELF_DIR}/thunar-trusted-local.patch" ] || { echo "[thunar] ERROR patch missing" >&2; exit 1; }
mkdir -p "${OUT}"
echo "[thunar] building patched thunar ${VER} (snapshot ${SNAPSHOT})" >&2

PATCH_B64="$(base64 < "${SELF_DIR}/thunar-trusted-local.patch" | tr -d '\n')"
docker run --rm --platform linux/amd64 \
  -e SNAPSHOT="${SNAPSHOT}" -e VER="${VER}" -e PATCH_B64="${PATCH_B64}" \
  -v "${OUT}":/out "${IMAGE}" /bin/bash -euo pipefail -c '
  printf "Server=https://archive.archlinux.org/repos/%s/\$repo/os/\$arch\n" "${SNAPSHOT}" > /etc/pacman.d/mirrorlist
  printf "[options]\nArchitecture = x86_64\nSigLevel = Never\nDisableSandbox\nParallelDownloads = 5\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n" > /etc/pacman.conf
  pacman -Sy --noconfirm --disable-sandbox --needed --overwrite "*" \
    base-devel git xfce4-dev-tools intltool exo libxfce4ui libxfce4util gtk3 \
    glib2 gdk-pixbuf2 libnotify xfconf pango >/dev/null
  useradd -m builder 2>/dev/null || true; echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
  echo "${PATCH_B64}" | base64 -d > /home/builder/trusted-local.patch
  # minimal PKGBUILD: stock thunar tarball + our patch, autotools build. pkgrel
  # bumped so pacman -U installs it over the identical-version stock package.
  cat > /home/builder/PKGBUILD <<PKGB
pkgname=thunar
pkgver=${VER}
pkgrel=99
pkgdesc="Modern file manager for Xfce (partyOS: local .desktop launchers trusted)"
arch=(x86_64)
url="https://xfce.org/"
license=(GPL2)
depends=(exo libxfce4ui libxfce4util gtk3 glib2 gdk-pixbuf2 libnotify xfconf pango libgudev)
makedepends=(xfce4-dev-tools intltool)
provides=("thunar=${VER}")
conflicts=()
options=(!emptydirs)
source=("https://archive.xfce.org/src/xfce/thunar/4.20/thunar-${VER}.tar.bz2" trusted-local.patch)
sha256sums=(SKIP SKIP)
prepare() {
  cd "thunar-${VER}"
  patch -p1 -i "\$srcdir/trusted-local.patch"
}
build() {
  cd "thunar-${VER}"
  ./configure --prefix=/usr --sysconfdir=/etc --libexecdir=/usr/lib --disable-static
  make
}
package() {
  cd "thunar-${VER}"
  make DESTDIR="\$pkgdir" install
}
PKGB
  cp /home/builder/trusted-local.patch /home/builder/PKGBUILD /home/builder/ 2>/dev/null || true
  chown -R builder:builder /home/builder
  ( cd /home/builder && sudo -u builder makepkg -s --noconfirm --skippgpcheck --skipchecksums )
  cp /home/builder/thunar-*.pkg.tar.zst /out/
  echo "[thunar] built: $(ls /out/thunar-*.pkg.tar.zst)" >&2
' 2>&1 | grep -vE "warning:|^\s+(CC|CCLD|GEN|make\[)" || { echo "[thunar] BUILD FAILED" >&2; exit 1; }

ls -lh "${OUT}"/thunar-*.pkg.tar.zst 2>/dev/null && echo "[thunar] DONE" >&2
