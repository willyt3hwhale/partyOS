#!/usr/bin/env bash
# test-http-allowlist.sh - hardware-free test for the public allowlist in
# server/http_server.py. The docroot is the whole repo, but only the public boot
# and blob artifacts may be served. Everything else is refused, and there are no
# directory listings. The test copies the REAL http_server.py into a temp tree
# with sample files, starts it HTTP-only on loopback, and asserts:
#
#   1. SERVE    - the allowlisted paths return 200, a Range request returns 206.
#   2. NO LIST  - a directory returns no listing (404, no file names in the body).
#   3. NAMES    - *.bak*, *.tmpl, *~, *.swp, dotfiles, *.key and *.pem are refused,
#      also inside an allowed directory. *.tmpl under server/config/ is served,
#      because the clients fetch the game config templates from there.
#   4. PRIVATE  - paths outside the allowlist (scripts/, Makefile, the server
#      source, build/) and traversal or symlink spellings of them are refused.
#   5. ROUTES   - /report still answers 200, and the secret denylist still 403s.
#
# On the old code (whole tree served, listings on) sections 2, 3 and 4 fail.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

SERVER="${REPO_ROOT}/server/http_server.py"
[ -f "${SERVER}" ] || { echo "FAIL: http_server.py not found at ${SERVER}"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not in PATH"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-allowtest.XXXXXX")"
SRV_PID=""
cleanup() {
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    rm -rf "${TMPDIR_T}"
}
trap cleanup EXIT

# --- the temp tree ----------------------------------------------------------
# http_server.py serves from its own ../, so a copy at <root>/server/ serves <root>.
# Every private file carries LEAK so a body check proves it was not sent.
LEAK="PARTYOS-ALLOWTEST-PRIVATE-DO-NOT-SERVE"
R="${TMPDIR_T}/repo"
install -d "${R}/server" "${R}/boot" "${R}/portal" "${R}/scripts/deploy" "${R}/build" \
    "${R}/blob-out/halo-ce" "${R}/server/images/custom/arch/x86_64" "${R}/server/games/icons" \
    "${R}/server/config/hexchat" "${R}/server/lanmirror" "${R}/server/lanmirror-local" \
    "${R}/server/sites" "${R}/ca"
cp "${SERVER}" "${R}/server/http_server.py"

# Public artifacts.
printf '#!ipxe\necho partyos\n'        > "${R}/boot/partyos.ipxe"
printf '#!/bin/sh\necho step3\n'        > "${R}/boot/step3-script.sh"
printf 'KERNEL\n'                       > "${R}/server/images/vmlinuz-linux"
printf 'INITRAMFS\n'                    > "${R}/server/images/initramfs-linux.img"
printf '0123456789ABCDEF'               > "${R}/server/images/custom/arch/x86_64/airootfs.sfs"
printf 'abc  airootfs.sfs\n'            > "${R}/server/images/custom/arch/x86_64/airootfs.sha512"
printf '{"games":[]}\n'                 > "${R}/server/games/catalog.json"
printf 'TORRENT\n'                      > "${R}/server/games/wc3.squashfs.torrent"
printf 'BLOB\n'                         > "${R}/server/games/wc3.squashfs"
printf 'PNG\n'                          > "${R}/server/games/icons/wc3.png"
printf 'servlist @NICK@\n'              > "${R}/server/config/hexchat/servlist.conf.tmpl"
printf 'DB\n'                           > "${R}/server/lanmirror/partyos.db.tar.gz"
ln -s partyos.db.tar.gz                   "${R}/server/lanmirror/partyos.db"
printf 'PKG\n'                          > "${R}/server/lanmirror/foo-1-1-x86_64.pkg.tar.zst"
printf 'LOCALDB\n'                      > "${R}/server/lanmirror-local/partyos-local.db"
printf '[]\n'                           > "${R}/server/notices.json"
printf 'BOOT_CONFIG=1\n'                > "${R}/server/boot-config.sh"
printf '<html>PORTAL-INDEX</html>\n'    > "${R}/portal/index.html"
printf '<html>SITE-INDEX</html>\n'      > "${R}/server/sites/index.html"
install -d "${R}/server/sites/gallery"
printf 'catalog.json\n'                 > "${R}/server/sites/gallery/a.html"

