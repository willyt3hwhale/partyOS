#!/usr/bin/env bash
# test-internyet-identity.sh - hardware-FREE unit test for the internyet identity source.
#
# The per-player identity comes from `internyet.env` on the shared exFAT partition
# (/mnt/share). The legacy .partyos on the ext4 home partition is only a fallback. This test drives the REAL baked files:
#   usr/local/lib/partyos-internyet.sh   the env parser + FQDN hostname
#   usr/local/lib/partyos-sync-common.sh the USERNAME MOUNT GATE (home gate)
#   usr/local/bin/partyos-trust-setup    the CA / client-certificate import
#
# It asserts:
#   * every mapped key parses out of a REAL-SHAPED env file (quoted values kept intact)
#   * the mapping: USERNAME <- INTERNYET_USER_NAME, nick <- INTERNYET_ALIAS,
#     hostname <- the full INTERNYET_DEFAULT_FQDN, email <- INTERNYET_EMAIL
#   * the home gate reads the ENV file, so a player's own stick mounts and a
#     different player's stick is refused
#   * a MISSING env file falls back to the legacy .partyos USERNAME=
#   * a MALFORMED env file never executes a line and never yields a bad identity
#   * the p12 password is NEVER echoed by partyos-trust-setup
# No VM, no network, no hardware, no root - pure shell.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

RFS="${REPO_ROOT}/scripts/build/files/rootfs"
LIB="${RFS}/usr/local/lib/partyos-internyet.sh"
COMMON="${RFS}/usr/local/lib/partyos-sync-common.sh"
TRUST="${RFS}/usr/local/bin/partyos-trust-setup"
IDENT="${RFS}/usr/local/bin/partyos-identity-setup"
UCONF="${RFS}/usr/local/bin/partyos-userconf-setup"
for f in "${LIB}" "${COMMON}" "${TRUST}" "${IDENT}" "${UCONF}"; do
    [ -f "${f}" ] || { echo "FAIL: baked file not found at ${f}"; exit 1; }
done

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-internyet.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- a REAL-SHAPED sample env file (same keys + quoting as the venue ships) ----
# The password values here are TEST LITERALS, not the venue's.
SHARE="${TMPDIR_T}/share"
mkdir -p "${SHARE}"
cat > "${SHARE}/internyet.env" <<'ENV'
INTERNYET_ALIAS="Player1"
INTERNYET_USER_NAME="player1"
INTERNYET_USER_PASSWORD="notarealpassword"
INTERNYET_ID="NEUTEMPE79BQDQEHER"
INTERNYET_EMAIL="player1@p.nyet"
INTERNYET_DEFAULT_FQDN="deck.player1.p.nyet"
INTERNYET_BASE_URL="https://internyet.party"
INTERNYET_ALIAS_MAPPING_KEY="notarealmappingkey"
INTERNYET_API_KEY="notarealapikey"
INTERNYET_P12_PASSWORD="SUPERSECRETP12"
ENV

echo "================ 1. the env file parses ======================="
# shellcheck source=/dev/null
PARTYOS_SHARE_MNT="${SHARE}" source "${LIB}"
PARTYOS_SHARE_MNT="${SHARE}"

ENVF="$(internyet_env_file "${SHARE}")"
assert_eq "${ENVF}" "${SHARE}/internyet.env" "internyet_env_file finds the file at the share root"
assert_eq "$(internyet_dir "${ENVF}")" "${SHARE}" "internyet_dir points at the certificate directory"

assert_eq "$(internyet_get INTERNYET_USER_NAME "${ENVF}")" "player1" "INTERNYET_USER_NAME parses (quotes stripped)"
assert_eq "$(internyet_get INTERNYET_ALIAS "${ENVF}")" "Player1" "INTERNYET_ALIAS parses with its original case"
assert_eq "$(internyet_get INTERNYET_EMAIL "${ENVF}")" "player1@p.nyet" "INTERNYET_EMAIL parses"
assert_eq "$(internyet_get INTERNYET_DEFAULT_FQDN "${ENVF}")" "deck.player1.p.nyet" "INTERNYET_DEFAULT_FQDN parses"
assert_eq "$(internyet_get INTERNYET_P12_PASSWORD "${ENVF}")" "SUPERSECRETP12" "INTERNYET_P12_PASSWORD parses"
assert_eq "$(internyet_get INTERNYET_NOT_A_KEY "${ENVF}")" "" "an absent key yields empty, not an error"

