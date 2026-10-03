#!/usr/bin/env bash
# test-install-certs.sh - hardware-free test of the bring-your-own-certificate path
# (scripts/deploy/install-certs.sh) and of the gen-ca.sh guard that protects it.
#
# It builds a throwaway "venue" CA in a temp dir, signs leaves with it, and drives
# install-certs.sh into temp ca/ + server/tls/ dirs (CA_DIR_OVERRIDE /
# TLS_DIR_OVERRIDE). The real repo ca/ and server/tls/ are never touched.
#
# Asserts:
#   1. a good CA + leaf + key installs, and lands in the paths the rest of the tree
#      reads (ca/partyos-ca.crt, server/tls/partyos.{crt,key}).
#   2. the self-minted CA key is moved aside and the EXTERNAL-CA marker is written.
#   3. gen-ca.sh REFUSES while the marker is there (no leaf against a wrong anchor).
#   4. --restore-lab puts the self-minted CA back and gen-ca.sh works again.
#   5. a key that does not match the cert is REFUSED.
#   6. a leaf that does not chain to the given CA is REFUSED.
#   7. a SAN that misses the deploy.conf server address is REFUSED, and --force
#      installs it anyway.
#   7b. an IP: SAN entry covers a bare-IP server address.
#   8. a wildcard SAN covers one label of the host.
#   9. a chain that expires BEFORE --event-date installs with a loud warning.
#  10. --dry-run writes nothing.
#
# No network, no hardware. Pure shell + openssl.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

