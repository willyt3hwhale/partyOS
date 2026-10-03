#!/usr/bin/env bash
# install-certs.sh - install an EXTERNALLY signed server leaf + its CA (BYOC).
#
# gen-ca.sh is the self-minted CA path: it mints our own CA and signs a leaf with
# it. If the venue operates its own CA, the party is a guest on that PKI. The venue
# then hands over only a CA certificate plus a signed leaf and its key. There is no
# CA private key, so nothing can sign. This script is that path.
#
# It installs into the SAME paths the rest of the tree already reads, so no other
# script changes:
#   ca/partyos-ca.crt      the trust anchor. build-image.sh bakes it into the
#                          rootfs, check-initramfs.sh asserts it, build-ipxe.sh
#                          embeds it, check-ipxe-efi.sh guards it.
#   server/tls/partyos.crt the leaf the server presents (run-servers.sh reads it)
#   server/tls/partyos.key the leaf key (SECRET, gitignored)
#
# It refuses more than it installs. A wrong cert here breaks every client at once:
#   * the key must belong to the cert,
#   * the cert must chain to the given CA,
#   * the SAN must cover EVERY server address in deploy.conf,
#   * an already-expired cert needs --force,
#   * a cert that expires before the event date is a loud warning.
#
# It also disarms the self-minted signer. The self-minted CA key stays on disk but is renamed, and
# a marker file records that an external CA is installed. gen-ca.sh refuses to run
# while that marker is there, so nobody can sign a leaf against the wrong CA and
# ship it. --restore-lab puts the self-minted CA back and removes the marker.
#
# THE iPXE EFI IS NOT TOUCHED. iPXE pins the CA by fingerprint at BUILD time. If
# the sticks are already flashed, the CA installed here MUST be the CA those sticks
# were built against. The script prints the fingerprint and runs check-ipxe-efi.sh
# when an EFI is present, so a mismatch is loud instead of a dead boot at the party.
#
# Usage:
#   install-certs.sh --ca FILE --cert FILE --key FILE [options]
#   install-certs.sh --restore-lab
#
# Options:
#   --ca FILE          the external CA certificate (PEM). Public, becomes the anchor.
#   --cert FILE        the server leaf certificate (PEM), signed by that CA.
#   --key FILE         the leaf private key (PEM). SECRET. Never commit it.
#   --conf FILE        deploy.conf to take the server addresses from
#                      (default: <repo>/deploy.conf).
#   --event-date DATE  the event date, YYYY-MM-DD. Anything in the chain that
#                      expires before it is a loud warning.
#   --force            install although the chain is already expired, or although
#                      the SAN misses an address. Use only when you know why.
#   --restore-lab      undo: put the self-minted CA + leaf back and drop the marker.
#   --dry-run          run every check, write nothing.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"

# shellcheck source=lib-ca-fingerprint.sh
source "${SELF_DIR}/lib-ca-fingerprint.sh"

CA_DIR="${CA_DIR_OVERRIDE:-${REPO_ROOT}/ca}"
TLS_DIR="${TLS_DIR_OVERRIDE:-${REPO_ROOT}/server/tls}"
CA_CRT="${CA_DIR}/partyos-ca.crt"
CA_KEY="${CA_DIR}/partyos-ca.key"
LEAF_CRT="${TLS_DIR}/partyos.crt"
LEAF_KEY="${TLS_DIR}/partyos.key"
MARKER="${CA_DIR}/EXTERNAL-CA"
BAK=".lab-backup"

OPENSSL="${OPENSSL:-$(command -v openssl || true)}"
[ -n "${OPENSSL}" ] || { echo "install-certs: openssl not found in PATH" >&2; exit 1; }

IN_CA=""; IN_CRT=""; IN_KEY=""
CONF="${REPO_ROOT}/deploy.conf"
EVENT_DATE=""
FORCE=0; RESTORE=0; DRY=0
FAILED=0

say()  { echo "[install-certs] $*"; }
warn() { echo "[install-certs] WARNING: $*" >&2; }
die()  { echo "[install-certs] REFUSED: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ca)          IN_CA="${2:-}";     shift 2 ;;
        --cert)        IN_CRT="${2:-}";    shift 2 ;;
        --key)         IN_KEY="${2:-}";    shift 2 ;;
        --conf)        CONF="${2:-}";      shift 2 ;;
        --event-date)  EVENT_DATE="${2:-}";shift 2 ;;
        --ca=*)         IN_CA="${1#*=}";      shift ;;
        --cert=*)       IN_CRT="${1#*=}";     shift ;;
        --key=*)        IN_KEY="${1#*=}";     shift ;;
        --conf=*)       CONF="${1#*=}";       shift ;;
        --event-date=*) EVENT_DATE="${1#*=}"; shift ;;
        --force)       FORCE=1;   shift ;;
        --restore-lab) RESTORE=1; shift ;;
        --dry-run)     DRY=1;     shift ;;
        -h|--help)     sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# --restore-lab: put the self-minted CA + leaf back, drop the marker.
