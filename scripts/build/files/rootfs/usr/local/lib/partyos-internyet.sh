#!/usr/bin/env bash
# partyos-internyet.sh - read the per-player identity from the venue env file.
#
# The player USB stick carries a shared exFAT partition (a share label, see
# partyos-usb-labels.sh; mounted at /mnt/share). The venue writes `internyet.env`
# there. internyet.env is the primary identity source. partyos-identity-setup
# falls back to .partyos on the home partition.
#
# Format (shell-style, but PARSED, never sourced - a hostile line must not run):
#   INTERNYET_ALIAS="Player1"
#   INTERNYET_USER_NAME="player1"
#   INTERNYET_EMAIL="player1@p.nyet"
#   INTERNYET_DEFAULT_FQDN="deck.player1.p.nyet"
#   INTERNYET_P12_PASSWORD="..."
#
# Usage:
#   source /usr/local/lib/partyos-internyet.sh
#   f="$(internyet_env_file)"
#   alias="$(internyet_get INTERNYET_ALIAS "${f}")"
#
# Warning: the file holds a password, an API key and a p12 password. Never log a
# value read from it unless the key is known to be public (alias, user name, FQDN).

# The exFAT share mountpoint. Same path partyos-usbhome mounts the share at.
PARTYOS_SHARE_MNT="${PARTYOS_SHARE_MNT:-/mnt/share}"

# internyet_env_file - print the path of the env file, or nothing if absent.
# Looks at the share root first, then one directory level down (the venue ships
# the files inside a per-player folder on some sticks).
internyet_env_file() {
    local base="${1:-${PARTYOS_SHARE_MNT}}" d
    [ -d "${base}" ] || return 0
    if [ -r "${base}/internyet.env" ]; then
        printf '%s' "${base}/internyet.env"
        return 0
    fi
    for d in "${base}"/*/; do
        [ -r "${d}internyet.env" ] || continue
        printf '%s' "${d}internyet.env"
        return 0
    done
    return 0
}

# internyet_dir FILE - print the directory that holds the env file (where ca.crt,
# client.p12 and the rest live too).
internyet_dir() {
    local f="${1:-}"
    [ -n "${f}" ] || return 0
    printf '%s' "${f%/*}"
}

# internyet_get KEY [FILE] - print the value of KEY, or nothing.
# The LAST assignment wins. Comments and blank lines are ignored. Surrounding
# whitespace and one layer of matching single or double quotes are stripped. A
# CR (the file may come from a Windows editor) is stripped. Internal spaces are
# KEPT - an alias may contain them.
internyet_get() {
    local key="$1" file="${2:-}" v
    [ -n "${key}" ] || return 1
    [ -n "${file}" ] || file="$(internyet_env_file)"
    [ -n "${file}" ] && [ -r "${file}" ] || return 0
    v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "${file}" 2>/dev/null \
        | grep -v '^[[:space:]]*#' | tail -1 | cut -d= -f2- | tr -d '\r')"
    # trim outer whitespace
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    # strip one matching quote pair
    case "${v}" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    printf '%s' "${v}"
}

# internyet_short_host FQDN - print the FIRST label of a dotted FQDN.
#
# INTERNYET_DEFAULT_FQDN comes from internyet.env (for example "deck.player1.p.nyet").
# Many FQDNs can share the same first label ("deck"). Thus the first label
# is not the hostname. It is only:
#   * the short alias on the 127.0.1.1 line in /etc/hosts.
#   * the fallback hostname if the FQDN is longer than 64 characters.
# Prints nothing if the label does not validate (RFC1123-ish, lowercase, <=63).
internyet_short_host() {
    local fqdn="$1" short
    short="${fqdn%%.*}"
    short="$(printf '%s' "${short}" | tr '[:upper:]' '[:lower:]')"
    [ -n "${short}" ] || return 0
    [ "${#short}" -le 63 ] || return 0
    printf '%s' "${short}" | grep -qE '^[a-z0-9][a-z0-9-]*$' || return 0
    printf '%s' "${short}"
}

# internyet_node_name FQDN - print the hostname for a dotted FQDN.
#
# The hostname is the FULL FQDN ("deck.player1.p.nyet"), lowercased.
# /etc/hostname and hostnamectl both get this name.
# The kernel limit for a hostname is 64 characters (HOST_NAME_MAX).
# Prints nothing if the FQDN is not valid or is longer than 64 characters.
# In that case, the caller uses internyet_short_host.
internyet_node_name() {
    local f
    f="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    internyet_valid_fqdn "${f}" || return 0
    [ "${#f}" -le 64 ] || return 0
    # A label is max 63 characters.
    printf '%s' "${f}" | grep -qE '[^.]{64}' && return 0
    printf '%s' "${f}"
}

# internyet_valid_fqdn FQDN - true if the value is a usable dotted host name.
internyet_valid_fqdn() {
    local f="$1"
    [ -n "${f}" ] || return 1
    [ "${#f}" -le 253 ] || return 1
    printf '%s' "${f}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$'
}
