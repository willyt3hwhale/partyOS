#!/usr/bin/env bash
# check-initramfs.sh - GUARD against serving a stale / insecure boot initramfs.
#
# The bug this guards: `make image`
# rebuilds ONLY the squashfs (server/images/custom/.../airootfs.sfs). It does NOT
# regenerate the SERVED initramfs (server/images/initramfs-linux.img) - that needs
# the separate privileged `make initramfs` (scripts/build/slim-initramfs.sh, which
# honors the mkinitcpio drop-ins: the FILES+=(/etc/partyos/ca.pem) that
# bundles the pinned CA, and the archiso_pxe_http _curl_get --cacert override).
# A clean rebuild that skips that step serves a STALE initramfs: no bundled CA, no
# --cacert. The now-all-HTTPS copytoram fetch then fails CLOSED (curl rejects the
# TLS sfs) = the party doesn't boot, and it looks like a coherent build.
#
# This guard FAILS (non-zero + an actionable message) if ANY of:
#   * the initramfs does NOT contain /etc/partyos/ca.pem,
#   * its archiso_pxe_http hook does NOT contain `--cacert /etc/partyos/ca.pem`,
#   * the initramfs is OLDER than the sfs (mtime) -> likely stale / not regenerated
#     after the last `make image`.
#
# It inspects the initramfs WITHOUT assuming `lsinitcpio` exists (that's an Arch
# tool; the dev box is macOS). It handles the microcode-prepended CPIO + compressed
# (zstd/xz/gzip) main archive by walking the early CPIO to its TRAILER and
# decompressing what follows, in this order: lsinitcpio (if present) -> bsdtar ->
# a self-contained python CPIO scan. The CA-present and --cacert checks are the
# critical ones.
#
# Usage: check-initramfs.sh [INITRAMFS] [SFS]
#   defaults: server/images/initramfs-linux.img
#             server/images/custom/arch/x86_64/airootfs.sfs
# Exit 0 = artifacts coherent; non-zero = stale/insecure, do not serve.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"

INITRAMFS="${1:-${REPO_ROOT}/server/images/initramfs-linux.img}"
SFS="${2:-${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs}"

CA_PATH="etc/partyos/ca.pem"            # path inside the initramfs (no leading /)
CACERT_FLAG="--cacert /etc/partyos/ca.pem"
HOOK_NAME="archiso_pxe_http"

# A clock-independent (WIDE) Root CA must expire far in the future and start far in
# the past, so a client whose RTC is wrong (dead battery / never set) still validates
# it over TLS. A NARROW CA (short validity, notBefore ~now) boot-loops such clients.
# We validate the CA by its validity WINDOW, not by fingerprint, so a CA legitimately
# re-minted with the same key (=> different fingerprint) still passes.
CA_MIN_NOTAFTER_YEAR=2100               # notAfter must be at/after this year
CA_MAX_NOTBEFORE_YEAR=2000              # notBefore must be at/before this year

# An EXTERNAL (venue) CA is installed by install-certs.sh. We do not mint it, so we
# cannot make it wide. If the bundled CA is exactly that installed CA, a narrow window
# is a loud WARNING, not a failure. The CA must still be valid at the current time.
CHECK_CA_DIR="${CHECK_CA_DIR:-${REPO_ROOT}/ca}"

fail() { echo "check-initramfs: FAIL - $*" >&2; exit 1; }

