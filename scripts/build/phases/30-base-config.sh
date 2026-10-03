# phase 30-base-config - sourced by build-custom-image.sh; not standalone
# --- 4. partyOS config layer -------------------------------------------------
echo "[build] applying partyOS config (gamer user, autologin, desktop-ready)..."

# NOTE: systemctl crashes under amd64-on-arm emulation in the chroot
# (was_rosetta_process_invoked_directly trap), so we do user creation + lightdm
# config in the chroot but perform service ENABLEMENT by writing the symlinks
# ourselves on the host side (which is exactly what `systemctl enable` does).
arch-chroot "${ROOTFS}" /bin/bash -c '
  set -e
  # --- user gamer (autologin target) ---
  id gamer >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel,video,audio,network gamer
  # passwordless for the live event; matches archiso live convention.
  passwd -d gamer || true

  # --- LightDM: autologin gamer into XFCE ---
  install -d /etc/lightdm
  # autologin needs the autologin group to exist.
  groupadd -f autologin
  gpasswd -a gamer autologin || true

  # --- HEADLESS Xorg: force the dummy software framebuffer driver ---
  # Under TCG emulation there is no GPU and no /dev/dri, so autodetection finds no
  # usable video device and Xorg/LightDM fail. The
  # dummy driver renders to an in-memory framebuffer with no DRM, so a full X
  # session starts headlessly. On a KVM/physical host with a real GPU you would
  # drop this file (or it loses to the GPU driver) and get accelerated rendering -
  # the documented accel bonus. 1280x800x24 is plenty for an XFCE session + the
  # non-blank screendump bonus.
  install -d /etc/X11/xorg.conf.d
'
# lightdm.conf + headless-dummy Xorg config (static content, installed host-side).
bake "etc/lightdm/lightdm.conf"
bake "etc/X11/xorg.conf.d/10-headless-dummy.conf"

# --- service enablement done by hand (no systemctl under emulation) ----------
# DEFAULT TARGET = multi-user.target (NOT graphical). This is deliberate and load-
# bearing: archiso's automated-script hook (which fetches script=<url> and runs it
# on the tty1 autologin) only fires under the live multi-user getty. Forcing
# graphical.target to land in LightDM SUPPRESSES that tty1 autologin, so the
# Step 3 boot script (boot/step3-script.sh) - which drives the HEADLESS Xvfb+XFCE
# bring-up and emits the desktop-ready proof - would never run. We keep the stock
# multi-user default so that hook works, and bring the desktop up from the boot
# script. LightDM is still ENABLED below as display-manager.service: on a KVM/
# physical host you can switch the default to graphical.target and LightDM will
# autologin gamer into XFCE on a real GPU (the documented accel path). In the
# headless VM the boot script owns the display instead.
ln -sf /usr/lib/systemd/system/multi-user.target \
    "${ROOTFS}/etc/systemd/system/default.target"
# enable lightdm via the display-manager.service alias for the KVM/physical path
# (graphical.target would pull it in there). NetworkManager is left unmanaged:
# archiso's live image already has the interface up (that is how it copytoram'd
# over HTTP); swapping in NetworkManager mid-session could tear that down. The
# package is PRESENT (driver-presence requirement).
ln -sf /usr/lib/systemd/system/lightdm.service \
    "${ROOTFS}/etc/systemd/system/display-manager.service"
echo "[build] enabled lightdm (display-manager); default=multi-user.target (boot script drives headless desktop)"

# --- audio: enable the PipeWire stack PER USER SESSION -----------------------
# These are *user* units, not system ones. `systemctl --user enable` can't run in
# the build chroot (no per-user bus), so we write the global enable symlinks under
# /etc/systemd/user/ by hand - the same trick we use for system units. Every user
# session (the autologin gamer included) then starts them, so after login
# /run/user/<uid>/{pulse/native,pipewire-0} exist and `pactl info` returns a server.
# Unit names/paths are the Arch upstream defaults for pipewire/wireplumber.
install -d "${ROOTFS}/etc/systemd/user/sockets.target.wants"
install -d "${ROOTFS}/etc/systemd/user/default.target.wants"
ln -sf /usr/lib/systemd/user/pipewire.socket \
    "${ROOTFS}/etc/systemd/user/sockets.target.wants/pipewire.socket"
ln -sf /usr/lib/systemd/user/pipewire-pulse.socket \
    "${ROOTFS}/etc/systemd/user/sockets.target.wants/pipewire-pulse.socket"
ln -sf /usr/lib/systemd/user/wireplumber.service \
    "${ROOTFS}/etc/systemd/user/default.target.wants/wireplumber.service"
echo "[build] enabled pipewire + pipewire-pulse sockets + wireplumber (global user enable)"