# A value with internal spaces must survive - an alias may contain them.
printf 'INTERNYET_ALIAS="Lil Wil"\n' > "${TMPDIR_T}/spaced.env"
assert_eq "$(internyet_get INTERNYET_ALIAS "${TMPDIR_T}/spaced.env")" "Lil Wil" "an alias keeps its internal space"

# A CRLF file (written on Windows) must parse identically.
printf 'INTERNYET_USER_NAME="player1"\r\n' > "${TMPDIR_T}/crlf.env"
assert_eq "$(internyet_get INTERNYET_USER_NAME "${TMPDIR_T}/crlf.env")" "player1" "a CRLF env file parses (CR stripped)"

echo
echo "================ 2. the FQDN / hostname decision =============="
# Under test: the hostname is the FULL FQDN, lowercased. Many FQDNs can share
# the first label ("deck"), so the first label does not identify a box.
# The first label is only the alias in /etc/hosts and the fallback for a long FQDN.
assert_eq "$(internyet_node_name deck.player1.p.nyet)" "deck.player1.p.nyet" "the hostname is the FULL FQDN, not the first label"
assert_eq "$(internyet_node_name DECK.Player1.P.Nyet)" "deck.player1.p.nyet" "the FQDN hostname is lowercased"
assert_eq "$(internyet_node_name nodots)" "nodots" "an undotted name is its own hostname"
FQ64="$(printf 'a%.0s' $(seq 1 57)).p.nyet"
assert_eq "${#FQ64}" "64" "the 64-char sample has 64 chars"
assert_eq "$(internyet_node_name "${FQ64}")" "${FQ64}" "a 64-char FQDN is a valid hostname (kernel limit)"
FQ65="b${FQ64}"
assert_eq "$(internyet_node_name "${FQ65}")" "" "a 65-char FQDN yields empty (caller uses the first label)"
assert_eq "$(internyet_short_host "${FQ65}")" "b$(printf 'a%.0s' $(seq 1 57))" "the fallback for a long FQDN is its first label"
assert_eq "$(internyet_node_name "$(printf 'c%.0s' $(seq 1 64))")" "" "a label longer than 63 chars is refused"
assert_eq "$(internyet_node_name 'evil;rm -rf /')" "" "an FQDN with shell metacharacters yields empty"
assert_eq "$(internyet_node_name '-bad.example')" "" "a label that breaks RFC1123 yields empty"
assert_eq "$(internyet_short_host deck.player1.p.nyet)" "deck" "the alias is the FIRST label of the FQDN"
assert_eq "$(internyet_short_host DECK.Player1.P.Nyet)" "deck" "the alias is lowercased"
assert_eq "$(internyet_short_host '-bad.example')" "" "a first label that breaks RFC1123 yields empty (caller derives instead)"
internyet_valid_fqdn "deck.player1.p.nyet"; assert_true $? "a normal FQDN validates"
internyet_valid_fqdn 'evil;rm -rf /'; assert_false $? "an FQDN with shell metacharacters is refused"
internyet_valid_fqdn ""; assert_false $? "an empty FQDN is refused"

