#!/usr/bin/env bash
# test-prepare-event.sh - hardware-free test of the event wizard.
#
# The wizard is scripts/deploy/prepare-event.sh. This test drives it
# non-interactively (--answers) against a throwaway deploy.conf and a temp
# catalog, and asserts:
#   1. an unanswered blob, mirror or chat question keeps the deploy.conf value,
#   2. without those keys in deploy.conf, the defaults follow the main server,
#   3. full answers write deploy.conf, and the wizard registers no players,
#   4. a re-run with the same answers leaves deploy.conf byte-identical,
#   5. no confirmation means no write,
#   6. --dry-run writes nothing,
#   7. a dropped title leaves the catalog and the served render,
#   8. the package mirror takes its own host and survives a re-run unchanged,
#   9. a missing Docker daemon stops the wizard before it writes anything,
#  10. the same path with the real setup.sh and a failing docker.
#
# setup.sh is stubbed, so there is no docker, no CA and no network. The stub
# only records that it ran and writes PXE_SERVER, the same key setup.sh owns.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

WIZ="${REPO_ROOT}/scripts/deploy/prepare-event.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-prepev.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

# --- throwaway state --------------------------------------------------------
CONF="${T}/deploy.conf"
cat > "${CONF}" <<'EOF'
# throwaway deploy.conf
PXE_SERVER=old.lan:8080
BLOB_SERVERS=old.lan:8080
BLOB_SERVER=old.lan:8080
MIRROR_SERVER=old.lan:8080
IRC_SERVER=old.lan:6667
BLOB_CACHE_RESERVE_GB=8
BOOT_CONFIG_URL=
EOF

mkdir -p "${T}/ca"
cat > "${T}/catalog.v2.json" <<'EOF'
{"version":3,"games":[
 {"id":"partyos.warsow","name":"warsow","title":"Warsow","source":"blob","size":626282496,"hidden":false},
 {"id":"partyos.wc3","name":"wc3","title":"WC3","source":"blob","size":1073741824,"hidden":true,"unlock_code":"NYET"},
 {"id":"partyos.krita","name":"krita","title":"Krita","source":"pkg","size":0,"hidden":false}
]}
EOF

# Stub setup.sh: record the arguments, then write PXE_SERVER like the real one.
cat > "${T}/stub-setup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_LOG}"
# The real setup.sh writes nothing on a --dry-run. The wizard's pre-flight uses exactly
# that, so the stub has to honour it too. PARTYOS_STUB_FAIL=1 makes the pre-flight fail,
# which is how the no-Docker path is tested.
for a in "$@"; do
    case "${a}" in
        --dry-run)
            if [ "${PARTYOS_STUB_FAIL:-0}" = 1 ]; then
                echo "[setup] MISSING: docker daemon not running." >&2
                echo "[setup] prerequisites not met - see the messages above." >&2
                exit 1
            fi
            exit 0 ;;
    esac
done
for a in "$@"; do
    case "${a}" in --server-name=*) NAME="${a#*=}";; esac
done
tmp="$(mktemp)"
sed "s|^PXE_SERVER=.*|PXE_SERVER=${NAME}|" "${CONF_FILE}" > "${tmp}"
cat "${tmp}" > "${CONF_FILE}"; rm -f "${tmp}"
EOF
chmod +x "${T}/stub-setup.sh"

# WIZ_CONF selects another deploy.conf for one run. The default is ${CONF}.
run_wiz() {
    local conf="${WIZ_CONF:-${CONF}}"
    STUB_LOG="${T}/stub.log" CONF_FILE="${conf}" \
    PARTYOS_DEPLOY_CONF="${conf}" \
    PARTYOS_CATALOG="${T}/catalog.v2.json" PARTYOS_CA_DIR="${T}/ca" \
    PARTYOS_SETUP_CMD="${T}/stub-setup.sh" \
        bash "${WIZ}" "$@" > "${T}/out.log" 2>&1
}

echo "== 0. the wizard parses =="
bash -n "${WIZ}"
assert_true $? "prepare-event.sh passes bash -n"

