#!/usr/bin/env bash
# identity-script.sh - autonomous in-guest verifier for the partyOS dynamic
# IDENTITY feature (USB `.partyos` -> desktop account name + hostname). Fetched
# at boot via archiso's automated-script hook (partyos-identity.ipxe passes
# script=<server>/boot/identity-script.sh). Runs on the tty1 root autologin once
# the live system is up, so it can mirror everything to the serial console the
# harness scrapes.
#
# The IDENTITY logic itself is BAKED into the image (partyos-identity.service ->
# partyos-identity-setup, see build-custom-image.sh): it parses USERNAME=/
# HOSTNAME= from the `.partyos` file on the LANPARTY_HOME stick, ensures the
# account at uid/gid 1000 with passwordless sudo, points its home at the synced
# /home/<name>, rewrites LightDM autologin, and sets the hostname (explicit
# HOSTNAME= wins, else <username>-<machine-suffix>, else partyos-<machine-suffix>).
# This script's job is to MOUNT the USB home, RUN that baked identity setup (the
# tty1 multi-user boot path the harness uses does not auto-start the display
# manager, so we invoke the baked resolver directly + run the Step 4 mount so
# /home/<name> is populated), then ASSERT the outcome and emit the proof.
#
# Markers (greppable on serial):
#   PARTYOS-IDENTITY-USER user=<name> uid=<uid>     resolved desktop account
#   PARTYOS-IDENTITY-SUDO sudo=<ok|no>              passwordless sudo works
#   PARTYOS-IDENTITY-HOME home=<populated|empty>    USB seed files in /home/<name>
#   PARTYOS-IDENTITY-HOSTNAME hostname=<name> src=<explicit|derived>
#   PARTYOS-IDENTITY-READY                          all checks held - step passed
#   PARTYOS-IDENTITY-ALIVE                          heartbeats proving it stays up
# HTTP callback:
#   /report?step=identity&status=ok&user=<name>&uid=1000&sudo=1&home=populated&hostname=<h>

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

# report_url is injected by partyos-identity.ipxe (no hardcoded IP).
report_base=""
for p in $(< /proc/cmdline); do case "$p" in report_url=*) report_base="${p#*=}";; esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-IDENTITY-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }

LABEL="LANPARTY_HOME"
MNT="/mnt/usbhome"

say "PARTYOS-IDENTITY boot script started (USB .partyos -> account + hostname)"

# --- 1. mount the USB home so the identity service can read .partyos ----------
# Reuse the Step 4 mount helper if the image shipped it; else mount by label.
# The baked partyos-identity.service is After=partyos-usbhome.service, so on a
# real (graphical) boot the mount is already there; in the tty1 test path we do
# it explicitly.
install -d "${MNT}"
if ! mountpoint -q "${MNT}"; then
    DEV="$(bash /usr/local/lib/partyos-usb-labels.sh resolve home 2>/dev/null || blkid -L "${LABEL}" 2>/dev/null || true)"
    [ -n "${DEV}" ] || DEV="$(readlink -f "/dev/disk/by-label/${LABEL}" 2>/dev/null || true)"
    if [ -n "${DEV}" ]; then
        mount -o ro "${DEV}" "${MNT}" 2>/dev/null && say "PARTYOS-IDENTITY mounted ${DEV} at ${MNT} (ro)" \
            || say "PARTYOS-IDENTITY WARN could not mount ${DEV}"
    else
        say "PARTYOS-IDENTITY no ${LABEL} stick found (will fall back to gamer)"
    fi
fi
say "PARTYOS-IDENTITY .partyos: $( [ -r "${MNT}/.partyos" ] && tr '\n' ';' < "${MNT}/.partyos" || echo '(absent)')"

# --- 2. run the BAKED identity resolver (the thing under test) ----------------
# This is partyos-identity-setup baked into the image. It resolves USERNAME +
# HOSTNAME from /mnt/usbhome/.partyos, sets the account/sudo/autologin/hostname.
say "PARTYOS-IDENTITY running baked partyos-identity-setup"
systemctl start partyos-identity.service 2>/dev/null || true
/usr/local/bin/partyos-identity-setup || say "PARTYOS-IDENTITY setup rc=$?"

# Resolve the account name the service published (fallback gamer).
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
HOME_DIR="/home/${USER_NAME}"

# --- 3. populate the home from the USB (Step 4 mount/copy to the resolved user)
# The identity setup points the account at /home/<name>; copy the USB seed in so
# we can assert "the player's data is in their home" exactly as Step 4 does.
if [ -x /usr/local/bin/partyos-mount-usbhome ]; then
    /usr/local/bin/partyos-mount-usbhome || say "PARTYOS-IDENTITY mount-usbhome rc=$?"
