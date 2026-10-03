#!/usr/bin/env bash
# step5-script.sh - autonomous in-guest VERIFIER for Step 5 (Continuous Home
# Synchronization). Fetched at boot via archiso's automated-script hook
# (partyos-step5.ipxe passes script=<server>/boot/step5-script.sh). It runs on the
# tty1 root autologin once the live system is up, so it has full control and
# mirrors everything to the serial console the harness scrapes.
#
# IMPORTANT - VERIFIER ONLY, NOT AN INSTALLER:
# The home-sync logic (partyos-home-pull / partyos-sync-home / the timer + the
# finalsync-on-shutdown unit + the shared partyos-sync-common.sh) is now BAKED into
# the production squashfs (scripts/build/build-custom-image.sh). This script does
# NOT install or overwrite any of those paths anymore - doing so would shadow the
# shipped units and make a green test prove the DEV code rather than the IMAGE. It
# only ASSERTS the baked units are present + enabled + active, DRIVES the data
# (writes a token into /home/<user> and lets the baked timer/service push it), and
# emits the proof. A marker can therefore only appear if the BAKED unit did the work.
#
# What it checks (Step 5), against the baked design:
#   - LANPARTY_HOME is mounted READ-WRITE at /mnt/usbhome by the baked
#     partyos-usbhome.service (the home CONTENT lives in the p2:/home SUBDIR;
#     .partyos / .partyos-cache stay at the p2 ROOT, never --delete'd).
#   - the baked boot pull ran: /run/partyos-home-pull-done exists.
#   - the baked every-45s sync timer (partyos-home-sync.timer) is ACTIVE and the
#     finalsync-on-shutdown unit (partyos-home-finalsync.service) is enabled.
#   - a uniquely-tagged file written into /home/<user> reaches p2:/home (the SUBDIR)
#     via the baked partyos-sync-home, while a .cache file is correctly EXCLUDED.
#   - config/.partyos-cache at the p2 ROOT are NOT deleted by the --delete mirror.
#
# Markers (greppable on serial):
#   PARTYOS-STEP5-USBHOME-MOUNTED-RW  LANPARTY_HOME mounted rw at /mnt/usbhome
#   PARTYOS-STEP5-TIMER-ACTIVE        the baked every-45s sync timer is active
#   PARTYOS-STEP5-SYNCED-TO-USB       the new home file reached p2:/home (subdir)
#   PARTYOS-STEP5-EXCLUDED-OK         a cache file was NOT synced (excludes work)
#   PARTYOS-STEP5-ROOT-PRESERVED      .partyos/.partyos-cache at p2 ROOT survived
#   PARTYOS-STEP5-READY               all of the above held - step passed
#   PARTYOS-STEP5-ALIVE               heartbeats proving the system stays up
# HTTP callback:
#   /report?step=5&status=ok&mounted_rw=1&synced=1&excluded=1&root_ok=1&token=<unique>

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

# report_url is injected by partyos-step5.ipxe (no hardcoded IP). persist_token=
# (optional) puts us in PERSISTENCE-CHECK mode: instead of writing a new token, we
# assert the token a PREVIOUS boot synced survived on the stick (p2:/home) AND was
# reloaded into /home/<user> by the baked boot pull.
report_base=""
persist_token=""
for p in $(< /proc/cmdline); do case "$p" in
    report_url=*)    report_base="${p#*=}";;
    persist_token=*) persist_token="${p#*=}";;
esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-STEP5-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }

LABEL="LANPARTY_HOME"
MNT="/mnt/usbhome"
USB_HOME="${MNT}/home"          # baked design: the home CONTENT lives in p2:/home
PULL_DONE="/run/partyos-home-pull-done"

# Resolve the desktop account (dynamic, published to /run/partyos-username by the
# baked identity service before the desktop; fallback gamer).
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
HOME_DIR="/home/${USER_NAME}"
SYNC_TOKEN_FILE="${HOME_DIR}/.partyos-sync-token"

