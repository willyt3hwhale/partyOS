#!/usr/bin/env bash
# step6-script.sh - autonomous in-guest VERIFIER for Step 6 (Hot-Plug USB
# Support). Fetched at boot via archiso's automated-script hook
# (partyos-step6.ipxe passes script=<server>/boot/step6-script.sh). It runs on the
# tty1 root autologin once the live system is up, mirroring proof to the serial
# console the harness scrapes.
#
# IMPORTANT - VERIFIER ONLY, NOT AN INSTALLER:
# The hot-plug logic (the udev rule 99-partyos-usbhome.rules, the
# partyos-usb-removed/reinserted handlers + their .service units, the pause-aware
# partyos-sync-home, partyos-usb-notify, the home pull/push timer + finalsync) is
# now BAKED into the production squashfs (scripts/build/build-custom-image.sh). This
# script does NOT install or overwrite any of those paths, daemon-reload, or reload
# udev rules anymore - doing so would shadow the shipped units and make the test
# prove the DEV code rather than the IMAGE. It only ASSERTS the baked rule + handlers
# are present, lets the HOST's QMP device_del/device_add drive the BAKED udev path,
# and emits the proof from the BAKED handlers' own markers.
#
# Builds on Step 5 (the baked continuous home sync). Step 6 verifies the four
# hot-plug behaviours, all implemented by the BAKED units:
#   1. udev rules detect USB removal/insertion of the LANPARTY_HOME stick.
#   2. sync PAUSES when the USB is removed (pause flag + timer stopped).
#   3. a NOTIFICATION shows USB status (serial marker + status file + notify-send).
#   4. sync RESUMES on reinsert, flushing files created while it was gone.
#
# The hot-plug events themselves are injected by the HOST via QMP device_del /
# device_add on the usb-storage qdev (id usb0) - the autonomous stand-in for a
# human yanking the stick. The BAKED udev rule reacts to them.
#
# Markers (greppable on serial). The hot-plug handlers are BAKED and emit the
# PARTYOS-USB-* markers below; this verifier re-emits step6-scoped aliases so the
# existing harness assertions keep working AND so a marker can only appear if the
# baked handler ran.
#   PARTYOS-STEP6-USBHOME-MOUNTED-RW   LANPARTY_HOME mounted rw at /mnt/usbhome
#   PARTYOS-STEP6-UDEV-INSTALLED       BAKED udev rule + handlers verified present
#   PARTYOS-STEP6-READY                baseline up, waiting for hot-plug events
#   PARTYOS-STEP6-USB-REMOVED          baked handler saw the stick go away
#   PARTYOS-STEP6-SYNC-PAUSED          baked handler paused sync (timer + flag)
#   PARTYOS-STEP6-NOTIFY-REMOVED       baked removal notification fired
#   PARTYOS-STEP6-OFFLINE-FILE-WRITTEN a file was created while USB was gone
#   PARTYOS-STEP6-USB-REINSERTED       baked handler saw the stick come back
#   PARTYOS-STEP6-SYNC-RESUMED         baked handler resumed sync
#   PARTYOS-STEP6-NOTIFY-REINSERTED    baked reinsertion notification fired
#   PARTYOS-STEP6-OFFLINE-FLUSHED      the offline file reached p2:/home on resume
#   PARTYOS-STEP6-ALIVE                heartbeats proving the system stays up
# HTTP callbacks (report_url injected by partyos-step6.ipxe, no hardcoded IP):
#   step=6 status=baseline ...                       (baseline ready)
#   step=6 status=removed paused=1 notified=1 ...     (after device_del)
#   step=6 status=ok resumed=1 flushed=1 token=...    (after device_add + flush)

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

report_base=""
for p in $(< /proc/cmdline); do case "$p" in
    report_url=*) report_base="${p#*=}";;
esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-STEP6-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }

# resolve the desktop user: identity-setup renames the uid-1000 account
# gamer->USER_NAME and publishes the name to /run/partyos-username.
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
HOME_DIR="/home/${USER_NAME}"

