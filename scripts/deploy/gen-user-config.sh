#!/usr/bin/env bash
# gen-user-config.sh - register a partyOS player in the config store (users/).
#
# Creates one folder per player - users/<name>/config + an empty users/<name>/home/ -
# so a stick can later be flashed BY NAME (scripts/deploy/flash-usb.sh --user <name>)
# and always get the SAME identity back.
#
# Networking is DHCP by default: the tool writes no STATIC_IP. The LAN DHCP server
# assigns the address (use a DHCP reservation if a player needs a fixed address).
# A client-side static IP is an opt-in only (--ip / --slot). Then the tool scans every
# existing users/*/config for used STATIC_IPs and refuses a collision.
#
# Usage:
#   scripts/deploy/gen-user-config.sh <username> [--ip A.B.C.D[/p] | --slot N]
#                                     [--nick NICK] [--hostname HOST] [--force]
#
#   <username>        login account (a-z, _, -, digits; must start a-z/_; <=32). Required.
#   --ip A.B.C.D[/p]  opt-in: pin THIS static IP on the stick (prefix defaults /24).
#   --slot N          opt-in: pin the Nth address in the player range (slot 1 = .200).
#   --nick NICK       display / IRC nick (default: the username).
#   --hostname HOST   machine hostname (default: <username>-pc).
#   --force           overwrite an existing users/<username>/ (rewrites config; keeps home/).
#
# The base/range for --slot are constants below, override-able via env for a different LAN:
#   PARTYOS_IP_PREFIX (default 10.13.37)  first three octets of the player subnet
#   PARTYOS_IP_LO / PARTYOS_IP_HI (200/249)  inclusive last-octet range for players
#   PARTYOS_USERS_DIR  the store location (default <repo>/users)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
USERS_DIR="${PARTYOS_USERS_DIR:-${REPO_ROOT}/users}"

# --- opt-in static-IP scheme (see users/README.md) --------------------------
# Only used with --ip / --slot. The player range is .200-.249 of the prefix.
# Override via the PARTYOS_IP_* env for a different LAN.
IP_PREFIX="${PARTYOS_IP_PREFIX:-10.13.37}"
IP_LO="${PARTYOS_IP_LO:-200}"
IP_HI="${PARTYOS_IP_HI:-249}"
IP_MASK="${PARTYOS_IP_MASK:-24}"

die() { echo "gen-user-config: $*" >&2; exit 1; }

USERNAME=""; WANT_IP=""; WANT_SLOT=""; NICK=""; HOST=""; FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --ip)       WANT_IP="$2"; shift 2;;
        --slot)     WANT_SLOT="$2"; shift 2;;
        --nick)     NICK="$2"; shift 2;;
        --hostname) HOST="$2"; shift 2;;
        --force)    FORCE=1; shift;;
        -h|--help)  sed -n '2,27p' "${BASH_SOURCE[0]}"; exit 0;;
        -*)         die "unknown flag $1";;
        *)          [ -z "${USERNAME}" ] && USERNAME="$1" || die "extra arg $1"; shift;;
    esac
done

[ -n "${USERNAME}" ] || die "no username given. See --help"
printf '%s' "${USERNAME}" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' \
    || die "invalid username '${USERNAME}' (a-z, _, -, digits; must start a-z/_; <=32)"
[ -z "${WANT_IP}" ] || [ -z "${WANT_SLOT}" ] || die "--ip and --slot are mutually exclusive"

USER_DIR="${USERS_DIR}/${USERNAME}"
CFG="${USER_DIR}/config"
if [ -e "${USER_DIR}" ] && [ "${FORCE}" != 1 ]; then
    die "users/${USERNAME}/ already exists (use --force to overwrite its config; home/ is kept)"
fi

# --- collect the static IPs already handed out ------------------------------
# Read every OTHER user's config STATIC_IP (last-octet) so we never reassign one.
# Same grep-based parse the runtime uses (KEY= | last | value | trim).
getk() { grep -E "^[[:space:]]*$1=" "$2" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -1 | cut -d= -f2- | tr -d '[:space:]'; }
declare -a USED_OCTETS=()
if [ -d "${USERS_DIR}" ]; then
    for cfg in "${USERS_DIR}"/*/config; do
        [ -f "${cfg}" ] || continue
        # skip THIS user's own current config (a --force re-run keeps its own slot free)
        [ "${cfg}" = "${CFG}" ] && continue
        ip="$(getk STATIC_IP "${cfg}" || true)"; [ -n "${ip}" ] || continue
        octet="${ip%/*}"; octet="${octet##*.}"
        # only track IPs in our prefix (a foreign-subnet static can't collide with ours)
        case "${ip%/*}" in "${IP_PREFIX}."*) USED_OCTETS+=("${octet}");; esac
    done
fi

is_used() { local o="$1" u; for u in "${USED_OCTETS[@]:-}"; do [ "${u}" = "${o}" ] && return 0; done; return 1; }

# --- resolve the static IP for this player ----------------------------------
STATIC_IP=""
if [ -n "${WANT_IP}" ]; then
    # explicit --ip: validate, then refuse a collision with an existing player's IP.
    addr="${WANT_IP%/*}"; mask="${IP_MASK}"; [ "${WANT_IP}" != "${addr}" ] && mask="${WANT_IP#*/}"
    printf '%s' "${addr}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || die "invalid --ip '${WANT_IP}'"
    case "${addr}" in
        "${IP_PREFIX}."*)
            o="${addr##*.}"
            is_used "${o}" && die "--ip ${addr} is already assigned to another player"
            ;;
    esac
    STATIC_IP="${addr}/${mask}"
elif [ -n "${WANT_SLOT}" ]; then
    # --slot N -> the Nth address in the range (slot 1 = IP_LO). Validate range + free.
    printf '%s' "${WANT_SLOT}" | grep -qE '^[0-9]+$' || die "invalid --slot '${WANT_SLOT}' (a number)"
    o=$(( IP_LO + WANT_SLOT - 1 ))
    [ "${WANT_SLOT}" -ge 1 ] && [ "${o}" -le "${IP_HI}" ] \
        || die "--slot ${WANT_SLOT} is out of the player range (slots 1..$(( IP_HI - IP_LO + 1 )))"
    is_used "${o}" && die "--slot ${WANT_SLOT} (${IP_PREFIX}.${o}) is already assigned"
    STATIC_IP="${IP_PREFIX}.${o}/${IP_MASK}"
fi

[ -n "${NICK}" ] || NICK="${USERNAME}"
[ -n "${HOST}" ] || HOST="${USERNAME}-pc"

# --- write the store entry --------------------------------------------------
mkdir -p "${USER_DIR}/home"
{
    echo "# partyOS player config for ${USERNAME} (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))."
    echo "# See users/README.md for the format. flash with: flash-usb.sh /dev/sdX --user ${USERNAME}"
    echo "USERNAME=${USERNAME}"
    echo "HOSTNAME=${HOST}"
    echo "NICK=${NICK}"
    [ -n "${STATIC_IP}" ] && echo "STATIC_IP=${STATIC_IP}"
    true
} > "${CFG}"

echo "gen-user-config: registered '${USERNAME}'"
echo "  ${CFG}"
echo "  USERNAME=${USERNAME}  HOSTNAME=${HOST}  NICK=${NICK}  ip=${STATIC_IP:-DHCP}"
echo "  home skeleton: ${USER_DIR}/home/  (drop dotfiles here to pre-seed the desktop)"
echo "gen-user-config: flash it with -> sudo scripts/deploy/flash-usb.sh /dev/sdX --user ${USERNAME}"
