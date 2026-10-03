#!/usr/bin/env bash
# test-server-name.sh - hardware-free test of the server-name knob.
#
# The knob is `setup.sh --server-name=NAME` (or `make server-name SERVER_NAME=NAME`).
# This test runs setup.sh into temp dirs and asserts that the one value reaches:
#   1. deploy.conf (PXE_SERVER, BLOB, MIRROR, IRC),
#   2. the iPXE embed (the chain URL that is baked into the EFI),
#   3. the SAN of the server leaf cert,
#   4. the rendered boot/partyos.ipxe (kernel, initrd, sfs, report URLs),
#   5. the EFI guard (check-ipxe-efi.sh), which also catches a stale name.
# It also asserts that a re-run without the flag keeps the name from deploy.conf,
# and that a name change reuses the CA.
#
# The EFI build is stubbed: the stub writes a fake EFI that holds the embed and the
# CA DER, the same bytes that the real build-ipxe.sh puts in. No docker, no network.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

SETUP="${REPO_ROOT}/scripts/deploy/setup.sh"
CHECK="${REPO_ROOT}/scripts/deploy/check-ipxe-efi.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-srvname.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

# Stub EFI builder: "MZ" + the embed script + the CA in DER form.
cat > "${T}/stub-build-ipxe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{ printf 'MZ'; cat "${EMBED}"; openssl x509 -in "${CA}" -outform DER; } > "${OUT}"
EOF

run_setup() {
    CONF_OUT="${T}/deploy.conf" EMBED_OUT="${T}/embed.ipxe" EFI_OUT="${T}/ipxe.efi" \
    PARTYOS_CA_DIR="${T}/ca" PARTYOS_TLS_DIR="${T}/tls" \
    BOOT_IPXE_OUT="${T}/partyos.ipxe" PORTAL_OUT="${T}/index.html" \
    BUILD_IPXE="${T}/stub-build-ipxe.sh" \
        bash "${SETUP}" --non-interactive --skip-build --skip-prereq "$@" > "${T}/setup.log" 2>&1
}

san_of() { openssl x509 -in "${T}/tls/partyos.crt" -noout -ext subjectAltName 2>/dev/null | tail -1; }
ca_fp()  { openssl x509 -in "${T}/ca/partyos-ca.crt" -noout -fingerprint -sha256; }

echo "== 1. --server-name=party.example flows everywhere =="
run_setup --server-name=party.example
rc=$?
assert_true "${rc}" "setup.sh --server-name runs (log: ${T}/setup.log)"
[ "${rc}" -eq 0 ] || cat "${T}/setup.log"
conf="$(cat "${T}/deploy.conf" 2>/dev/null)"
assert_contains "${conf}" "PXE_SERVER=party.example:8080" "deploy.conf PXE_SERVER has the name"
assert_contains "${conf}" "BLOB_SERVERS=party.example:8080" "deploy.conf BLOB_SERVERS follows the name"
assert_contains "${conf}" "MIRROR_SERVER=party.example:8080" "deploy.conf MIRROR_SERVER follows the name"
assert_contains "${conf}" "IRC_SERVER=party.example:6667" "deploy.conf IRC_SERVER follows the name"
assert_contains "${conf}" "PARTY_NAME=Internyet" "a fresh deploy.conf gets the default party name as a KEY"
assert_contains "${conf}" "BOOT_CONFIG_URL=party.example:8080/server/boot-config.sh" "the operator hook is ON by default, pointed at this server"
assert_not_contains "${conf}" "PARTY_NAME={{" "the party-name placeholder is substituted"
assert_contains "$(cat "${T}/embed.ipxe" 2>/dev/null)" "chain https://party.example:8443/boot/partyos.ipxe" "embed chains to the name"
assert_contains "$(san_of)" "DNS:party.example" "leaf cert SAN has the name"
boot="$(cat "${T}/partyos.ipxe" 2>/dev/null)"
assert_contains "${boot}" "kernel https://party.example:8443/server/images/vmlinuz-linux" "rendered kernel URL uses the name"
assert_contains "${boot}" "archiso_http_srv=https://party.example:8443/" "rendered sfs URL uses the name"
assert_contains "${boot}" "report_url=https://party.example:8443" "rendered report_url uses the name"
assert_contains "${boot}" "config_url=https://party.example:8443/server/boot-config.sh" "the default-on operator hook reaches the client as config_url="
assert_contains "$(tr -d '\\000' < "${T}/ipxe.efi" 2>/dev/null)" "https://party.example:8443" "the (stub) EFI carries the name"
bash "${CHECK}" "${T}/ipxe.efi" "${T}/ca/partyos-ca.crt" "${T}/deploy.conf" >/dev/null 2>&1
assert_true $? "check-ipxe-efi passes for a matching EFI"
FP1="$(ca_fp)"

