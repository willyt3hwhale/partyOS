#!/usr/bin/env bash
# flash-usb.sh - flash a player's USB stick with THE production partyOS boot EFI.
#
# This is the operator's "flash a stick" command. It is a thin wrapper over
# scripts/create_usb.sh that DEFAULTS the EFI to the HTTPS, CA-baked, server-IP-baked
# production binary (build/ipxe-custom-https.efi, built by scripts/deploy/setup.sh),
# so an operator never has to remember which EFI to flash. create_usb.sh does the
# real work: it ERASES the device and lays down the partyOS stick (ESP with the iPXE
# EFI + exFAT PARTYDATA + ext4 PARTYOSHOME, the venue labels), with its own
# interactive confirm. HOME_LABEL overrides the home label (create_usb.sh reads it too).
#
# PER-PLAYER IDENTITY (--user):
#   Pass --user <name> (or PARTYOS_USER=<name>) to flash a player's stick BY NAME.
#   It looks up users/<name>/ in the config store (scripts/deploy/gen-user-config.sh),
#   flashes the device as usual, THEN mounts the fresh home partition and writes that
#   player's identity onto it so a reprovision never drops their pinned static IP:
#     .partyos   <- USERNAME / HOSTNAME               (read by partyos-identity)
#     user.conf  <- NICK / STATIC_IP / GATEWAY / DNS   (read by partyos-userconf +
#                   / FULLNAME / EMAIL / IRC_SERVER     partyos-staticip)
#   and rsyncs users/<name>/home/ into the stick's home/. STATIC_IP lives in user.conf,
#   NOT .partyos - that split matches what the OS actually reads. If there is NO
#   users/<name>/ folder it WARNS and STOPS, unless --blank (alias --no-config) is
#   given to provision a blank stick anyway (today's behaviour).
#
#   The identity write lives HERE (not in create_usb.sh, which keeps its low-level
#   device contract), so create_usb.sh still just does partition/mkfs/efi.
#
# Usage:
#   sudo scripts/deploy/flash-usb.sh DEVICE [ipxe_efi]                    # blank stick
#   sudo scripts/deploy/flash-usb.sh DEVICE --user <name> [ipxe_efi]     # by player name
#   sudo scripts/deploy/flash-usb.sh DEVICE --blank                      # force blank
#     DEVICE      the target block device, e.g. /dev/sdX (ERASED).
#     --user NAME provision the player registered in users/NAME/ (or PARTYOS_USER=NAME).
#     --blank     provision a blank stick even if a --user lookup misses (--no-config).
#     ipxe_efi    OPTIONAL explicit EFI override (e.g. the plain-http EFI). Defaults to
#                 the https production EFI - you normally do NOT pass this.
#     FORCE=1     skip the erase confirm (forwarded to create_usb.sh).
#     PARTYOS_USERS_DIR      config store location (default <repo>/users).
#     PARTYOS_FLASH_HOME_DIR write identity into THIS dir instead of flashing+mounting a
#                 device (hardware-free dry-run seam, used by the tests - no sudo).
#
# If the production EFI is missing it stops and tells you to run setup.sh first
# (setup.sh mints the CA and bakes your server IP into that EFI). The server IP is
# NOT an argument here - it is already baked into the EFI by setup.sh.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
CREATE_USB="${REPO_ROOT}/scripts/create_usb.sh"
HTTPS_EFI="${REPO_ROOT}/build/ipxe-custom-https.efi"
USERS_DIR="${PARTYOS_USERS_DIR:-${REPO_ROOT}/users}"
# hardware-free seam: when set, write the identity into this dir (a stand-in for the
# mounted home partition) and do NOT flash/mount a device. Used by the tests.
FLASH_HOME_DIR="${PARTYOS_FLASH_HOME_DIR:-}"

usage() {
    echo "Usage: sudo $0 DEVICE [--user NAME] [--blank] [ipxe_efi]"
    echo "  Flashes the partyOS stick with the https production EFI (built by setup.sh)."
    echo "  DEVICE is ERASED. FORCE=1 skips the confirm. ipxe_efi overrides the EFI (rare)."
    echo "  --user NAME provisions the player registered in users/NAME/ (pinned IP + home)."
    echo "  --blank forces a blank stick even if a --user lookup misses."
    echo "  Examples: sudo $0 /dev/sdb            (blank)"
    echo "            sudo $0 /dev/sdb --user alice"
}

