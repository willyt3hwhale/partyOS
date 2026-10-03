#!/usr/bin/env bash
# gen-ca.sh - generate the partyOS private CA + a server LEAF cert for the HTTPS
# boot chain.
#
# Why a private CA and not a system/public one: the boot chain is a closed LAN
# with no public PKI. Clients connect to the server by its DNS name (or an IP),
# and both iPXE and curl pin trust to THIS CA's fingerprint (TRUST=<sha256>) - they
# do NOT consult the system trust store. So we mint our own CA once, sign a
# server leaf with the server name in its SAN, and ship only the public CA cert to
# clients. The CA *key* never leaves the operator's box.
#
# What it produces (idempotent-ish: the CA is reused unless --force):
#   ca/partyos-ca.crt   - the public CA cert        (ship to clients, pin its fp)
#   ca/partyos-ca.key   - the CA private key        (SECRET, gitignored)
#   server/tls/partyos.crt - the server leaf cert   (the server presents this)
#   server/tls/partyos.key - the server leaf key    (SECRET, gitignored)
#
# Re-running signs a FRESH leaf against the EXISTING CA - so you can add a new
# IP/hostname to the SAN without rotating the CA (which would break every client
# already pinned to the old CA fingerprint). Pass --force only to start over and
# rotate the CA itself (then every client must re-pin).
#
# The PRIMARY SAN entry (the canonical address every client connects to) is now
# REQUIRED - it is the FIRST positional arg (after --force is parsed out) or the
# PRIMARY_IP env var. There is no baked default any more: setup.sh threads the
# operator's chosen server IP/hostname in here so the leaf SAN matches whatever the
# clients actually dial (iPXE and curl enforce SAN-vs-host). Add more IPs/hostnames
# as further args or via the SANS env var to cover extra server addresses.
#
# Usage:
#   scripts/deploy/gen-ca.sh [--force|--reissue-ca] PRIMARY_SAN [EXTRA_SAN ...]
#     --force        rotate the CA (new KEY + cert); the default REUSES an existing
#                    CA and only re-signs the leaf. Every client must then re-pin.
#     --reissue-ca   re-mint the CA CERT from the EXISTING key (key KEPT, only the
#                    validity dates change) - e.g. to widen a narrow CA's window.
#                    The cert bytes (=> its SHA-256 fingerprint) change, so iPXE
#                    (which trusts roots by fingerprint) needs every EFI rebuilt +
#                    every stick reflashed. Distinct from --force (which re-keys).
#     PRIMARY_SAN    REQUIRED - the canonical server IP/hostname (goes FIRST in the
#                    SAN, IP: or DNS: auto-detected). Or pass it via PRIMARY_IP env.
#     EXTRA_SAN ...  extra SAN entries (IPs or DNS names) for the leaf, e.g.
#                    192.168.0.10 partyos.lan. IPs are auto-detected (digits +
#                    dots / colons) and added as IP:, everything else as DNS:.
#   Env:
#     PRIMARY_IP     the primary SAN, same as the first positional arg.
#     SANS="a b c"   same as passing extra SANs as args (space/comma separated).
#     CA_DIR_OVERRIDE / TLS_DIR_OVERRIDE  write the CA / leaf into these dirs instead
#                    of the repo ca/ + server/tls/ (used by setup.sh to mint into a
#                    temp dir during verification so the dev CA is never touched).
#     WIDE_NOTBEFORE clock-independent notBefore for BOTH CA + leaf, YYYYMMDDHHMMSSZ
#                    (default 19700101000000Z). Needs openssl 3.3+.
#     WIDE_NOTAFTER  clock-independent notAfter  for BOTH CA + leaf, YYYYMMDDHHMMSSZ
#                    (default 22310101000000Z). Needs openssl 3.3+.
#     CA_DAYS/LEAF_DAYS  fallback -days windows, ONLY used when openssl lacks
#                    -not_before/-not_after (default 3650 each; NOT clock-safe).
#     CA_FP_CONF     the config file whose CA_FINGERPRINT records this CA. Defaults
#                    to the repo deploy.conf when minting into the repo ca/, and to
#                    nothing (no record written) when minting into an override dir.
#                    Set it to "" to skip the record.
#
# REFUSALS (it exits non-zero and writes nothing):
#   * the CA cert is present but its key is not - a clone or a copied-in venue CA.
#     Minting here would overwrite a certificate this box did not mint.
#   * the CA key does not match the CA cert.
#   * the CA on disk is not the CA that CA_FINGERPRINT records.
# Each refusal names the ways out. Use --force to rotate the CA on purpose.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"