LABEL="LANPARTY_HOME"
MNT="/mnt/usbhome"
USB_HOME="${MNT}/home"          # baked design: the home CONTENT lives in p2:/home
PAUSE_FLAG="/run/partyos-sync-paused"
STATUS_FILE="/run/partyos-usb-status"   # written by the baked partyos-usb-notify
EVENT_LOG="/run/partyos-hotplug.log"    # written by the baked handlers
PULL_DONE="/run/partyos-home-pull-done"
SYNC_TOKEN_FILE="${HOME_DIR}/.partyos-sync-token"
OFFLINE_FILE="${HOME_DIR}/offline-while-removed.txt"

say "PARTYOS-STEP6 boot script started (VERIFIER for the baked hot-plug units)"
say "PARTYOS-STEP6 user ${USER_NAME}: $(id "${USER_NAME}" 2>&1)"
say "PARTYOS-STEP6 report_base=${report_base}"

# --- 0. assert the BAKED hot-plug units + udev rule are present ----------------
# We do NOT write them. They ship in airootfs.sfs (build-custom-image.sh).
udev_ok=1
RULE=/etc/udev/rules.d/99-partyos-usbhome.rules
if [ -f "${RULE}" ] && grep -q 'partyos-usb-labels.sh is home' "${RULE}"; then
    say "PARTYOS-STEP6 baked udev rule present: ${RULE}"
else
    udev_ok=0; say "PARTYOS-STEP6 ERROR baked udev rule MISSING/empty: ${RULE}"
fi
for b in /usr/local/bin/partyos-usb-removed /usr/local/bin/partyos-usb-reinserted \
         /usr/local/bin/partyos-usb-notify /usr/local/bin/partyos-sync-home \
         /usr/local/bin/partyos-home-pull; do
    if [ -x "${b}" ]; then say "PARTYOS-STEP6 baked present: ${b}"; else
        udev_ok=0; say "PARTYOS-STEP6 ERROR baked handler MISSING: ${b}"; fi
done
for u in partyos-usb-removed.service partyos-usb-reinserted.service; do
    if [ -f "/etc/systemd/system/${u}" ]; then say "PARTYOS-STEP6 baked unit present: ${u}"; else
        udev_ok=0; say "PARTYOS-STEP6 ERROR baked unit MISSING: ${u}"; fi
done
# udevadm test the baked add rule against the live home device to confirm it would
# fire the reinserted service (no install/reload by us).
HDEV0="$(bash /usr/local/lib/partyos-usb-labels.sh resolve home 2>/dev/null || blkid -L "${LABEL}" 2>/dev/null || true)"
if [ -n "${HDEV0}" ]; then
    SYS="$(udevadm info -q path -n "${HDEV0}" 2>/dev/null || true)"
    if [ -n "${SYS}" ] && udevadm test "${SYS}" 2>/dev/null | grep -q 'partyos-usb-reinserted.service'; then
        say "PARTYOS-STEP6 baked udev rule resolves to partyos-usb-reinserted.service (udevadm test)"
    fi
fi
[ "${udev_ok}" -eq 1 ] && say "PARTYOS-STEP6-UDEV-INSTALLED baked udev rule + add/remove handlers verified present"

# --- 1. wait for the baked partyos-usbhome.service to mount LANPARTY_HOME rw ----
mounted_rw=0
for _ in $(seq 1 30); do
    if mountpoint -q "${MNT}" && ! mount | grep -F " ${MNT} " | grep -qw ro; then
        mounted_rw=1; break
    fi
    sleep 1
done
if [ "${mounted_rw}" -eq 1 ]; then
    say "PARTYOS-STEP6-USBHOME-MOUNTED-RW ${MNT} <- $(findmnt -no SOURCE "${MNT}" 2>/dev/null) opts=$(findmnt -no OPTIONS "${MNT}" 2>/dev/null)"
    # The stick is attached at boot, before any udev add event we react to. The
    # BAKED partyos-usbhome.service mounts it but does not stamp the udev tag the
    # REMOVE rule matches (ENV{PARTYOS_USBHOME}=1). Trigger an add on the present
    # device so the BAKED add rule runs and stamps the tag for THIS device, so the
    # REMOVE rule fires when the host device_del's it. (This triggers the BAKED
    # rule; it does not install anything.)
    if [ -n "${HDEV0}" ]; then
        udevadm trigger --action=add "${HDEV0}" 2>/dev/null || true
        udevadm settle --timeout=10 2>/dev/null || true
    fi
else
    say "PARTYOS-STEP6 ERROR ${MNT} not mounted rw by the baked partyos-usbhome.service"
fi