# --- parse args (DEVICE + optional [ipxe_efi] positional, plus flags) --------
DEVICE=""; EFI=""; PLAYER="${PARTYOS_USER:-}"; BLANK=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)          usage; exit 1;;
        --user)             PLAYER="$2"; shift 2;;
        --blank|--no-config) BLANK=1; shift;;
        -*)                 echo "flash-usb: unknown flag $1" >&2; usage >&2; exit 1;;
        *)  if [ -z "${DEVICE}" ]; then DEVICE="$1"
            elif [ -z "${EFI}" ]; then EFI="$1"
            else echo "flash-usb: extra arg $1" >&2; exit 1; fi
            shift;;
    esac
done

[ -n "${DEVICE}" ] || { usage >&2; exit 1; }
# Default to the https production EFI; the positional 2nd arg is an explicit override.
EFI="${EFI:-${HTTPS_EFI}}"
[ -x "${CREATE_USB}" ] || { echo "flash-usb: create_usb.sh not found/executable: ${CREATE_USB}" >&2; exit 1; }

# --- resolve the player's store config (if --user was given) -----------------
# On a lookup MISS we WARN and STOP, unless --blank was passed (provision blank anyway).
CFG=""
if [ -n "${PLAYER}" ]; then
    CFG="${USERS_DIR}/${PLAYER}/config"
    if [ ! -f "${CFG}" ]; then
        if [ "${BLANK}" = 1 ]; then
            echo "[flash-usb] WARNING: no config for '${PLAYER}' in ${USERS_DIR}/ - provisioning a BLANK stick (--blank)." >&2
            PLAYER=""; CFG=""
        else
            echo "flash-usb: no player '${PLAYER}' in the config store (${USERS_DIR}/${PLAYER}/)." >&2
            echo "flash-usb: register them first:  scripts/deploy/gen-user-config.sh ${PLAYER}" >&2
            echo "flash-usb: or pass --blank to flash a blank stick with no identity." >&2
            exit 2
        fi
    fi
fi