# shellcheck source=lib-ca-fingerprint.sh
source "${SELF_DIR}/lib-ca-fingerprint.sh"

# CA / leaf output dirs. Default to the repo's standard ca/ + server/tls/, but honour
# CA_DIR_OVERRIDE / TLS_DIR_OVERRIDE so a caller (setup.sh's verification run) can mint
# into a throwaway temp dir without clobbering the live dev CA.
CA_DIR="${CA_DIR_OVERRIDE:-${REPO_ROOT}/ca}"
TLS_DIR="${TLS_DIR_OVERRIDE:-${REPO_ROOT}/server/tls}"
CA_CRT="${CA_DIR}/partyos-ca.crt"
CA_KEY="${CA_DIR}/partyos-ca.key"
LEAF_CRT="${TLS_DIR}/partyos.crt"
LEAF_KEY="${TLS_DIR}/partyos.key"

# Clock-independent validity window, shared by the CA *and* the leaf. Party
# laptops boot with wrong RTCs / dead CMOS batteries, and iPXE validates the
# notBefore/notAfter of EVERY cert in the chain - INCLUDING the trust-anchor CA.
# A narrow CA is rejected 0216eb8f ("no usable certificates") when the client
# clock is before its notBefore, which bricks netboot on any box whose RTC reset.
# So BOTH certs span far-past -> far-future. Needs openssl 3.3+ (-not_before /
# -not_after); older openssl falls back to the -days window below (NOT clock-safe).
WIDE_NOTBEFORE="${WIDE_NOTBEFORE:-19700101000000Z}"
WIDE_NOTAFTER="${WIDE_NOTAFTER:-22310101000000Z}"
# Fallback -days windows, only used when openssl lacks -not_before/-not_after.
CA_DAYS="${CA_DAYS:-3650}"
LEAF_DAYS="${LEAF_DAYS:-3650}"

# The canonical server IP/hostname every client connects to - goes FIRST in the leaf
# SAN. REQUIRED: from PRIMARY_IP env (set here) or the first positional arg (resolved
# in the arg parse below). No baked default - setup.sh supplies the operator's value.
PRIMARY_IP="${PRIMARY_IP:-}"

# Pick an openssl. The notBefore backdate (clock tolerance - party RTCs are
# wrong) needs `openssl x509 -not_before`, added in OpenSSL 3.3. The host PATH
# openssl may be older (e.g. MacPort's 3.2), so prefer one that has the flag:
# honour $OPENSSL, then PATH if it supports -not_before, then a Homebrew 3.3+,
# then fall back to PATH (and warn the backdate is skipped).
_has_not_before() { "$1" x509 -help 2>&1 | grep -q -- '-not_before'; }
# Honour an explicit override ($OPENSSL or $OPENSSL_BIN) before auto-detecting.
OPENSSL="${OPENSSL:-${OPENSSL_BIN:-}}"
if [ -z "${OPENSSL}" ]; then
    if command -v openssl >/dev/null 2>&1 && _has_not_before openssl; then
        OPENSSL="$(command -v openssl)"
    else
        # Look for a newer Homebrew/MacPorts openssl that has -not_before.
        for cand in \
            /opt/homebrew/opt/openssl@3/bin/openssl \
            /opt/homebrew/opt/openssl/bin/openssl \
            /opt/homebrew/opt/openssl@3.6/bin/openssl \
            /opt/homebrew/opt/openssl@3.5/bin/openssl \
            /opt/homebrew/opt/openssl@3.4/bin/openssl \
            /opt/homebrew/opt/openssl@3.3/bin/openssl \
            /usr/local/opt/openssl@3/bin/openssl; do
            if [ -x "${cand}" ] && _has_not_before "${cand}"; then OPENSSL="${cand}"; break; fi
        done
    fi
fi
# Last resort: whatever openssl is on PATH (backdate then just no-ops).
[ -n "${OPENSSL}" ] || OPENSSL="$(command -v openssl || true)"
[ -n "${OPENSSL}" ] || { echo "gen-ca: openssl not found in PATH" >&2; exit 1; }
echo "[gen-ca] using openssl: ${OPENSSL} ($("${OPENSSL}" version 2>/dev/null))"

