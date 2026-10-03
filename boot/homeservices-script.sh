#!/usr/bin/env bash
# homeservices-script.sh - autonomous in-guest verifier for start-services-
# from-home. Fetched at boot via archiso's automated-script hook
# (partyos-homeservices.ipxe passes script=<server>/boot/homeservices-script.sh).
# Runs on the tty1 root autologin once the live system is up, so it can mirror
# everything to the serial console the harness scrapes.
#
# The LOGIC under test is BAKED into the image (partyos-home-services.service ->
# /usr/local/bin/partyos-home-services, see build-custom-image.sh): a per-user
# boot hook that discovers the participant's own services declared in their HOME
# (~/.partyos-services/) and starts them AS THE USER, with state in the home.
# This script's job is to bring the home up (mount + populate), run that baked
# hook, then ASSERT the outcome and emit the proof.
#
# The home stick (LANPARTY_HOME) is seeded by the test in one of two shapes:
#   WITH a service:  ~/.partyos-services/<name>.sh that binds a TCP port + writes
#                    a marker file -> we assert it auto-started as the user.
#   WITHOUT one:     no services dir -> we assert the hook is a clean no-op and
#                    nothing breaks (HOMESVC_EXPECT=none).
#
# Markers (greppable on serial):
#   PARTYOS-HOMESVC-USER user=<name> uid=<uid>      resolved desktop account
#   PARTYOS-HOMESVC-STARTED name=<svc> pid=<p> user=<u>   service launched as user
#   PARTYOS-HOMESVC-PORT name=<svc> port=<p> listen=<yes|no>  port is bound
#   PARTYOS-HOMESVC-STATE name=<svc> marker=<ok|missing> owner=<u:g> token=<t>
#   PARTYOS-HOMESVC-NONE-OK                          no services -> clean no-op
#   PARTYOS-HOMESVC-READY                            all checks held - step passed
#   PARTYOS-HOMESVC-ALIVE                            heartbeats proving it stays up
# HTTP callback:
#   /report?step=homeservices&status=ok&user=<u>&svc=<name>&started=1&listen=1&state=ok&token=<t>
#   /report?step=homeservices&status=ok&mode=none&user=<u>&started=0   (no-service case)

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

# report_url + homesvc_expect/port/name are injected on the kernel cmdline by
# partyos-homeservices.ipxe (no hardcoded IP).
report_base=""
HOMESVC_EXPECT="service"   # "service" | "none"
SVC_NAME="partysvc"
SVC_PORT="8099"
for p in $(< /proc/cmdline); do
  case "$p" in
    report_url=*)      report_base="${p#*=}";;
    homesvc_expect=*)  HOMESVC_EXPECT="${p#*=}";;
    homesvc_name=*)    SVC_NAME="${p#*=}";;
    homesvc_port=*)    SVC_PORT="${p#*=}";;
  esac
done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-HOMESERVICES-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }

LABEL="LANPARTY_HOME"
MNT="/mnt/usbhome"

say "PARTYOS-HOMESVC boot script started (start-services-from-home, expect=${HOMESVC_EXPECT})"

# --- 1. resolve identity + mount/populate the home ---------------------------
# Run the baked identity resolver first so /run/partyos-username is set and the
# account exists at uid 1000 (same as the desktop boot path), then populate the
# resolved user's home from the USB (the Step 4 mount helper). The home services
# convention lives inside that home.
systemctl start partyos-identity.service 2>/dev/null || true
/usr/local/bin/partyos-identity-setup 2>/dev/null || true

USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
HOME_DIR="/home/${USER_NAME}"

if [ -x /usr/local/bin/partyos-mount-usbhome ]; then
    /usr/local/bin/partyos-mount-usbhome || say "PARTYOS-HOMESVC mount-usbhome rc=$?"
else
    install -d "${MNT}" "${HOME_DIR}"
    DEV="$(bash /usr/local/lib/partyos-usb-labels.sh resolve home 2>/dev/null || blkid -L "${LABEL}" 2>/dev/null || true)"
    [ -n "${DEV}" ] && mount -o ro "${DEV}" "${MNT}" 2>/dev/null || true
    mountpoint -q "${MNT}" && cp -a "${MNT}/." "${HOME_DIR}/" 2>/dev/null || true
    chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}" 2>/dev/null || true
fi

uid="$(id -u "${USER_NAME}" 2>/dev/null || echo '')"
say "PARTYOS-HOMESVC-USER user=${USER_NAME} uid=${uid:-none}"
say "PARTYOS-HOMESVC home services dir: $( [ -d "${HOME_DIR}/.partyos-services" ] && ls -A "${HOME_DIR}/.partyos-services" 2>/dev/null | tr '\n' ' ' || echo '(absent)')"

# --- 2. run the BAKED per-user boot hook (the thing under test) --------------
say "PARTYOS-HOMESVC running baked partyos-home-services"
systemctl start partyos-home-services.service 2>/dev/null || true
/usr/local/bin/partyos-home-services || say "PARTYOS-HOMESVC hook rc=$?"
# Give a launched listener a moment to bind its port.
sleep 3

started_count=0
[ -r /run/partyos-home-services-count ] && started_count="$(tr -d '[:space:]' < /run/partyos-home-services-count)"
say "PARTYOS-HOMESVC hook reported started=${started_count}"