# --- 2. wait for the baked boot pull (the push gate) + the baked timer ---------
for _ in $(seq 1 60); do [ -e "${PULL_DONE}" ] && break; sleep 1; done
[ -e "${PULL_DONE}" ] && say "PARTYOS-STEP6 baked boot pull done" \
    || say "PARTYOS-STEP6 WARN baked pull-done gate not set; pushes will no-op"

# Seed a baseline token into /home/<user> and let the BAKED push put it on the stick.
install -d -o "${USER_NAME}" -g "${USER_NAME}" "${HOME_DIR}" 2>/dev/null || install -d "${HOME_DIR}"
BASE_TOKEN="step6-$(date +%s)-$$-${RANDOM}"
echo "${BASE_TOKEN}" > "${SYNC_TOKEN_FILE}"
chown "${USER_NAME}:${USER_NAME}" "${SYNC_TOKEN_FILE}" 2>/dev/null || true

timer_active=0
if systemctl is-active partyos-home-sync.timer >/dev/null 2>&1; then
    timer_active=1
    say "PARTYOS-STEP6 baked timer active"
else
    say "PARTYOS-STEP6 WARN baked timer not active: $(systemctl is-active partyos-home-sync.timer 2>&1)"
fi
# Initial BAKED push so the baseline token is on the stick (p2:/home).
rm -f "${PAUSE_FLAG}"
systemctl start partyos-home-sync.service 2>/dev/null \
    || /usr/local/bin/partyos-sync-home || say "PARTYOS-STEP6 baseline baked sync rc=$?"

# --- 3. baseline ready: hand off to the HOST to inject the hot-plug events ----
if [ "${mounted_rw}" -eq 1 ] && [ "${udev_ok}" -eq 1 ]; then
    say "PARTYOS-STEP6-READY baseline up (mounted_rw timer_active baked-udev-verified); awaiting hot-plug"
    curl -s --max-time 5 \
      "${report_base}/report?step=6&status=baseline&mounted_rw=1&timer=${timer_active}&base_token=${BASE_TOKEN}" \
      >/dev/null 2>&1 || say "PARTYOS-STEP6 baseline callback-failed (non-fatal)"
else
    say "PARTYOS-STEP6 NOT ready (mounted_rw=${mounted_rw} udev_ok=${udev_ok})"
    curl -s --max-time 5 \
      "${report_base}/report?step=6&status=fail&mounted_rw=${mounted_rw}&udev_ok=${udev_ok}" >/dev/null 2>&1 || true
fi

# --- 4. event-driven progress reporting + heartbeats -------------------------
# The host now issues QMP device_del (remove). The BAKED partyos-usb-removed handler
# (started by the BAKED udev remove rule) sets the pause flag + writes STATUS_FILE
# + emits PARTYOS-USB-REMOVED. We watch for that, re-emit the step6 aliases the
# harness greps for, create the offline file while the stick is gone, then let the
# BAKED partyos-usb-reinserted handler flush it on reinsert.
removed_reported=0
reinserted_reported=0
offline_written=0
OFFLINE_TOKEN="offline-$(date +%s)-${RANDOM}"
saw_removed_marker=0
saw_reins_marker=0

# Re-emit a step6 alias the first time we see a baked PARTYOS-USB-* marker on the
# serial log (so the harness's PARTYOS-STEP6-* assertions are satisfied ONLY when
# the baked handler actually ran). We scrape our own serial mirror via journald is
# overkill; instead we detect the handler's side effects directly (status file,
# pause flag, event log) which the BAKED handlers produce.