# Build the shared validity args, reused verbatim for BOTH the CA and the leaf so
# the whole chain carries the same clock-independent window. openssl 3.3+ gets an
# explicit wide -not_before/-not_after; older openssl falls back to -days from now
# (setup.sh requires 3.3+, so the fallback is only hit on a misconfigured host).
if _has_not_before "${OPENSSL}"; then
    CA_DATE_ARGS=(-not_before "${WIDE_NOTBEFORE}" -not_after "${WIDE_NOTAFTER}")
    LEAF_DATE_ARGS=(-not_before "${WIDE_NOTBEFORE}" -not_after "${WIDE_NOTAFTER}")
    echo "[gen-ca] clock-independent validity: ${WIDE_NOTBEFORE} .. ${WIDE_NOTAFTER} (CA + leaf, same window)"
else
    CA_DATE_ARGS=(-days "${CA_DAYS}")
    LEAF_DATE_ARGS=(-days "${LEAF_DAYS}")
    echo "[gen-ca] WARNING: ${OPENSSL} lacks -not_before; CA/leaf get a -days window that is NOT clock-independent."
    echo "[gen-ca]          install openssl 3.3+ so RTC-wrong clients can still netboot."
fi

# ---- parse args: --force flag, then PRIMARY_SAN (first positional, unless given
# via PRIMARY_IP env), then the rest are extra SAN entries ---------------------
FORCE=0
REISSUE_CA=0
declare -a EXTRA_SANS=()
for arg in "$@"; do
    case "${arg}" in
        --force) FORCE=1 ;;
        --reissue-ca) REISSUE_CA=1 ;;
        -h|--help)
            sed -n '2,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            # First non-flag positional is the PRIMARY SAN (unless PRIMARY_IP env
            # already supplied it); every positional after that is an extra SAN.
            if [ -z "${PRIMARY_IP}" ]; then PRIMARY_IP="${arg}"; else EXTRA_SANS+=("${arg}"); fi
            ;;
    esac
done
# Fold in the SANS env var (space/comma separated) so it behaves like extra args.
if [ -n "${SANS:-}" ]; then
    _oldifs="${IFS}"; IFS=', '
    for s in ${SANS}; do [ -n "${s}" ] && EXTRA_SANS+=("${s}"); done
    IFS="${_oldifs}"
fi

# The primary SAN is REQUIRED - fail loudly if neither arg 1 nor PRIMARY_IP gave one.
[ -n "${PRIMARY_IP}" ] || {
    echo "gen-ca: primary SAN IP/hostname required (arg 1 or PRIMARY_IP env)" >&2
    exit 1
}

# ---- BYOC guard -------------------------------------------------------------
# install-certs.sh writes ca/EXTERNAL-CA when an externally signed leaf + its CA
# are installed (a venue CA, whose private key we do NOT have). Signing anything
# then produces a leaf that chains to the WRONG anchor, and every client fails TLS.
# So refuse while the marker is there. Restore the self-minted CA path with:
#   scripts/deploy/install-certs.sh --restore-lab
# GEN_CA_ALLOW_EXTERNAL=1 overrides, for a test that needs to mint into a temp dir.
if [ -f "${CA_DIR}/EXTERNAL-CA" ] && [ "${GEN_CA_ALLOW_EXTERNAL:-0}" != "1" ]; then
    echo "gen-ca: REFUSED - an external CA is installed (${CA_DIR}/EXTERNAL-CA)." >&2
    echo "  We do not hold that CA's key, so a leaf signed here would not chain." >&2
    echo "  Install a venue-signed leaf with:   scripts/deploy/install-certs.sh" >&2
    echo "  Go back to the self-minted CA with: scripts/deploy/install-certs.sh --restore-lab" >&2
    exit 1
fi

# is_ip TOKEN -> 0 if it looks like an IPv4/IPv6 literal, 1 otherwise. Crude but
# enough to split SAN entries into IP: vs DNS: - operators pass plain IPs/names.
is_ip() {
    case "$1" in
        *[!0-9.]*)
            case "$1" in *:*[0-9a-fA-F]*) return 0 ;; *) return 1 ;; esac ;;  # has a colon -> treat as IPv6
        *.*.*.*) return 0 ;;   # four dotted groups -> IPv4
        *) return 1 ;;
    esac
}