echo "== 2. re-run with no flag keeps the name from deploy.conf =="
run_setup
assert_true $? "setup.sh re-run without --server-name runs"
assert_contains "$(cat "${T}/deploy.conf")" "PXE_SERVER=party.example:8080" "name kept from deploy.conf"
assert_contains "$(cat "${T}/embed.ipxe")" "chain https://party.example:8443/" "embed keeps the name"

echo "== 3. SERVER_NAME env switches to an IP, same CA =="
SERVER_NAME=10.9.8.7 run_setup
assert_true $? "SERVER_NAME=10.9.8.7 setup.sh runs"
assert_contains "$(cat "${T}/deploy.conf")" "PXE_SERVER=10.9.8.7:8080" "deploy.conf has the IP"
assert_contains "$(cat "${T}/embed.ipxe")" "chain https://10.9.8.7:8443/boot/partyos.ipxe" "embed chains to the IP"
assert_contains "$(san_of)" "IP Address:10.9.8.7" "leaf cert SAN has the IP"
assert_not_contains "$(san_of)" "party.example" "old name is gone from the SAN"
assert_eq "$(ca_fp)" "${FP1}" "the CA is reused (not rotated) on a name change"

echo "== 4. guard catches an EFI with a stale name =="
sed -e 's/^PXE_SERVER=.*/PXE_SERVER=other.example:8080/' "${T}/deploy.conf" > "${T}/stale.conf"
out="$(bash "${CHECK}" "${T}/ipxe.efi" "${T}/ca/partyos-ca.crt" "${T}/stale.conf" 2>&1)"
assert_false $? "check-ipxe-efi fails when deploy.conf names another server"
assert_contains "${out}" "the EFI has: chain https://10.9.8.7:8443" "failure names the baked chain URL"

echo "== 5. --party-name writes the PARTY_NAME key, not only a comment =="
# announce.sh reads ^PARTY_NAME=, so the flag has to reach the KEY. A run without the
# flag must leave the name alone (the merge preserves operator edits).
run_setup --party-name="Internyet 2027"
assert_true $? "setup.sh --party-name runs"
assert_contains "$(cat "${T}/deploy.conf")" "PARTY_NAME=Internyet 2027" "the flag writes the PARTY_NAME key"
assert_contains "$(cat "${T}/deploy.conf")" "# Party: Internyet 2027" "the flag also updates the header comment"
assert_eq "$(grep -c '^PARTY_NAME=' "${T}/deploy.conf")" "1" "exactly one PARTY_NAME key"
run_setup
assert_true $? "a re-run without --party-name runs"
assert_contains "$(cat "${T}/deploy.conf")" "PARTY_NAME=Internyet 2027" "the re-run preserves the party name"

echo "== 6. a party name with a | is rejected =="
run_setup --party-name="bad|name"
assert_false $? "a party name containing | fails"
assert_contains "$(cat "${T}/setup.log")" "invalid party name" "the failure says why"
assert_contains "$(cat "${T}/deploy.conf")" "PARTY_NAME=Internyet 2027" "the rejected name never reached deploy.conf"

echo "== 7. the operator boot-config hook follows the server, and an operator edit wins =="
# It tracks the PXE box with the stock path, so a name change moves it with the server.
run_setup --server-name=moved.example
assert_true $? "the move run succeeds"
assert_contains "$(cat "${T}/deploy.conf")" "BOOT_CONFIG_URL=moved.example:8080/server/boot-config.sh" "the hook follows the new server name"
# An operator who empties the key has switched the hook off. A re-run must not undo that.
sed -e 's|^BOOT_CONFIG_URL=.*|BOOT_CONFIG_URL=|' "${T}/deploy.conf" > "${T}/off.conf"
cat "${T}/off.conf" > "${T}/deploy.conf"
run_setup --server-name=other.example
assert_true $? "the re-run with the hook off succeeds"
assert_eq "$(grep '^BOOT_CONFIG_URL=' "${T}/deploy.conf")" "BOOT_CONFIG_URL=" "an emptied hook stays off across a re-run"
assert_not_contains "$(cat "${T}/partyos.ipxe")" "config_url=" "no config_url= is emitted when the hook is off"
# A hand-pointed URL on another host is an operator edit and survives too.
sed -e 's|^BOOT_CONFIG_URL=.*|BOOT_CONFIG_URL=ops.example:8080/hook.sh|' "${T}/deploy.conf" > "${T}/hand.conf"
cat "${T}/hand.conf" > "${T}/deploy.conf"
run_setup --server-name=third.example
assert_true $? "the re-run with a hand-pointed hook succeeds"
assert_eq "$(grep '^BOOT_CONFIG_URL=' "${T}/deploy.conf")" "BOOT_CONFIG_URL=ops.example:8080/hook.sh" "a hand-pointed hook is preserved"