# ---------------------------------------------------------------------------
if [ "${RESTORE}" -eq 1 ]; then
    [ -f "${MARKER}" ] || die "no external CA installed (${MARKER} absent); nothing to restore"
    restored=0
    for f in "${CA_CRT}" "${CA_KEY}" "${LEAF_CRT}" "${LEAF_KEY}"; do
        if [ -f "${f}${BAK}" ]; then
            [ "${DRY}" -eq 1 ] || mv -f "${f}${BAK}" "${f}"
            say "restored ${f##*/}"
            restored=$((restored + 1))
        fi
    done
    [ "${restored}" -gt 0 ] || warn "no ${BAK} files found - the self-minted CA was not saved by this script"
    [ "${DRY}" -eq 1 ] || rm -f "${MARKER}"
    # The anchor went back to the self-minted CA, so the recorded fingerprint must follow it.
    # Leaving the venue CA's fingerprint behind would make every later guard fail.
    if [ "${DRY}" -ne 1 ] && [ -f "${CONF}" ] && [ -f "${CA_CRT}" ]; then
        lab_fp="$(ca_fp_of "${CA_CRT}" "${OPENSSL}")"
        [ -n "${lab_fp}" ] && ca_fp_write "${CONF}" "${lab_fp}" \
            && say "recorded the self-minted CA fingerprint in ${CONF}"
    fi
    say "self-minted CA path restored. gen-ca.sh works again."
    say "REBUILD the image, the initramfs and the EFI before booting a client."
    exit 0
fi

[ -n "${IN_CA}" ] && [ -n "${IN_CRT}" ] && [ -n "${IN_KEY}" ] \
    || die "--ca, --cert and --key are all required (see --help)"
for f in "${IN_CA}" "${IN_CRT}" "${IN_KEY}"; do
    [ -r "${f}" ] || die "cannot read ${f}"
done

# ---------------------------------------------------------------------------
# 1. The three files must parse.
# ---------------------------------------------------------------------------
"${OPENSSL}" x509 -in "${IN_CA}"  -noout        >/dev/null 2>&1 || die "${IN_CA} is not a PEM certificate"
"${OPENSSL}" x509 -in "${IN_CRT}" -noout        >/dev/null 2>&1 || die "${IN_CRT} is not a PEM certificate"
"${OPENSSL}" pkey -in "${IN_KEY}" -noout        >/dev/null 2>&1 || die "${IN_KEY} is not a PEM private key"

CA_SUBJ="$("${OPENSSL}" x509 -in "${IN_CA}"  -noout -subject | sed 's/^subject=//')"
LEAF_SUBJ="$("${OPENSSL}" x509 -in "${IN_CRT}" -noout -subject | sed 's/^subject=//')"
CA_FP="$("${OPENSSL}" x509 -in "${IN_CA}" -noout -fingerprint -sha256 | sed 's/^.*=//')"
say "CA   : ${CA_SUBJ}"
say "leaf : ${LEAF_SUBJ}"

# The anchor must actually be a CA, or nothing downstream can validate a chain.
if ! "${OPENSSL}" x509 -in "${IN_CA}" -noout -ext basicConstraints 2>/dev/null | grep -qi 'CA:TRUE'; then
    die "${IN_CA} is not marked CA:TRUE - it cannot be a trust anchor"
fi

# ---------------------------------------------------------------------------
# 2. The key must belong to the cert.
# ---------------------------------------------------------------------------
if [ "$("${OPENSSL}" pkey -in "${IN_KEY}" -pubout 2>/dev/null)" \
   = "$("${OPENSSL}" x509 -in "${IN_CRT}" -noout -pubkey 2>/dev/null)" ]; then
    say "key matches the leaf certificate"
else
    die "the key does not belong to the certificate"
fi

# ---------------------------------------------------------------------------
# 3. The leaf must chain to the CA. Separate a time failure from a trust failure:
#    a bad chain is always fatal, an expired chain is reported by the date check.
# ---------------------------------------------------------------------------
if "${OPENSSL}" verify -CAfile "${IN_CA}" "${IN_CRT}" >/dev/null 2>&1; then
    say "leaf chains to the CA (and is inside its validity window)"
elif "${OPENSSL}" verify -no_check_time -CAfile "${IN_CA}" "${IN_CRT}" >/dev/null 2>&1; then
    warn "leaf chains to the CA but the chain is NOT valid at the current time"
else
    die "the leaf does not chain to ${IN_CA}"
fi

