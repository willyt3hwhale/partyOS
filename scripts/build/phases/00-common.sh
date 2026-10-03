# phase 00-common - sourced by build-custom-image.sh; not standalone
# --- 0. host-side pacman: tooling we need in the CONTAINER (squashfs-tools,
# arch-install-scripts for arch-chroot). The container's own pacman is current;
# that is fine, we only use it for tooling, not for the target rootfs.
# pacman 7.x runs downloads in a sandbox (seccomp + 'alpm' user) which fails
# inside Docker (no user namespaces / landlock -> "error restricting syscalls
# via seccomp: 22"). DisableSandbox turns it off. It MUST live in the [options]
# section (appending at EOF lands under the last [repo] and is ignored), so we
# insert it right after the first [options] line. Applied to the container's
# pacman here and to the target rootfs's pacman.conf below.
grep -q '^DisableSandbox$' /etc/pacman.conf || \
    sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

echo "[build] installing container tooling (squashfs-tools, arch-install-scripts, git)..."
pacman -Sy --noconfirm --needed squashfs-tools arch-install-scripts git >/dev/null

