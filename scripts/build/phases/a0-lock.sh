# phase a0-lock - sourced by build-custom-image.sh; not standalone
# ============================================================================
# Away-from-keyboard - screensaver + optional password lockscreen
# ============================================================================
# Split roles. xscreensaver owns the IDLE eye-candy (classic Win95-style saver hacks) +
# DPMS blank/off and NEVER locks (lock:False always). The LOCKER is our own custom GTK3
# app, /usr/local/bin/partyos-lock-screen, which renders the EXACT Win95 "Welcome to
# Windows" logon dialog (teal bg, grey raised dialog, navy titlebar, gold key, User name +
# Password fields, OK/Cancel). It inherits the baked Chicago95 GTK theme for the grey
# panel/sunken entries/raised buttons and adds only ~30 lines of CSS for the teal bg +
# navy titlebar. It PAM-authenticates the RESOLVED unix user against /etc/shadow via a
# renamed /etc/pam.d/partyos-lock service (pam_unix, NO nullok) - the same crypt hash
# applied by partyos-identity-setup + partyos-set-passwd; zero custom crypto.
#
# HARDENING: the locker is a fullscreen override-redirect window that grabs keyboard +
# pointer atomically (gdk_seat_grab) and FAILS CLOSED (retry loop, never shows an
# ungrabbable field). The titlebar ?/X and Cancel are inert cosmetic widgets. partyos-lock
# is the SUPERVISOR: it respawns the locker on any non-zero exit so a `kill` re-locks;
# only an explicit exit 0 (genuine PAM unlock) clears the lock.
#
# Locking is OPTIONAL: it engages ONLY when the player set a password (a crypt hash on the
# USB home), so the default party kiosk just shows the saver and wakes on input - no risk
# of locking a passwordless rig out of itself. The `[ -s /mnt/usbhome/.partyos-passwd ]`
# gate routes passwordless rigs to the saver-only path; they NEVER reach the locker.
#
# CAVEAT: this is a SOFT away-from-keyboard lock for a LAN party, not a hardened kiosk.
# Ctrl+Alt+Fn VT-switching can't be blocked from an X11/userspace app, and the desktop
# user has NOPASSWD sudo (see partyos-identity-setup), so the machine's own owner can always defeat it.

# partyos-set-passwd (root, called via `sudo -n` from the wizard): validate a crypt
# hash from stdin, store it 0600 on the USB home, and apply it live to /etc/shadow.
# `--clear` removes it (back to passwordless). identity-setup reapplies it every boot.
bake "usr/local/bin/partyos-set-passwd"

# partyos-lock (desktop user): manual lock from the Win95 'Lock Screen' icon / Win+L /
# xfce4-session LockCommand. This is the SUPERVISOR for the custom Win95 locker. Only
# truly LOCKS when a password is set; otherwise it just shows the xscreensaver saver so a
# passwordless kiosk can never lock itself out (the locker - and its PAM path - is never
# reached). The LOCK is /usr/local/bin/partyos-lock-screen (the Win95 dialog); the
# saver-only fallback stays on xscreensaver.
bake "usr/local/bin/partyos-lock"

# --- Win95 locker assets: per-app CSS (the teal bg + navy titlebar the Chicago95 theme
# can't give). The grey #c0c0c0 face, sunken white entries and raised OK/Cancel buttons
# are all themed by the already-active Chicago95 GTK theme. The gold-key-over-card icon
# and the cosmetic ?/X titlebar glyphs are DRAWN with cairo inside partyos-lock-screen
# (python-cairo is a dep) - no baked PNG to lose at strip time, no host image tooling.
install -d "${ROOTFS}/usr/share/partyos/lock"
bake "usr/share/partyos/lock/style.css"
echo "[build] baked /usr/share/partyos/lock/style.css (teal bg + navy titlebar)"

# --- the custom Win95 "Welcome to Windows" PAM locker -------------------------
# python3 + PyGObject(GTK3). Renders the exact dialog (teal bg, grey raised frame, navy
# titlebar with cosmetic ?/X, gold key drawn with cairo, User name[prefilled nick] +
# Password fields, OK/Cancel), grabs keyboard+pointer atomically (fail-closed), runs as a
# fullscreen override-redirect window with no escape, and authenticates the RESOLVED unix
# user via ctypes->libpam against the "partyos-lock" PAM service. exit 0 == unlock; any
# other exit keeps the lock (the partyos-lock supervisor respawns it).
bake "usr/local/bin/partyos-lock-screen"
echo "[build] baked /usr/local/bin/partyos-lock-screen (custom Win95 PAM locker)"