# identity-setup must write the FULL FQDN to /etc/hostname + hostnamectl, and
# keep the first label as the alias on the 127.0.1.1 line in /etc/hosts.
IDENT_SRC="$(cat "${IDENT}")"
assert_contains "${IDENT_SRC}" 'HOSTNAME_RESOLVED="$(internyet_node_name "${FQDN}")"' "identity-setup takes the hostname from the full FQDN"
assert_not_contains "${IDENT_SRC}" 'HOSTNAME_RESOLVED="$(internyet_short_host' "identity-setup does NOT cut the hostname to the first label"
assert_contains "${IDENT_SRC}" 'HOSTNAME_RESOLVED="${SHORT_HOST}"' "identity-setup falls back to the first label for a long FQDN"
assert_contains "${IDENT_SRC}" 'echo "${HOSTNAME_RESOLVED}" > /etc/hostname' "identity-setup writes the resolved hostname to /etc/hostname"
assert_contains "${IDENT_SRC}" 'hostnamectl set-hostname "${HOSTNAME_RESOLVED}"' "identity-setup sets the resolved hostname live"
assert_contains "${IDENT_SRC}" '/etc/hosts' "identity-setup writes the full FQDN into /etc/hosts"
assert_contains "${IDENT_SRC}" '127.0.1.1' "identity-setup uses the 127.0.1.1 convention for the FQDN"
assert_contains "${IDENT_SRC}" '"${FQDN}" "${SHORT_HOST}"' "the 127.0.1.1 line keeps the first label as an alias"
assert_contains "${IDENT_SRC}" 'INTERNYET_USER_NAME' "identity-setup reads INTERNYET_USER_NAME"
assert_contains "${IDENT_SRC}" 'INTERNYET_DEFAULT_FQDN' "identity-setup reads INTERNYET_DEFAULT_FQDN"

echo
echo "================ 3. the nick / email mapping =================="
UCONF_SRC="$(cat "${UCONF}")"
assert_contains "${UCONF_SRC}" 'NICK_RAW="$(getenvk INTERNYET_ALIAS)"' "nick maps from INTERNYET_ALIAS"
assert_contains "${UCONF_SRC}" 'FULLNAME="$(getenvk INTERNYET_ALIAS)"' "the old FULLNAME key is fed from INTERNYET_ALIAS"
assert_contains "${UCONF_SRC}" 'EMAIL="$(getenvk INTERNYET_EMAIL)"' "the old EMAIL key is fed from INTERNYET_EMAIL"
assert_contains "${UCONF_SRC}" 'getk NICK' "the legacy user.conf NICK stays as the fallback"

echo
echo "================ 4. the home gate reads the env file =========="
# Drive the REAL stick_username + home_stick_gate out of partyos-sync-common.sh. The
# file is sourced whole, so point every path it defines at the sandbox first.
gate_verdict() {  # gate_verdict SHAREDIR LEGACY_PARTYOS LOGIN_USER -> verdict
    local sharedir="$1" legacy="$2" login="$3"
    (
        PARTYOS_SHARE_MNT="${sharedir}"
        # shellcheck source=/dev/null
        source "${LIB}"
        PARTYOS_SHARE_MNT="${sharedir}"
        # carve just the two functions out of the common lib (sourcing it whole would
        # touch /run and /mnt on the dev host).
        eval "$(sed -n '/^stick_username() {/,/^}/p;/^home_stick_gate() {/,/^}/p' "${COMMON}")"
        MNT="$(dirname "${legacy}")"
        home_stick_gate "$(stick_username "${legacy}")" "${login}"
    )
}

LEGACY_DIR="${TMPDIR_T}/usbhome"; mkdir -p "${LEGACY_DIR}"
EMPTY_SHARE="${TMPDIR_T}/emptyshare"; mkdir -p "${EMPTY_SHARE}"

assert_eq "$(gate_verdict "${SHARE}" "${LEGACY_DIR}/.partyos" player1)" "mount" \
    "the gate MOUNTS when the env file's user matches the logged-in user"
assert_eq "$(gate_verdict "${SHARE}" "${LEGACY_DIR}/.partyos" someoneelse)" "foreign" \
    "the gate REFUSES a stick whose env file names a different player"

# THE REGRESSION THIS GUARDS: before the fix the gate read .partyos, which the venue
# deleted. Every stick then looked blank and any stick was adopted by any box.
assert_eq "$(gate_verdict "${EMPTY_SHARE}" "${LEGACY_DIR}/.partyos" someoneelse)" "blank" \
    "with NO identity anywhere the stick is blank (adoptable) - the documented fresh-stick case"

echo
echo "================ 5. the missing-env fallback =================="
# No env file on the share, but a LEGACY .partyos on the home partition: the old
# stick must still resolve to its owner.
printf 'USERNAME=oldtimer\nHOSTNAME=oldbox\n' > "${LEGACY_DIR}/.partyos"
assert_eq "$(gate_verdict "${EMPTY_SHARE}" "${LEGACY_DIR}/.partyos" oldtimer)" "mount" \
    "with no env file the gate falls back to the legacy .partyos USERNAME"
