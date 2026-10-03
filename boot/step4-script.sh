#!/usr/bin/env bash
# step4-script.sh - autonomous in-guest VERIFIER for Step 4 (USB Home
# Directory Reading). Fetched at boot via archiso's automated-script hook
# (partyos-step4.ipxe passes script=<server>/boot/step4-script.sh). It runs on the
# tty1 root autologin once the live system is up, so it has full control and can
# mirror everything to the serial console the harness scrapes.
#
# IMPORTANT - VERIFIER ONLY, NOT AN INSTALLER:
# The USB-home mount + read is now BAKED into the production squashfs
# (scripts/build/build-custom-image.sh): partyos-usbhome.service mounts the ext4
# LANPARTY_HOME stick at /mnt/usbhome (+ exFAT PARTYSHARE at /mnt/share), and
# partyos-home-pull seeds /home/<user> from the p2:/home SUBDIR. This script no
# longer installs partyos-mount-usbhome or its unit (doing so shadowed the baked
# service and made a green test prove the DEV code). It only ASSERTS the BAKED
# service mounted the stick and the BAKED pull populated the home, then emits proof.
#
# What it checks (Step 4), against the baked design:
#   - the BAKED partyos-usbhome.service mounted LANPARTY_HOME at /mnt/usbhome.
#   - the BAKED partyos-home-pull copied the stick's home tree (p2:/home SUBDIR)
#     into /home/<user> (owned by the desktop user).
#
# Markers (greppable on serial):
#   PARTYOS-STEP4-USBHOME-MOUNTED   LANPARTY_HOME mounted at /mnt/usbhome (baked)
#   PARTYOS-STEP4-HOME-POPULATED    seeded files present in /home/<user> (baked pull)
#   PARTYOS-STEP4-READY             both of the above held - step passed
#   PARTYOS-STEP4-ALIVE             heartbeats proving the system stays up
# HTTP callback:
#   /report?step=4&status=ok&mounted=1&home=populated&token=<seed-token>...

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

# report_url is injected by partyos-step4.ipxe (no hardcoded IP).
report_base=""
for p in $(< /proc/cmdline); do case "$p" in report_url=*) report_base="${p#*=}";; esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-STEP4-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }

LABEL="LANPARTY_HOME"
MNT="/mnt/usbhome"
USB_HOME="${MNT}/home"          # baked design: the home CONTENT lives in p2:/home
PULL_DONE="/run/partyos-home-pull-done"

# Resolve the desktop account name (baked partyos-identity publishes it to
# /run/partyos-username, fallback gamer).
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
HOME_DIR="/home/${USER_NAME}"

say "PARTYOS-STEP4 boot script started (VERIFIER for the baked USB-home mount + pull)"
say "PARTYOS-STEP4 desktop user resolved: ${USER_NAME}"
say "PARTYOS-STEP4 user ${USER_NAME}: $(id "${USER_NAME}" 2>&1)"

# --- 0. assert the BAKED mount unit + pull helper are present (not installed) ---
for b in /usr/local/bin/partyos-usbhome /usr/local/bin/partyos-home-pull; do
    if [ -x "${b}" ]; then say "PARTYOS-STEP4 baked present: ${b}"; else
        say "PARTYOS-STEP4 ERROR baked path MISSING: ${b} (image regression?)"; fi
done

# --- 1. wait for the BAKED partyos-usbhome.service to mount LANPARTY_HOME -------
mounted=0
for _ in $(seq 1 30); do
    if mountpoint -q "${MNT}"; then mounted=1; break; fi
    sleep 1
done
if [ "${mounted}" -eq 1 ]; then
    say "PARTYOS-STEP4-USBHOME-MOUNTED ${MNT} <- $(findmnt -no SOURCE "${MNT}" 2>/dev/null)"
    say "PARTYOS-STEP4 usbhome listing: $(ls -A "${MNT}" 2>/dev/null | tr '\n' ' ')"
else
    say "PARTYOS-STEP4 ERROR ${MNT} not mounted by the baked partyos-usbhome.service"
fi

# --- 2. wait for the BAKED boot pull to populate /home/<user> ------------------
# partyos-home-pull mirrors the p2:/home SUBDIR into /home/<user>. Wait for its gate.
for _ in $(seq 1 60); do [ -e "${PULL_DONE}" ] && break; sleep 1; done
[ -e "${PULL_DONE}" ] && say "PARTYOS-STEP4 baked boot pull done (${PULL_DONE})" \
    || say "PARTYOS-STEP4 WARN baked pull-done gate not set"

# --- 3. assert: the seed files the USB builder wrote under home/ appear in /home -
# build-usbhome.sh (HOME_SUBDIR=1) seeds p2:/home/{WELCOME.txt,Documents/notes.txt,
# .config/partyos/settings.conf,.partyos-home-token}; the baked pull copies them
# into /home/<user>.
populated=0
token=""
if [ -f "${HOME_DIR}/WELCOME.txt" ] && \
   [ -f "${HOME_DIR}/Documents/notes.txt" ] && \
   [ -f "${HOME_DIR}/.config/partyos/settings.conf" ] && \
   [ -f "${HOME_DIR}/.partyos-home-token" ]; then
    populated=1
    token="$(tr -d '\n' < "${HOME_DIR}/.partyos-home-token" 2>/dev/null)"
    say "PARTYOS-STEP4-HOME-POPULATED ${HOME_DIR} has the USB seed files (token=${token})"
    say "PARTYOS-STEP4 ${HOME_DIR} listing: $(ls -A "${HOME_DIR}" 2>/dev/null | tr '\n' ' ')"
    say "PARTYOS-STEP4 owner: $(stat -c '%U:%G' "${HOME_DIR}/WELCOME.txt" 2>/dev/null)"
else
    say "PARTYOS-STEP4 ERROR seed files missing in ${HOME_DIR}"
    say "PARTYOS-STEP4 present: $(ls -A "${HOME_DIR}" 2>/dev/null | tr '\n' ' ')"
    say "PARTYOS-STEP4 ${USB_HOME} listing: $(ls -A "${USB_HOME}" 2>/dev/null | tr '\n' ' ')"
fi

# --- 4. emit the ready proof + HTTP callback --------------------------------
if [ "${mounted}" -eq 1 ] && [ "${populated}" -eq 1 ]; then
    say "PARTYOS-STEP4-READY baked usbhome mounted and ${HOME_DIR} populated"
    curl -s --max-time 5 \
      "${report_base}/report?step=4&status=ok&mounted=1&home=populated&token=${token}" \
      >/dev/null 2>&1 || say "PARTYOS-STEP4 callback-failed (non-fatal)"
else
    say "PARTYOS-STEP4 NOT ready (mounted=${mounted} populated=${populated})"
    curl -s --max-time 5 \
      "${report_base}/report?step=4&status=fail&mounted=${mounted}&populated=${populated}" \
      >/dev/null 2>&1 || true
fi

# --- 5. heartbeats: prove the system stays up, then power off ---------------
i=0
while [ "$i" -lt 20 ]; do
  sleep 3; i=$((i+1))
  say "PARTYOS-STEP4-ALIVE heartbeat ${i} mounted=${mounted} home=${populated}"
done

say "PARTYOS-STEP4 stay-up window complete, powering off"
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