# partyos-lock-setup (desktop user, per-session autostart): write ~/.xscreensaver (the
# classic-hack set + DPMS, lock:False ALWAYS - xscreensaver is the saver, never the
# locker) then start it. Wire the XFCE LockCommand + Win+L to partyos-lock, and - when a
# password exists - start xss-lock so X idle fires the gated Win95 locker. Idempotent.
# Easy to re-skin later (the `programs:` list is the saver content).
bake "usr/local/bin/partyos-lock-setup"

# PAM stack for the custom Win95 locker. partyos-lock-screen opens a transaction against
# the service name "partyos-lock"; without this file the locker can't authenticate and the
# screen would LOCK with no way to unlock. The body includes the image's existing
# system-login stack (pam_unix -> /etc/shadow, NO nullok - the SAME hash the old locker
# used). ASSERT it baked: a missing/malformed PAM file must never silently fail-open.
bake "etc/pam.d/partyos-lock"
[ -s "${ROOTFS}/etc/pam.d/partyos-lock" ] \
  || { echo "[build] FATAL: /etc/pam.d/partyos-lock was not baked - locker would fail-open/lock-out"; exit 1; }
grep -q 'include  system-login' "${ROOTFS}/etc/pam.d/partyos-lock" \
  || { echo "[build] FATAL: /etc/pam.d/partyos-lock missing system-login include"; exit 1; }
echo "[build] baked /etc/pam.d/partyos-lock (pam_unix -> /etc/shadow, no nullok)"

bake "etc/xdg/autostart/partyos-screensaver.desktop"
# Win95-classics ONLY: keep a tight whitelist of recognizable, OFFLINE hacks and delete
# the rest. This is bulletproof - `random` can only ever pick a classic regardless of the
# (finicky) ~/.xscreensaver programs list, and the networked scraper (webcollage, the one
# that fetched Wikipedia) physically no longer exists on this NO-INTERNET OS. Anchored on
# 3D Pipes. Ship exactly 3 GL hacks: pipes, the gltext banner, and maze3d - the
# first-person Win95 "3D Maze" recreation that SHIPS in xscreensaver 6.10 (hacks/glx/maze3d).
# All GL, but mesa/llvmpipe always provides software GL so a saver runs even without accel.
XSKEEP="pipes gltext maze3d"
if [ -d "${ROOTFS}/usr/lib/xscreensaver" ]; then
  for h in "${ROOTFS}/usr/lib/xscreensaver/"*; do
    b="$(basename "${h}")"
    case "${b}" in xscreensaver*) continue;; esac          # keep getimage/helper infra
    case " ${XSKEEP} " in *" ${b} "*) continue;; esac        # keep the classics
    rm -f "${h}" 2>/dev/null || true
  done
fi
# Rewrite the AUTHORITATIVE hack list (xscreensaver app-defaults `programs:`) to ONLY the
# classics. Deleting the other binaries isn't enough: xscreensaver's compiled-in default
# programs list still NAMES ~250 hacks and picks them at random; a pick whose binary we
# removed (e.g. `pacman`) throws a red "<hack> crashed with status 1" box on screen. With
# the list itself trimmed to present classics, nothing missing is ever referenced.
XSAD="${ROOTFS}/usr/lib/X11/app-defaults/XScreenSaver"
if [ -f "${XSAD}" ]; then
  awk '
    /^\*programs:/ {
      print "*programs:\t\\"
      print "   GL:\tpipes --root\t\\n\\"
      print "   GL:\tgltext -text partyOS --root\t\\n\\"
      print "   GL:\tmaze3d --root"
      inprog=1; next
    }
    inprog { if ($0 !~ /\\$/) inprog=0; next }   # drop old block lines through the last (no trailing backslash)
    { print }
  ' "${XSAD}" > "${XSAD}.new" && mv "${XSAD}.new" "${XSAD}" \
    && echo "[build] trimmed xscreensaver app-defaults programs list to Win95 classics (no missing-hack crash box)"
fi
echo "[build] baked screensaver/lock (xscreensaver Win95-classics saver+DPMS, custom partyos-lock-screen GTK 'Welcome to Windows' PAM locker, optional password)"

