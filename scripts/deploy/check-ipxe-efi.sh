#!/usr/bin/env bash
# check-ipxe-efi.sh - GUARD that the built HTTPS boot EFI embeds the CURRENT CA.
#
# The https iPXE EFI (build/ipxe-custom-https.efi) compiles the pinned partyOS CA
# in (CERT=+TRUST=) so the whole boot chain validates against it over TLS. If the
# CA is rotated (gen-ca.sh --force) but the EFI is NOT rebuilt (`make ipxe`), the
# stale EFI still trusts the OLD CA and the new TLS chain fails. This guard catches
# that: it converts the CURRENT ca/partyos-ca.crt to DER and asserts those exact
# bytes are embedded in the EFI (the same proof build-ipxe.sh does inline).
#
# It is the iPXE-EFI analogue of check-initramfs.sh's bundled-CA guard. It is
# TOLERANT of the EFI being absent: the .efi is gitignored and host-local (only
# present on the box that ran `make ipxe`), so a missing EFI is a NOTE+skip (exit
# 0), not a failure - a CI/deploy box that never built it must not be blocked.
# A PRESENT-but-stale EFI (current CA not embedded) FAILS (non-zero).
#
# It also checks the server name. The EFI chains to one baked https URL. If
# PXE_SERVER in deploy.conf changes but the EFI is not rebuilt, the sticks still
# dial the old name. So the guard asserts that the EFI contains the chain URL that
# deploy.conf gives. If deploy.conf is absent, this check is skipped.
#
# Usage: check-ipxe-efi.sh [EFI] [CA] [CONF]
#   defaults: build/ipxe-custom-https.efi   ca/partyos-ca.crt   deploy.conf
# Exit 0 = EFI absent (skip) OR embeds the current CA; non-zero = stale EFI.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"

# shellcheck source=lib-ca-fingerprint.sh
source "${SELF_DIR}/lib-ca-fingerprint.sh"

EFI="${1:-${REPO_ROOT}/build/ipxe-custom-https.efi}"
CA="${2:-${REPO_ROOT}/ca/partyos-ca.crt}"
CONF="${3:-${REPO_ROOT}/deploy.conf}"

# ---------------------------------------------------------------------------
# 0. The CA on disk must be the CA deploy.conf RECORDS.
# ---------------------------------------------------------------------------
# This check runs FIRST and runs even when the EFI is absent. The embed check
# below only proves the EFI matches whatever cert sits in ca/ right now, so if
# something swapped that cert AND the EFI was rebuilt from it, the embed check
# passes and the wrong CA ships. CA_FINGERPRINT is written once when the CA is
# minted or installed, so it is the only value that can catch the swap.
if [ -f "${CA}" ] && [ -f "${CONF}" ]; then
    recorded="$(ca_fp_read "${CONF}")"
    ondisk="$(ca_fp_of "${CA}")"
    if [ -z "${recorded}" ]; then
        echo "check-ipxe-efi: WARNING - ${CONF##*/} records no CA_FINGERPRINT, so a swapped CA cannot be detected." >&2
        echo "  this config predates the check, or the CA was never minted through gen-ca.sh." >&2
        echo "  record the current CA with: scripts/deploy/gen-ca.sh <server-name>" >&2
    elif [ -z "${ondisk}" ]; then
        echo "check-ipxe-efi: FAIL - could not read a fingerprint from ${CA}" >&2
        exit 1
    elif [ "${recorded}" != "${ondisk}" ]; then
        echo "check-ipxe-efi: FAIL - the CA on disk is NOT the CA ${CONF##*/} records." >&2
        echo "  on disk  : ${ondisk}  (${CA})" >&2
        echo "  recorded : ${recorded}  (CA_FINGERPRINT in ${CONF})" >&2
        echo "  Every already-flashed stick pins the RECORDED CA. Building against the" >&2
        echo "  cert on disk would produce sticks that trust a different anchor." >&2
        echo "  fix: restore the recorded CA, or rotate on purpose (setup.sh --fresh)," >&2
        echo "       or install an external CA (scripts/deploy/install-certs.sh)." >&2
        exit 1
    else
        echo "check-ipxe-efi: PASS - the CA on disk matches CA_FINGERPRINT in ${CONF##*/}"
    fi
fi

if [ ! -f "${EFI}" ]; then
    echo "check-ipxe-efi: NOTE - ${EFI} not present (gitignored, host-local); skipping"
    echo "  (run \`make ipxe\` on the box that flashes the stick to (re)build it)"
    exit 0
fi
[ -f "${CA}" ] || { echo "check-ipxe-efi: FAIL - CA not found: ${CA} (run scripts/deploy/gen-ca.sh)" >&2; exit 1; }

# Convert the current CA to DER and assert those bytes are embedded in the EFI.
DER="$(mktemp "${TMPDIR:-/tmp}/partyos-ca.XXXXXX.der")"
trap 'rm -f "${DER}"' EXIT
openssl x509 -in "${CA}" -outform DER -out "${DER}" 2>/dev/null \
    || { echo "check-ipxe-efi: FAIL - could not convert ${CA} to DER" >&2; exit 1; }

if python3 - "${EFI}" "${DER}" <<'PY'
import sys
hay = open(sys.argv[1], "rb").read()
needle = open(sys.argv[2], "rb").read()
sys.exit(0 if needle in hay else 1)
PY
then
    echo "check-ipxe-efi: PASS - ${EFI##*/} embeds the current ${CA##*/} (CA-pinned, fresh)"
else
    echo "check-ipxe-efi: FAIL - ${EFI} does NOT embed the current CA (${CA})" >&2
    echo "  the CA was likely rotated (gen-ca.sh --force) without rebuilding the EFI." >&2
    echo "  fix: run \`make ipxe\` to rebuild build/ipxe-custom-https.efi against the current CA." >&2
    exit 1
fi

# The server name: the EFI must chain to https://<PXE_SERVER host>:<port+363>.
if [ ! -f "${CONF}" ]; then
    echo "check-ipxe-efi: NOTE - ${CONF} not present; server-name check skipped"
    exit 0
fi
PXE="$(grep -E '^PXE_SERVER=' "${CONF}" | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
case "${PXE}" in
    *:*) host="${PXE%%:*}"; port="${PXE##*:}";;
    *)   host="${PXE}";     port="8080";;
esac
case "${port}" in ''|*[!0-9]*) port="8080";; esac
URL="chain https://${host}:$(( port + ${HTTPS_PORT_OFFSET:-363} ))/boot/partyos.ipxe"
if grep -aqF "${URL}" "${EFI}"; then
    echo "check-ipxe-efi: PASS - ${EFI##*/} chains to ${host} (= PXE_SERVER in ${CONF##*/})"
    exit 0
fi
baked="$(grep -aoE 'chain https://[^ ]*/boot/partyos\.ipxe' "${EFI}" | head -1)"
echo "check-ipxe-efi: FAIL - ${EFI##*/} does not chain to PXE_SERVER=${PXE} from ${CONF}" >&2
echo "  the EFI has: ${baked:-<no chain URL found>}" >&2
echo "  fix: run 'make server-name SERVER_NAME=${host}' to rebuild the EFI with this name." >&2
exit 1
