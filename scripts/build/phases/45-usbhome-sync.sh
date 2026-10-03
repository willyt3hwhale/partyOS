# phase 45-usbhome-sync - sourced by build-custom-image.sh; not standalone
# --- partyos-usbhome: mount the participant USB home -------------------------
# Find the ext4 home partition on the boot stick and mount it rw at /mnt/usbhome. Runs
# BEFORE partyos-identity (which reads /mnt/usbhome/.partyos). Best-effort: a stick
# with no home partition (or no stick) just skips -> the RAM cache fallback.
# NO USERNAME MOUNT GATE here (unlike partyos-usb-reinserted): this boot-mount runs BEFORE
# identity, so there is no logged-in user yet to compare against - the login is DEFINED by
# whatever stick this mounts (partyos-identity reads its .partyos USERNAME). The box's own
# boot stick therefore always matches by construction; the foreign-stick refusal only makes
# sense post-identity, at the hotplug reinsert handler.
# partyos-usb-labels.sh: the ordered partition label lists (cmdline or baked
# default) and the label -> device lookup. Every stick consumer sources it.
bake "usr/local/lib/partyos-usb-labels.sh"
bake "usr/local/bin/partyos-usbhome"
bake "etc/systemd/system/partyos-usbhome.service"
ln -sf /etc/systemd/system/partyos-usbhome.service \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants/partyos-usbhome.service" 2>/dev/null || \
ln -sf /etc/systemd/system/partyos-usbhome.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-usbhome.service"
install -d "${ROOTFS}/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/partyos-usbhome.service \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants/partyos-usbhome.service"
echo "[build] baked partyos-usbhome.service (mounts the home partition at /mnt/usbhome, enabled)"

# ============================================================================
# PERSISTENT RAM HOME with rsync sync (Steps 4/5/6 + safe eject, BAKED into the image)
# ============================================================================
# The dev-only boot scripts (boot/step5-script.sh + step6-script.sh) prove the
# RAM-home<->USB sync in QEMU but are NEVER in the production squashfs. This block
# ports those proven helpers into the image and HARDENS them:
#   (a) FIRST-BOOT SEED  - seed an empty p2:/home from the baked /usr/share/partyos/
#       home-skel BEFORE any --delete pull, so the pull can't wipe the seed.
#   (b) SANE-SOURCE ABORT - never --delete-mirror from an unexpectedly-empty or
#       failed-mount source (either direction); ro USB -> never push.
#   (c) PUSH GATED ON PULL BASELINE - the runtime push is a no-op until the boot
#       pull wrote /run/partyos-home-pull-done.
#   (d) GENERATION GUARD - stamp a counter in p2:/.partyos-home-state on each
#       pull/push; on reinsert, if the stick's generation is NEWER than what THIS
#       box last synced, PULL instead of push (stick came from another partyOS box).
# The home CONTENT lives in p2:/home/ (a subdir); .partyos / user.conf /
# .partyos-passwd / .partyos-cache stay at the p2 ROOT, so the --delete mirror of
# RAM:/home/<user>/ <-> p2:/home/ can never delete the identity or the blob cache.

# --- shared rsync excludes + helpers, sourced by every sync helper -----------
bake "usr/local/lib/partyos-sync-common.sh"

# --- partyos-home-pull: the BOOT pull (guards a + b, then writes pull-done) ---
bake "usr/local/bin/partyos-home-pull"

# --- partyos-sync-home: the RUNTIME push (guards b + c + d) -------------------
bake "usr/local/bin/partyos-sync-home"

# --- partyos-usb-notify: desktop + serial + status-file USB notification ------
bake "usr/local/bin/partyos-usb-notify"

# --- partyos-usb-removed: pause sync on USB removal (port of step6) ----------
bake "usr/local/bin/partyos-usb-removed"

# --- partyos-usb-reinserted: remount + generation-guard + resume (port step6)-
bake "usr/local/bin/partyos-usb-reinserted"

# --- partyos-usb-poll: SAFETY-NET reconciler for missed udev events ----------
# udev is the primary hotplug path (99-partyos-usbhome.rules); on the rare dropped
# event the mount state and the real device state can drift. This low-frequency
# poller reconciles them by re-triggering the SAME handlers (it never mounts or
# unmounts itself - it just kicks the serialized reinsert/removed oneshots, which
# already flock). It must NOT fight a deliberate safe-eject: a paused state means
# the player ejected on purpose, so we never auto-remount while PAUSE_FLAG is set.
bake "usr/local/bin/partyos-usb-poll"

# --- partyos-safe-eject: final sync, pause, unmount, "safe to remove" ---
bake "usr/local/bin/partyos-safe-eject"

# A desktop launcher for safe eject so the player can eject from the desktop.
bake "usr/share/applications/partyos-safe-eject.desktop"

# --- systemd units: boot pull, runtime push timer, finalsync, hotplug --------
bake "etc/systemd/system/partyos-home-pull.service"

bake "etc/systemd/system/partyos-home-sync.service"

bake "etc/systemd/system/partyos-home-sync.timer"

bake "etc/systemd/system/partyos-home-finalsync.service"

bake "etc/systemd/system/partyos-usb-removed.service"

# The udev remove rule starts this template with the MAJ:MIN of the removed partition.
bake "etc/systemd/system/partyos-usb-removed@.service"

bake "etc/systemd/system/partyos-usb-reinserted.service"

# Safety-net poller: reconciles mount state vs the real device for missed udev events.
# LONG-LIVED loop service (NOT a timer-fired oneshot): the script sleeps internally, so a
# quiet box no longer racks up a SERVICE_START/STOP + kernel-audit pair every ~8s.
# Restart if the loop ever dies.
bake "etc/systemd/system/partyos-usb-poll.service"

# udev rules: match a home label on add/remove and START the matching service
# (--no-block). udev RUN+= runs in a private mount namespace where mount is denied,
# so we never mount from udev - the systemd oneshots do it in the proper namespace.
install -d "${ROOTFS}/etc/udev/rules.d"
bake "etc/udev/rules.d/99-partyos-usbhome.rules"

# Enable the always-on units via *.wants symlinks (no systemctl under emulation).
install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
install -d "${ROOTFS}/etc/systemd/system/timers.target.wants"
ln -sf /etc/systemd/system/partyos-home-pull.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-home-pull.service"
ln -sf /etc/systemd/system/partyos-home-finalsync.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-home-finalsync.service"
ln -sf /etc/systemd/system/partyos-home-sync.timer \
    "${ROOTFS}/etc/systemd/system/timers.target.wants/partyos-home-sync.timer"
ln -sf /etc/systemd/system/partyos-usb-poll.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-usb-poll.service"
# partyos-usb-removed/reinserted are udev-triggered (started by the rules), not
# enabled at boot - no *.wants symlink needed.
echo "[build] baked persistent RAM-home rsync sync (boot pull + push timer + finalsync + hotplug + poll safety-net + safe-eject)"