# Build the SAN line: the primary SAN first (IP: or DNS: depending on whether it
# looks like an IP literal - it can now be a hostname), then any extras (deduped).
declare -a SAN_PARTS
if is_ip "${PRIMARY_IP}"; then SAN_PARTS=("IP:${PRIMARY_IP}"); else SAN_PARTS=("DNS:${PRIMARY_IP}"); fi
seen=" ${PRIMARY_IP} "
for s in "${EXTRA_SANS[@]:-}"; do
    [ -n "${s}" ] || continue
    case "${seen}" in *" ${s} "*) continue ;; esac   # dedupe
    seen="${seen}${s} "
    if is_ip "${s}"; then SAN_PARTS+=("IP:${s}"); else SAN_PARTS+=("DNS:${s}"); fi
done
SAN_LINE="$(IFS=,; echo "${SAN_PARTS[*]}")"

mkdir -p "${CA_DIR}" "${TLS_DIR}"

echo "[gen-ca] repo root : ${REPO_ROOT}"
echo "[gen-ca] leaf SAN  : ${SAN_LINE}"

# Was there a CA here before this run? A FIRST mint (no cert on disk) is free to
# write the CA_FINGERPRINT record at the end; a run that found a cert must not
# silently rewrite a record that describes the flashed sticks.
HAD_CA=0
[ -f "${CA_CRT}" ] && HAD_CA=1

# ============================================================================
# 1a. GUARD - never overwrite a CA cert this box did not mint.
# ============================================================================
# ca/partyos-ca.crt is a PUBLIC file that travels (a clone, a copy from another
# box, an operator dropping in a venue CA). The key does not travel: it is
# gitignored and secret. So "cert present, key absent" is the normal state of any
# box that is not the minting box.
#
# Without this guard, that state falls through to the mint branch below. That
# writes a NEW self-signed CA with the SAME subject (CN=partyOS Root CA) over the
# existing cert, and every stick flashed afterwards pins a CA nobody else trusts.
#
# So: refuse. The cert is left byte-identical and the operator picks a way out.
if [ -f "${CA_CRT}" ] && [ ! -f "${CA_KEY}" ] && [ "${FORCE}" -ne 1 ]; then
    cat >&2 <<EOF
gen-ca: REFUSED - a CA certificate is present but its private key is NOT.
  cert : ${CA_CRT}
  key  : ${CA_KEY} (missing)

  This box cannot sign with that CA. Minting a new one here would OVERWRITE the
  certificate above with a different CA that carries the same subject name, and
  every USB stick already flashed against the old one would fail the TLS boot
  chain. Refusing instead of overwriting it.

  Pick one:
    1. Supply the matching key at ${CA_KEY} (copy it from the box that minted it).
    2. Deliberately ROTATE the CA:   $0 --force ${PRIMARY_IP}
       (this DISCARDS the certificate above; every flashed stick must be reflashed)
    3. The cert is an externally signed CA (a venue CA) whose key you will never
       hold - install it with its leaf instead of minting:
         scripts/deploy/install-certs.sh --ca <ca.crt> --cert <leaf.crt> --key <leaf.key>
EOF
    exit 1
fi

# The pair must actually BELONG together. A cert plus an unrelated key used to
# reach `openssl x509 -req` below, which failed with its stderr redirected to
# /dev/null - the script then aborted under set -e with no message at all.
if [ -f "${CA_CRT}" ] && [ -f "${CA_KEY}" ] && [ "${FORCE}" -ne 1 ]; then
    _cert_pub="$("${OPENSSL}" x509 -in "${CA_CRT}" -noout -pubkey 2>/dev/null || true)"
    _key_pub="$("${OPENSSL}" pkey -in "${CA_KEY}" -pubout 2>/dev/null || true)"
    if [ -z "${_cert_pub}" ]; then
        echo "gen-ca: REFUSED - ${CA_CRT} is not a readable PEM certificate." >&2
        exit 1
    fi
    if [ -z "${_key_pub}" ]; then
        echo "gen-ca: REFUSED - ${CA_KEY} is not a readable PEM private key." >&2
        exit 1
    fi
    if [ "${_cert_pub}" != "${_key_pub}" ]; then
        cat >&2 <<EOF