assert_eq "$(gate_verdict "${EMPTY_SHARE}" "${LEGACY_DIR}/.partyos" player1)" "foreign" \
    "the legacy fallback still refuses a different player"
# and the env file WINS over a legacy file that disagrees.
assert_eq "$(gate_verdict "${SHARE}" "${LEGACY_DIR}/.partyos" player1)" "mount" \
    "the env file wins over a stale legacy .partyos"
assert_eq "$(internyet_env_file "${EMPTY_SHARE}")" "" "internyet_env_file yields empty when the share has no env file"
assert_eq "$(internyet_get INTERNYET_USER_NAME "${EMPTY_SHARE}/internyet.env")" "" \
    "reading a key from an absent env file is empty, not an error"

# The venue also ships the files inside a per-player subdirectory on some sticks.
NESTED="${TMPDIR_T}/nested"; mkdir -p "${NESTED}/player1"
cp "${SHARE}/internyet.env" "${NESTED}/player1/internyet.env"
assert_eq "$(internyet_env_file "${NESTED}")" "${NESTED}/player1/internyet.env" \
    "internyet_env_file finds the file one directory down"

echo
echo "================ 6. a malformed env file is inert ============="
MAL="${TMPDIR_T}/malformed"; mkdir -p "${MAL}"
cat > "${MAL}/internyet.env" <<'ENV'
# a comment line
this line has no equals sign at all
INTERNYET_USER_NAME="root; touch /tmp/partyos-pwned-$$"
INTERNYET_DEFAULT_FQDN="$(touch /tmp/partyos-pwned2)"
INTERNYET_ALIAS=
   INTERNYET_EMAIL   =   "spaced@example.com"
ENV
rm -f /tmp/partyos-pwned2
MAL_USER="$(internyet_get INTERNYET_USER_NAME "${MAL}/internyet.env")"
assert_eq "${MAL_USER}" 'root; touch /tmp/partyos-pwned-$$' "a hostile value is returned as DATA, verbatim"
[ -e /tmp/partyos-pwned2 ]; assert_false $? "parsing never executes a command substitution from the file"
# identity-setup validates the name, so a hostile one can never become the account.
printf '%s' "${MAL_USER}" | grep -qE '^[a-z_][a-z0-9_-]*$'
assert_false $? "the hostile user name fails identity-setup's validation (falls back to gamer)"
MAL_FQ="$(internyet_get INTERNYET_DEFAULT_FQDN "${MAL}/internyet.env")"
internyet_valid_fqdn "${MAL_FQ}"; assert_false $? "the hostile FQDN fails validation (hostname is derived instead)"
assert_eq "$(internyet_get INTERNYET_ALIAS "${MAL}/internyet.env")" "" "an empty assignment yields empty"
assert_contains "$(cat "${LIB}")" "never sourced" "the parser documents that it never sources the file"
assert_not_contains "$(cat "${LIB}")" 'source "${file}"' "the parser really does not source the env file"
rm -f /tmp/partyos-pwned2

echo
echo "================ 7. the p12 password is never logged =========="
TRUST_SRC="$(cat "${TRUST}")"
# The password must reach pk12util through a file, never as an argv element.
assert_contains "${TRUST_SRC}" '-w "${pwfile}"' "pk12util takes the password from a FILE, not from argv"
assert_not_contains "${TRUST_SRC}" '-W "${P12_PASSWORD}"' "the password is never an argv element"
assert_not_contains "${TRUST_SRC}" 'log "${P12_PASSWORD}' "the password is never logged directly"
# The only line allowed to expand the password is the one that writes the 0600
# password file for pk12util. No echo/log/printf-to-stdout line may mention it.
BAD_LOG="$(grep -nE '(^|[[:space:]])(log|echo)[[:space:]].*\$\{P12_PASSWORD' "${TRUST}" || true)"
assert_eq "${BAD_LOG}" "" "no log or echo line expands the p12 password"
# The value may be expanded in exactly two places: the emptiness check and the
# write into the 0600 password file. Neither reaches stdout or a log.
PW_USES="$(grep -c '\${P12_PASSWORD}' "${TRUST}" || true)"
assert_eq "${PW_USES}" "2" "the password expands only in the emptiness check and the password file"