[ -f "${INITRAMFS}" ] || fail "served initramfs not found: ${INITRAMFS}
  run \`make initramfs\` after \`make image\` to produce it."

# --- inspect the initramfs ----------------------------------------------------
# We need two things from it: the full file LISTING (to confirm /etc/partyos/ca.pem)
# and the CONTENT of the archiso_pxe_http hook (to confirm the --cacert flag).
# Emit the listing to ${LIST} and the hook body to ${HOOKBODY}.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/partyos-check-ir.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
LIST="${WORK}/listing"
HOOKBODY="${WORK}/hook"
CABODY="${WORK}/ca"                      # the bundled etc/partyos/ca.pem bytes, extracted
: > "${LIST}"
: > "${HOOKBODY}"
: > "${CABODY}"

inspect_with_lsinitcpio() {
    command -v lsinitcpio >/dev/null 2>&1 || return 1
    lsinitcpio "${INITRAMFS}" > "${LIST}" 2>/dev/null || return 1
    [ -s "${LIST}" ] || return 1
    # lsinitcpio -x extracts to cwd; pull the hook body out.
    ( cd "${WORK}" && lsinitcpio -x "${INITRAMFS}" >/dev/null 2>&1 ) || true
    if [ -f "${WORK}/hooks/${HOOK_NAME}" ]; then
        cp "${WORK}/hooks/${HOOK_NAME}" "${HOOKBODY}"
    fi
    if [ -f "${WORK}/${CA_PATH}" ]; then
        cp "${WORK}/${CA_PATH}" "${CABODY}"
    fi
    return 0
}

# bsdtar reads concatenated cpio + autodetects the compression of the main archive,
# but on some platforms it only descends the EARLY (microcode) cpio. We try it and
# fall back to the python scanner if the listing doesn't carry the rootfs.
inspect_with_bsdtar() {
    command -v bsdtar >/dev/null 2>&1 || return 1
    bsdtar -tf "${INITRAMFS}" 2>/dev/null > "${LIST}" || return 1
    grep -q "${CA_PATH}" "${LIST}" 2>/dev/null || return 1   # only trust it if it saw the rootfs
    bsdtar -xOf "${INITRAMFS}" "hooks/${HOOK_NAME}" 2>/dev/null > "${HOOKBODY}" || true
    bsdtar -xOf "${INITRAMFS}" "${CA_PATH}" 2>/dev/null > "${CABODY}" || true
    return 0
}

# Self-contained scanner: walk the early newc cpio to its TRAILER, then decompress
# the following stream (zstd/xz/gzip, autodetected by magic) and scan its cpio for
# the listing + the hook body. No Arch tools required.
inspect_with_python() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "${INITRAMFS}" "${LIST}" "${HOOKBODY}" "${HOOK_NAME}" "${CABODY}" "${CA_PATH}" <<'PY'
import sys, lzma, zlib, io

img_path, list_path, hook_path, hook_name, ca_path, ca_name = sys.argv[1:7]
data = open(img_path, "rb").read()

def cpio_iter(buf):
    """Yield (name, file_bytes) for a newc (070701) cpio image. Returns the byte
    offset just past TRAILER!!! as the iterator's .end attribute via a holder."""
    pos = 0
    n = len(buf)
    while pos + 110 <= n:
        if buf[pos:pos+6] != b"070701":
            break
        def field(i):
            return int(buf[pos+6+i*8:pos+6+i*8+8], 16)
        filesize = field(6)
        namesize = field(11)
        name = buf[pos+110:pos+110+namesize-1]
        hdr = (110 + namesize + 3) & ~3
        dstart = pos + hdr
        if name == b"TRAILER!!!":
            cpio_iter.end = (dstart + 3) & ~3
            return
        fend = dstart + filesize
        yield name.decode("utf-8", "replace"), buf[dstart:fend]
        pos = (fend + 3) & ~3
    cpio_iter.end = pos

def decompress(buf):
    """Autodetect zstd/xz/gzip and return decompressed bytes (or None)."""
    if buf[:6] == bytes.fromhex("fd377a585a00"):
        return lzma.decompress(buf)            # xz
    if buf[:4] == bytes.fromhex("28b52ffd"):
        try:
            import zstandard as zstd
            return zstd.ZstdDecompressor(max_window_size=2**31).decompress(buf)
        except Exception:
            import subprocess
            for cmd in (["unzstd","--long=31","-q","-c"], ["zstd","-d","--long=31","-q","-c"]):
                try:
                    return subprocess.run(cmd, input=buf, stdout=subprocess.PIPE,
                                          stderr=subprocess.DEVNULL, check=True).stdout
                except Exception:
                    continue
            return None
    if buf[:2] == bytes.fromhex("1f8b"):
        return zlib.decompress(buf, 16 + zlib.MAX_WBITS)  # gzip
    if buf[:6] == b"070701":
        return buf                              # already a plain cpio
    return None

names = []
hook_body = b""
ca_body = b""

# 1) the early (uncompressed) cpio - microcode + firmware + maybe the rootfs.
for name, body in cpio_iter(data):
    names.append(name)
    if name == "hooks/" + hook_name:
        hook_body = body
    if name.lstrip("/") == ca_name:
        ca_body = body
early_end = cpio_iter.end

# 2) the compressed main archive that follows (skip zero padding).
p = early_end
while p < len(data) and data[p] == 0:
    p += 1
if p < len(data):
    dec = decompress(data[p:])
    if dec:
        for name, body in cpio_iter(dec):
            names.append(name)
            if name == "hooks/" + hook_name:
                hook_body = body
            if name.lstrip("/") == ca_name:
                ca_body = body

with open(list_path, "w") as f:
    f.write("\n".join(names) + "\n")
with open(hook_path, "wb") as f:
    f.write(hook_body)
with open(ca_path, "wb") as f:
    f.write(ca_body)

# non-zero if we never saw the CA file at all (lets the shell fall through cleanly)
sys.exit(0 if any(n.lstrip("/") == "etc/partyos/ca.pem" for n in names) else 3)
PY
}

USED=""
if inspect_with_lsinitcpio; then USED="lsinitcpio"
elif inspect_with_bsdtar;   then USED="bsdtar"
elif inspect_with_python;   then USED="python"
else
    # python may have exited non-zero only because the CA was absent; the listing
    # is still valid for the checks below. Accept it if we got any listing.
    [ -s "${LIST}" ] && USED="python(no-ca)" || fail "could not inspect ${INITRAMFS}
  none of lsinitcpio / bsdtar / python3 could read it (install one, or run on Arch)."
fi

# --- the three checks ---------------------------------------------------------
errs=0

# 1) CA bundled into the initramfs.
CA_PRESENT=0
if grep -Eq "(^|/)etc/partyos/ca\.pem$" "${LIST}"; then
    CA_PRESENT=1
    echo "check-initramfs: OK  - /etc/partyos/ca.pem is bundled in the initramfs"
else
    echo "check-initramfs: FAIL - /etc/partyos/ca.pem is NOT bundled in the initramfs" >&2
    errs=$((errs+1))
fi

# 1b) the bundled CA must be a WIDE / clock-independent CA (very early notBefore,
#     far-future notAfter), not a NARROW one. A narrow CA (short validity, notBefore
#     ~now) boot-loops any client whose RTC is wrong: the TLS layer rejects the cert
#     as not-yet-valid or expired and the copytoram fetch fails CLOSED. We check the
#     validity WINDOW (openssl -startdate/-enddate), NOT the fingerprint, so a CA
#     re-minted with the same key (different fingerprint) still passes.
if [ "${CA_PRESENT}" -eq 1 ]; then
    if ! command -v openssl >/dev/null 2>&1; then
        echo "check-initramfs: NOTE - openssl not found; skipping the bundled-CA validity-window check" >&2
    elif [ ! -s "${CABODY}" ]; then
        echo "check-initramfs: FAIL - bundled CA is present in the listing but its bytes could not be extracted to verify its validity window" >&2
        errs=$((errs+1))
    else
        enddate="$(openssl x509 -enddate -noout -in "${CABODY}" 2>/dev/null || true)"
        startdate="$(openssl x509 -startdate -noout -in "${CABODY}" 2>/dev/null || true)"
        end_year="$(printf '%s\n' "${enddate}" | grep -oE '[12][0-9]{3}' | head -1)"
        start_year="$(printf '%s\n' "${startdate}" | grep -oE '[12][0-9]{3}' | head -1)"
        if [ -z "${end_year}" ]; then
            echo "check-initramfs: FAIL - could not parse the bundled CA's notAfter (openssl could not read etc/partyos/ca.pem)" >&2
            errs=$((errs+1))
        elif { [ "${end_year}" -lt "${CA_MIN_NOTAFTER_YEAR}" ] || { [ -n "${start_year}" ] && [ "${start_year}" -gt "${CA_MAX_NOTBEFORE_YEAR}" ]; }; } \
             && [ -f "${CHECK_CA_DIR}/EXTERNAL-CA" ] && [ -f "${CHECK_CA_DIR}/partyos-ca.crt" ] \
             && cmp -s "${CABODY}" "${CHECK_CA_DIR}/partyos-ca.crt"; then
            if openssl verify -CAfile "${CABODY}" "${CABODY}" >/dev/null 2>&1; then
                echo "check-initramfs: WARN - bundled CA is the installed EXTERNAL CA and is NARROW-window (${startdate}, ${enddate})" >&2
                echo "  it cannot be re-minted here. A client with a wrong RTC fails TLS outside that window." >&2
                echo "check-initramfs: OK  - bundled CA is the installed external CA and is valid now"
            else
                echo "check-initramfs: FAIL - bundled EXTERNAL CA is not valid at the current time (${startdate}, ${enddate})" >&2
                errs=$((errs+1))
            fi
        elif [ "${end_year}" -lt "${CA_MIN_NOTAFTER_YEAR}" ]; then
            echo "check-initramfs: FAIL - bundled CA is NARROW-window (${enddate}); notAfter year ${end_year} < ${CA_MIN_NOTAFTER_YEAR}" >&2
            echo "  a narrow CA boot-loops clients with a wrong RTC (TLS rejects it as not-yet-valid/expired)." >&2
            echo "  re-mint a WIDE / clock-independent CA (notBefore ~1970, notAfter far in the future) and rebuild the initramfs." >&2
            errs=$((errs+1))
        elif [ -n "${start_year}" ] && [ "${start_year}" -gt "${CA_MAX_NOTBEFORE_YEAR}" ]; then
            echo "check-initramfs: FAIL - bundled CA notBefore is too recent (${startdate}); notBefore year ${start_year} > ${CA_MAX_NOTBEFORE_YEAR}" >&2
            echo "  a client whose RTC is rewound before that date would reject the cert. re-mint with an early notBefore (~1970)." >&2
            errs=$((errs+1))
        else
            echo "check-initramfs: OK  - bundled CA is wide-window / clock-independent (notBefore year ${start_year:-?} <= ${CA_MAX_NOTBEFORE_YEAR}, notAfter year ${end_year} >= ${CA_MIN_NOTAFTER_YEAR})"
        fi
    fi
fi

# 2) the archiso_pxe_http hook pins the CA on its fetch.
if [ -s "${HOOKBODY}" ] && grep -qF -- "${CACERT_FLAG}" "${HOOKBODY}"; then
    echo "check-initramfs: OK  - ${HOOK_NAME} pins the CA (${CACERT_FLAG})"
else
    echo "check-initramfs: FAIL - ${HOOK_NAME} hook is missing \`${CACERT_FLAG}\`" >&2
    errs=$((errs+1))
fi

# 3) freshness: the served initramfs must be NEWER than the sfs it boots with.
if [ -f "${SFS}" ]; then
    if [ "${INITRAMFS}" -ot "${SFS}" ]; then
        echo "check-initramfs: FAIL - initramfs is OLDER than the sfs (likely stale - not regenerated after \`make image\`)" >&2
        errs=$((errs+1))
    else
        echo "check-initramfs: OK  - initramfs is newer-or-equal to the sfs (not stale by mtime)"
    fi
else
    echo "check-initramfs: NOTE - sfs not found (${SFS}); skipping the freshness check" >&2
fi

echo "check-initramfs: (inspected via ${USED})"

if [ "${errs}" -ne 0 ]; then
    fail "served initramfs is stale or missing the pinned CA - run \`make initramfs\` after \`make image\`
  initramfs: ${INITRAMFS}
  sfs      : ${SFS}"
fi

echo "check-initramfs: PASS - served boot artifacts are coherent and CA-pinned"
exit 0
