# phase 10-rootfs-base - sourced by build-custom-image.sh; not standalone
# --- 1. unsquash the stock live rootfs --------------------------------------
echo "[build] unsquashing stock airootfs.sfs (this takes a minute)..."
rm -rf "${ROOTFS}"
mkdir -p /build
unsquashfs -q -d "${ROOTFS}" "${IN_SFS}"
echo "[build] rootfs extracted: $(du -sh "${ROOTFS}" | cut -f1)"

KVER="$(ls "${ROOTFS}/usr/lib/modules" | head -1)"
echo "[build] target kernel modules version: ${KVER} (must stay pinned)"

# --- 2. point the rootfs's pacman at the pinned snapshot so installs match the
# already-installed package set exactly (no partial-upgrade / kernel bump). -----
sed "s|@SNAPSHOT@|${SNAPSHOT}|g" "${FILES}/rootfs/etc/pacman.d/mirrorlist.tmpl" > "${ROOTFS}/etc/pacman.d/mirrorlist"

# Same sandbox workaround inside the target rootfs's pacman.conf ([options]).
grep -q '^DisableSandbox$' "${ROOTFS}/etc/pacman.conf" || \
    sed -i '/^\[options\]/a DisableSandbox' "${ROOTFS}/etc/pacman.conf"
# CheckSpace mis-fires inside Docker's overlay/bind chroot ("not enough free
# disk space" / "could not determine cachedir mount point"), so disable it.
sed -i 's/^CheckSpace/#CheckSpace/' "${ROOTFS}/etc/pacman.conf"
# Package signature verification: GPG sigs are the trust root, not transport. We
# populate the archlinux-keyring into pacman's trust db (below) and require every
# Arch package to carry a valid signature against it. A rogue or tampered pacman
# mirror (build-time archive OR the runtime operator LAN mirror) can then NOT inject
# a package - the sig check rejects anything not signed by a trusted Arch dev/master
# key, so transport stops mattering for package integrity. DatabaseOptional because
# our LAN [partyos] repo db is built by repo-add WITHOUT a signing key (only the
# PACKAGES carry Arch's sigs, not the db) - a test confirmed that a bare "Required"
# demands a partyos.db.sig and aborts the sync.
sed -i 's/^SigLevel.*/SigLevel = Required DatabaseOptional/' "${ROOTFS}/etc/pacman.conf"
# LocalFileSigLevel = Optional: a bare Required SigLevel ALSO governs `pacman -U` of
# an explicit LOCAL file, so our UNSIGNED custom packages (the thunar-patched build
# installed below via -U, built with --skippgpcheck) would be rejected "missing
# required signature" and abort the build (a test confirmed RC=1).
# Optional lets an explicit -U file be unsigned (operator-trusted: the file is right
# here on disk) while REPO installs stay Required. It does NOT weaken the rogue-mirror
# defense: repo packages still need a valid sig; only local -U files are exempted.
grep -q '^LocalFileSigLevel' "${ROOTFS}/etc/pacman.conf" \
  && sed -i 's/^LocalFileSigLevel.*/LocalFileSigLevel = Optional/' "${ROOTFS}/etc/pacman.conf" \
  || sed -i '/^SigLevel = Required DatabaseOptional$/a LocalFileSigLevel = Optional' "${ROOTFS}/etc/pacman.conf"

# Bind mounts needed for arch-chroot pacman (resolv.conf, /dev, /proc, /sys).
# The stock airootfs ships /etc/resolv.conf as a dangling symlink to the
# systemd-resolved stub; replace it with a real file so chroot pacman resolves
# the archive mirror. We restore the symlink before squashing.
rm -f "${ROOTFS}/etc/resolv.conf"
cp -L /etc/resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || \
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "${ROOTFS}/etc/resolv.conf"