# ---------------------------------------------------------------------------
# 4. SAN coverage. Every server address in deploy.conf must be in the leaf SAN,
#    because iPXE and curl both enforce host-against-SAN. A miss here is a boot
#    that fails at the party, so it is fatal without --force.
#    IRC is a DIFFERENT service on its own leaf, so IRC_SERVER is not checked.
# ---------------------------------------------------------------------------
SAN="$("${OPENSSL}" x509 -in "${IN_CRT}" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n')"
say "leaf SAN: ${SAN:-<none>}"

# san_covers HOST -> 0 when the SAN has an exact DNS entry, a matching one-label
# wildcard, or an IP entry for HOST.
san_covers() {
    local host="$1" entry name
    local _ifs="${IFS}"; IFS=','
    for entry in ${SAN}; do
        case "${entry}" in
            DNS:*)
                name="${entry#DNS:}"
                [ "${name}" = "${host}" ] && { IFS="${_ifs}"; return 0; }
                case "${name}" in
                    \*.*)
                        # A wildcard matches exactly one leading label.
                        if [ "${host#*.}" = "${name#\*.}" ] && [ "${host#*.}" != "${host}" ]; then
                            IFS="${_ifs}"; return 0
                        fi ;;
                esac ;;
            IP:*|IPAddress:*)
                # openssl prints "IP Address:1.2.3.4"; the SAN read above strips the
                # spaces, so the prefix arrives here as IPAddress:.
                name="${entry#IP:}"; name="${name#IPAddress:}"
                [ "${name}" = "${host}" ] && { IFS="${_ifs}"; return 0; } ;;
        esac
    done
    IFS="${_ifs}"
    return 1
}

if [ -f "${CONF}" ]; then
    # Plain KEY=value parse, the same one render.sh and run-servers.sh use.
    get() { grep -E "^${1}=" "${CONF}" | tail -1 | cut -d= -f2- | tr -d '[:space:]'; }
    # Collect every address the CLIENTS dial over TLS against THIS leaf.
    ADDRS="$(get PXE_SERVER),$(get BLOB_SERVERS),$(get BLOB_SERVER),$(get MIRROR_SERVER),$(get BOOT_CONFIG_URL)"
    checked=""
    _ifs="${IFS}"; IFS=','
    for a in ${ADDRS}; do
        IFS="${_ifs}"
        [ -n "${a}" ] || continue
        h="${a%%/*}"      # strip any path (BOOT_CONFIG_URL carries one)
        h="${h#*://}"     # strip any scheme
        h="${h%%:*}"      # strip the port
        [ -n "${h}" ] || continue
        case ",${checked}," in *",${h},"*) continue ;; esac
        checked="${checked}${h},"
        if san_covers "${h}"; then
            say "SAN covers ${h}"
        else
            if [ "${FORCE}" -eq 1 ]; then
                warn "SAN does NOT cover ${h} (--force: installing anyway)"
            else
                echo "[install-certs] SAN does NOT cover ${h} (from ${CONF##*/})" >&2
                FAILED=1
            fi
        fi
        IFS=','
    done
    IFS="${_ifs}"
    [ "${FAILED}" -eq 0 ] || die "the leaf SAN does not cover every server address in ${CONF}.
  Fix deploy.conf to use an address the leaf covers, or get a leaf with the right SAN.
  --force installs anyway (clients will then fail the TLS host check)."
else
    warn "${CONF} not present - the SAN was not checked against any server address"
fi

# ---------------------------------------------------------------------------
# 5. Expiry. The whole chain is only as good as its earliest notAfter.
# ---------------------------------------------------------------------------
# epoch_of FILE -> the cert notAfter as a unix timestamp, or empty when the host
# date(1) cannot parse it. GNU and BSD date take different flags, so try both.
epoch_of() {
    local na
    na="$("${OPENSSL}" x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    [ -n "${na}" ] || return 0
    date -j -f '%b %e %T %Y %Z' "${na}" '+%s' 2>/dev/null && return 0
    date -d "${na}" '+%s' 2>/dev/null && return 0
    return 0
}

NOW="$(date '+%s')"
EVENT_EPOCH=""
if [ -n "${EVENT_DATE}" ]; then
    EVENT_EPOCH="$(date -j -f '%Y-%m-%d' "${EVENT_DATE}" '+%s' 2>/dev/null \
                || date -d "${EVENT_DATE}" '+%s' 2>/dev/null || true)"
    [ -n "${EVENT_EPOCH}" ] || warn "could not parse --event-date ${EVENT_DATE}; expiry is checked against today"
fi

