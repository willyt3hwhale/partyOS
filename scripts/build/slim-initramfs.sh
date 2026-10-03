#!/bin/bash
set -e
pacman -Sy --disable-sandbox --noconfirm --quiet squashfs-tools mkinitcpio >/dev/null 2>&1
cd /srv
rm -rf /rootfs
echo "[ir] unsquashing slim sfs..."
unsquashfs -q -d /rootfs custom/arch/x86_64/airootfs.sfs >/dev/null
KVER=$(ls /rootfs/usr/lib/modules | head -1); echo "[ir] kernel: $KVER"
for f in /rootfs/etc/mkinitcpio.conf /rootfs/etc/mkinitcpio.conf.d/*.conf; do
  [ -f "$f" ] || continue
  grep -q '^HOOKS' "$f" && sed -i '/^HOOKS=/ s/ kms//' "$f"
done
echo "[ir] archiso HOOKS: $(grep '^HOOKS' /rootfs/etc/mkinitcpio.conf.d/archiso.conf)"
mount -t proc proc /rootfs/proc
mount --rbind /sys /rootfs/sys
mount --rbind /dev /rootfs/dev
echo "[ir] regenerating (no kms)..."
chroot /rootfs mkinitcpio -k "$KVER" -g /tmp/ir-new.img 2>&1 | tail -6
umount -R /rootfs/proc /rootfs/sys /rootfs/dev 2>/dev/null || true
cp /rootfs/tmp/ir-new.img /srv/initramfs-linux.img.new
echo "[ir] === verify ==="
echo "  size: $(ls -lh /srv/initramfs-linux.img.new | awk '{print $5}')"
echo "  archiso_pxe_http (MUST >=1): $(lsinitcpio /srv/initramfs-linux.img.new 2>/dev/null | grep -c archiso_pxe_http)"
echo "  nvidia fw files (want 0):    $(lsinitcpio /srv/initramfs-linux.img.new 2>/dev/null | grep -c firmware/nvidia)"
lsinitcpio -a /srv/initramfs-linux.img.new 2>/dev/null | grep -E 'Early CPIO|Size:'
echo "IR-DONE"
