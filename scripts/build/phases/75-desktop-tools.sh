# phase 75-desktop-tools - sourced by build-custom-image.sh; not standalone
# --- default Win95-style desktop tools ---------------------------------------
# Static launchers for apps already in the image, with retro names + Chicago95
# icons. They survive gen-launchers refreshes (it only removes partyos-app /
# category launchers, never these). The browser (Internet Explorer) + NYET
# Messenger launchers are added by their own sections.
# Win95-style desktop tool launchers (pre-expanded static .desktop files; see
# files/rootfs/home/gamer/Desktop/*.desktop - identical to the _tool_launcher output).
bake "home/gamer/Desktop/cmd.exe.desktop"
bake "home/gamer/Desktop/control-panel.desktop"
bake "home/gamer/Desktop/my-computer.desktop"
bake "home/gamer/Desktop/faq.desktop"

# --- Recycle Bin: a Win95 desktop "folder" with a prank Windows installer -----
# The Recycle Bin opens a hidden dir holding one gag launcher, "Windows
# Installer.exe", that pretends to install Windows over partyOS and (of course)
# fails. Pure joke; harmless. The gen-launchers refresh never touches non
# partyos-app desktop files or .recycle-bin, so this survives every boot.
bake "usr/local/bin/partyos-win-installer"
install -d -o 1000 -g 1000 "${ROOTFS}/home/gamer/Desktop/.recycle-bin"
bake "home/gamer/Desktop/.recycle-bin/Windows Installer.exe.desktop"
# open via $HOME (resolved at runtime) - the home dir is renamed gamer->username
# at first boot, so an absolute /home/gamer path would break.
bake "usr/local/bin/partyos-recyclebin"
bake "home/gamer/Desktop/Recycle Bin.desktop"

chown -R 1000:1000 "${ROOTFS}/home/gamer/Desktop" 2>/dev/null || true
echo "[build] baked Win95 desktop tools (cmd.exe, Control Panel, My Computer, FAQ, Recycle Bin)"

# A per-boot oneshot regenerates the per-app menu + desktop icons from the live LAN
# catalog (best-effort; never fatal) so the icons - which ARE the store - reflect
# whatever the catalog currently serves.
bake "usr/local/bin/partyos-appstore-refresh"
bake "etc/systemd/system/partyos-appstore.service"
ln -sf /etc/systemd/system/partyos-appstore.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-appstore.service"
echo "[build] baked partyos-appstore.service (per-boot shortcut refresh, enabled)"

# A timer re-runs the shortcut refresh periodically so the icons self-heal after any
# boot-time race (e.g. the home-pull --delete mirror wiping fresh launchers) AND pick
# up server-side catalog changes without a reboot. Mirrors partyos-home-sync.timer.
# The timer drives its OWN oneshot (no RemainAfterExit) - a timer-started oneshot with
# RemainAfterExit=yes stays "active (exited)" and would never re-run ExecStart.
bake "etc/systemd/system/partyos-appstore-refresh.service"
bake "etc/systemd/system/partyos-appstore.timer"
install -d "${ROOTFS}/etc/systemd/system/timers.target.wants"
ln -sf /etc/systemd/system/partyos-appstore.timer \
    "${ROOTFS}/etc/systemd/system/timers.target.wants/partyos-appstore.timer"
echo "[build] baked partyos-appstore.timer + refresh service (periodic shortcut refresh, enabled)"

# --- partyos-seeder.service: ONE client aria2c for seeding + downloads ---
# The USB blob cache survives a reboot. partyos-seeder.service runs one aria2c with
# JSON-RPC on loopback (partyos-aria2d). Its ExecStartPost adds every cached blob
# without a re-hash (partyos-seed-cached), so every booted client with cached games
# seeds from the start. Downloads go through the same aria2c (partyos-aria2rpc).
# Seeding is unbounded (until eviction) and capped by blob_seed_up_limit.
bake "usr/local/bin/partyos-aria2d"
bake "usr/local/bin/partyos-aria2rpc"
bake "usr/local/bin/partyos-seed-cached"
bake "etc/systemd/system/partyos-seeder.service"
ln -sf /etc/systemd/system/partyos-seeder.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-seeder.service"
echo "[build] baked partyos-seeder.service (one client aria2c: seed + download over RPC, enabled)"

# --- partyos-shutdown-teardown.service: free everything that blocks reboot ---
# Reboot-hang fix: a soft `systemctl reboot` hung the box on the
# splash, ssh dead, never re-PXEd -> physical power-cycle. Root cause: nothing tore
# down the long-lived game/seeding processes + the USB-backed game overlays before
# shutdown, so the USB unmount + finalsync blocked indefinitely. This oneshot runs
# its teardown in ExecStop, ordered Before the USB-home unmount + umount.target, to:
#   1. kill the aria2 seeders + wine/wineserver/bwrap game procs (TERM, then KILL
#      after a few seconds) - bounded, so a stuck proc can't hang us.
#   2. lazily unmount the game overlays under /run/partyos-games/* (overlay dest +
#      squashfs lowerdir whose blob lives on the USB) so the USB is no longer busy.
# RemainAfterExit=yes + ExecStart=/bin/true: the unit is "active" all session so its
# ExecStop fires exactly once on the way down. DefaultDependencies=no + the explicit
# Before/Conflicts wire it into the shutdown transaction ahead of the unmounts.
bake "usr/local/bin/partyos-shutdown-teardown"
bake "etc/systemd/system/partyos-shutdown-teardown.service"
ln -sf /etc/systemd/system/partyos-shutdown-teardown.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-shutdown-teardown.service"
echo "[build] baked partyos-shutdown-teardown.service (reboot-hang fix, enabled)"