# read one KEY out of the store config - same grep-based parse the runtime uses.
getk() { local v; v="$(grep -E "^[[:space:]]*$1=" "${CFG}" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || true; printf '%s' "${v}"; }

# write .partyos + user.conf identity + seed home/ onto a mounted home partition dir.
write_identity() {
    local home_root="$1" run="$2"
    local username hostname nick static gw dns fullname email irc
    username="$(getk USERNAME)"; hostname="$(getk HOSTNAME)"; nick="$(getk NICK)"
    static="$(getk STATIC_IP)"; gw="$(getk GATEWAY)"; dns="$(getk DNS)"
    fullname="$(getk FULLNAME)"; email="$(getk EMAIL)"; irc="$(getk IRC_SERVER)"
    [ -n "${username}" ] || { echo "flash-usb: config ${CFG} has no USERNAME=" >&2; exit 1; }

    # .partyos (identity) - USERNAME + optional HOSTNAME.
    { echo "USERNAME=${username}"; [ -n "${hostname}" ] && echo "HOSTNAME=${hostname}"; true; } \
        | ${run} tee "${home_root}/.partyos" >/dev/null
    # user.conf (nick / network / contact) - only emit keys that are set.
    {
        [ -n "${nick}" ]     && echo "NICK=${nick}"
        [ -n "${fullname}" ] && echo "FULLNAME=${fullname}"
        [ -n "${email}" ]    && echo "EMAIL=${email}"
        [ -n "${irc}" ]      && echo "IRC_SERVER=${irc}"
        [ -n "${static}" ]   && echo "STATIC_IP=${static}"
        [ -n "${static}" ] && [ -n "${gw}" ]  && echo "GATEWAY=${gw}"
        [ -n "${static}" ] && [ -n "${dns}" ] && echo "DNS=${dns}"
        true
    } | ${run} tee "${home_root}/user.conf" >/dev/null

    # home/ subdir backs the RAM /home/<user> (rsync'd). Seed the player's skeleton.
    ${run} mkdir -p "${home_root}/home"
    if [ -d "${USERS_DIR}/${PLAYER}/home" ]; then
        ${run} rsync -a "${USERS_DIR}/${PLAYER}/home/" "${home_root}/home/"
    fi
    ${run} sync 2>/dev/null || true

    echo "[flash-usb] identity written for '${username}':"
    echo "  .partyos  -> USERNAME=${username}${hostname:+ HOSTNAME=${hostname}}"
    echo "  user.conf -> ${nick:+NICK=${nick} }$( [ -n "${static}" ] && echo "STATIC_IP=${static}" || echo "DHCP" )${gw:+ GATEWAY=${gw}}${dns:+ DNS=${dns}}"
}

# --- dry-run seam: write identity into a plain dir, no device/EFI/mount ------
# (hardware-free; used by the tests). Requires --user (nothing to write otherwise).
if [ -n "${FLASH_HOME_DIR}" ]; then
    if [ -z "${PLAYER}" ]; then
        echo "[flash-usb] dry-run (PARTYOS_FLASH_HOME_DIR) with no/blank player - nothing to write."
        exit 0
    fi
    echo "[flash-usb] dry-run: writing identity for '${PLAYER}' into ${FLASH_HOME_DIR} (no device flashed)"
    mkdir -p "${FLASH_HOME_DIR}"
    write_identity "${FLASH_HOME_DIR}" ""
    exit 0
fi

# --- real flash path --------------------------------------------------------
# Guard: a missing production EFI almost always means setup.sh has not been run yet
# (it is what mints the CA + bakes the server IP into this EFI). Point the operator
# there instead of failing deep inside create_usb.sh. A passed-in override that is
# missing also fails here with the same message.
if [ ! -f "${EFI}" ]; then
    if [ "${EFI}" = "${HTTPS_EFI}" ]; then
        echo "flash-usb: the production EFI is missing: ${EFI}" >&2
        echo "flash-usb: run scripts/deploy/setup.sh first - it mints the CA and bakes your" >&2
        echo "           server IP into this EFI. See docs/HOSTING.md (Quick start)." >&2
    else
        echo "flash-usb: the EFI override you passed does not exist: ${EFI}" >&2
    fi
    exit 1
fi

echo "[flash-usb] device : ${DEVICE} (will be ERASED)"
echo "[flash-usb] EFI    : ${EFI}"
[ "${EFI}" = "${HTTPS_EFI}" ] && echo "[flash-usb]          (https production EFI - CA + server IP baked in by setup.sh)"
[ -n "${PLAYER}" ] && echo "[flash-usb] player : ${PLAYER} (identity written after flash)"

# Blank stick (no --user, or --blank on a miss): keep the original exec behaviour -
# hand off to create_usb.sh entirely (back-compat; the process is replaced).
if [ -z "${PLAYER}" ]; then
    exec bash "${CREATE_USB}" "${DEVICE}" "${EFI}"
fi

# Per-player: run create_usb.sh (partition/format/efi), THEN mount the home partition and
# write the player's identity onto it. (We can't exec here - we must run past it.)
bash "${CREATE_USB}" "${DEVICE}" "${EFI}"

SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"
${SUDO} partprobe "${DEVICE}" 2>/dev/null || true
PART2=""
HOME_LABEL="${HOME_LABEL:-PARTYOSHOME}"
export HOME_LABEL
for _ in $(seq 1 10); do PART2="$(${SUDO} blkid -L "${HOME_LABEL}" 2>/dev/null || true)"; [ -n "${PART2}" ] && break; sleep 1; done
[ -n "${PART2}" ] || { echo "flash-usb: could not find the ${HOME_LABEL} partition after flashing" >&2; exit 1; }

MNT="$(mktemp -d)"
cleanup() { ${SUDO} umount "${MNT}" 2>/dev/null || true; rmdir "${MNT}" 2>/dev/null || true; }
trap cleanup EXIT
${SUDO} mount "${PART2}" "${MNT}" || { echo "flash-usb: could not mount ${PART2}" >&2; exit 1; }
write_identity "${MNT}" "${SUDO}"
echo "[flash-usb] done - ${DEVICE} boots as '${PLAYER}'"
