#!/usr/bin/env bash
# build-ipxe.sh - HOST orchestrator that builds the partyOS boot iPXE EFI.
#
# The deployed boot EFIs were built AD-HOC in a throwaway linux/amd64 docker
# container (clone iPXE, `make -C src bin-x86_64-efi/ipxe.efi EMBED=... CERT=...
# TRUST=...`), with no runnable recipe in the repo - so a CA rotation
# (gen-ca.sh --force), an iPXE/embed change, or a lost binary left no `make ipxe`
# to regenerate them. This is that recipe.
#
# Like build-image.sh / build-initramfs.sh, the actual build runs inside a
# linux/amd64 docker container (macOS/arm64 hosts have no iPXE toolchain).
# In the container: clone iPXE at a PINNED git ref, embed our autoboot script,
# and for the https variant compile our private CA in (BOTH CERT= and TRUST=,
# see below), then `make -C src bin-x86_64-efi/ipxe.efi`. The produced ipxe.efi
# is installed ATOMICALLY (temp + mv) to the host OUT path.
#
# Two variants (VARIANT=):
#   https (default): EMBED=build/embed-test-https.ipxe, the boot chain goes over
#                    HTTPS:8443 validated against the pinned partyOS CA. iPXE
#                    needs BOTH `CERT=ca.crt TRUST=ca.crt`: TRUST= alone embeds
#                    only the CA *fingerprint*, not the cert, so a private-CA-only
#                    chain fails 0216eb8f ("no usable certificates") - CERT= the
#                    same CA so the cert ITSELF is compiled in. Output ->
#                    build/ipxe-custom-https.efi.
#   http:            EMBED=build/embed-test.ipxe, NO CERT/TRUST (plain HTTP:8080).
#                    Output -> build/ipxe-custom.efi.
#
# DOWNLOAD_PROTO_HTTPS is already enabled by default for the bin-x86_64-efi
# platform, so no config edit is needed to turn HTTPS on - but we ASSERT it is
# present in the produced binary (the self-verification below) and only patch
# config/general.h if a future iPXE ever shipped it off.
#
# iPXE EFI builds are NOT bit-reproducible (build timestamps/ids), so this does
# NOT require an sha match to the currently-deployed binary. Instead it
# self-verifies the produced binary (valid PE/EFI; for https: the FULL current
# ca/partyos-ca.crt DER is embedded + HTTPS is compiled in) and FAILS CLOSED if
# any check is missing.
#
# Overrides via env: VARIANT, EMBED, CA, OUT, IPXE_REF, ARCH_IMAGE.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
IMAGE="${ARCH_IMAGE:-debian:bookworm-slim}"

# Pinned iPXE ref. The HTTPS build was proven on HEAD 327378a; pin that exact commit
# (full hash 327378a764064b5edbc8bbebbb95980234892d04, on master) so the binary is
# reproducibly buildable. Override with IPXE_REF=<commit|tag>.
IPXE_REF="${IPXE_REF:-327378a764064b5edbc8bbebbb95980234892d04}"
IPXE_REPO="${IPXE_REPO:-https://github.com/ipxe/ipxe.git}"

VARIANT="${VARIANT:-https}"

CA_SRC="${CA:-${REPO_ROOT}/ca/partyos-ca.crt}"

case "${VARIANT}" in
    https)
        EMBED_SRC="${EMBED:-${REPO_ROOT}/build/embed-test-https.ipxe}"
        OUT="${OUT:-${REPO_ROOT}/build/ipxe-custom-https.efi}"
        WITH_CA=1
        ;;
    http)
        EMBED_SRC="${EMBED:-${REPO_ROOT}/build/embed-test.ipxe}"
        OUT="${OUT:-${REPO_ROOT}/build/ipxe-custom.efi}"
        WITH_CA=0
        ;;
    *)
        echo "ERROR: unknown VARIANT='${VARIANT}' (expected: https | http)" >&2
        exit 1
        ;;
esac

[ -f "${EMBED_SRC}" ] || { echo "ERROR: embed script not found: ${EMBED_SRC}" >&2; exit 1; }
if [ "${WITH_CA}" = "1" ]; then
    [ -f "${CA_SRC}" ] || { echo "ERROR: pinned CA not found: ${CA_SRC} (run scripts/deploy/gen-ca.sh)" >&2; exit 1; }
fi

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon not running" >&2; exit 1; }

mkdir -p "$(dirname "${OUT}")"