# =============================================================================
# CASE A: no service declared -> assert a clean no-op (nothing breaks).
# =============================================================================
if [ "${HOMESVC_EXPECT}" = "none" ]; then
    none_ok=0
    # The hook must have started nothing AND the system is plainly still healthy.
    if [ "${started_count}" = "0" ] && [ ! -d "${HOME_DIR}/.partyos-services" ]; then
        none_ok=1
        say "PARTYOS-HOMESVC-NONE-OK no services declared -> hook was a clean no-op"
    else
        say "PARTYOS-HOMESVC NONE check failed (started=${started_count} dir=$( [ -d "${HOME_DIR}/.partyos-services" ] && echo present || echo absent))"
    fi
    if [ "${none_ok}" -eq 1 ]; then
        say "PARTYOS-HOMESVC-READY mode=none user=${USER_NAME}"
        curl -s --max-time 5 \
          "${report_base}/report?step=homeservices&status=ok&mode=none&user=${USER_NAME}&started=0" \
          >/dev/null 2>&1 || say "PARTYOS-HOMESVC callback-failed (non-fatal)"
    else
        curl -s --max-time 5 \
          "${report_base}/report?step=homeservices&status=fail&mode=none&user=${USER_NAME}&started=${started_count}" \
          >/dev/null 2>&1 || true
    fi
else
# =============================================================================
# CASE B: a service is declared -> assert it auto-started as the user, is
# listening on its port, and its state landed in the home owned by the user.
# =============================================================================
    RUNDIR="${HOME_DIR}/.partyos-services/.run"
    pidf="${RUNDIR}/${SVC_NAME}.pid"
    markf="${RUNDIR}/${SVC_NAME}.marker"

    # (b1) started as the user: a live pid owned by USER_NAME.
    started_ok=0; svc_pid=""; svc_owner=""
    if [ -r "${pidf}" ]; then
        svc_pid="$(cat "${pidf}" 2>/dev/null)"
        if [ -n "${svc_pid}" ] && kill -0 "${svc_pid}" 2>/dev/null; then
            svc_owner="$(ps -o user= -p "${svc_pid}" 2>/dev/null | tr -d '[:space:]')"
            [ "${svc_owner}" = "${USER_NAME}" ] && started_ok=1
        fi
    fi
    say "PARTYOS-HOMESVC-STARTED name=${SVC_NAME} pid=${svc_pid:-none} user=${svc_owner:-none} ok=${started_ok}"

    # (b2) the service is LISTENING on its port (genuine running service).
    listen_ok=0
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "[:.]${SVC_PORT}\b"; then
        listen_ok=1
    elif curl -s --max-time 3 "http://127.0.0.1:${SVC_PORT}/" 2>/dev/null | grep -q 'partysvc-ok'; then
        listen_ok=1
    fi
    # Confirm reachability + capture the token the service serves.
    served_token="$(curl -s --max-time 3 "http://127.0.0.1:${SVC_PORT}/" 2>/dev/null | grep -oE 'token=[^ ]+' | head -1 | cut -d= -f2)"
    say "PARTYOS-HOMESVC-PORT name=${SVC_NAME} port=${SVC_PORT} listen=$( [ "${listen_ok}" -eq 1 ] && echo yes || echo no) served_token=${served_token:-none}"

    # (b3) state lives in the home, owned by the user: the marker file.
    state_ok=0; mark_owner=""; mark_token=""
    if [ -r "${markf}" ]; then
        mark_owner="$(stat -c '%U:%G' "${markf}" 2>/dev/null)"
        mark_token="$(grep -oE 'token=[^ ]+' "${markf}" 2>/dev/null | head -1 | cut -d= -f2)"
        # The marker must exist and be owned by the desktop user (state in home).
        case "${mark_owner}" in "${USER_NAME}:"*) state_ok=1;; esac
    fi
    say "PARTYOS-HOMESVC-STATE name=${SVC_NAME} marker=$( [ -r "${markf}" ] && echo ok || echo missing) owner=${mark_owner:-none} token=${mark_token:-none}"

    if [ "${started_ok}" -eq 1 ] && [ "${listen_ok}" -eq 1 ] && [ "${state_ok}" -eq 1 ]; then
        say "PARTYOS-HOMESVC-READY user=${USER_NAME} svc=${SVC_NAME} pid=${svc_pid} listen=yes token=${mark_token}"
        curl -s --max-time 5 \
          "${report_base}/report?step=homeservices&status=ok&user=${USER_NAME}&svc=${SVC_NAME}&pid=${svc_pid}&started=1&listen=1&state=ok&owner=${svc_owner}&token=${mark_token}" \
          >/dev/null 2>&1 || say "PARTYOS-HOMESVC callback-failed (non-fatal)"
    else
        say "PARTYOS-HOMESVC NOT ready (started=${started_ok} listen=${listen_ok} state=${state_ok})"
        curl -s --max-time 5 \
          "${report_base}/report?step=homeservices&status=fail&user=${USER_NAME}&svc=${SVC_NAME}&started=${started_ok}&listen=${listen_ok}&state=${state_ok}" \
          >/dev/null 2>&1 || true
    fi
fi

# --- 3. heartbeats: prove the system stays up, then power off ----------------
i=0
while [ "$i" -lt 12 ]; do
  sleep 3; i=$((i+1))
  say "PARTYOS-HOMESVC-ALIVE heartbeat ${i} user=${USER_NAME}"
done

say "PARTYOS-HOMESVC stay-up window complete, powering off"
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