gen-ca: REFUSED - the CA key does not match the CA certificate.
  cert : ${CA_CRT}
  key  : ${CA_KEY}
  Their public keys differ, so this key cannot sign a leaf that chains to that
  certificate. Nothing was written.

  Pick one:
    1. Put the CORRECT key at ${CA_KEY}.
    2. Deliberately ROTATE the CA:  $0 --force ${PRIMARY_IP}
       (new key AND new cert; every flashed stick must be reflashed)
EOF
        exit 1
    fi
    echo "[gen-ca] CA key matches the CA cert (public keys identical)."
fi

# ============================================================================
# 1. CA - self-signed root. Reused unless --force (rotating it re-pins clients).
# ============================================================================
if [ -f "${CA_CRT}" ] && [ -f "${CA_KEY}" ] && [ "${FORCE}" -ne 1 ] && [ "${REISSUE_CA}" -ne 1 ]; then
    echo "[gen-ca] CA already exists at ${CA_CRT} - reusing it (--force rotates the key, --reissue-ca re-dates the cert)."
elif [ "${REISSUE_CA}" -eq 1 ] && [ "${FORCE}" -ne 1 ] && [ -f "${CA_KEY}" ]; then
    # --reissue-ca: re-mint the self-signed CA CERT from the EXISTING key (the key
    # is KEPT, so the public key - and every leaf signed by it - stays valid). This
    # widens a narrow CA's validity window in place. It is DISTINCT from --force,
    # which rotates the key. NOTE: the cert BYTES change (new validity dates), so the
    # CA's SHA-256 FINGERPRINT changes. iPXE trusts roots by fingerprint (TRUST=),
    # so every stick's iPXE EFI must be rebuilt (make ipxe) + reflashed to bake the
    # re-dated CA. See docs/HOSTING.md ("Rotating the CA ... all-clients operation").
    echo "[gen-ca] --reissue-ca: re-minting the CA cert from the existing key (key KEPT, wide window)."
    "${OPENSSL}" req -x509 -new -key "${CA_KEY}" -sha256 \
        -subj "/CN=partyOS Root CA/O=partyOS" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        "${CA_DATE_ARGS[@]}" \
        -out "${CA_CRT}" 2>/dev/null
    echo "[gen-ca] re-issued CA cert -> ${CA_CRT} (same key; rebuild the EFI + reflash all sticks)"
else
    if [ -f "${CA_CRT}" ] && [ "${FORCE}" -eq 1 ]; then
        echo "[gen-ca] --force: ROTATING the CA (new key; clients pinned to the old CA must re-pin)."
    fi
    echo "[gen-ca] generating CA key + self-signed cert (clock-independent window)..."
    "${OPENSSL}" genrsa -out "${CA_KEY}" 4096 2>/dev/null
    chmod 600 "${CA_KEY}"
    # Self-signed CA marked CA:TRUE so it can sign the leaf, with the same wide
    # clock-independent window as the leaf (party RTCs are often years off, and
    # iPXE validates the CA's own notBefore/notAfter too).
    "${OPENSSL}" req -x509 -new -key "${CA_KEY}" -sha256 \
        -subj "/CN=partyOS Root CA/O=partyOS" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        "${CA_DATE_ARGS[@]}" \
        -out "${CA_CRT}" 2>/dev/null
    echo "[gen-ca] wrote CA cert -> ${CA_CRT}"
    echo "[gen-ca] wrote CA key  -> ${CA_KEY} (SECRET, gitignored)"
fi

# ============================================================================
# 2. SERVER LEAF - a fresh key + CSR, signed by the CA, with the IP SAN. Always
#    regenerated (cheap, and lets you re-run to add a SAN without CA rotation).
# ============================================================================
echo "[gen-ca] generating server leaf key + CSR..."
"${OPENSSL}" genrsa -out "${LEAF_KEY}" 2048 2>/dev/null
chmod 600 "${LEAF_KEY}"

# A throwaway extensions file so the leaf carries the SAN + serverAuth EKU. We
# use a temp file (not just -addext) so the same SAN goes into the signed cert
# via openssl x509 -extfile, which is the portable way to copy SAN onto a leaf.
EXT_FILE="$(mktemp "${TMPDIR:-/tmp}/partyos-leaf-ext.XXXXXX")"
trap 'rm -f "${EXT_FILE}"' EXIT
cat > "${EXT_FILE}" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${SAN_LINE}
EOF