echo "== 1. unanswered blob, mirror and chat questions keep the deploy.conf values =="
cat > "${T}/answers-min" <<EOF
SERVER_NAME=party.example:8080
CONFIRM=yes
EOF
run_wiz --answers "${T}/answers-min"
rc=$?
assert_true "${rc}" "the wizard runs with only the server answered (log: ${T}/out.log)"
[ "${rc}" -eq 0 ] || cat "${T}/out.log"
conf="$(cat "${CONF}")"
assert_contains "${conf}" "PXE_SERVER=party.example:8080" "setup.sh applied the server name"
assert_contains "${conf}" "BLOB_SERVERS=old.lan:8080" "the blob list keeps the deploy.conf value"
assert_contains "${conf}" "BLOB_SERVER=old.lan:8080" "the legacy blob key keeps the deploy.conf value"
assert_contains "${conf}" "MIRROR_SERVER=old.lan:8080" "the mirror keeps the deploy.conf value"
assert_contains "${conf}" "IRC_SERVER=old.lan:6667" "the chat server keeps the deploy.conf value"
out="$(cat "${T}/out.log")"
assert_contains "${out}" "5/5 party name" "the wizard asks five questions"
assert_not_contains "${out}" "6/6" "there is no sixth question"
assert_not_contains "${out}" "roster file" "the summary has no roster line"

echo "== 2. without those keys in deploy.conf, the defaults follow the main server =="
CONF_BARE="${T}/deploy-bare.conf"
cat > "${CONF_BARE}" <<'EOF'
# throwaway deploy.conf without blob, mirror or chat keys
PXE_SERVER=old.lan:8080
EOF
WIZ_CONF="${CONF_BARE}" run_wiz --answers "${T}/answers-min"
assert_true $? "the wizard runs against a bare deploy.conf"
conf="$(cat "${CONF_BARE}")"
assert_contains "${conf}" "BLOB_SERVERS=party.example:8080" "the blob list falls back to the main server"
assert_contains "${conf}" "MIRROR_SERVER=party.example:8080" "the mirror falls back to the main server"
assert_contains "${conf}" "IRC_SERVER=party.example:6667" "the chat server falls back to the main host on port 6667"
CONF_LEGACY="${T}/deploy-legacy.conf"
cat > "${CONF_LEGACY}" <<'EOF'
# throwaway deploy.conf with only the legacy blob key
PXE_SERVER=old.lan:8080
BLOB_SERVER=legacy.lan:8080
EOF
WIZ_CONF="${CONF_LEGACY}" run_wiz --answers "${T}/answers-min"
assert_true $? "the wizard runs against a legacy deploy.conf"
assert_contains "$(cat "${CONF_LEGACY}")" "BLOB_SERVERS=legacy.lan:8080" "the blob list falls back to the legacy BLOB_SERVER"

echo "== 3. full answers write deploy.conf and register no players =="
cat > "${T}/answers-good" <<EOF
SERVER_NAME=party.example:8080
BLOB_SERVERS=blob1.example:8080,blob2.example
MIRROR_SERVER=party.example
IRC_SERVER=chat.example
PARTY_NAME=Internyet
CONFIRM=yes
EOF
run_wiz --answers "${T}/answers-good"
rc=$?
assert_true "${rc}" "the wizard runs with full answers (log: ${T}/out.log)"
[ "${rc}" -eq 0 ] || cat "${T}/out.log"
conf="$(cat "${CONF}")"
assert_contains "${conf}" "PXE_SERVER=party.example:8080" "setup.sh applied the server name"
assert_contains "${conf}" "BLOB_SERVERS=blob1.example:8080,blob2.example:8080" "the blob list gets the default port"
assert_contains "${conf}" "BLOB_SERVER=blob1.example:8080" "the legacy blob key takes the first host"
assert_contains "${conf}" "IRC_SERVER=chat.example:6667" "the chat server gets port 6667"
assert_contains "${conf}" "MIRROR_SERVER=party.example:8080" "the mirror answer gets the default port"
assert_contains "${conf}" "PARTY_NAME=Internyet" "PARTY_NAME is added to deploy.conf"
assert_contains "${conf}" "BOOT_CONFIG_URL=" "the operator keys survive the write"
assert_contains "$(cat "${T}/stub.log")" "--server-name=party.example:8080" "setup.sh got the server name"
assert_true "$( ls "${CONF}".bak.* >/dev/null 2>&1 && echo 0 || echo 1 )" "deploy.conf was backed up"
assert_not_contains "$(cat "${T}/out.log")" "registered" "the wizard registers no players"
assert_contains "$(cat "${T}/out.log")" "unlock code NYET" "the hidden row names its unlock code"
assert_contains "$(cat "${T}/out.log")" "64 GB or larger" "the stick-size recommendation is shown"