say "PARTYOS-STEP5 boot script started (VERIFIER for the baked home-sync units)"
[ -n "${persist_token}" ] && say "PARTYOS-STEP5 PERSISTENCE-CHECK mode, expecting token=${persist_token}"
say "PARTYOS-STEP5 desktop user resolved: ${USER_NAME}"
say "PARTYOS-STEP5 user ${USER_NAME}: $(id "${USER_NAME}" 2>&1)"

# --- 0. assert the BAKED helpers + units are present (not installed by us) -----
for b in /usr/local/bin/partyos-home-pull /usr/local/bin/partyos-sync-home \
         /usr/local/lib/partyos-sync-common.sh; do
    if [ -e "${b}" ]; then say "PARTYOS-STEP5 baked present: ${b}"; else
        say "PARTYOS-STEP5 ERROR baked path MISSING: ${b} (image regression?)"; fi
done
[ -x /usr/local/bin/partyos-sync-home ] || say "PARTYOS-STEP5 ERROR partyos-sync-home not executable"

# Source the baked common to learn the real mountpoints/excludes the image uses.
[ -r /usr/local/lib/partyos-sync-common.sh ] && . /usr/local/lib/partyos-sync-common.sh 2>/dev/null || true
# Re-pin to the baked values if the common defined them (keeps us in lockstep with
# the shipped contract even if it changes).
MNT="${MNT:-/mnt/usbhome}"
USB_HOME="${USB_HOME:-${MNT}/home}"

# --- 1. wait for the baked partyos-usbhome.service to mount LANPARTY_HOME rw ----
# We do NOT mount it ourselves. The baked sysinit service mounts it before identity.
mounted_rw=0
for _ in $(seq 1 30); do
    if mountpoint -q "${MNT}" && ! mount | grep -F " ${MNT} " | grep -qw ro; then
        mounted_rw=1; break
    fi
    sleep 1
done
if [ "${mounted_rw}" -eq 1 ]; then
    say "PARTYOS-STEP5-USBHOME-MOUNTED-RW ${MNT} <- $(findmnt -no SOURCE "${MNT}" 2>/dev/null) opts=$(findmnt -no OPTIONS "${MNT}" 2>/dev/null)"
else
    say "PARTYOS-STEP5 ERROR ${MNT} not mounted rw by the baked partyos-usbhome.service"
fi

# --- 2. wait for the baked boot pull to complete (the push gate) ---------------
pull_done=0
for _ in $(seq 1 60); do
    [ -e "${PULL_DONE}" ] && { pull_done=1; break; }
    sleep 1
done
if [ "${pull_done}" -eq 1 ]; then
    say "PARTYOS-STEP5 baked boot pull done (${PULL_DONE} present)"
else
    say "PARTYOS-STEP5 WARN baked pull-done gate ${PULL_DONE} not set; pushes will no-op"
fi

# --- PERSISTENCE CHECK -------------------------------------------------------
# Second-boot path: the baked partyos-home-pull already seeded /home/<user> from
# p2:/home. Assert the token a previous boot pushed is still in the p2:/home SUBDIR
# AND reloaded into /home/<user> (files persist across a reboot).
if [ -n "${persist_token}" ]; then
    on_usb=0; in_home=0
    grep -qF "${persist_token}" "${USB_HOME}/.partyos-sync-token" 2>/dev/null && on_usb=1
    grep -qF "${persist_token}" "${SYNC_TOKEN_FILE}" 2>/dev/null && in_home=1
    say "PARTYOS-STEP5 persist usb=${on_usb} home=${in_home} (token=${persist_token})"
    if [ "${on_usb}" -eq 1 ] && [ "${in_home}" -eq 1 ]; then
        say "PARTYOS-STEP5-PERSISTED token survived reboot in p2:/home and reloaded into ${HOME_DIR}"
        curl -s --max-time 5 \
          "${report_base}/report?step=5&status=ok&persisted=1&token=${persist_token}" \
          >/dev/null 2>&1 || true
    else
        say "PARTYOS-STEP5 ERROR token did NOT persist (usb=${on_usb} home=${in_home})"
        say "PARTYOS-STEP5 ${USB_HOME} listing: $(ls -A "${USB_HOME}" 2>/dev/null | tr '\n' ' ')"
        say "PARTYOS-STEP5 ${HOME_DIR} listing: $(ls -A "${HOME_DIR}" 2>/dev/null | tr '\n' ' ')"
        curl -s --max-time 5 \
          "${report_base}/report?step=5&status=fail&persisted=0&token=${persist_token}" \
          >/dev/null 2>&1 || true
    fi
    say "PARTYOS-STEP5-TOKEN ${persist_token}"
    i=0
    while [ "$i" -lt 6 ]; do sleep 3; i=$((i+1)); say "PARTYOS-STEP5-ALIVE persist heartbeat ${i}"; done
    say "PARTYOS-STEP5 persistence-check complete, powering off"
    systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
    exit 0