# Private files: backups, templates, editor files, dotfiles and keys INSIDE the
# allowed directories, plus files outside the allowlist.
for f in boot/partyos.ipxe.bak-20260923-prebootif \
         server/images/initramfs-linux.img.bak-20260923-pre-sync \
         server/images/custom/arch/x86_64/airootfs.sfs.bak-20260925-pre-x \
         server/games/catalog.json.bak-20260923-pre-brkn \
         boot/partyos.ipxe.tmpl portal/index.html.tmpl \
         boot/step3-script.sh~ boot/.step3-script.sh.swp \
         server/games/._wc3.squashfs.torrent server/games/.hidden \
         server/games/leak.key server/config/hexchat/leak.pem \
         server/config/hexchat/servlist.conf.tmpl.bak-1 \
         scripts/deploy/publish-blob.sh Makefile build/build-image.sh \
         blob-out/halo-ce/halo.squashfs \
         server/bt_tracker.py server/test.txt README.md deploy.conf ca/partyos-ca.key; do
    printf '%s %s\n' "${LEAK}" "${f}" > "${R}/${f}"
done
# A symlink inside an allowed directory that points back at a private file.
ln -s ../../Makefile "${R}/server/games/evil.squashfs"

# --- start the server --------------------------------------------------------
PORT=$(( (RANDOM % 2000) + 29080 ))
SRV_LOG="${TMPDIR_T}/srv.log"
PARTYOS_NO_HTTPS=1 python3 -u "${R}/server/http_server.py" "${PORT}" 127.0.0.1 > "${SRV_LOG}" 2>&1 &
SRV_PID=$!
up=0
for _ in $(seq 1 50); do
    if curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:${PORT}/report?step=probe" 2>/dev/null; then
        up=1; break
    fi
    sleep 0.1
done
assert_true "$([ "${up}" = 1 ]; echo $?)" "http_server.py came up on :${PORT}"

BASE="http://127.0.0.1:${PORT}"
OUT="${TMPDIR_T}/body"

# code URL [extra curl args] - print the HTTP status, body to ${OUT}.
code() {
    local url="$1"; shift
    curl -sS --path-as-is --max-time 5 -o "${OUT}" -w '%{http_code}' "$@" "${url}" 2>/dev/null
}

assert_served() {
    assert_eq "$(code "${BASE}$1")" "200" "GET $1 -> 200"
}

# assert_refused PATH - the status is 404 or 403 and no private body is sent.
assert_refused() {
    local c; c="$(code "${BASE}$1")"
    case "${c}" in 403|404) _assert_ok "GET $1 -> ${c}";; *) _assert_bad "GET $1 -> ${c} (expected 404/403)";; esac
    assert_not_contains "$(cat "${OUT}" 2>/dev/null)" "${LEAK}" "GET $1 -> no private body"
}

# ============================================================================
echo "================ 1. allowlisted paths are served ==============="
for p in /boot/partyos.ipxe /boot/step3-script.sh \
         /server/images/vmlinuz-linux /server/images/initramfs-linux.img \
         /server/images/custom/arch/x86_64/airootfs.sfs \
         /server/images/custom/arch/x86_64/airootfs.sha512 \
         /server/games/catalog.json /server/games/wc3.squashfs.torrent \
         /server/games/wc3.squashfs /server/games/icons/wc3.png \
         /server/config/hexchat/servlist.conf.tmpl \
         /server/lanmirror/partyos.db /server/lanmirror/foo-1-1-x86_64.pkg.tar.zst \
         /server/lanmirror-local/partyos-local.db \
         /server/notices.json /server/boot-config.sh /portal/index.html /sites/index.html; do
    assert_served "${p}"
done
assert_eq "$(code "${BASE}/server/notices.json?t=123")" "200" "GET /server/notices.json?t=123 -> 200"
assert_eq "$(code "${BASE}/portal/")" "200" "GET /portal/ -> 200 (directory with index.html)"
assert_contains "$(cat "${OUT}")" "PORTAL-INDEX" "/portal/ body is its index.html"
assert_eq "$(code "${BASE}/server/games/wc3.squashfs" -I)" "200" "HEAD /server/games/wc3.squashfs -> 200"