# RUN it for real against the sample share and prove the password never reaches stdout.
TRUST_OUT="$(HOME="${TMPDIR_T}/home" PARTYOS_SHARE_MNT="${SHARE}" \
    bash "${TRUST}" --user 2>&1 || true)"
assert_not_contains "${TRUST_OUT}" "SUPERSECRETP12" "a real --user run never prints the p12 password"
assert_not_contains "${TRUST_OUT}" "notarealpassword" "a real --user run never prints the account password"
assert_not_contains "${TRUST_OUT}" "notarealapikey" "a real --user run never prints the API key"
assert_contains "${TRUST_OUT}" "PARTYOS-TRUST-DONE" "the import reports it finished"
# REGRESSION (found on hardware): a non-root run wrote its marker into the
# root-owned /run/partyos-trust and printed "Permission denied" on every login.
assert_not_contains "${TRUST_OUT}" "Permission denied" "a session run writes no permission error"
# REGRESSION (found on hardware): pk12util names the certificate after the
# friendly name in the p12 bag and IGNORES -n, so a nickname check never matched
# and every login imported a duplicate. The marker keys on the p12's content.
assert_contains "${TRUST_SRC}" '.partyos-p12-imported' "the p12 import is keyed on a content marker, not on a nickname"
assert_contains "${TRUST_SRC}" 'sha256sum "${P12}"' "the marker records the p12's sha256, so a replaced p12 re-imports"
assert_not_contains "${TRUST_SRC}" 'certutil -d "sql:${db}" -L -n "${CLIENT_NICK}"' \
    "the dead nickname check is gone"

# NON-FATAL contract: a run with NO share at all must still exit 0.
bash "${TRUST}" --user >/dev/null 2>&1 <<<"" ; :
HOME="${TMPDIR_T}/home" PARTYOS_SHARE_MNT="${TMPDIR_T}/nosuchshare" bash "${TRUST}" --user >/dev/null 2>&1
assert_true $? "a run with no share present still exits 0 (login is never blocked)"
HOME="${TMPDIR_T}/home" PARTYOS_SHARE_MNT="${SHARE}" bash "${TRUST}" --system >/dev/null 2>&1
assert_true $? "a --system run as a non-root user still exits 0"

echo
echo "================ 8. the build wiring ==========================="
MANIFEST="${RFS}.manifest"
for p in usr/local/lib/partyos-internyet.sh usr/local/bin/partyos-trust-setup \
         etc/systemd/system/partyos-trust.service etc/xdg/autostart/partyos-trust.desktop; do
    grep -q "^${p}	" "${MANIFEST}"
    assert_true $? "${p} is in the rootfs manifest"
done
PHASE="$(cat "${REPO_ROOT}/scripts/build/phases/40-identity.sh")"
assert_contains "${PHASE}" 'bake "usr/local/lib/partyos-internyet.sh"' "the build bakes the env parser"
assert_contains "${PHASE}" 'bake "usr/local/bin/partyos-trust-setup"' "the build bakes the trust importer"
assert_contains "${PHASE}" 'multi-user.target.wants/partyos-trust.service' "the trust service is enabled at build time"

# Networking stays DHCP: no static-IP handling may be added to the new path.
assert_not_contains "$(cat "${LIB}")" "STATIC_IP" "the env parser adds no static-IP handling"
assert_not_contains "${TRUST_SRC}" "STATIC_IP" "the trust importer adds no static-IP handling"

