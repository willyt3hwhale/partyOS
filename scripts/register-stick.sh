#!/bin/bash
# register-stick.sh - provision a partyOS player stick at the party desk.
#
# ONE command at the door: turn a blank USB into a ready-to-boot player stick.
# It builds THE party stick (p1 ESP iPXE + p2 ext4 PARTYOSHOME, via create_usb.sh)
# and writes the per-player config onto the home partition:
#   .partyos    USERNAME=<login>  HOSTNAME=<host>      (read by partyos-identity)
#   user.conf   NICK=, STATIC_IP=/GATEWAY=/DNS=, FULLNAME=, EMAIL=, IRC_SERVER=
#               (read by partyos-userconf + partyos-staticip)
#
# Linux only (the device build needs sgdisk/mkfs.ext4). Run it on the party server
# or any Linux box. Re-register an already-built stick with --no-format (rewrites
# the config only, keeps the player's home + blob cache).
#
#   sudo ./register-stick.sh /dev/sdX --user alice --nick Alice                  # DHCP
#   sudo ./register-stick.sh /dev/sdX --user ann --nick Ann --static-ip 192.168.0.50/24
#   sudo ./register-stick.sh --no-format /dev/sdX --nick Ann \
#        --static-ip 192.168.0.50/24 --gateway 192.168.0.1
#
# Networking is binary: give --static-ip for a fully-explicit static config, or omit it
# for plain DHCP. The party's DHCP server isn't ours (no reservations), so a fixed
# address means the stick carries the WHOLE config. The client applies it to whichever
# wired NIC actually has link.
#
# Flags:
#   --user NAME          login account (a-z, _, -, digits; <=32). Required.
#   --nick NICK          IRC / display nick. Required.
#   --static-ip IP[/p]   full static IP with optional prefix (default /24). Omit = DHCP.
#   --gateway IP         optional default gateway (off-subnet routing; omit on a flat
#                        offline LAN). Needs --static-ip.
#   --dns IP             optional DNS server (omit -> mDNS; defaults to --gateway).
#   --hostname HOST      machine hostname (default <user>-pc).
#   --fullname "X Y"     optional.
#   --email ADDR         optional.
#   --irc HOST:PORT      optional LAN IRC server (else the image default).
#   --password           prompt (hidden) for an optional account password; stored
#                        HASHED on the stick (.partyos-passwd) for the away-from-keyboard
#                        lockscreen. Omit = passwordless kiosk.
#   --password-hash H    non-interactive: store a precomputed crypt string ($6$/$y$...).
#   --no-format          do NOT rebuild the stick; just (re)write the config onto
#                        an existing home partition (PARTYOSHOME or LANPARTY_HOME).
#   --efi PATH           iPXE .efi for create_usb.sh (default build/ipxe-custom.efi).
#   --esp-mb N           ESP size for create_usb.sh (default 512).
#   --share-mb N         exFAT share (PARTYDATA) size for create_usb.sh (default 4096).
#   FORCE=1 (env)        skip the erase confirmation.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE=""; USER_NAME=""; NICK=""; STATIC_IP=""; GATEWAY=""; DNS=""; HOST=""
FULLNAME=""; EMAIL=""; IRC=""; NO_FORMAT=0; EFI=""; ESP_MB=""; SHARE_MB=""
PWHASH=""; PW_PROMPT=0

die() { echo "register-stick: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --user)      USER_NAME="$2"; shift 2;;
        --nick)      NICK="$2"; shift 2;;
        --static-ip) STATIC_IP="$2"; shift 2;;
        --gateway)   GATEWAY="$2"; shift 2;;
        --dns)       DNS="$2"; shift 2;;
        --hostname)  HOST="$2"; shift 2;;
        --fullname)  FULLNAME="$2"; shift 2;;
        --email)     EMAIL="$2"; shift 2;;
        --irc)       IRC="$2"; shift 2;;
        --password)  PW_PROMPT=1; shift;;
        --password-hash) PWHASH="$2"; shift 2;;
        --no-format) NO_FORMAT=1; shift;;
        --efi)       EFI="$2"; shift 2;;
        --esp-mb)    ESP_MB="$2"; shift 2;;
        --share-mb)  SHARE_MB="$2"; shift 2;;
        -h|--help)   sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0;;
        -*)          die "unknown flag $1";;
        *)           [ -z "${DEVICE}" ] && DEVICE="$1" || die "extra arg $1"; shift;;
    esac
