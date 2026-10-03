# phase b5-desktop-ready - sourced by build-custom-image.sh; not standalone
# --- 5. desktop-ready callback (the Step 3 autonomous "screen came up" proof)
# An XFCE autostart .desktop runs once the gamer session starts. It writes a
# serial marker AND curls the report URL. report_url is read from /proc/cmdline
# (injected by partyos.ipxe, same mechanism Step 2 uses) so no IP is hardcoded.
install -d "${ROOTFS}/etc/xdg/autostart"
install -d "${ROOTFS}/usr/local/bin"
bake "usr/local/bin/partyos-desktop-ready"

bake "etc/xdg/autostart/partyos-desktop-ready.desktop"

# --- 5b. baked XFCE launcher helper (used by the fetched boot script) ---------
# The actual headless desktop bring-up is driven by boot/step3-script.sh, fetched
# at boot via the archiso script= hook and run on the tty1 autologin (which is why
# default.target stays multi-user above). Keeping it in a FETCHED script lets the
# in-guest desktop logic be iterated without rebuilding this ~1.6GB squashfs.
# This small launcher is baked in as a clean-env entry point the boot script (or a
# KVM display manager) can exec to start the gamer session: it sets DISPLAY,
# XDG_RUNTIME_DIR and a session dbus (xfce4-session needs all three) and prefers
# startxfce4 (the canonical wrapper) over a bare xfce4-session.
bake "usr/local/bin/partyos-xfce-launch"

# Enable linger for gamer so systemd --user (+ /run/user/UID/bus) starts at boot,
# independent of a login - this is what makes portals/user services available.
install -d "${ROOTFS}/var/lib/systemd/linger"
: > "${ROOTFS}/var/lib/systemd/linger/gamer"