echo "== 4. a re-run with the same answers leaves deploy.conf byte-identical =="
CONF_SHA_GOOD="$(cksum < "${CONF}")"
run_wiz --answers "${T}/answers-good"
assert_true $? "the re-run succeeds"
assert_eq "$(cksum < "${CONF}")" "${CONF_SHA_GOOD}" "deploy.conf is byte-identical after the re-run"

echo "== 5. no confirmation means no write =="
cp "${CONF}" "${T}/conf.snapshot"
cat > "${T}/answers-noconfirm" <<EOF
SERVER_NAME=other.example:8080
CONFIRM=no
EOF
run_wiz --answers "${T}/answers-noconfirm"
assert_false $? "an unconfirmed run exits non-zero"
assert_contains "$(cat "${T}/out.log")" "Nothing was written" "the unconfirmed run says nothing was written"
assert_eq "$(cat "${CONF}")" "$(cat "${T}/conf.snapshot")" "deploy.conf is byte-identical after an unconfirmed run"

echo "== 6. --dry-run writes nothing =="
run_wiz --answers "${T}/answers-good" --dry-run
assert_true $? "the dry run exits 0"
assert_contains "$(cat "${T}/out.log")" "DRY-RUN" "the dry run says so"
assert_eq "$(cat "${CONF}")" "$(cat "${T}/conf.snapshot")" "deploy.conf is unchanged after a dry run"

echo "== 7. a dropped title leaves the catalog AND the served render =="
cat > "${T}/answers-drop" <<EOF
SERVER_NAME=party.example:8080
DROP_TITLES=wc3
CONFIRM=yes
EOF
run_wiz --answers "${T}/answers-drop"
assert_true $? "the drop run succeeds"
assert_not_contains "$(cat "${T}/catalog.v2.json")" "partyos.wc3" "the dropped row is gone from the source"
assert_contains "$(cat "${T}/catalog.v2.json")" "partyos.warsow" "the kept rows stay in the source"
# Clients fetch catalog.json, not catalog.v2.json. The wizard must re-render it, or the
# drop reaches nobody.
assert_true "$( [ -f "${T}/catalog.json" ] && echo 0 || echo 1 )" "the served catalog.json is rendered"
assert_not_contains "$(cat "${T}/catalog.json")" "partyos.wc3" "the dropped row is gone from the SERVED catalog"
assert_contains "$(cat "${T}/catalog.json")" "partyos.warsow" "the kept rows are in the SERVED catalog"
CATALOG_V2="${T}/catalog.v2.json" bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" --check "${T}" >/dev/null 2>&1
assert_true $? "the drift guard says the served catalog matches the source"