fi

# --- 3. assert the BAKED timer is active + finalsync enabled -------------------
timer_active=0
if systemctl is-active partyos-home-sync.timer >/dev/null 2>&1; then
    timer_active=1
    say "PARTYOS-STEP5-TIMER-ACTIVE partyos-home-sync.timer is active (baked)"
    say "PARTYOS-STEP5 timer: $(systemctl list-timers partyos-home-sync.timer --no-pager --no-legend 2>/dev/null | tr -s ' ')"
else
    say "PARTYOS-STEP5 WARN baked timer not active: $(systemctl is-active partyos-home-sync.timer 2>&1)"
fi
if systemctl is-enabled partyos-home-finalsync.service >/dev/null 2>&1; then
    say "PARTYOS-STEP5 baked finalsync enabled: $(systemctl is-enabled partyos-home-finalsync.service 2>&1)"
else
    say "PARTYOS-STEP5 WARN baked finalsync not enabled: $(systemctl is-enabled partyos-home-finalsync.service 2>&1)"
fi
if systemctl is-enabled partyos-home-pull.service >/dev/null 2>&1; then
    say "PARTYOS-STEP5 baked home-pull enabled: $(systemctl is-enabled partyos-home-pull.service 2>&1)"
fi

# --- 4. record the p2 ROOT state so we can prove the --delete mirror spares it --
# .partyos and .partyos-cache live at the p2 ROOT, NOT under p2:/home, so the
# RAM /home/<user>/ <-> p2:/home/ --delete mirror must never touch them.
root_before="$(ls -A "${MNT}" 2>/dev/null | grep -vx 'home' | grep -vx 'lost+found' | tr '\n' ' ')"
say "PARTYOS-STEP5 p2 ROOT before push: ${root_before}"

# --- 5. drive the test: write a tagged file + a cache file, let the BAKED unit push
# A unique token ties the file the host later reads off the USB qcow2 to THIS run.
# We write it into /home/<user> (RAM); the BAKED partyos-sync-home must copy it to
# p2:/home.
TOKEN="step5-$(date +%s)-$$-${RANDOM}"
install -d -o "${USER_NAME}" -g "${USER_NAME}" "${HOME_DIR}" 2>/dev/null || install -d "${HOME_DIR}"
echo "${TOKEN}" > "${SYNC_TOKEN_FILE}"
chown "${USER_NAME}:${USER_NAME}" "${SYNC_TOKEN_FILE}" 2>/dev/null || true
say "PARTYOS-STEP5 wrote home file ${SYNC_TOKEN_FILE} token=${TOKEN}"

# A cache file that MUST be excluded from the sync (proves the baked excludes work).
install -d "${HOME_DIR}/.cache"
echo "this-should-not-sync-${TOKEN}" > "${HOME_DIR}/.cache/excluded-marker"

# Trigger the BAKED sync once (the baked every-45s timer would also do this; we
# start the baked service directly so the test does not wait a full interval - but
# it is the BAKED partyos-sync-home that does the work, not a copy we installed).
say "PARTYOS-STEP5 starting the BAKED partyos-home-sync.service (RAM /home -> p2:/home)"
systemctl start partyos-home-sync.service 2>/dev/null \
    || /usr/local/bin/partyos-sync-home || say "PARTYOS-STEP5 baked sync rc=$?"

