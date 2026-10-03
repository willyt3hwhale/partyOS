# phase c0-finalize - sourced by build-custom-image.sh; not standalone
# --- 5.9 bake the read-only home SKELETON (first-boot seed source) -----------
# partyos-home-pull seeds an empty USB home (p2:/home) from this fixed read-only
# tree on first boot, BEFORE any --delete pull. It is a snapshot of the fully-baked
# /home/gamer template (Desktop launchers, .config, mimeapps, the retro tools).
# MUST run AFTER all /home/gamer content is baked (it is - this is near the end).
# Copied (not symlinked) so it survives the gamer->username rename + stays uid 1000.
echo "[build] baking read-only home skeleton from /home/gamer -> /usr/share/partyos/home-skel..."
install -d "${ROOTFS}/usr/share/partyos"
rm -rf "${ROOTFS}/usr/share/partyos/home-skel"
cp -a "${ROOTFS}/home/gamer" "${ROOTFS}/usr/share/partyos/home-skel"
# A ~/Shared real dir must NOT live in the skel (it is a runtime symlink to the p3
# mount, created by identity-setup + excluded from the home rsync).
rm -rf "${ROOTFS}/usr/share/partyos/home-skel/Shared" 2>/dev/null || true
chown -R 1000:1000 "${ROOTFS}/usr/share/partyos/home-skel" 2>/dev/null || true
echo "[build] home-skel: $(du -sh "${ROOTFS}/usr/share/partyos/home-skel" 2>/dev/null | cut -f1)"

# --- 6. emit pkglist for the Step 3 package-presence assertion ---------------
echo "[build] generating pkglist..."
arch-chroot "${ROOTFS}" /bin/bash -c 'pacman -Q' > "${OUT_DIR}/pkglist.x86_64.txt"
echo "[build] pkglist has $(wc -l < "${OUT_DIR}/pkglist.x86_64.txt") packages"

# --- 7. clean caches so the squashfs stays lean ------------------------------
echo "[build] cleaning pacman cache..."
rm -rf "${ROOTFS}/var/cache/pacman/pkg/"* 2>/dev/null || true
# Restore resolv.conf as the systemd-resolved stub symlink (the live default).
rm -f "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true
ln -sf /run/systemd/resolve/stub-resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true
# The build-time resolver (host copy or 1.1.1.1/8.8.8.8) must never ship in the image.
if [ "$(readlink "${ROOTFS}/etc/resolv.conf" 2>/dev/null)" != /run/systemd/resolve/stub-resolv.conf ]; then
    echo "[build] FATAL: /etc/resolv.conf is not the resolved stub symlink, the build resolver would leak" >&2
    exit 1
fi
# keep pacman sync db small
rm -rf "${ROOTFS}/var/lib/pacman/sync/"* 2>/dev/null || true

# --- 7.5 slim the rootfs (boot transfer is the dominant boot-time cost) ------
# A LAN-party netboot ships the whole image over the wire on every boot, so every
# MB removed is real boot-time saved. We drop content not needed to reach a
# working ethernet-connected XFCE desktop. Measured: ~1.4GB off the rootfs,
# ~546MB off the xz sfs (1.6GB -> 1.07GB), ~7s off a real-gigabit boot.
echo "[build] slimming rootfs (docs, non-en locale, wifi/bt firmware)..."
# docs / man / info - host them separately if ever needed.
rm -rf "${ROOTFS}/usr/share/doc/"* "${ROOTFS}/usr/share/man/"* \
       "${ROOTFS}/usr/share/info/"* "${ROOTFS}/usr/share/gtk-doc" \
       "${ROOTFS}/usr/share/help" 2>/dev/null || true
# locale: keep en only.
find "${ROOTFS}/usr/share/locale" -mindepth 1 -maxdepth 1 -type d ! -name 'en*' \
    -exec rm -rf {} + 2>/dev/null || true
# firmware: wired ethernet only - drop wifi/bt + exotic-NIC blobs. KEEP nvidia
# (GSP firmware nouveau needs), intel/amdgpu/i915/radeon (GPU), *ucode, ethernet,
# audio (cirrus).
( cd "${ROOTFS}/usr/lib/firmware" 2>/dev/null && \
  rm -rf mrvl mediatek ath11k ath10k ath12k ath9k_htc ath6k ath3k atmel brcm cypress \
         libertas mwlwifi rtw88 rtw89 rtlwifi ti-connectivity wfx qca dpaa2 cxgb4 \
         bnx2x vxge rtl_bt 2>/dev/null; \
  rm -f iwlwifi-*.ucode 2>/dev/null ) || true
echo "[build] slimmed rootfs: $(du -sh "${ROOTFS}" | cut -f1)"

# Defensive: ensure NO faked-system-time pin survives into the shipped image. The
# latest-keyring float (section 2b) means the build no longer sets one, but strip any
# stray line so the booted OS's runtime gpg/pacman-key always runs on the real clock
# (the first-boot populate + runtime SigLevel=Required verify need the real wall-clock
# so the renewed keys validate). The keyring itself (trustdb + imported keys) stays.
if [ -f "${ROOTFS}/etc/pacman.d/gnupg/gpg.conf" ]; then
  sed -i "/^faked-system-time /d" "${ROOTFS}/etc/pacman.d/gnupg/gpg.conf"
fi

# --- 8. re-squash into the archiso HTTP layout -------------------------------
# The archiso PXE-http hook fetches ${archiso_http_srv}${archisobasedir}/x86_64/
# airootfs.sfs (+ .sha512). We lay the custom sfs out so the server can serve it
# at custom/arch/x86_64/airootfs.sfs, reusing the same kernel/initramfs Step 2
# already boots. pkglist stays at the top of /out for the host test to read.
SFS_DIR="${OUT_DIR}/arch/x86_64"
install -d "${SFS_DIR}"
echo "[build] mksquashfs -> ${SFS_DIR}/airootfs.sfs (zstd, this takes several minutes)..."
rm -f "${SFS_DIR}/airootfs.sfs"
mksquashfs "${ROOTFS}" "${SFS_DIR}/airootfs.sfs" \
  -comp zstd -Xcompression-level 19 -noappend -no-progress 2>&1 | tail -5

# checksum for integrity (archiso checksum= path can use this if ever wanted).
( cd "${SFS_DIR}" && sha512sum airootfs.sfs > airootfs.sha512 )
# arch/version + a copy of the pkglist where archiso expects them.
echo "2025.09.01-partyos" > "${OUT_DIR}/arch/version"
cp "${OUT_DIR}/pkglist.x86_64.txt" "${OUT_DIR}/arch/pkglist.x86_64.txt"
echo "[build] custom airootfs.sfs: $(du -h "${SFS_DIR}/airootfs.sfs" | cut -f1)"
echo "[build] === DONE ==="
