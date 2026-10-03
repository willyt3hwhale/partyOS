#!/usr/bin/env bash
# test-ca-guard.sh - hardware-free test of the CA overwrite guards.
#
# gen-ca.sh must never mint a new CA over a certificate that has no key.
#
# What this asserts:
#   1. a certificate without its key REFUSES, and the certificate is byte-identical
#      afterwards,
#   2. a key that does not match the certificate REFUSES with a clear message,
#   3. a correct pair is REUSED - the CA is not re-minted,
#   4. --force rotates on purpose,
#   5. the recorded CA_FINGERPRINT catches an EFI built against a different CA,
#   6. setup.sh --fresh removes the EXTERNAL-CA marker,
#   7. the real-world scenario end to end: drop a foreign CA certificate in with no
#      key, run the wizard non-interactively, and assert it REFUSES and leaves the
#      foreign certificate untouched.
#
# Temp dirs only. No docker, no network, no hardware. The EFI build is stubbed the
# same way test-server-name.sh stubs it.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

GENCA="${REPO_ROOT}/scripts/deploy/gen-ca.sh"
SETUP="${REPO_ROOT}/scripts/deploy/setup.sh"
CHECK="${REPO_ROOT}/scripts/deploy/check-ipxe-efi.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-caguard.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

# Stub EFI builder: "MZ" + the embed script + the CA in DER form, the same bytes
# the real build-ipxe.sh embeds.
cat > "${T}/stub-build-ipxe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{ printf 'MZ'; cat "${EMBED}"; openssl x509 -in "${CA}" -outform DER; } > "${OUT}"
EOF

