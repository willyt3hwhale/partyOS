#!/usr/bin/env bash
# test-initramfs-guard.sh - MUTATION test for scripts/deploy/check-initramfs.sh.
#
# The guard exists because `make image` rebuilds only the sfs, not the SERVED
# initramfs. A stale served initramfs
# lacks the bundled CA (/etc/partyos/ca.pem) + the archiso_pxe_http
# `--cacert` flag, so the all-HTTPS copytoram boot fails CLOSED. The guard must
# REFUSE to let such an initramfs be served silently.
#
# This test proves the guard's logic by MUTATION: it synthesizes minimal but REAL
# fixtures (a microcode-style early cpio + an xz-compressed main cpio, the exact
# layout mkinitcpio emits, so the guard runs its real decompress+scan path) with a
# REAL self-signed CA bundled inside, and asserts:
#   (good)  WIDE CA (notBefore 1970 / notAfter 2231) + --cacert + newer -> guard PASSES.
#   (bad A) CA file STRIPPED out of the initramfs                       -> guard FAILS.
#   (bad B) --cacert STRIPPED from the archiso_pxe_http hook            -> guard FAILS.
#   (bad C) initramfs mtime OLDER than the sfs (stale)                  -> guard FAILS.
#   (bad D) NARROW CA (notAfter ~1yr) bundled instead of the wide one   -> guard FAILS.
# (bad D) is the clock-independence guard: a narrow-window CA boot-loops any client
# with a wrong RTC, so the guard must refuse it even though it is PRESENT.
# Hardware-free; no VM, no network, no Arch tools. Needs python3 + xz/unxz + openssl
# (the same tools the guard itself uses), which the dev box + CI have.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

GUARD="${REPO_ROOT}/scripts/deploy/check-initramfs.sh"
[ -f "${GUARD}" ] || { echo "FAIL: guard not found at ${GUARD}"; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable (guard test needs it)"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl unavailable (guard CA-window test needs it)"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-irguard-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# --- CA minting ---------------------------------------------------------------
# Mint real self-signed CAs with an EXPLICIT validity window via `openssl ca
# -selfsign -startdate/-enddate`, so we can hand the guard a WIDE (clock-independent)
# CA and a NARROW one and prove it distinguishes them by notAfter/notBefore.
CADIR="${TMP}/ca-mint"
mkdir -p "${CADIR}"
cat > "${CADIR}/ca.cnf" <<EOF
[ca]
default_ca = t
[t]
database = ${CADIR}/index.txt
serial = ${CADIR}/serial
new_certs_dir = ${CADIR}
default_md = sha256
policy = pol
[pol]
commonName = optional
EOF
openssl req -new -newkey rsa:2048 -nodes -keyout "${CADIR}/key.pem" \
    -out "${CADIR}/req.csr" -subj "/CN=partyOS Test Root" >/dev/null 2>&1

# mint_ca OUT_PEM STARTDATE ENDDATE  (dates as YYYYMMDDHHMMSSZ)
mint_ca() {
    : > "${CADIR}/index.txt"; echo 01 > "${CADIR}/serial"
    openssl ca -selfsign -config "${CADIR}/ca.cnf" -in "${CADIR}/req.csr" \
        -keyfile "${CADIR}/key.pem" -out "$1" -startdate "$2" -enddate "$3" \
        -batch -notext >/dev/null 2>&1
}

WIDE_CA="${TMP}/wide-ca.pem"
NARROW_CA="${TMP}/narrow-ca.pem"
mint_ca "${WIDE_CA}"   19700101000000Z 22310101000000Z
mint_ca "${NARROW_CA}" 20260601000000Z 20270601000000Z
[ -s "${WIDE_CA}" ]   || { echo "FAIL: could not mint the wide test CA";   exit 1; }
[ -s "${NARROW_CA}" ] || { echo "FAIL: could not mint the narrow test CA"; exit 1; }

# --- fixture builder ----------------------------------------------------------
# Build a synthetic initramfs that matches the REAL on-disk layout the guard
# parses: an UNCOMPRESSED early newc cpio (stands in for the microcode archive)
# followed by an xz-compressed main newc cpio holding the rootfs. CA_PEM is the path
# to the real CA to bundle (empty => none) and WITH_CACERT toggles the hook flag, so
# we can mutate each security-critical bit independently.
#   build_fixture OUT CA_PEM WITH_CACERT   (CA_PEM="" => no CA bundled)
make_fixture_py="${TMP}/make_fixture.py"
cat > "${make_fixture_py}" <<'PY'
import sys, lzma, io

out_path, ca_pem, with_cacert = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with_ca = bool(ca_pem)

def newc(entries):
    """entries: list of (name, mode, data_bytes). Build a newc cpio with TRAILER."""
    buf = io.BytesIO()
    ino = 1
    def pad4(b):
        if len(b) % 4:
            b += b"\x00" * (4 - len(b) % 4)
        return b
    for name, mode, data in entries:
        nameb = name.encode() + b"\x00"
        hdr = b"070701"
        fields = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nameb), 0]
        hdr += b"".join(b"%08X" % f for f in fields)
        buf.write(pad4(hdr + nameb))
        buf.write(pad4(data))
        ino += 1
    # TRAILER
    nameb = b"TRAILER!!!\x00"
    hdr = b"070701" + b"".join(b"%08X" % f for f in
                               [0,0,0,0,1,0,0,0,0,0,0,len(nameb),0])
    buf.write(pad4(hdr + nameb))
    return buf.getvalue()