# --- 2b. float the LATEST archlinux-keyring into the rootfs, then populate -----
# DELIBERATE FLOAT off the 2025/09/01 snapshot pin for THIS ONE PACKAGE only:
# install the CURRENT archlinux-keyring (from the build container's rolling repos)
# over the snapshot's pinned keyring. Why: Arch periodically RENEWS its dev keys,
# and the snapshot's keyring (20250807.1) carries dev keys that EXPIRE later in 2025
# (e.g. anthraxx 2025-12-31). At the real build/runtime clock (mid-2026) those
# snapshot keys evaluate as expired -> gpgme caps them at validity 'e' -> every
# dev-signed snapshot package fails SigLevel=Required. The LATEST keyring carries the
# RENEWED keys (same fingerprints, new expiry), so the EXACT SAME 2025/09/01 snapshot
# packages verify at the real clock with NO clock-fake. A test proved this:
# archlinux-keyring 20260612-1 verified the full snapshot spread (xfwm4/aria2/mesa/
# lilv/c-ares/firefox/nvidia/thunar/pipewire + closure) at the real 2026 clock, rc=0,
# zero expired/revoked failures. So we DROP the faked-system-time hack entirely - it
# is no longer needed at build OR runtime, which also keeps the shipped image clean.
echo "[build] floating LATEST archlinux-keyring into rootfs (off the snapshot pin)..."
# Source the CURRENT keyring from the build CONTAINER (archlinux:latest = rolling),
# NOT the rootfs's snapshot-pinned mirror (that would just hand back the old keyring).
# Install it on the container, then copy the freshly-installed keyring material into
# the rootfs over the snapshot's. The archlinux-keyring package is pure DATA (the key
# material + the trusted/revoked lists under /usr/share/pacman/keyrings), arch-
# independent, so copying its installed files into the rootfs is sound and gives the
# rootfs Arch's RENEWED dev keys (valid at the real 2026 clock).
pacman -Sy --noconfirm --disable-sandbox --needed archlinux-keyring >/dev/null 2>&1 || \
  pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1
_KR_VER="$(pacman -Q archlinux-keyring 2>/dev/null | awk '{print $2}')"
echo "[build] container archlinux-keyring: ${_KR_VER:-unknown} (floating into rootfs)"
cp -a /usr/share/pacman/keyrings/. "${ROOTFS}/usr/share/pacman/keyrings/" 2>/dev/null || true

# --- populate pacman's keyring so SigLevel=Required has a trust root ----------
# The keyring on disk is just key MATERIAL until imported into pacman's own gpg
# trust db. Run pacman-key --init then --populate archlinux INSIDE the rootfs so the
# [core]/[extra]/snapshot SigLevel=Required check (set above) has trusted Arch dev/
# master keys to verify against. MUST run before the package install below so the
# build-time installs from the 2025/09/01 snapshot are themselves signature-checked
# (catches a tampered build mirror too, not just runtime). arch-chroot supplies the
# /dev,/proc,/sys mounts pacman-key/gpg need; GNUPGHOME = the rootfs /etc/pacman.d/gnupg.
# NO faked-system-time: the floated current keyring's renewed keys are valid at the
# real clock, so the populate + verify both run under the real wall-clock.
install -d -m700 "${ROOTFS}/etc/pacman.d/gnupg"
echo "[build] populating pacman keyring in rootfs (pacman-key --init/--populate archlinux, real clock)..."
arch-chroot "${ROOTFS}" /bin/bash -c "
  set -e
  pacman-key --init
  pacman-key --populate archlinux
"
_keycnt="$(arch-chroot "${ROOTFS}" pacman-key --list-keys 2>/dev/null | grep -c '^pub' || true)"
[ "${_keycnt}" -ge 1 ] || { echo "[build] FATAL: pacman keyring did not populate (key count ${_keycnt}); SigLevel=Required would block all installs"; exit 1; }
# Stop the gpg-agent/keyboxd spawned by the populate and drop its transient sockets
# (S.gpg-agent*, S.keyboxd) so the squashfs ships only the PERSISTENT trust db
# (pubring.gpg, trustdb.gpg, private-keys-v1.d, ...) - not stale live sockets. The
# baked db is read at runtime as-is (the empty-tmpfs shadow mount is masked), so no
# runtime init is needed. A fresh process recreates any socket it needs on demand.
arch-chroot "${ROOTFS}" gpgconf --homedir /etc/pacman.d/gnupg --kill all >/dev/null 2>&1 || true
rm -f "${ROOTFS}/etc/pacman.d/gnupg/"S.* 2>/dev/null || true
echo "[build] pacman keyring populated (${_keycnt} keys, agent stopped) - Arch package sigs now verified"