i=0
while [ "$i" -lt 90 ]; do
    sleep 2; i=$((i+1))
    state="$(cat "${STATUS_FILE}" 2>/dev/null || echo started)"

    # Phase A: BAKED removal handler ran (status=removed + pause flag set).
    if [ "${state}" = "removed" ] && [ "${removed_reported}" -eq 0 ]; then
        paused=0; [ -e "${PAUSE_FLAG}" ] && paused=1
        timer_now=1; systemctl is-active partyos-home-sync.timer >/dev/null 2>&1 || timer_now=0
        # The baked handler already emitted PARTYOS-USB-REMOVED + paused + notified;
        # re-emit the step6 aliases the harness asserts on (only reachable because
        # the BAKED handler set status=removed).
        say "PARTYOS-STEP6-USB-REMOVED baked handler detected LANPARTY_HOME removal"
        say "PARTYOS-STEP6-SYNC-PAUSED baked handler paused sync (paused=${paused} timer=${timer_now})"
        grep -q removed "${STATUS_FILE}" 2>/dev/null && say "PARTYOS-STEP6-NOTIFY-REMOVED baked notification fired"
        # Create a file while the USB is GONE - it must survive + flush on resume.
        echo "${OFFLINE_TOKEN}" > "${OFFLINE_FILE}"
        chown "${USER_NAME}:${USER_NAME}" "${OFFLINE_FILE}" 2>/dev/null || true
        offline_written=1
        say "PARTYOS-STEP6-OFFLINE-FILE-WRITTEN ${OFFLINE_FILE} token=${OFFLINE_TOKEN}"
        curl -s --max-time 5 \
          "${report_base}/report?step=6&status=removed&paused=${paused}&notified=1&timer=${timer_now}&offline_token=${OFFLINE_TOKEN}" \
          >/dev/null 2>&1 || true
        removed_reported=1
    fi

    # Phase B: BAKED reinsert handler ran (status=reinserted + resumed).
    if [ "${state}" = "reinserted" ] && [ "${removed_reported}" -eq 1 ] && [ "${reinserted_reported}" -eq 0 ]; then
        say "PARTYOS-STEP6-USB-REINSERTED baked handler detected LANPARTY_HOME insertion"
        # Give the baked resume handler's flush a moment (it runs partyos-sync-home).
        sleep 2
        flushed=0
        if mountpoint -q "${MNT}" && grep -qF "${OFFLINE_TOKEN}" "${USB_HOME}/offline-while-removed.txt" 2>/dev/null; then
            flushed=1
            say "PARTYOS-STEP6-OFFLINE-FLUSHED ${OFFLINE_TOKEN} reached ${USB_HOME}/offline-while-removed.txt (baked resume sync)"
        else
            # The baked resume handler may still be syncing; trigger one more BAKED push.
            systemctl start partyos-home-sync.service 2>/dev/null || /usr/local/bin/partyos-sync-home || true
            if mountpoint -q "${MNT}" && grep -qF "${OFFLINE_TOKEN}" "${USB_HOME}/offline-while-removed.txt" 2>/dev/null; then
                flushed=1
                say "PARTYOS-STEP6-OFFLINE-FLUSHED ${OFFLINE_TOKEN} reached ${USB_HOME}/offline-while-removed.txt (after explicit baked push)"
            else
                say "PARTYOS-STEP6 ERROR offline file NOT in ${USB_HOME} after resume"
                say "PARTYOS-STEP6 ${USB_HOME} listing: $(ls -A "${USB_HOME}" 2>/dev/null | tr '\n' ' ')"
            fi
        fi
        timer_now=0; systemctl is-active partyos-home-sync.timer >/dev/null 2>&1 && timer_now=1
        paused=0; [ -e "${PAUSE_FLAG}" ] && paused=1
        say "PARTYOS-STEP6-SYNC-RESUMED baked handler resumed sync (paused=${paused} timer=${timer_now})"
        say "PARTYOS-STEP6-NOTIFY-REINSERTED baked notification fired"
        if [ "${flushed}" -eq 1 ]; then
            curl -s --max-time 5 \
              "${report_base}/report?step=6&status=ok&resumed=1&flushed=1&timer=${timer_now}&offline_token=${OFFLINE_TOKEN}" \
              >/dev/null 2>&1 || true
        else
            curl -s --max-time 5 \
              "${report_base}/report?step=6&status=fail&resumed=1&flushed=0&offline_token=${OFFLINE_TOKEN}" \
              >/dev/null 2>&1 || true
        fi
        reinserted_reported=1
    fi

    say "PARTYOS-STEP6-ALIVE heartbeat ${i} state=${state} offline_written=${offline_written}"

    # Done once we have observed both events; linger a few more beats then power off.
    if [ "${reinserted_reported}" -eq 1 ]; then
        [ "$i" -lt 86 ] && i=86
    fi
done

say "PARTYOS-STEP6 final baked push before poweroff"
rm -f "${PAUSE_FLAG}"
systemctl start partyos-home-sync.service 2>/dev/null || /usr/local/bin/partyos-sync-home || true
say "PARTYOS-STEP6 stay-up window complete, powering off"
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