echo "[ipxe] variant : ${VARIANT}"
echo "[ipxe] image   : ${IMAGE} (linux/amd64)"
echo "[ipxe] ipxe ref: ${IPXE_REF}"
echo "[ipxe] embed   : ${EMBED_SRC}"
[ "${WITH_CA}" = "1" ] && echo "[ipxe] CA      : ${CA_SRC} (CERT= + TRUST=, cert compiled in)"
echo "[ipxe] output  : ${OUT}"

# Stage the inputs the container reads from /in (read-only). We copy them into a
# temp dir so the container mount is a small, explicit input set (not the whole
# repo) and the embed/CA names are stable inside the container.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/partyos-ipxe.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
cp "${EMBED_SRC}" "${STAGE}/embed.ipxe"
if [ "${WITH_CA}" = "1" ]; then
    cp "${CA_SRC}" "${STAGE}/ca.crt"
fi

# The in-container build. Clones iPXE at the pinned ref, asserts DOWNLOAD_PROTO_HTTPS
# is on for the efi platform (patching general.h only if a future iPXE turned it
# off), builds bin-x86_64-efi/ipxe.efi with the embed (+ CERT/TRUST for https),
# and copies the result to /out/ipxe.efi.
docker run --rm --platform linux/amd64 \
    -e VARIANT="${VARIANT}" \
    -e WITH_CA="${WITH_CA}" \
    -e IPXE_REF="${IPXE_REF}" \
    -e IPXE_REPO="${IPXE_REPO}" \
    -v "${STAGE}:/in:ro" \
    -v "${STAGE}:/out" \
    "${IMAGE}" \
    /bin/bash -euo pipefail -c '
        set -x
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # libc6-dev is REQUIRED: gcc with --no-install-recommends does NOT pull it,
        # so the host has no system <stdint.h>/<bits/stdint.h>. iPXE then builds its
        # HOST tool util/elf2efi64 with -idirafter include, falls through to iPXEs
        # own include/stdint.h, and fails on `#include <bits/stdint.h>` (an iPXE arch
        # path not on the host-tool include path): "bits/stdint.h: No such file".
        apt-get install -y -qq --no-install-recommends \
            git make gcc binutils libc6-dev perl liblzma-dev mtools genisoimage ca-certificates >/dev/null
        set +x

        cd /tmp
        mkdir ipxe
        cd ipxe
        git init -q
        git remote add origin "${IPXE_REPO}"
        # Fetch exactly the pinned ref shallowly. GitHub allows fetch-by-sha
        # (uploadpack.allowReachableSHA1InWant), and this also accepts a tag/branch
        # name in IPXE_REF; either way we check out FETCH_HEAD. If fetch-by-sha is
        # refused by some mirror, fall back to a full clone + checkout.
        if git fetch --quiet --depth 1 origin "${IPXE_REF}"; then
            git checkout --quiet FETCH_HEAD
        else
            echo "[ipxe/container] shallow fetch-by-ref failed; full clone fallback"
            cd /tmp && rm -rf ipxe && git clone --quiet "${IPXE_REPO}" ipxe && cd ipxe
            git checkout --quiet "${IPXE_REF}"
        fi
        echo "[ipxe/container] checked out $(git rev-parse HEAD)"

        cd src

        # DOWNLOAD_PROTO_HTTPS is default-on for the bin-x86_64-efi platform. Assert
        # the default header carries it and only enable it explicitly if a future
        # iPXE shipped it off (do NOT silently rely on a default that changed).
        if grep -Rq "define[[:space:]]\+DOWNLOAD_PROTO_HTTPS" config/ 2>/dev/null; then
            echo "[ipxe/container] DOWNLOAD_PROTO_HTTPS present in default config"
        else
            echo "[ipxe/container] DOWNLOAD_PROTO_HTTPS NOT default - enabling in config/local/general.h"
            echo "#define DOWNLOAD_PROTO_HTTPS" >> config/local/general.h
        fi

        EMBED_ARG="EMBED=/in/embed.ipxe"
        CA_ARGS=""
        if [ "${WITH_CA}" = "1" ]; then
            # BOTH CERT= and TRUST= the same CA: TRUST= alone embeds only the CA
            # fingerprint; CERT= compiles the cert itself in so a private-CA-only
            # chain validates (else 0216eb8f "no usable certificates").
            CA_ARGS="CERT=/in/ca.crt TRUST=/in/ca.crt"
        fi

        echo "[ipxe/container] building bin-x86_64-efi/ipxe.efi ${EMBED_ARG} ${CA_ARGS}"
        make -j"$(nproc)" -C . bin-x86_64-efi/ipxe.efi ${EMBED_ARG} ${CA_ARGS}

        cp bin-x86_64-efi/ipxe.efi /out/ipxe.efi
        echo "[ipxe/container] produced ipxe.efi $(stat -c %s /out/ipxe.efi) bytes"
    '