INSTALL="${REPO_ROOT}/scripts/deploy/install-certs.sh"
GENCA="${REPO_ROOT}/scripts/deploy/gen-ca.sh"
[ -f "${INSTALL}" ] || { echo "FAIL: install-certs.sh not found at ${INSTALL}"; exit 1; }
[ -f "${GENCA}" ]   || { echo "FAIL: gen-ca.sh not found at ${GENCA}"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-byoc.XXXXXX")"
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/ca" "${T}/tls" "${T}/venue"
V="${T}/venue"

HOST="partyos.c.example"
CONF="${T}/deploy.conf"
cat > "${CONF}" <<EOF
PXE_SERVER=${HOST}:8080
BLOB_SERVERS=${HOST}:8080
BLOB_SERVER=${HOST}:8080
MIRROR_SERVER=${HOST}:8080
IRC_SERVER=chat.c.example:6667
BOOT_CONFIG_URL=${HOST}:8080/server/boot-config.sh
EOF

# ---- a throwaway venue CA + a signer helper ---------------------------------
# mkca NAME -> <V>/NAME.crt + <V>/NAME.key, a self-signed CA.
mkca() {
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 \
        -subj "/CN=$1 CA/O=venue" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "${V}/$1.key" -out "${V}/$1.crt" >/dev/null 2>&1
}
# mkleaf NAME CA SAN [DAYS] -> <V>/NAME.crt + <V>/NAME.key, signed by CA.
mkleaf() {
    local name="$1" ca="$2" san="$3" days="${4:-365}"
    openssl req -newkey rsa:2048 -nodes -sha256 -subj "/CN=${name}/O=venue" \
        -keyout "${V}/${name}.key" -out "${V}/${name}.csr" >/dev/null 2>&1
    printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' \
        "${san}" > "${V}/${name}.ext"
    openssl x509 -req -in "${V}/${name}.csr" -CA "${V}/${ca}.crt" -CAkey "${V}/${ca}.key" \
        -CAcreateserial -sha256 -days "${days}" -extfile "${V}/${name}.ext" \
        -out "${V}/${name}.crt" >/dev/null 2>&1
}

mkca venue
mkca other
mkleaf good  venue "DNS:${HOST},DNS:*.${HOST},IP:10.13.36.5"
mkleaf wrongsan venue "DNS:somewhere.else"
mkleaf wildcard venue "DNS:*.c.example"
mkleaf foreign other "DNS:${HOST}"

# run_install ... -> runs install-certs.sh against the temp dirs; output in $OUT.
run_install() {
    OUT="$(CA_DIR_OVERRIDE="${T}/ca" TLS_DIR_OVERRIDE="${T}/tls" \
        bash "${INSTALL}" --conf "${CONF}" "$@" 2>&1)"
    RC=$?
    return ${RC}
}
run_genca() {
    CA_DIR_OVERRIDE="${T}/ca" TLS_DIR_OVERRIDE="${T}/tls" \
        bash "${GENCA}" "${HOST}" >"${T}/genca.log" 2>&1
}

# A pretend self-minted CA already sitting in the temp ca/, so the install has something
# to move aside and --restore-lab has something to restore.
seed_lab() {
    rm -rf "${T}/ca" "${T}/tls"; mkdir -p "${T}/ca" "${T}/tls"
    run_genca
}

# ============================================================================
echo "================ 1. good CA + leaf installs ================="
seed_lab
LAB_FP="$(openssl x509 -in "${T}/ca/partyos-ca.crt" -noout -fingerprint -sha256)"
run_install --ca "${V}/venue.crt" --cert "${V}/good.crt" --key "${V}/good.key"
assert_true "$?" "install-certs accepts a good CA + leaf + key"
assert_contains "${OUT}" "SAN covers ${HOST}" "it reports the SAN covers the deploy.conf server"
assert_eq "$(openssl x509 -in "${T}/ca/partyos-ca.crt" -noout -subject)" \
          "$(openssl x509 -in "${V}/venue.crt" -noout -subject)" \
          "ca/partyos-ca.crt is now the venue CA"
assert_eq "$(openssl x509 -in "${T}/tls/partyos.crt" -noout -subject)" \
          "$(openssl x509 -in "${V}/good.crt" -noout -subject)" \
          "server/tls/partyos.crt is now the venue leaf"
assert_true "$(cmp -s "${T}/tls/partyos.key" "${V}/good.key"; echo $?)" \
          "server/tls/partyos.key is the venue leaf key"
assert_contains "${OUT}" "fingerprint" "it prints the CA fingerprint to pin"

echo
echo "================ 2. the self-minted signer is disarmed =============="
assert_true "$([ -f "${T}/ca/EXTERNAL-CA" ]; echo $?)" "the EXTERNAL-CA marker is written"
assert_false "$([ -f "${T}/ca/partyos-ca.key" ]; echo $?)" "the self-minted CA key is gone from its live path"
assert_true "$([ -f "${T}/ca/partyos-ca.key.lab-backup" ]; echo $?)" "the self-minted CA key is kept as .lab-backup"
assert_contains "$(cat "${T}/ca/EXTERNAL-CA")" "ca_sha256=" "the marker records the CA fingerprint"

echo
echo "================ 3. gen-ca.sh refuses while external ========"
run_genca
assert_false "$?" "gen-ca.sh REFUSES to sign against a CA we do not hold"
assert_contains "$(cat "${T}/genca.log")" "external CA is installed" "gen-ca.sh says why it refused"

echo
echo "================ 4. --restore-lab undoes it ================="
run_install --restore-lab
assert_true "$?" "--restore-lab runs"
assert_false "$([ -f "${T}/ca/EXTERNAL-CA" ]; echo $?)" "the marker is removed"
assert_eq "$(openssl x509 -in "${T}/ca/partyos-ca.crt" -noout -fingerprint -sha256)" "${LAB_FP}" \
          "the self-minted CA cert is back"
run_genca
assert_true "$?" "gen-ca.sh works again after --restore-lab"

echo
echo "================ 5. mismatched key is refused ==============="
seed_lab
run_install --ca "${V}/venue.crt" --cert "${V}/good.crt" --key "${V}/wildcard.key"
assert_false "$?" "a key that does not belong to the cert is REFUSED"
assert_contains "${OUT}" "does not belong" "it names the mismatch"
assert_false "$([ -f "${T}/ca/EXTERNAL-CA" ]; echo $?)" "nothing was installed on a refusal"

echo
echo "================ 6. wrong CA is refused ====================="
run_install --ca "${V}/venue.crt" --cert "${V}/foreign.crt" --key "${V}/foreign.key"
assert_false "$?" "a leaf signed by a DIFFERENT CA is REFUSED"
assert_contains "${OUT}" "does not chain" "it says the chain does not verify"

echo
echo "================ 7. SAN must cover the server address ======="
run_install --ca "${V}/venue.crt" --cert "${V}/wrongsan.crt" --key "${V}/wrongsan.key"
assert_false "$?" "a leaf whose SAN misses PXE_SERVER is REFUSED"
assert_contains "${OUT}" "SAN does NOT cover ${HOST}" "it names the address the SAN misses"
run_install --force --ca "${V}/venue.crt" --cert "${V}/wrongsan.crt" --key "${V}/wrongsan.key"
assert_true "$?" "--force installs a SAN-mismatched leaf anyway"
assert_contains "${OUT}" "WARNING" "--force still warns loudly"

echo
echo "================ 7b. an IP SAN covers a bare-IP address ====="
CONF_IP="${T}/deploy.ip.conf"
sed "s|${HOST}|10.13.36.5|g" "${CONF}" > "${CONF_IP}"
seed_lab
OUT="$(CA_DIR_OVERRIDE="${T}/ca" TLS_DIR_OVERRIDE="${T}/tls" \
    bash "${INSTALL}" --conf "${CONF_IP}" \
    --ca "${V}/venue.crt" --cert "${V}/good.crt" --key "${V}/good.key" 2>&1)"
assert_true "$?" "a leaf with IP:10.13.36.5 in its SAN covers a bare-IP PXE_SERVER"
assert_contains "${OUT}" "SAN covers 10.13.36.5" "the IP SAN match is reported"

echo
echo "================ 8. a wildcard SAN covers one label ========="
seed_lab
run_install --ca "${V}/venue.crt" --cert "${V}/wildcard.crt" --key "${V}/wildcard.key"
assert_true "$?" "DNS:*.c.example covers ${HOST}"
assert_contains "${OUT}" "SAN covers ${HOST}" "the wildcard match is reported"

echo
echo "================ 9. expiry before the event warns ==========="
# A leaf valid for one more day, checked against an event 30 days out. The chain is
# good today, so it installs - but the operator must be told it dies mid-party.
mkleaf shortlived venue "DNS:${HOST}" 1
seed_lab
run_install --ca "${V}/venue.crt" --cert "${V}/shortlived.crt" --key "${V}/shortlived.key" \
    --event-date "$(date -v+30d '+%Y-%m-%d' 2>/dev/null || date -d '+30 days' '+%Y-%m-%d')"
assert_true "$?" "a chain that is still valid today installs"
assert_contains "${OUT}" "BEFORE the event date" "a cert expiring before the event warns loudly"

echo
echo "================ 10. --dry-run writes nothing ==============="
seed_lab
BEFORE="$(openssl x509 -in "${T}/ca/partyos-ca.crt" -noout -fingerprint -sha256)"
run_install --dry-run --ca "${V}/venue.crt" --cert "${V}/good.crt" --key "${V}/good.key"
assert_true "$?" "--dry-run runs the checks"
assert_contains "${OUT}" "nothing was written" "--dry-run says it wrote nothing"
assert_eq "$(openssl x509 -in "${T}/ca/partyos-ca.crt" -noout -fingerprint -sha256)" "${BEFORE}" \
          "--dry-run left ca/partyos-ca.crt untouched"
assert_false "$([ -f "${T}/ca/EXTERNAL-CA" ]; echo $?)" "--dry-run wrote no marker"

assert_summary "test-install-certs" || exit 1
echo "test-install-certs: ALL PASS"