echo "== 8. the package mirror takes its own host and survives a re-run =="
cat > "${T}/answers-mirror" <<EOF
SERVER_NAME=party.example:8080
BLOB_SERVERS=blob1.example:8080
MIRROR_SERVER=mirror.example
IRC_SERVER=chat.example
PARTY_NAME=Internyet
CONFIRM=yes
EOF
run_wiz --answers "${T}/answers-mirror"
assert_true $? "the split-mirror run succeeds"
assert_contains "$(cat "${CONF}")" "MIRROR_SERVER=mirror.example:8080" "the mirror gets its own host and the default port"
assert_contains "$(cat "${T}/out.log")" "MIRROR_SERVER=mirror.example:8080" "the summary line names the mirror"
MIRROR_BEFORE="$(grep '^MIRROR_SERVER=' "${CONF}")"
run_wiz --answers "${T}/answers-mirror"
assert_true $? "the split-mirror re-run succeeds"
assert_eq "$(grep '^MIRROR_SERVER=' "${CONF}")" "${MIRROR_BEFORE}" "the re-run leaves the split mirror unchanged"

echo "== 9. a missing Docker daemon stops the wizard BEFORE it writes anything =="
# The apply step calls setup.sh, which needs Docker. Without the pre-flight the wizard
# died mid-apply: deploy.conf already backed up and rewritten, the rest not yet
# written. The pre-flight must catch it before question 1.
cp "${CONF}" "${T}/conf.predocker"
CONF_SHA_BEFORE="$(cksum < "${CONF}")"
: > "${T}/stub.log"
PARTYOS_STUB_FAIL=1 run_wiz --answers "${T}/answers-good"
assert_false $? "the wizard fails when the Docker prereq is missing"
out="$(cat "${T}/out.log")"
assert_contains "${out}" "pre-flight" "the failure names the pre-flight"
assert_contains "${out}" "RUNNING Docker daemon" "the Docker requirement is stated up front"
assert_contains "${out}" "docker daemon not running" "setup.sh's own reason is shown"
assert_contains "${out}" "Nothing was written" "the wizard says nothing was written"
assert_eq "$(cksum < "${CONF}")" "${CONF_SHA_BEFORE}" "deploy.conf is byte-identical after the no-Docker run"
assert_true "$( ls "${CONF}".bak.* >/dev/null 2>&1 && echo 0 || echo 1 )" "(older backups from earlier cases still exist)"
assert_not_contains "$(cat "${T}/stub.log")" "--server-name=" "setup.sh never ran to APPLY"

echo "== 10. the same path with the REAL setup.sh and a failing docker =="
# Case 9 stubs setup.sh. This one keeps the real setup.sh and only makes `docker` fail,
# so the wizard's pre-flight is proven against the actual prereq gate. Every setup.sh
# output path is redirected to the temp dir, so the live repo is never a target.
mkdir -p "${T}/fakebin"
cat > "${T}/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon (test stub)" >&2
exit 1
EOF
chmod +x "${T}/fakebin/docker"
cp "${CONF}" "${T}/conf.realsetup"
REAL_SHA_BEFORE="$(cksum < "${CONF}")"
PATH="${T}/fakebin:${PATH}" \
CONF_OUT="${T}/setup-deploy.conf" EMBED_OUT="${T}/setup-embed.ipxe" EFI_OUT="${T}/setup-ipxe.efi" \
PARTYOS_CA_DIR="${T}/setup-ca" PARTYOS_TLS_DIR="${T}/setup-tls" \
BOOT_IPXE_OUT="${T}/setup-partyos.ipxe" PORTAL_OUT="${T}/setup-index.html" \
STUB_LOG="${T}/stub.log" CONF_FILE="${CONF}" \
PARTYOS_DEPLOY_CONF="${CONF}" \
PARTYOS_CATALOG="${T}/catalog.v2.json" PARTYOS_CA_DIR="${T}/setup-ca" \
    bash "${WIZ}" --answers "${T}/answers-good" > "${T}/out.log" 2>&1
assert_false $? "the real setup.sh pre-flight fails with a broken docker"
assert_contains "$(cat "${T}/out.log")" "docker daemon not running" "the real prereq gate reports the docker daemon"
assert_eq "$(cksum < "${CONF}")" "${REAL_SHA_BEFORE}" "deploy.conf is byte-identical after the real-setup no-Docker run"
assert_true "$( [ ! -f "${T}/setup-deploy.conf" ] && echo 0 || echo 1 )" "setup.sh wrote no deploy.conf of its own"

assert_summary test-prepare-event