done

[ "$(uname -s)" = "Linux" ] || die "Linux only (needs sgdisk/mkfs.ext4); run on the party server"
[ -n "${DEVICE}" ] || die "no device given (e.g. /dev/sdb). See --help"
[[ "${DEVICE}" =~ ^/dev/(sd[a-z]|nvme[0-9]+n[0-9]+|mmcblk[0-9]+|disk[0-9]+|loop[0-9]+)$ ]] \
    || die "${DEVICE} doesn't look like a removable device"

# --- interactive fill-in (only when a tty is attached) ----------------------
prompt() { local v; read -r -p "$1" v; printf '%s' "${v}"; }
if [ -t 0 ]; then
    [ -n "${USER_NAME}" ] || USER_NAME="$(prompt 'Login username: ')"
    [ -n "${NICK}" ]      || NICK="$(prompt 'Display / IRC nick: ')"
    if [ -z "${STATIC_IP}" ]; then
        STATIC_IP="$(prompt 'Static IP e.g. 192.168.0.50[/24] (blank = DHCP): ')"
        if [ -n "${STATIC_IP}" ]; then
            [ -n "${GATEWAY}" ] || GATEWAY="$(prompt 'Gateway (blank = none, fine on an offline LAN): ')"
            [ -n "${DNS}" ]     || DNS="$(prompt 'DNS server (blank = none / mDNS): ')"
        fi
    fi
    if [ "${PW_PROMPT}" = 1 ] && [ -z "${PWHASH}" ]; then
        read -r -s -p 'Account password for the lockscreen (blank = none): ' _p1; echo
        if [ -n "${_p1}" ]; then
            read -r -s -p 'Confirm password: ' _p2; echo
            [ "${_p1}" = "${_p2}" ] || die "passwords did not match"
            command -v openssl >/dev/null 2>&1 || die "openssl is needed to hash the password"
            PWHASH="$(printf '%s\n' "${_p1}" | openssl passwd -6 -stdin)"
        fi
        unset _p1 _p2
    fi
fi

# --- validate ---------------------------------------------------------------
[ -n "${USER_NAME}" ] || die "--user is required"
[ -n "${NICK}" ]      || die "--nick is required"
printf '%s' "${USER_NAME}" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' \
    || die "invalid --user '${USER_NAME}' (a-z, _, -, digits; must start a-z/_; <=32)"
NICK="$(printf '%s' "${NICK}" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -n "${NICK}" ] || die "nick is empty after trimming"
[ -z "${HOST}" ] && HOST="${USER_NAME}-pc"
printf '%s' "${HOST}" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$' \
    || die "invalid --hostname '${HOST}'"
if [ -n "${STATIC_IP}" ]; then
    printf '%s' "${STATIC_IP%/*}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        || die "invalid --static-ip '${STATIC_IP}'"
fi
if [ -n "${GATEWAY}" ]; then
    printf '%s' "${GATEWAY}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || die "invalid --gateway '${GATEWAY}'"
fi
if [ -n "${PWHASH}" ]; then
    printf '%s' "${PWHASH}" | grep -qE '^\$(y|6|7|2[aby])\$' \
        || die "invalid --password-hash (need a crypt string like \$6\$... or \$y\$...)"
fi
if [ -n "${DNS}" ]; then
    printf '%s' "${DNS}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || die "invalid --dns '${DNS}'"