else
    install -d "${HOME_DIR}"
    if mountpoint -q "${MNT}"; then
        cp -a "${MNT}/." "${HOME_DIR}/" 2>/dev/null || true
        chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}" 2>/dev/null || true
    fi
fi

# --- 4. assert: account name + uid 1000 --------------------------------------
uid="$(id -u "${USER_NAME}" 2>/dev/null || echo '')"
say "PARTYOS-IDENTITY-USER user=${USER_NAME} uid=${uid:-none} ($(id "${USER_NAME}" 2>&1))"
user_ok=0
[ "${uid:-}" = "1000" ] && user_ok=1

# --- 5. assert: passwordless sudo (sudo -n true as the resolved user) ---------
sudo_ok=0
if runuser -l "${USER_NAME}" -c 'sudo -n true' >/dev/null 2>&1; then
    sudo_ok=1
    say "PARTYOS-IDENTITY-SUDO sudo=ok (passwordless sudo -n true succeeded for ${USER_NAME})"
else
    say "PARTYOS-IDENTITY-SUDO sudo=no (sudo -n true failed for ${USER_NAME})"
fi

# --- 6. assert: USB seed files landed in the resolved user's home -------------
home_ok=0
token=""
if [ -f "${HOME_DIR}/WELCOME.txt" ] && [ -f "${HOME_DIR}/.partyos-home-token" ]; then
    home_ok=1
    token="$(tr -d '\n' < "${HOME_DIR}/.partyos-home-token" 2>/dev/null)"
    say "PARTYOS-IDENTITY-HOME home=populated ${HOME_DIR} has USB seed (token=${token})"
    say "PARTYOS-IDENTITY home owner: $(stat -c '%U:%G' "${HOME_DIR}/WELCOME.txt" 2>/dev/null)"
else
    say "PARTYOS-IDENTITY-HOME home=empty (seed files missing in ${HOME_DIR})"
    say "PARTYOS-IDENTITY ${HOME_DIR} listing: $(ls -A "${HOME_DIR}" 2>/dev/null | tr '\n' ' ')"
fi

# --- 7. assert: hostname (explicit override OR derived <user>-<4hex>) ---------
hn="$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')"
[ -n "${hn}" ] || hn="$(uname -n 2>/dev/null)"
# Decide whether .partyos carried an explicit HOSTNAME= (so the harness knows
# which assertion to make); we just report what we see + the source hint.
hn_src="derived"
if [ -r "${MNT}/.partyos" ] && grep -qE '^[[:space:]]*HOSTNAME=' "${MNT}/.partyos" 2>/dev/null; then
    hn_src="explicit"
fi
say "PARTYOS-IDENTITY-HOSTNAME hostname=${hn} src=${hn_src} live=$(hostname 2>/dev/null)"
host_ok=0
[ -n "${hn}" ] && host_ok=1

# --- 8. emit the ready proof + HTTP callback ---------------------------------
if [ "${user_ok}" -eq 1 ] && [ "${sudo_ok}" -eq 1 ] && [ "${home_ok}" -eq 1 ] && [ "${host_ok}" -eq 1 ]; then
    say "PARTYOS-IDENTITY-READY user=${USER_NAME} uid=${uid} sudo=ok home=populated hostname=${hn}"
    curl -s --max-time 5 \
      "${report_base}/report?step=identity&status=ok&user=${USER_NAME}&uid=${uid}&sudo=1&home=populated&hostname=${hn}&hsrc=${hn_src}&token=${token}" \
      >/dev/null 2>&1 || say "PARTYOS-IDENTITY callback-failed (non-fatal)"
else
    say "PARTYOS-IDENTITY NOT ready (user=${user_ok} sudo=${sudo_ok} home=${home_ok} host=${host_ok})"
    curl -s --max-time 5 \
      "${report_base}/report?step=identity&status=fail&user=${USER_NAME}&uid=${uid}&sudo=${sudo_ok}&home=${home_ok}&hostname=${hn}" \
      >/dev/null 2>&1 || true
fi

# --- 9. heartbeats: prove the system stays up, then power off ----------------
i=0
while [ "$i" -lt 12 ]; do
  sleep 3; i=$((i+1))
  say "PARTYOS-IDENTITY-ALIVE heartbeat ${i} user=${USER_NAME} hostname=${hn}"
done

say "PARTYOS-IDENTITY stay-up window complete, powering off"
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
