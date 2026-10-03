# phase 70-report-notify - sourced by build-custom-image.sh; not standalone
# --- partyos-report: in-session "Report an Issue" player INBOX -----------------
# A player hits the Win95 "Report an Issue" tile -> this pops a zenity form with a
# free-text MESSAGE field + a "this is a bug - attach system info" CHECKBOX. The
# checkbox is the consent gate for system context (opt-in, no silent capture):
#   * UNTICKED (default, the suggestion-box case): the report is nick + message ONLY.
#     No hostname, no journal, no RAM, no game. A pure inbox entry.
#   * TICKED (the debuggable-bug case): the report ALSO carries build_id + a bounded
#     journal tail (the core "system info"), plus the cheap-and-useful game + free
#     RAM. Kept lean - message + nick + build + journal-tail is the spirit.
# Then it POSTs to the LAN server's /feedback endpoint (report_url= on the cmdline,
# same channel every boot script uses; HTTPS pins the baked CA). If the server is
# unreachable the report is QUEUED on the USB stick and a flush unit drains it once
# the server reappears. Runs UNPRIVILEGED as the desktop user (sudo never invoked).
#
# The context collector (collect_context) is carved out + unit-tested by
# scripts/test/test-report-feedback.sh, so don't reshape it without updating that.
#
# Scriptable for tests/automation (no GUI): set PARTYOS_REPORT_MESSAGE to the body
# and PARTYOS_REPORT_BUG=1 to opt into system info; the script then sends without
# popping any zenity dialog. Unset = the interactive GUI path.
bake "usr/local/bin/partyos-report"
echo "[build] baked partyos-report (in-session player issue reporter)"

# --- partyos-report-flush: drain the offline report queue to the server -------
# Mirrors the home-sync "best-effort when reachable" idea: a oneshot driven by a
# timer that, IFF the server answers, POSTs each queued /mnt/usbhome/.partyos-reports/*
# to /feedback and removes it ON SUCCESS only (a failed POST keeps the file for the
# next tick). Bounded curls; never fatal. Runs as root via the system timer but
# touches only the player's queue dir on the USB.
bake "usr/local/bin/partyos-report-flush"

bake "etc/systemd/system/partyos-report-flush.service"

bake "etc/systemd/system/partyos-report-flush.timer"

install -d "${ROOTFS}/etc/systemd/system/timers.target.wants"
ln -sf /etc/systemd/system/partyos-report-flush.timer \
    "${ROOTFS}/etc/systemd/system/timers.target.wants/partyos-report-flush.timer"
echo "[build] baked partyos-report-flush (offline report queue drain, timer-driven)"

# --- partyos-timesync: set the client clock from the LAN server's Date header --
# The party LAN is ISOLATED (no internet, no public NTP), so the ONE trusted time
# source is the partyOS server itself: an HTTPS HEAD to the server root returns an
# RFC1123 Date header we parse and apply. Best-effort by design - it NEVER blocks
# boot: a short curl timeout, a couple of retries, then it gives up quietly and
# leaves the clock as-is. The SERVER_BASE/cacert idiom is copied verbatim from
# partyos-report-flush (the closest analog - a headless, system-scoped, network
# oneshot+timer). A boot-time run corrects the clock BEFORE partyos-home-pull writes
# the RAM home (so its generation/mtimes are sane); a timer re-runs it to trim drift.
bake "usr/local/bin/partyos-timesync"

bake "etc/systemd/system/partyos-timesync.service"

bake "etc/systemd/system/partyos-timesync.timer"

install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
install -d "${ROOTFS}/etc/systemd/system/timers.target.wants"
ln -sf /etc/systemd/system/partyos-timesync.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-timesync.service"
ln -sf /etc/systemd/system/partyos-timesync.timer \
    "${ROOTFS}/etc/systemd/system/timers.target.wants/partyos-timesync.timer"
echo "[build] baked partyos-timesync (LAN clock from server Date header, boot run + drift timer)"

# ============================================================================
# Operator broadcasts - in-session desktop poller for the server notices feed
# ============================================================================
# A session-scoped autostart loop (NOT a system timer): it needs DISPLAY +
# DBUS_SESSION_BUS_ADDRESS to pop notify-send toasts, which only exist inside the
# gamer XFCE session. report-flush is system-scoped and headless, so it uses a
# timer; this poller MUST live in the session, hence the /etc/xdg/autostart entry
# below. The SERVER_BASE/cacert idiom is copied verbatim from partyos-report-flush
# (the closest analog).
#
# FOCUS-SAFE BY DESIGN: every notice is delivered ONLY via notify-send, which the
# notification daemon (xfce4-notifyd) renders as an override-redirect, NON-focus-
# stealing OSD overlay. There is NO managed/focus-grabbing window anywhere in this
# poller (no zenity, no dialog). A notice arriving while a player is in a fullscreen
# game can therefore NOT steal keyboard/mouse focus, un-fullscreen/minimize the game,
# or tab the player out. (xfce4-notifyd's do-not-disturb / fullscreen-suppression is
# explicitly turned OFF in partyos-lock-setup so broadcasts still appear during play.)
#
# --- partyos-notify-poll: show operator broadcasts as focus-safe OSD toasts ---
bake "usr/local/bin/partyos-notify-poll"

bake "etc/xdg/autostart/partyos-notify-poll.desktop"
echo "[build] baked partyos-notify-poll (operator-broadcast session poller, autostart-driven)"

