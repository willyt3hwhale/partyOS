#!/usr/bin/env bash
# lib-ca-fingerprint.sh - read and write the RECORDED CA fingerprint.
#
# Why this exists. The iPXE EFI pins the trust anchor by its exact bytes at BUILD
# time. Every guard used to compare the EFI against whatever certificate happened
# to sit in ca/ at CHECK time. If something replaced that certificate, the guard
# compared the new CA against an EFI built from the new CA and passed - it could
# never catch a wrong CA.
#
# So the fingerprint of the CA the operator MEANT to use is recorded in deploy.conf
# as CA_FINGERPRINT. It is written once, when the CA is deliberately minted
# (gen-ca.sh) or installed (install-certs.sh). Every later check compares the CA on
# disk against that record, not against itself.
#
# The value is the SHA-256 of the certificate in DER form, uppercase hex with colon
# separators - the same text `openssl x509 -noout -fingerprint -sha256` prints, and
# the same value iPXE TRUST= pins.
#
# Source this file; do not execute it.

# ca_fp_of CERT [OPENSSL] -> print the SHA-256 fingerprint, or nothing on failure.
ca_fp_of() {
    local cert="$1" ossl="${2:-openssl}"
    [ -f "${cert}" ] || return 0
    # Never return non-zero on a miss: callers run under `set -e` and assign the
    # result, so a failing grep/openssl here would abort the whole script silently.
    "${ossl}" x509 -in "${cert}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' || true
    return 0
}

# ca_fp_read CONF -> print the recorded CA_FINGERPRINT, or nothing if absent/empty.
# A missing file, a missing key and an empty value all print nothing and return 0,
# so callers can treat "no record" as one case (older configs, a first run).
ca_fp_read() {
    local conf="$1"
    [ -f "${conf}" ] || return 0
    # Same reason as ca_fp_of: a config with no CA_FINGERPRINT is a normal case, not
    # an error, and grep's exit 1 must not take the calling script down with it.
    grep -E '^CA_FINGERPRINT=' "${conf}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true
    return 0
}

# ca_fp_write CONF FP - record FP as CA_FINGERPRINT in CONF. Replaces an existing
# key in place, or appends a commented block. Creates CONF if it does not exist.
ca_fp_write() {
    local conf="$1" fp="$2" tmp
    [ -n "${fp}" ] || return 1
    mkdir -p "$(dirname "${conf}")"
    if [ -f "${conf}" ] && grep -qE '^CA_FINGERPRINT=' "${conf}"; then
        tmp="$(mktemp "${TMPDIR:-/tmp}/partyos-cafp.XXXXXX")"
        # Rewrite the first CA_FINGERPRINT line and drop any duplicates after it.
        awk -v fp="${fp}" '
            /^CA_FINGERPRINT=/ { if (!done) { print "CA_FINGERPRINT=" fp; done=1 } next }
            { print }
        ' "${conf}" > "${tmp}" && cat "${tmp}" > "${conf}"
        rm -f "${tmp}"
    else
        cat >> "${conf}" <<EOF

# --- pinned trust anchor ------------------------------------------------------
# SHA-256 of the CA certificate the build is meant to use, written when the CA was
# minted (gen-ca.sh) or installed (install-certs.sh). check-ipxe-efi.sh compares
# the CA on disk against this value, so a swapped CA is caught instead of trusted.
# Do not edit by hand. To change the anchor, rotate it (setup.sh --fresh) or
# install a new one (install-certs.sh).
CA_FINGERPRINT=${fp}
EOF
    fi
}
