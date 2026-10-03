# phase 80-diagnostics - sourced by build-custom-image.sh; not standalone
# --- persistent journal on the USB: snapshot model ---------------------------------------
# partyOS runs from RAM, so the live journal is lost at every reboot.
# partyos-journal-snapshot copies the live journal of the current boot to
#   /mnt/usbhome/.partyos-journal/boot-<YYYYmmdd-HHMMSS>-<short-boot-id>/
# A timer runs it every 60s and a shutdown oneshot runs it once more. The last 5 boots are kept.
# The machine-id changes every boot, so partyos-lastboot-log reads the saved files with
# `journalctl --directory`. The dir is outside /home, so the home-pull --delete mirror skips it.
# All copies are best-effort and bounded by `timeout`, so a slow stick cannot block boot or shutdown.
install -d "${ROOTFS}/var/log/journal"
bake "etc/systemd/journald.conf"

# --- the snapshot script: copy the live journal to a timestamped per-boot dir on the USB ----
# Best-effort + bounded so a missing/slow stick can NEVER wedge boot OR shutdown.
bake "usr/local/bin/partyos-journal-snapshot"

# --- partyos-lastboot-log: read a SAVED per-boot journal back (defaults to the PREVIOUS boot)
bake "usr/local/bin/partyos-lastboot-log"

# --- units: snapshot timer (every 60s) + shutdown oneshot ----------------------------------
bake "etc/systemd/system/partyos-journal-snapshot.service"

bake "etc/systemd/system/partyos-journal-snapshot.timer"
install -d "${ROOTFS}/etc/systemd/system/timers.target.wants"
ln -sf /etc/systemd/system/partyos-journal-snapshot.timer \
    "${ROOTFS}/etc/systemd/system/timers.target.wants/partyos-journal-snapshot.timer"

# Shutdown oneshot: one final snapshot on a CLEAN reboot so we capture the last ~60s of the
# session up to the moment of shutdown. Best-effort and bounded so it cannot block shutdown.
bake "etc/systemd/system/partyos-journal-snapshot-shutdown.service"
install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/partyos-journal-snapshot-shutdown.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-journal-snapshot-shutdown.service"

echo "[build] baked journal-snapshot (timer+shutdown) + partyos-lastboot-log (diagnostics)"

# --- guaranteed reboot bound: hardware watchdog + sysrq fallback -------------
# A D-state process on a slow USB can block umount.target past every userspace timeout.
# RuntimeWatchdogSec keeps the hardware watchdog armed for the whole session, so if PID 1
# stops petting it (a D-state wedge included), the chip resets the box and it re-PXEs.
# RebootWatchdogSec gives a tighter bound once the final reboot phase is reached.
# The watchdog driver is not auto-loaded, so modules-load.d loads iTCO_wdt, common
# alternates and a softdog fallback. Without /dev/watchdog0 the systemd watchdog does nothing.
install -d "${ROOTFS}/etc/modules-load.d"
bake "etc/modules-load.d/partyos-watchdog.conf"
# Belt: some firmware exposes iTCO only after the vendor-support shim and a bounded
# heartbeat; modules-load.d handles load order, but make softdog non-fatal if iTCO binds
# first (only one /dev/watchdog0 is used by systemd anyway). nowayout via module param so a
# crashed pet-loop still resets (the chip cannot be disarmed by closing the device).
install -d "${ROOTFS}/etc/modprobe.d"
bake "etc/modprobe.d/partyos-watchdog.conf"
install -d "${ROOTFS}/etc/systemd/system.conf.d"
bake "etc/systemd/system.conf.d/20-partyos-reboot-watchdog.conf"
install -d "${ROOTFS}/etc/sysctl.d"
bake "etc/sysctl.d/99-partyos-sysrq.conf"
# Quiet the boot CONSOLE scroll: the Intel SOF driver (sof-audio-pci-intel-cnl) probes
# the HDMI/DisplayPort display-audio codecs (iDisp1/2/3) and logs dozens of harmless
# "ASoC error (-22)" lines at KERN_ERR when no HDMI audio sink is wired. These are
# cosmetic - the onboard sof-hda-dsp analog path still works. Lower the CONSOLE loglevel
# to 3 (EMERG/ALERT/CRIT only) so the ERR storm stops scrolling the tty; everything is
# STILL in the kernel ring buffer (dmesg / journalctl -k). This touches ONLY console
# verbosity, NOT the audio stack, so analog + HDMI audio are untouched. Tradeoff: genuine
# kernel ERR/WARN also stay out of the console scroll but remain in dmesg/journald.
bake "etc/sysctl.d/50-partyos-quiet-console.conf"
echo "[build] baked guaranteed-reboot bound: HW watchdog (iTCO/softdog, 120s) + RuntimeWatchdogSec=90s + RebootWatchdogSec=60s + kernel.sysrq=1"

# --- bake the extracted game icons (native game icons) --------------------
# Games are blobs (not installed system-wide), so their app icons aren't in the
# image's icon theme. scripts/build/extract-game-icons.sh pulled each blob's native
# icon into server/games/icons/<name>.png; bake them at a fixed path the catalog
# rows point Icon= at (/usr/share/pixmaps/partyos-games/<name>.png), so the desktop
# launchers show real icons instead of the generic gamepad.
GICONS="$(dirname "${BASH_SOURCE[0]}")/../../server/games/icons"; [ -d "${GICONS}" ] || GICONS=/game-icons
if [ -d "${GICONS}" ]; then
    install -d "${ROOTFS}/usr/share/pixmaps/partyos-games"
    cp -f "${GICONS}"/*.png "${ROOTFS}/usr/share/pixmaps/partyos-games/" 2>/dev/null || true
    echo "[build] baked $(ls -1 "${ROOTFS}/usr/share/pixmaps/partyos-games/"*.png 2>/dev/null | wc -l | tr -d ' ') native game icons"
else
    echo "[build] WARN no game-icons dir (${GICONS}) - launchers fall back to category icons"
fi