fp_of()  { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'; }
sum_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# mint_ca DIR NAME - a self-signed CA + key in DIR, subject CN=NAME.
mint_ca() {
    local dir="$1" cn="$2"
    mkdir -p "${dir}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
        -subj "/CN=${cn}/O=partyOS" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "${dir}/partyos-ca.key" -out "${dir}/partyos-ca.crt" 2>/dev/null
    chmod 600 "${dir}/partyos-ca.key"
}

# run_genca DIR ARGS... - gen-ca into DIR/ca + DIR/tls, log to DIR/genca.log.
run_genca() {
    local dir="$1"; shift
    CA_DIR_OVERRIDE="${dir}/ca" TLS_DIR_OVERRIDE="${dir}/tls" CA_FP_CONF="" \
        bash "${GENCA}" "$@" > "${dir}/genca.log" 2>&1
}

echo "== 1. a certificate WITHOUT its key refuses and leaves the cert untouched =="
C1="${T}/c1"; mkdir -p "${C1}/ca" "${C1}/tls"
mint_ca "${T}/foreign" "Venue Root CA"
cp "${T}/foreign/partyos-ca.crt" "${C1}/ca/partyos-ca.crt"
BEFORE_SUM="$(sum_of "${C1}/ca/partyos-ca.crt")"
BEFORE_FP="$(fp_of "${C1}/ca/partyos-ca.crt")"
run_genca "${C1}" 10.0.0.1
assert_false $? "gen-ca REFUSES when the cert is present and the key is not"
LOG1="$(cat "${C1}/genca.log")"
assert_contains "${LOG1}" "REFUSED" "the refusal is named as such"
assert_contains "${LOG1}" "private key is NOT" "it names the situation"
assert_contains "${LOG1}" "--force" "it offers the deliberate rotation"
assert_contains "${LOG1}" "install-certs.sh" "it offers the externally signed CA path"
assert_eq "$(sum_of "${C1}/ca/partyos-ca.crt")" "${BEFORE_SUM}" \
    "the certificate is BYTE-IDENTICAL after the refusal"
assert_false "$([ -f "${C1}/ca/partyos-ca.key" ]; echo $?)" "no key was minted"
assert_false "$([ -f "${C1}/tls/partyos.crt" ]; echo $?)" "no leaf was written"

echo "== 2. a key that does not match the certificate refuses clearly =="
C2="${T}/c2"; mkdir -p "${C2}/ca" "${C2}/tls"
mint_ca "${T}/pairA" "partyOS Root CA"
mint_ca "${T}/pairB" "partyOS Root CA"
cp "${T}/pairA/partyos-ca.crt" "${C2}/ca/partyos-ca.crt"
cp "${T}/pairB/partyos-ca.key" "${C2}/ca/partyos-ca.key"
MISMATCH_SUM="$(sum_of "${C2}/ca/partyos-ca.crt")"
run_genca "${C2}" 10.0.0.1
assert_false $? "gen-ca REFUSES a mismatched key/cert pair"
LOG2="$(cat "${C2}/genca.log")"
assert_contains "${LOG2}" "does not match" "the mismatch is named, not a silent set -e abort"
assert_not_contains "${LOG2}" "Segmentation" "no crash"
assert_eq "$(sum_of "${C2}/ca/partyos-ca.crt")" "${MISMATCH_SUM}" \
    "the certificate is untouched after the mismatch refusal"

echo "== 3. a correct pair is REUSED, not re-minted =="
C3="${T}/c3"; mkdir -p "${C3}/tls"
cp -R "${T}/pairA" "${C3}/ca"
FP3="$(fp_of "${C3}/ca/partyos-ca.crt")"
KEYSUM3="$(sum_of "${C3}/ca/partyos-ca.key")"
run_genca "${C3}" 10.0.0.1
assert_true $? "gen-ca runs with a matching pair"
assert_contains "$(cat "${C3}/genca.log")" "reusing it" "it says it is reusing the CA"
assert_eq "$(fp_of "${C3}/ca/partyos-ca.crt")" "${FP3}" "the CA fingerprint is unchanged"
assert_eq "$(sum_of "${C3}/ca/partyos-ca.key")" "${KEYSUM3}" "the CA key is unchanged"
assert_true "$([ -s "${C3}/tls/partyos.crt" ]; echo $?)" "a fresh leaf WAS signed"

echo "== 4. --force rotates on purpose =="
run_genca "${C3}" --force 10.0.0.1
assert_true $? "gen-ca --force runs"
FP4="$(fp_of "${C3}/ca/partyos-ca.crt")"
assert_false "$([ "${FP4}" = "${FP3}" ]; echo $?)" "--force produced a DIFFERENT CA"
assert_contains "$(cat "${C3}/genca.log")" "ROTATING" "it announces the rotation"

echo "== 4b. --force also overrides the cert-without-key refusal =="
C4="${T}/c4"; mkdir -p "${C4}/ca" "${C4}/tls"
cp "${T}/foreign/partyos-ca.crt" "${C4}/ca/partyos-ca.crt"
run_genca "${C4}" --force 10.0.0.1
assert_true $? "--force mints over a keyless cert when the operator asks for it"
assert_contains "$(openssl x509 -in "${C4}/ca/partyos-ca.crt" -noout -subject)" "partyOS Root CA" \
    "the rotated CA replaced the foreign one"

echo "== 5. the recorded fingerprint catches an EFI built against a different CA =="
C5="${T}/c5"; mkdir -p "${C5}/tls"
cp -R "${T}/pairA" "${C5}/ca"
printf 'PXE_SERVER=10.0.0.1:8080\n' > "${C5}/deploy.conf"
CA_DIR_OVERRIDE="${C5}/ca" TLS_DIR_OVERRIDE="${C5}/tls" CA_FP_CONF="${C5}/deploy.conf" \
    bash "${GENCA}" 10.0.0.1 > "${C5}/genca.log" 2>&1
assert_true $? "gen-ca runs and records the fingerprint"
assert_contains "$(cat "${C5}/deploy.conf")" "CA_FINGERPRINT=$(fp_of "${C5}/ca/partyos-ca.crt")" \
    "deploy.conf records the CA fingerprint"
# Build the stub EFI against the RECORDED CA - the guard must pass.
EMBED="${C5}/embed.ipxe"
printf '#!ipxe\nchain https://10.0.0.1:8443/boot/partyos.ipxe\n' > "${EMBED}"
EMBED="${EMBED}" CA="${C5}/ca/partyos-ca.crt" OUT="${C5}/ipxe.efi" bash "${T}/stub-build-ipxe.sh"
bash "${CHECK}" "${C5}/ipxe.efi" "${C5}/ca/partyos-ca.crt" "${C5}/deploy.conf" > "${C5}/chk-ok.log" 2>&1
assert_true $? "the guard passes when the EFI and the record agree"
assert_contains "$(cat "${C5}/chk-ok.log")" "matches CA_FINGERPRINT" "it says the record matched"
# Now swap the CA on disk AND rebuild the EFI from it. The old embed check compared
# the EFI with whatever cert was on disk, so this passed trivially. The recorded
# fingerprint is the only thing that can catch it.
cp "${T}/pairB/partyos-ca.crt" "${C5}/ca/partyos-ca.crt"
cp "${T}/pairB/partyos-ca.key" "${C5}/ca/partyos-ca.key"
EMBED="${EMBED}" CA="${C5}/ca/partyos-ca.crt" OUT="${C5}/ipxe.efi" bash "${T}/stub-build-ipxe.sh"
bash "${CHECK}" "${C5}/ipxe.efi" "${C5}/ca/partyos-ca.crt" "${C5}/deploy.conf" > "${C5}/chk-bad.log" 2>&1
assert_false $? "the guard FAILS when the CA on disk is not the recorded one"
CHKBAD="$(cat "${C5}/chk-bad.log")"
assert_contains "${CHKBAD}" "the CA on disk is NOT the CA" "it names the swap"
assert_contains "${CHKBAD}" "$(fp_of "${T}/pairA/partyos-ca.crt")" "it prints the recorded fingerprint"
# gen-ca must refuse to build on a CA that is not the recorded one, too.
CA_DIR_OVERRIDE="${C5}/ca" TLS_DIR_OVERRIDE="${C5}/tls" CA_FP_CONF="${C5}/deploy.conf" \
    bash "${GENCA}" 10.0.0.1 > "${C5}/genca2.log" 2>&1
assert_false $? "gen-ca refuses when the CA on disk is not the recorded one"

echo "== 5b. no record = a warning, not a hard failure (older configs, first run) =="
printf 'PXE_SERVER=10.0.0.1:8080\n' > "${C5}/noconf.conf"
bash "${CHECK}" "${C5}/ipxe.efi" "${C5}/ca/partyos-ca.crt" "${C5}/noconf.conf" > "${C5}/chk-warn.log" 2>&1
assert_true $? "a config with no CA_FINGERPRINT still passes"
assert_contains "$(cat "${C5}/chk-warn.log")" "records no CA_FINGERPRINT" "but it warns explicitly"
printf 'PXE_SERVER=10.0.0.1:8080\nCA_FINGERPRINT=\n' > "${C5}/emptyfp.conf"
bash "${CHECK}" "${C5}/ipxe.efi" "${C5}/ca/partyos-ca.crt" "${C5}/emptyfp.conf" > "${C5}/chk-empty.log" 2>&1
assert_true $? "an EMPTY CA_FINGERPRINT also warns rather than failing"
assert_contains "$(cat "${C5}/chk-empty.log")" "records no CA_FINGERPRINT" "the empty value is treated as no record"

echo "== 6. setup.sh --fresh clears the EXTERNAL-CA marker =="
C6="${T}/c6"; mkdir -p "${C6}/ca" "${C6}/tls"
cp -R "${T}/pairA/." "${C6}/ca/"
printf '# an external CA\nca_sha256=%s\n' "$(fp_of "${C6}/ca/partyos-ca.crt")" > "${C6}/ca/EXTERNAL-CA"
CONF_OUT="${C6}/deploy.conf" EMBED_OUT="${C6}/embed.ipxe" EFI_OUT="${C6}/ipxe.efi" \
PARTYOS_CA_DIR="${C6}/ca" PARTYOS_TLS_DIR="${C6}/tls" \
BOOT_IPXE_OUT="${C6}/partyos.ipxe" PORTAL_OUT="${C6}/index.html" \
BUILD_IPXE="${T}/stub-build-ipxe.sh" \
    bash "${SETUP}" --non-interactive --fresh --skip-build --skip-prereq \
    --server-name=10.0.0.1 > "${C6}/setup.log" 2>&1
assert_true $? "setup.sh --fresh runs (log: ${C6}/setup.log)"
assert_false "$([ -f "${C6}/ca/EXTERNAL-CA" ]; echo $?)" "the EXTERNAL-CA marker is GONE after --fresh"
LOG6="$(cat "${C6}/setup.log")"
assert_contains "${LOG6}" "DESTROYING the current trust anchor" "the wipe names what it destroys"
assert_contains "${LOG6}" "EVERY USB stick flashed against this CA is invalidated" \
    "the wipe states that flashed sticks are invalidated"
assert_contains "${LOG6}" "EXTERNAL (venue) CA is installed" "it warns that a venue CA is discarded"
assert_true "$([ -s "${C6}/ca/partyos-ca.crt" ]; echo $?)" "a new CA was minted"
assert_true "$([ -s "${C6}/ca/partyos-ca.key" ]; echo $?)" "with its key"
assert_contains "$(cat "${C6}/deploy.conf")" "CA_FINGERPRINT=$(fp_of "${C6}/ca/partyos-ca.crt")" \
    "the fresh deploy.conf records the NEW CA fingerprint"

echo "== 7. THE REAL SCENARIO: foreign CA cert, no key, wizard run non-interactively =="
# An operator's venue CA certificate is in ca/ with no key (a clone, or a hand copy). The wizard must REFUSE, and the
# operator's certificate must survive byte-identical.
C7="${T}/c7"; mkdir -p "${C7}/ca" "${C7}/tls"
cp "${T}/foreign/partyos-ca.crt" "${C7}/ca/partyos-ca.crt"
VENUE_SUM="$(sum_of "${C7}/ca/partyos-ca.crt")"
VENUE_FP="$(fp_of "${C7}/ca/partyos-ca.crt")"
CONF_OUT="${C7}/deploy.conf" EMBED_OUT="${C7}/embed.ipxe" EFI_OUT="${C7}/ipxe.efi" \
PARTYOS_CA_DIR="${C7}/ca" PARTYOS_TLS_DIR="${C7}/tls" \
BOOT_IPXE_OUT="${C7}/partyos.ipxe" PORTAL_OUT="${C7}/index.html" \
BUILD_IPXE="${T}/stub-build-ipxe.sh" \
    bash "${SETUP}" --non-interactive --skip-build --skip-prereq \
    --server-name=10.0.0.1 > "${C7}/setup.log" 2>&1
assert_false $? "the wizard REFUSES rather than minting over the operator's CA"
LOG7="$(cat "${C7}/setup.log")"
assert_contains "${LOG7}" "REFUSED" "the wizard surfaces the refusal"
assert_eq "$(sum_of "${C7}/ca/partyos-ca.crt")" "${VENUE_SUM}" \
    "the operator's CA certificate is BYTE-IDENTICAL"
assert_eq "$(fp_of "${C7}/ca/partyos-ca.crt")" "${VENUE_FP}" \
    "its fingerprint is unchanged"
assert_contains "$(openssl x509 -in "${C7}/ca/partyos-ca.crt" -noout -subject)" "Venue Root CA" \
    "it is still the VENUE CA, not a fresh CN=partyOS Root CA"
assert_false "$([ -f "${C7}/ca/partyos-ca.key" ]; echo $?)" "no CA key was minted"
assert_false "$([ -s "${C7}/ipxe.efi" ]; echo $?)" "NO EFI was built against a wrong CA"

echo "== 8. ca/partyos-ca.crt is not tracked in git =="
if git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    assert_eq "$(git -C "${REPO_ROOT}" ls-files ca/partyos-ca.crt)" "" \
        "the CA certificate is NOT tracked, so no clone starts with a CA it cannot sign with"
else
    echo "  SKIP: not a git checkout"
fi

assert_summary "test-ca-guard"