echo "---- Range ----"
assert_eq "$(code "${BASE}/server/images/custom/arch/x86_64/airootfs.sfs" -r 0-0)" "206" "Range 0-0 on airootfs.sfs -> 206"
assert_eq "$(cat "${OUT}")" "0" "Range 0-0 body is 1 byte"
assert_eq "$(code "${BASE}/server/images/custom/arch/x86_64/airootfs.sfs" -r 2-5)" "206" "Range 2-5 on airootfs.sfs -> 206"
assert_eq "$(cat "${OUT}")" "2345" "Range 2-5 body is the right slice"
assert_true "$(grep -q 'airootfs.sfs RANGE 2-5' "${SRV_LOG}"; echo $?)" "XFER log has the RANGE line"
assert_true "$(grep -q 'XFER.*catalog.json sent' "${SRV_LOG}"; echo $?)" "XFER log has the sent line"

# ============================================================================
echo
echo "================ 2. no directory listings ======================"
for p in / /boot/ /server/ /server/games/ /server/games/icons/ /server/images/ \
         /server/lanmirror/ /server/config/ /scripts/ /build/ /sites/gallery/ /server/games; do
    c="$(code "${BASE}${p}")"
    case "${c}" in 403|404) _assert_ok "GET ${p} -> ${c}";; *) _assert_bad "GET ${p} -> ${c} (expected 404/403)";; esac
    assert_not_contains "$(cat "${OUT}" 2>/dev/null)" "Directory listing" "GET ${p} -> no listing"
    assert_not_contains "$(cat "${OUT}" 2>/dev/null)" "catalog.json" "GET ${p} -> no file names"
done
# partyos-timesync reads the Date header of HEAD / without -f, so a 404 still works.
hdr="$(curl -sSI --max-time 5 "${BASE}/" 2>/dev/null)"
assert_contains "${hdr}" "Date:" "HEAD / still carries a Date header (partyos-timesync)"

# ============================================================================
echo
echo "================ 3. denied names inside allowed dirs ============"
for p in /boot/partyos.ipxe.bak-20260923-prebootif \
         /server/images/initramfs-linux.img.bak-20260923-pre-sync \
         /server/images/custom/arch/x86_64/airootfs.sfs.bak-20260925-pre-x \
         /server/games/catalog.json.bak-20260923-pre-brkn \
         /boot/partyos.ipxe.tmpl /portal/index.html.tmpl \
         /boot/step3-script.sh~ /boot/.step3-script.sh.swp \
         /server/games/._wc3.squashfs.torrent /server/games/.hidden \
         /server/games/leak.key /server/config/hexchat/leak.pem \
         /server/config/hexchat/servlist.conf.tmpl.bak-1; do
    assert_refused "${p}"
done
# A Range probe must not leak a backup either.
c="$(code "${BASE}/server/images/custom/arch/x86_64/airootfs.sfs.bak-20260925-pre-x" -r 0-9)"
assert_eq "${c}" "404" "Range on a *.bak* -> 404"

# ============================================================================
echo
echo "================ 4. paths outside the allowlist ================="
for p in /scripts/deploy/publish-blob.sh /Makefile /server/http_server.py \
         /build/build-image.sh /blob-out/halo-ce/halo.squashfs \
         /server/bt_tracker.py /server/test.txt /README.md /server/sites/index.html \
         /boot/../Makefile /%2e%2e/Makefile //Makefile /server/games/../../Makefile \
         /server/games/../http_server.py /server/games/%2e%2e/http_server.py \
         /server/games/evil.squashfs; do
    assert_refused "${p}"
done
assert_eq "$(code "${BASE}/Makefile" -I)" "404" "HEAD /Makefile -> 404"
assert_true "$(grep -q 'DENY not-public' "${SRV_LOG}"; echo $?)" "server logged a DENY not-public line"

# ============================================================================
echo
echo "================ 5. /report and the secret denylist ============"
assert_eq "$(code "${BASE}/report?step=allowtest&status=ok")" "200" "GET /report -> 200"
assert_eq "$(cat "${OUT}")" "ok" "/report body is ok"
assert_true "$(grep -q 'REPORT step=allowtest status=ok' "${SRV_LOG}"; echo $?)" "REPORT line logged"
assert_eq "$(code "${BASE}/ca/partyos-ca.key")" "403" "GET /ca/partyos-ca.key -> 403 (denylist)"
assert_eq "$(code "${BASE}/deploy.conf")" "403" "GET /deploy.conf -> 403 (denylist)"

kill "${SRV_PID}" 2>/dev/null || true; SRV_PID=""

assert_summary "test-http-allowlist" || exit 1
echo "test-http-allowlist: ALL PASS"