echo
echo "================ 9. the identity report reads report_url= ========"
# The report must find report_url= on /proc/cmdline.
# $(< /proc/cmdline 2>/dev/null) is always empty in bash. Extract the
# real report function, point it at a fake cmdline, and stub curl + logger.
FN="$(awk '/^partyos_identity_report\(\) \{/,/^\}/' "${IDENT}")"
assert_contains "${FN}" 'partyos_identity_report()' "the report function is extracted from the baked script"
assert_not_contains "${FN}" 'in $(< /proc/cmdline' "the report does not use the broken \$(< file 2>) form"
CMDL="${TMPDIR_T}/cmdline"; CURL_LOG="${TMPDIR_T}/curl.log"; : > "${CURL_LOG}"
echo "initrd=x ip=dhcp report_url=https://partyos.c.nyet:8443 quiet" > "${CMDL}"
OUT="$(
    curl()   { echo "$*" >> "${CURL_LOG}"; }
    logger() { :; }
    eval "${FN//\/proc\/cmdline/${CMDL}}"
    partyos_identity_report ok player1 "" 2>&1
)"
assert_not_contains "${OUT}" "NO-SERVER" "report_url= on the cmdline gives no NO-SERVER line"
assert_contains "$(cat "${CURL_LOG}")" "https://partyos.c.nyet:8443/report?step=identity&status=ok&user=player1" \
    "the report goes to the report_url= from the cmdline"
echo "initrd=x ip=dhcp quiet" > "${CMDL}"
OUT="$(
    curl()   { echo "$*" >> "${CURL_LOG}"; }
    logger() { :; }
    eval "${FN//\/proc\/cmdline/${CMDL}}"
    partyos_identity_report ok player1 "" 2>&1
)"
assert_contains "${OUT}" "PARTYOS-IDENTITY-SETUP-NO-SERVER" "no report_url= still logs NO-SERVER"

echo
echo
echo "================ 10. the venue stick labels and share ============"
# The venue stick: ext4 PARTYOSHOME (home) + exFAT PARTYDATA (share). Legacy sticks:
# LANPARTY_HOME + PARTYSHARE. Every consumer finds the partitions through the one
# helper, partyos-usb-labels.sh (its lookup is tested in test-home-select).
LABELS_LIB="${RFS}/usr/local/lib/partyos-usb-labels.sh"
for f in "${IDENT}" "${RFS}/usr/local/bin/partyos-usbhome" "${RFS}/usr/local/bin/partyos-usb-reinserted" \
         "${RFS}/usr/local/bin/partyos-usb-poll"; do
    src="$(grep -v '^[[:space:]]*#' "${f}")"
    assert_contains "${src}" "/usr/local/lib/partyos-usb-labels.sh" "$(basename "${f}") sources the label helper"
    assert_contains "${src}" "partyos_resolve_label_dev home" "$(basename "${f}") resolves the home through the helper"
    assert_not_contains "${src}" "LANPARTY_HOME" "$(basename "${f}") has no fixed home label"
    assert_not_contains "${src}" "PARTYSHARE" "$(basename "${f}") has no fixed share label"
    assert_not_contains "${src}" "blkid -L" "$(basename "${f}") does no own blkid -L lookup"
done
assert_contains "$(cat "${IDENT}")" "partyos_resolve_label_dev share" "identity-setup finds internyet.env on the share through the helper"
grep -q "^usr/local/lib/partyos-usb-labels.sh	" "${MANIFEST}"
assert_true $? "partyos-usb-labels.sh is in the rootfs manifest"
assert_contains "$(cat "${REPO_ROOT}/scripts/build/phases/45-usbhome-sync.sh")" 'bake "usr/local/lib/partyos-usb-labels.sh"' \
    "the build bakes the label helper"
# The real venue share holds more than internyet.env: certificates, a README and misc/.
VSHARE="${TMPDIR_T}/venue-share"; mkdir -p "${VSHARE}/misc"
cp "${SHARE}/internyet.env" "${VSHARE}/internyet.env"
for f in ca.crt client.crt client.key client.p12 server.crt server.key great_house-1.crt great_house-1.key README.txt; do
    printf 'x\n' > "${VSHARE}/${f}"
done
printf 'x\n' > "${VSHARE}/misc/Firefox Setup 128.exe"
assert_eq "$(internyet_env_file "${VSHARE}")" "${VSHARE}/internyet.env" "the venue share with certs, README and misc/: internyet.env is found"
assert_eq "$(internyet_get INTERNYET_USER_NAME "$(internyet_env_file "${VSHARE}")")" "player1" "the venue share: the user name parses"
HOME="${TMPDIR_T}/home-venue" PARTYOS_SHARE_MNT="${VSHARE}" bash "${TRUST}" --user >/dev/null 2>&1
assert_true $? "the trust importer exits 0 on the venue share with the extra files"

assert_summary "test-internyet-identity"