# early (uncompressed) cpio: a microcode-ish blob, like the real early archive.
early = newc([
    ("early_cpio", 0o100644, b"1\n"),
    ("kernel/x86/microcode/GenuineIntel.bin", 0o100644, b"\x00" * 64),
])

# the archiso_pxe_http hook body, with or without the --cacert flag.
cacert = "--cacert /etc/partyos/ca.pem " if with_cacert else ""
hook = (
    "#!/bin/bash\n"
    "# synthetic archiso_pxe_http fixture\n"
    "_curl_get() { curl -L -f --retry 5 " + cacert +
    '-o "/run/archiso/httpspace/${1##*/}" "$1"; }\n'
).encode()

main_entries = [
    ("bin", 0o40755, b""),
    ("hooks", 0o40755, b""),
    ("hooks/archiso_pxe_http", 0o100755, hook),
]
if with_ca:
    ca_bytes = open(ca_pem, "rb").read()
    main_entries += [
        ("etc", 0o40755, b""),
        ("etc/partyos", 0o40755, b""),
        ("etc/partyos/ca.pem", 0o100644, ca_bytes),
    ]
main = newc(main_entries)
main_xz = lzma.compress(main, format=lzma.FORMAT_XZ)

with open(out_path, "wb") as f:
    f.write(early)
    f.write(main_xz)
PY
# build_fixture OUT CA_PEM WITH_CACERT   (CA_PEM="" => no CA bundled)
build_fixture() {
    python3 "${make_fixture_py}" "$1" "${2:-}" "$3"
}

# a stand-in sfs the guard mtime-compares against.
SFS="${TMP}/airootfs.sfs"
printf 'fake sfs\n' > "${SFS}"

# run_guard IMG SFS -> echoes the guard's exit code (isolated; never aborts the test).
run_guard() {
    local rc
    ( bash "${GUARD}" "$1" "$2" ) >/dev/null 2>&1
    rc=$?
    echo "${rc}"
}

# --- self-check: the synthetic GOOD fixture must be readable by the guard -----
# (proves the fixture layout exercises the guard's real decompress+scan path; if
# the guard couldn't parse it at all, every case below would be meaningless.)
GOOD="${TMP}/good.img"
build_fixture "${GOOD}" "${WIDE_CA}" 1
# make it clearly NEWER than the sfs.
sleep 1; touch "${GOOD}"
goodout="$( bash "${GUARD}" "${GOOD}" "${SFS}" 2>&1 )"
assert_contains "${goodout}" "ca.pem is bundled" "fixture is parseable: guard reads the bundled CA out of the synthetic xz cpio"
assert_contains "${goodout}" "wide-window" "GOOD: guard confirms the bundled CA is wide-window / clock-independent"

# --- GOOD: WIDE CA + --cacert + newer -> PASS ---------------------------------
rc="$(run_guard "${GOOD}" "${SFS}")"
assert_eq "${rc}" "0" "GOOD (wide CA + --cacert + newer than sfs): guard PASSES"

# --- BAD A: CA stripped -> FAIL -----------------------------------------------
NOCA="${TMP}/no-ca.img"
build_fixture "${NOCA}" "" 1
sleep 1; touch "${NOCA}"
rc="$(run_guard "${NOCA}" "${SFS}")"
assert_false "${rc}" "BAD-A (no /etc/partyos/ca.pem bundled): guard FAILS"
out="$( bash "${GUARD}" "${NOCA}" "${SFS}" 2>&1 || true )"
assert_contains "${out}" "ca.pem is NOT bundled" "BAD-A: guard names the missing CA"
assert_contains "${out}" "run \`make initramfs\`" "BAD-A: guard message is actionable (make initramfs)"

# --- BAD B: --cacert stripped from the hook -> FAIL ---------------------------
NOCACERT="${TMP}/no-cacert.img"
build_fixture "${NOCACERT}" "${WIDE_CA}" 0
sleep 1; touch "${NOCACERT}"
rc="$(run_guard "${NOCACERT}" "${SFS}")"
assert_false "${rc}" "BAD-B (archiso_pxe_http missing --cacert): guard FAILS"
out="$( bash "${GUARD}" "${NOCACERT}" "${SFS}" 2>&1 || true )"
assert_contains "${out}" "missing" "BAD-B: guard reports the missing --cacert flag"