BUILT="${STAGE}/ipxe.efi"
[ -f "${BUILT}" ] || { echo "ERROR: container produced no ipxe.efi" >&2; exit 1; }

# --- self-verification (fail closed) -----------------------------------------
# 1) valid PE/EFI binary (DOS 'MZ' magic + a PE header). 2) for https: the FULL
# current CA DER is embedded (PEM->DER, then byte-grep the binary - the same proof
# the first HTTPS build used that CERT= embedded the cert, and it catches a rotated
# CA that forgot to rebuild). 3) for https: HTTPS is compiled in.
echo "[ipxe] self-verifying ${BUILT}"

verify_fail() { echo "ERROR: self-verify FAIL - $*" >&2; exit 1; }

# 1) PE/EFI magic.
MAGIC="$(dd if="${BUILT}" bs=1 count=2 2>/dev/null | od -An -c | tr -d ' \n')"
if [ "${MAGIC}" != "MZ" ]; then
    verify_fail "${BUILT} is not a PE/EFI image (no 'MZ' magic; got '${MAGIC}')"
fi
if command -v file >/dev/null 2>&1; then
    if file "${BUILT}" | grep -qiE 'PE32\+|EFI application'; then
        echo "[ipxe] OK  - valid PE32+/EFI binary"
    else
        verify_fail "file(1) does not report a PE32+/EFI binary for ${BUILT}"
    fi
else
    echo "[ipxe] OK  - 'MZ' PE magic present (file(1) unavailable for the PE32+ check)"
fi

if [ "${WITH_CA}" = "1" ]; then
    # 2) the FULL current CA DER must be embedded in the binary.
    CA_DER="${STAGE}/ca.der"
    openssl x509 -in "${CA_SRC}" -outform DER -out "${CA_DER}" 2>/dev/null \
        || verify_fail "could not convert CA to DER for the embed check"
    # grep -F the raw DER bytes inside the binary.
    if grep -aqF -f <(cat "${CA_DER}") "${BUILT}" 2>/dev/null; then
        echo "[ipxe] OK  - current ca/partyos-ca.crt (DER) is embedded in the binary"
    else
        # grep -f with binary patterns can be flaky across platforms; fall back to
        # an explicit byte-substring scan in python so the check is robust.
        if python3 - "${BUILT}" "${CA_DER}" <<'PY'
import sys
hay = open(sys.argv[1], "rb").read()
needle = open(sys.argv[2], "rb").read()
sys.exit(0 if needle in hay else 1)
PY
        then
            echo "[ipxe] OK  - current ca/partyos-ca.crt (DER) is embedded in the binary"
        else
            verify_fail "the current CA DER is NOT embedded in ${BUILT} (CERT= missing? CA rotated without a rebuild?)"
        fi
    fi

    # 3) HTTPS compiled in. The iPXE EFI carries protocol/feature tags in its
    # strings table; the standalone 'HTTPS' token appears when DOWNLOAD_PROTO_HTTPS
    # is built in. Scan the WHOLE binary (-a) - on some platforms strings only walks
    # the loadable sections by default and misses the section the feature tags live
    # in - and accept the token bounded by non-letters (so plain 'HTTP' alone never
    # satisfies it). Fall back to a raw byte scan if strings is unavailable.
    if { strings -a "${BUILT}" 2>/dev/null || strings "${BUILT}" 2>/dev/null; } \
            | grep -qE '(^|[^A-Za-z])HTTPS([^A-Za-z]|$)'; then
        echo "[ipxe] OK  - HTTPS is compiled into the binary"
    elif grep -aoE 'HTTPS' "${BUILT}" 2>/dev/null | grep -q .; then
        echo "[ipxe] OK  - HTTPS is compiled into the binary (raw byte scan)"
    else
        verify_fail "no HTTPS feature string found in ${BUILT} (DOWNLOAD_PROTO_HTTPS not built in?)"
    fi
fi

# --- atomic install to OUT ---------------------------------------------------
TMP="${OUT}.tmp.$$"
cp "${BUILT}" "${TMP}"
mv -f "${TMP}" "${OUT}"

SHA="$( { shasum -a 256 "${OUT}" 2>/dev/null || sha256sum "${OUT}"; } | awk '{print $1}' )"
echo "[ipxe] installed -> ${OUT}"
echo "[ipxe] sha256    : ${SHA}"
echo "[ipxe] self-verify PASSED (variant=${VARIANT}, ipxe ref=${IPXE_REF})"
echo "[ipxe] done."