"${OPENSSL}" req -new -key "${LEAF_KEY}" -sha256 \
    -subj "/CN=partyos-server/O=partyOS" \
    -out "${EXT_FILE}.csr" 2>/dev/null

# Sign the leaf with the same clock-independent window as the CA (LEAF_DATE_ARGS,
# built once above): party clients can boot with an RTC set years off, so a leaf
# valid from far-past to far-future avoids "not yet valid" / "expired" TLS errors.
"${OPENSSL}" x509 -req -in "${EXT_FILE}.csr" \
    -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
    -sha256 \
    "${LEAF_DATE_ARGS[@]}" \
    -extfile "${EXT_FILE}" \
    -out "${LEAF_CRT}" || {
        echo "gen-ca: FAILED to sign the leaf with ${CA_CRT} + ${CA_KEY}." >&2
        echo "  openssl's error is printed above (its stderr is deliberately NOT swallowed)." >&2
        exit 1
    }
rm -f "${EXT_FILE}.csr"

echo "[gen-ca] wrote leaf cert -> ${LEAF_CRT}"
echo "[gen-ca] wrote leaf key  -> ${LEAF_KEY} (SECRET, gitignored)"

# ============================================================================
# 3. Fingerprint - the value the iPXE TRUST= (and any curl pin) will use later.
# ============================================================================
FP="$("${OPENSSL}" x509 -in "${CA_CRT}" -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/^.*=//')"
echo
echo "[gen-ca] CA SHA-256 fingerprint (pin this in iPXE TRUST=):"
echo "         ${FP}"
echo

# Record it in deploy.conf so every later guard can compare the CA on disk against
# the CA the operator MEANT to use. Without the record a guard only ever compares
# the current CA with itself and can never catch a swap.
# CA_FP_CONF points at the config to update. It defaults to the repo deploy.conf,
# but ONLY when we minted into the repo ca/ - a mint into a temp dir (the tests and
# setup.sh's verification run) must never touch the live config.
if [ -z "${CA_FP_CONF+x}" ]; then
    if [ "${CA_DIR}" = "${REPO_ROOT}/ca" ]; then CA_FP_CONF="${REPO_ROOT}/deploy.conf"; else CA_FP_CONF=""; fi
fi
if [ -n "${CA_FP_CONF}" ]; then
    RECORDED="$(ca_fp_read "${CA_FP_CONF}")"
    if [ -z "${RECORDED}" ]; then
        ca_fp_write "${CA_FP_CONF}" "${FP}"
        echo "[gen-ca] recorded CA_FINGERPRINT in ${CA_FP_CONF}"
    elif [ "${RECORDED}" = "${FP}" ]; then
        echo "[gen-ca] CA_FINGERPRINT in ${CA_FP_CONF} already matches this CA."
    elif [ "${HAD_CA}" -eq 0 ] || [ "${FORCE}" -eq 1 ] || [ "${REISSUE_CA}" -eq 1 ]; then
        ca_fp_write "${CA_FP_CONF}" "${FP}"
        if [ "${HAD_CA}" -eq 0 ]; then
            echo "[gen-ca] first mint on this box - recorded CA_FINGERPRINT in ${CA_FP_CONF}"
            echo "[gen-ca] the previous record named a CA this box never had; it is replaced."
        else
            echo "[gen-ca] the CA changed on purpose - updated CA_FINGERPRINT in ${CA_FP_CONF}"
        fi
        echo "[gen-ca] REBUILD the EFI (make ipxe) and REFLASH every stick."
    else
        cat >&2 <<EOF
gen-ca: REFUSED - the CA on disk is not the CA ${CA_FP_CONF} records.
  on disk  : ${FP}
  recorded : ${RECORDED}
  Something replaced ${CA_CRT} outside gen-ca.sh / install-certs.sh. The recorded
  anchor is what the flashed sticks pin, so this is not a safe thing to build on.
  Restore the recorded CA, or rotate deliberately with --force (which reflashes
  every stick), or install an external CA with install-certs.sh.
EOF
        exit 1
    fi
fi

echo "[gen-ca] done. Server presents ${LEAF_CRT}; ship ${CA_CRT} to clients."