# Verify the file reached p2:/home (the SUBDIR, not the partition root).
synced=0
if [ -f "${USB_HOME}/.partyos-sync-token" ] && \
   grep -qF "${TOKEN}" "${USB_HOME}/.partyos-sync-token" 2>/dev/null; then
    synced=1
    say "PARTYOS-STEP5-SYNCED-TO-USB token reached ${USB_HOME}/.partyos-sync-token (baked push)"
else
    say "PARTYOS-STEP5 ERROR token NOT in ${USB_HOME}"
    say "PARTYOS-STEP5 ${USB_HOME} listing: $(ls -A "${USB_HOME}" 2>/dev/null | tr '\n' ' ')"
fi

# Verify the excluded cache file did NOT sync.
excluded=0
if [ ! -e "${USB_HOME}/.cache/excluded-marker" ]; then
    excluded=1
    say "PARTYOS-STEP5-EXCLUDED-OK .cache not synced to p2:/home"
else
    say "PARTYOS-STEP5 ERROR .cache leaked to p2:/home"
fi

# Verify the p2 ROOT (.partyos / .partyos-cache) was NOT wiped by the --delete mirror.
# Match each entry EXACTLY against the space-delimited root_before list: a substring
# / -w word match would wrongly see ".partyos" inside ".partyos-cache" (the '-' is a
# word boundary) and then flag the (absent-by-design) ".partyos" as deleted.
root_ok=1
for keep in .partyos .partyos-cache; do
    case " ${root_before} " in
        *" ${keep} "*)
            if [ ! -e "${MNT}/${keep}" ]; then
                root_ok=0; say "PARTYOS-STEP5 ERROR p2 ROOT ${keep} was DELETED by the home mirror"
            fi
            ;;
    esac
done
[ "${root_ok}" -eq 1 ] && say "PARTYOS-STEP5-ROOT-PRESERVED p2 ROOT config/cache survived the --delete home mirror"

# --- 6. emit the ready proof + HTTP callback (token lets host correlate) ------
if [ "${mounted_rw}" -eq 1 ] && [ "${timer_active}" -eq 1 ] && [ "${synced}" -eq 1 ] && \
   [ "${excluded}" -eq 1 ] && [ "${root_ok}" -eq 1 ]; then
    say "PARTYOS-STEP5-READY baked home sync working (mounted_rw timer synced excluded root_ok)"
    curl -s --max-time 5 \
      "${report_base}/report?step=5&status=ok&mounted_rw=1&synced=1&excluded=1&root_ok=1&token=${TOKEN}" \
      >/dev/null 2>&1 || say "PARTYOS-STEP5 callback-failed (non-fatal)"
else
    say "PARTYOS-STEP5 NOT ready (mounted_rw=${mounted_rw} timer=${timer_active} synced=${synced} excluded=${excluded} root_ok=${root_ok})"
    curl -s --max-time 5 \
      "${report_base}/report?step=5&status=fail&mounted_rw=${mounted_rw}&synced=${synced}&excluded=${excluded}&root_ok=${root_ok}&token=${TOKEN}" \
      >/dev/null 2>&1 || true
fi

# Always emit the token on serial too so the harness can capture it even if the
# callback is lost, and pass it to the host for the qcow2 cross-check.
say "PARTYOS-STEP5-TOKEN ${TOKEN}"

# --- 7. heartbeats: prove the system stays up, then power off -----------------
# The baked finalsync unit's ExecStop runs the final push at shutdown.
i=0
while [ "$i" -lt 15 ]; do
  sleep 3; i=$((i+1))
  say "PARTYOS-STEP5-ALIVE heartbeat ${i} mounted_rw=${mounted_rw} synced=${synced}"
done

# Trigger one more BAKED push before power-off (belt-and-braces; the baked finalsync
# ExecStop also runs at shutdown).
say "PARTYOS-STEP5 final baked push before poweroff"
systemctl start partyos-home-sync.service 2>/dev/null || /usr/local/bin/partyos-sync-home || true
say "PARTYOS-STEP5 stay-up window complete, powering off"
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