EXPIRED=0
for pair in "CA:${IN_CA}" "leaf:${IN_CRT}"; do
    label="${pair%%:*}"; file="${pair#*:}"
    na="$("${OPENSSL}" x509 -in "${file}" -noout -enddate | sed 's/^notAfter=//')"
    ep="$(epoch_of "${file}")"
    if [ -z "${ep}" ]; then
        warn "${label} expires ${na} (this host cannot compare the date - check it by hand)"
        continue
    fi
    if [ "${ep}" -le "${NOW}" ]; then
        echo "[install-certs] EXPIRED: the ${label} expired ${na}" >&2
        EXPIRED=1
    elif [ -n "${EVENT_EPOCH}" ] && [ "${ep}" -le "${EVENT_EPOCH}" ]; then
        warn "the ${label} expires ${na}, BEFORE the event date ${EVENT_DATE}."
        warn "  clients will fail TLS during the party. Get a longer cert."
    else
        days=$(( (ep - NOW) / 86400 ))
        say "${label} expires ${na} (${days} days from now)"
        [ "${days}" -le 30 ] && warn "the ${label} expires in ${days} days - plan the renewal"
    fi
done
if [ "${EXPIRED}" -eq 1 ]; then
    [ "${FORCE}" -eq 1 ] || die "the chain is already expired. --force installs it anyway."
    warn "--force: installing an EXPIRED chain"
fi

if [ "${DRY}" -eq 1 ]; then
    say "--dry-run: every check ran, nothing was written."
    exit 0
fi

# ---------------------------------------------------------------------------
# 6. Install. Save whatever is there now, so --restore-lab can undo it.
# ---------------------------------------------------------------------------
mkdir -p "${CA_DIR}" "${TLS_DIR}"
if [ ! -f "${MARKER}" ]; then
    for f in "${CA_CRT}" "${CA_KEY}" "${LEAF_CRT}" "${LEAF_KEY}"; do
        [ -f "${f}" ] && { cp -p "${f}" "${f}${BAK}"; say "saved ${f##*/} -> ${f##*/}${BAK}"; }
    done
fi

install -m 0644 "${IN_CA}"  "${CA_CRT}"
install -m 0644 "${IN_CRT}" "${LEAF_CRT}"
install -m 0600 "${IN_KEY}" "${LEAF_KEY}"
say "installed CA   -> ${CA_CRT}"
say "installed leaf -> ${LEAF_CRT}"
say "installed key  -> ${LEAF_KEY} (SECRET, gitignored)"

# Disarm the self-minted signer. The key is kept (renamed) so --restore-lab still works,
# but gen-ca.sh must not sign a leaf against a CA that is no longer the anchor.
if [ -f "${CA_KEY}" ]; then
    mv -f "${CA_KEY}" "${CA_KEY}${BAK}"
    say "moved the self-minted CA key aside -> ${CA_KEY##*/}${BAK} (nothing can sign now)"
fi
rm -f "${CA_DIR}/partyos-ca.srl"

cat > "${MARKER}" <<EOF
# An EXTERNAL CA is installed. gen-ca.sh refuses to run while this file exists.
# Remove it with: scripts/deploy/install-certs.sh --restore-lab
ca_subject=${CA_SUBJ}
ca_sha256=${CA_FP}
leaf_subject=${LEAF_SUBJ}
leaf_san=${SAN}
installed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
say "wrote the marker -> ${MARKER}"

# Record the anchor in deploy.conf. From here on every guard compares the CA on
# disk against THIS value, so a later swap is caught instead of trusted.
if [ -f "${CONF}" ]; then
    ca_fp_write "${CONF}" "${CA_FP}" && say "recorded CA_FINGERPRINT in ${CONF}"
else
    warn "${CONF} not found - CA_FINGERPRINT not recorded, so a swapped CA cannot be detected"
fi

echo
say "CA SHA-256 fingerprint (this is what iPXE must already pin):"
echo "         ${CA_FP}"
echo

# ---------------------------------------------------------------------------
# 7. Guard the already-flashed sticks. The EFI pins the CA at build time.
# ---------------------------------------------------------------------------
CHECK_EFI="${SELF_DIR}/check-ipxe-efi.sh"
if [ -f "${CHECK_EFI}" ]; then
    say "checking the built EFI against the installed CA..."
    bash "${CHECK_EFI}" "${REPO_ROOT}/build/ipxe-custom-https.efi" "${CA_CRT}" "${CONF}" || {
        echo >&2
        warn "the built EFI does NOT match the installed CA or server name."
        warn "  Already-flashed sticks pin the CA they were built against."
        warn "  Either get a leaf signed by THAT CA, or rebuild and reflash."
    }
fi

echo
say "NEXT: the trust anchor changed, so rebuild what carries it:"
say "  make image && make initramfs   (bakes ${CA_CRT##*/} into the rootfs + initramfs)"
say "  scripts/deploy/render.sh       (boot script, portal, kernel cmdline)"
say "Do NOT commit ${LEAF_KEY##*/}."