# --- BAD C: initramfs OLDER than the sfs (stale) -> FAIL ----------------------
# Same fully-good content, only the mtime is regressed below the sfs.
STALE="${TMP}/stale.img"
build_fixture "${STALE}" "${WIDE_CA}" 1
# bump the sfs to NOW, then set the initramfs mtime into the past so it is older.
touch "${SFS}"
touch -t 202001010000 "${STALE}"
rc="$(run_guard "${STALE}" "${SFS}")"
assert_false "${rc}" "BAD-C (initramfs older than sfs): guard FAILS as stale"
out="$( bash "${GUARD}" "${STALE}" "${SFS}" 2>&1 || true )"
assert_contains "${out}" "OLDER than the sfs" "BAD-C: guard reports the stale mtime"

# --- BAD D: NARROW-window CA bundled (present but not clock-independent) -> FAIL
# The CA is PRESENT and the --cacert flag is set and the mtime is fresh - a
# presence-only guard would happily pass this and ship a boot-looping image. The
# strengthened guard must REFUSE it because the CA's notAfter is not far enough out.
NARROW="${TMP}/narrow.img"
build_fixture "${NARROW}" "${NARROW_CA}" 1
sleep 1; touch "${NARROW}"
rc="$(run_guard "${NARROW}" "${SFS}")"
assert_false "${rc}" "BAD-D (narrow-window CA, present + --cacert + fresh): guard FAILS"
out="$( bash "${GUARD}" "${NARROW}" "${SFS}" 2>&1 || true )"
assert_contains "${out}" "NARROW-window" "BAD-D: guard names the narrow validity window"
assert_contains "${out}" "wrong RTC" "BAD-D: guard explains the wrong-RTC boot-loop risk"

# --- EXTERNAL CA: a narrow venue CA that is the installed external CA -> PASS with WARN
# install-certs.sh writes ca/EXTERNAL-CA. We cannot re-mint a venue CA, so the guard
# only warns if the bundled CA is byte-identical to the installed one and valid now.
EXTDIR="${TMP}/extca"; mkdir -p "${EXTDIR}"
NOW_CA="${TMP}/now-narrow-ca.pem"
mint_ca "${NOW_CA}" "$(date -u -v-1d +%Y%m%d%H%M%SZ 2>/dev/null || date -u -d '-1 day' +%Y%m%d%H%M%SZ)" \
    "$(date -u -v+7d +%Y%m%d%H%M%SZ 2>/dev/null || date -u -d '+7 day' +%Y%m%d%H%M%SZ)"
cp "${NOW_CA}" "${EXTDIR}/partyos-ca.crt"; : > "${EXTDIR}/EXTERNAL-CA"
EXTIMG="${TMP}/ext.img"
build_fixture "${EXTIMG}" "${NOW_CA}" 1
sleep 1; touch "${EXTIMG}"
out="$( CHECK_CA_DIR="${EXTDIR}" bash "${GUARD}" "${EXTIMG}" "${SFS}" 2>&1 )"; rc=$?
assert_true "${rc}" "EXT: the installed narrow external CA, valid now: guard PASSES"
assert_contains "${out}" "WARN - bundled CA is the installed EXTERNAL CA" "EXT: guard warns about the narrow window"
rm -f "${EXTDIR}/EXTERNAL-CA"
rc="$( CHECK_CA_DIR="${EXTDIR}" bash "${GUARD}" "${EXTIMG}" "${SFS}" >/dev/null 2>&1; echo $? )"
assert_false "${rc}" "EXT: the same narrow CA without the EXTERNAL-CA marker: guard FAILS"
: > "${EXTDIR}/EXTERNAL-CA"; cp "${NARROW_CA}" "${EXTDIR}/partyos-ca.crt"
rc="$( CHECK_CA_DIR="${EXTDIR}" bash "${GUARD}" "${EXTIMG}" "${SFS}" >/dev/null 2>&1; echo $? )"
assert_false "${rc}" "EXT: a bundled CA that is not the installed external CA: guard FAILS"
cp "${NARROW_CA}" "${EXTDIR}/partyos-ca.crt"
EXPIMG="${TMP}/expired.img"; EXP_CA="${TMP}/expired-ca.pem"
mint_ca "${EXP_CA}" 20200101000000Z 20210101000000Z
cp "${EXP_CA}" "${EXTDIR}/partyos-ca.crt"
build_fixture "${EXPIMG}" "${EXP_CA}" 1; sleep 1; touch "${EXPIMG}"
rc="$( CHECK_CA_DIR="${EXTDIR}" bash "${GUARD}" "${EXPIMG}" "${SFS}" >/dev/null 2>&1; echo $? )"
assert_false "${rc}" "EXT: an expired installed external CA: guard FAILS"

# --- missing file -> FAIL -----------------------------------------------------
rc="$(run_guard "${TMP}/does-not-exist.img" "${SFS}")"
assert_false "${rc}" "MISSING initramfs file: guard FAILS"

assert_summary "test-initramfs-guard"