fi
if [ -z "${STATIC_IP}" ] && { [ -n "${GATEWAY}" ] || [ -n "${DNS}" ]; }; then
    die "--gateway/--dns require --static-ip (DHCP provides them otherwise)"
fi

SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"

# --- build the stick (unless re-registering) --------------------------------
if [ "${NO_FORMAT}" = 1 ]; then
    # Resolve the home partition on THE GIVEN DEVICE only. A system-wide
    # `blkid -L <label>` returns whatever stick happens to carry the label, so
    # with two sticks at the registration desk this player's identity / static IP /
    # password hash could land on the OTHER stick. Derive p2 from DEVICE (same naming
    # as the format path) and confirm its label before writing anything to it.
    case "${DEVICE}" in *[0-9]) P="${DEVICE}p";; *) P="${DEVICE}";; esac
    PART2="${P}2"
    [ -b "${PART2}" ] || die "--no-format: ${PART2} not found on ${DEVICE} (build it first without --no-format)"
    LBL="$(${SUDO} blkid -o value -s LABEL "${PART2}" 2>/dev/null || true)"
    # The venue label (PARTYOSHOME) or the legacy label (LANPARTY_HOME).
    case "${LBL}" in PARTYOSHOME|LANPARTY_HOME) ;;
        *) die "--no-format: ${PART2} is not a partyOS home partition, PARTYOSHOME or LANPARTY_HOME (found '${LBL:-none}') - wrong device?";;
    esac
    echo "register-stick: re-registering existing ${PART2} (home preserved)"
else
    echo "============================================================"
    echo " REGISTER partyOS stick on ${DEVICE}  (THIS ERASES THE DEVICE)"
    echo "   user=${USER_NAME}  host=${HOST}  nick=${NICK}"
    echo "   ip=$( [ -n "${STATIC_IP}" ] && echo "${STATIC_IP}${GATEWAY:+ gw ${GATEWAY}}${DNS:+ dns ${DNS}}" || echo DHCP )"
    echo "============================================================"
    [ "${FORCE:-0}" = 1 ] || { read -r -p "Continue? (y/N): " c; [[ "${c}" =~ ^[Yy]$ ]] || { echo aborted; exit 0; }; }
    # create_usb.sh formats p1 ESP + p3 exFAT PARTYDATA + p2 ext4 PARTYOSHOME.
    # FORCE=1 -> no second prompt. Its args are positional (device efi esp_mb share_mb);
    # --share-mb needs esp_mb populated to reach the 4th slot, so default it to 512.
    [ -n "${SHARE_MB}" ] && [ -z "${ESP_MB}" ] && ESP_MB=512
    FORCE=1 "${SCRIPT_DIR}/create_usb.sh" "${DEVICE}" ${EFI:+"${EFI}"} ${ESP_MB:+"${ESP_MB}"} ${SHARE_MB:+"${SHARE_MB}"}
    case "${DEVICE}" in *[0-9]) P="${DEVICE}p";; *) P="${DEVICE}";; esac
    PART2="${P}2"
fi

# wait for the partition node + label to settle
${SUDO} partprobe "${DEVICE}" 2>/dev/null || true
for _ in $(seq 1 10); do [ -b "${PART2}" ] && break; sleep 1; done
[ -b "${PART2}" ] || die "partition ${PART2} not found"

# --- write the per-player config onto the home partition --------------------
MNT="$(mktemp -d)"
${SUDO} mount "${PART2}" "${MNT}" || die "could not mount ${PART2}"
cleanup() { ${SUDO} umount "${MNT}" 2>/dev/null || true; rmdir "${MNT}" 2>/dev/null || true; }
trap cleanup EXIT