echo "== 8. the CA is recorded once and survives every name change =="
# The server name changes many times above and the CA is reused throughout. The
# recorded CA_FINGERPRINT must track the CA on disk, never drift from it, and the
# EFI guard must keep passing. A drift here would make the guard fail on a rename.
CONF_FP="$(grep -E '^CA_FINGERPRINT=' "${T}/deploy.conf" | tail -1 | cut -d= -f2-)"
DISK_FP="$(ca_fp | sed 's/^.*=//')"
assert_eq "${CONF_FP}" "${DISK_FP}" "deploy.conf CA_FINGERPRINT matches the CA on disk"
assert_eq "${DISK_FP}" "$(echo "${FP1}" | sed 's/^.*=//')" "the CA was never re-minted across the renames"
assert_eq "$(grep -cE '^CA_FINGERPRINT=' "${T}/deploy.conf")" "1" "only ONE CA_FINGERPRINT line, no duplicates"
bash "${CHECK}" "${T}/ipxe.efi" "${T}/ca/partyos-ca.crt" "${T}/deploy.conf" > "${T}/chk8.log" 2>&1
assert_true $? "check-ipxe-efi still passes with the recorded fingerprint in place"
assert_contains "$(cat "${T}/chk8.log")" "matches CA_FINGERPRINT" "the guard checked the record, not just the EFI"

echo "== 9. an external (venue) CA: setup.sh builds the EFI against it, no gen-ca =="
# install-certs.sh writes ca/EXTERNAL-CA and gen-ca.sh then refuses. setup.sh must
# still render the embed and build the EFI against the installed CA, so a venue CA
# has a supported path to a production EFI.
V="${T}/venue"; mkdir -p "${V}"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 -subj "/CN=venue CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "${V}/ca.key" -out "${V}/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -sha256 -subj "/CN=venue.example" \
    -keyout "${V}/leaf.key" -out "${V}/leaf.csr" >/dev/null 2>&1
printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:venue.example\n' > "${V}/leaf.ext"
openssl x509 -req -in "${V}/leaf.csr" -CA "${V}/ca.crt" -CAkey "${V}/ca.key" -CAcreateserial \
    -sha256 -days 365 -extfile "${V}/leaf.ext" -out "${V}/leaf.crt" >/dev/null 2>&1
CA_DIR_OVERRIDE="${T}/ca" TLS_DIR_OVERRIDE="${T}/tls" \
    bash "${REPO_ROOT}/scripts/deploy/install-certs.sh" --conf "${T}/deploy.conf" --force \
    --ca "${V}/ca.crt" --cert "${V}/leaf.crt" --key "${V}/leaf.key" > "${T}/install.log" 2>&1
assert_true $? "install-certs installs the venue CA into the temp dirs"
run_setup --server-name=venue.example
rc=$?
assert_true "${rc}" "setup.sh runs with an external CA installed (log: ${T}/setup.log)"
[ "${rc}" -eq 0 ] || cat "${T}/setup.log"
assert_contains "$(cat "${T}/setup.log")" "gen-ca skipped" "setup.sh skips gen-ca for an external CA"
assert_eq "$(ca_fp)" "$(openssl x509 -in "${V}/ca.crt" -noout -fingerprint -sha256)" "the venue CA is still the CA on disk"
assert_contains "$(cat "${T}/embed.ipxe")" "chain https://venue.example:8443/boot/partyos.ipxe" "the embed chains to the venue name"
bash "${CHECK}" "${T}/ipxe.efi" "${T}/ca/partyos-ca.crt" "${T}/deploy.conf" > "${T}/chk9.log" 2>&1
assert_true $? "check-ipxe-efi passes: the EFI pins the venue CA and chains to the venue name"
run_setup --server-name=notcovered.example
assert_false $? "setup.sh refuses a server name that the venue leaf does not cover"

assert_summary