# home/ subdir: backs the RAM /home/<user> (rsync'd). Leave it EMPTY so the image's
# first-boot seed guard populates it from the baked home skeleton. On --no-format we
# NEVER touch home/ - that is the player's persisted data.
if [ "${NO_FORMAT}" = 1 ]; then
    [ -d "${MNT}/home" ] || ${SUDO} mkdir -p "${MNT}/home"
    echo "register-stick: preserved existing home/ (player data untouched)"
else
    ${SUDO} mkdir -p "${MNT}/home"
fi

# .partyos (identity) - stays at the p2 ROOT (read before the home exists).
{ echo "USERNAME=${USER_NAME}"; echo "HOSTNAME=${HOST}"; } | ${SUDO} tee "${MNT}/.partyos" >/dev/null

# user.conf (nick / network / contact). Only emit keys that were set.
{
    echo "NICK=${NICK}"
    [ -n "${FULLNAME}" ] && echo "FULLNAME=${FULLNAME}"
    [ -n "${EMAIL}" ]    && echo "EMAIL=${EMAIL}"
    [ -n "${IRC}" ]      && echo "IRC_SERVER=${IRC}"
    [ -n "${STATIC_IP}" ] && echo "STATIC_IP=${STATIC_IP}"
    [ -n "${STATIC_IP}" ] && [ -n "${GATEWAY}" ] && echo "GATEWAY=${GATEWAY}"
    [ -n "${STATIC_IP}" ] && [ -n "${DNS}" ] && echo "DNS=${DNS}"
    true
} | ${SUDO} tee "${MNT}/user.conf" >/dev/null

# .partyos-passwd (optional lock password, hashed) - at the p2 ROOT, 0600.
if [ -n "${PWHASH}" ]; then
    printf '%s\n' "${PWHASH}" | ${SUDO} tee "${MNT}/.partyos-passwd" >/dev/null
    ${SUDO} chmod 600 "${MNT}/.partyos-passwd"
fi

${SUDO} sync

# --- p3: drop a certs/ README on the exFAT share (best-effort) ------------
# The cross-OS share gets a hint for where per-stick certs go. Skipped on
# --no-format (the share may already hold the player's files) and harmless if the
# partition is absent (legacy 2-partition stick) or exFAT can't be mounted here.
if [ "${NO_FORMAT}" = 0 ]; then
    # Device-scoped again - only touch THIS stick's share (p3), never a
    # second plugged-in stick's share. Skipped cleanly for legacy 2-partition sticks
    # (no p3) or when p3 is not actually a share (PARTYDATA or PARTYSHARE).
    SHARE_DEV="${P}3"
    SHARE_LBL="$(${SUDO} blkid -o value -s LABEL "${SHARE_DEV}" 2>/dev/null || true)"
    if [ -b "${SHARE_DEV}" ] && { [ "${SHARE_LBL}" = PARTYDATA ] || [ "${SHARE_LBL}" = PARTYSHARE ]; }; then
        SMNT="$(mktemp -d)"
        if ${SUDO} mount "${SHARE_DEV}" "${SMNT}" 2>/dev/null; then
            ${SUDO} mkdir -p "${SMNT}/certs" 2>/dev/null || true
            echo "place per-stick certs here (cross-OS exFAT share, mounts at ~/Shared)" \
                | ${SUDO} tee "${SMNT}/certs/README.txt" >/dev/null 2>&1 || true
            ${SUDO} sync; ${SUDO} umount "${SMNT}" 2>/dev/null || true
        fi
        rmdir "${SMNT}" 2>/dev/null || true
    fi
fi

echo "register-stick: provisioned ${PART2}"
echo "  .partyos  -> USERNAME=${USER_NAME} HOSTNAME=${HOST}"
echo "  user.conf -> NICK=${NICK}${STATIC_IP:+ STATIC_IP=${STATIC_IP}}${GATEWAY:+ GATEWAY=${GATEWAY}}${DNS:+ DNS=${DNS}}${IRC:+ IRC_SERVER=${IRC}}"
echo "register-stick: done - ${DEVICE} boots as '${USER_NAME}' (${NICK})"
