#!/usr/bin/env bash
# test-browser-object-crash.sh - hardware-free test for the WebKit object-subframe
# workaround in partyos-browser.
#
# Bug: WebKitGTK 2.48.5 crashes the Epiphany UI process when a page loads a hidden
# <object type="text/html" data="about:blank">. Wiki.js does this.
#
# Fix: partyos-browser adds a user stylesheet rule that hides these objects, and
# enables user CSS through the relocatable schema path.
#
# The schema org.gnome.Epiphany.web is relocatable. A gsettings call without the
# path fails silently, so the homepage-url call must also give the path.
#
# This runs the REAL launcher with stub epiphany and gsettings binaries. Then it
# checks the stylesheet, the gsettings call, and that a second run does not add
# the rule again or remove existing user CSS.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

BROWSER="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-browser"
[ -f "${BROWSER}" ] || { echo "FAIL: partyos-browser not found at ${BROWSER}"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-browsercss.XXXXXX")"
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/home"
printf '#!/bin/sh\necho "EPIPHANY $*" >> "%s/calls"\n' "${T}" > "${T}/bin/epiphany"
printf '#!/bin/sh\necho "GSETTINGS $*" >> "%s/calls"\n' "${T}" > "${T}/bin/gsettings"
chmod +x "${T}/bin/epiphany" "${T}/bin/gsettings"

RULE='object[type="text/html"]{display:none !important}'
UCSS="${T}/home/.local/share/epiphany/user-stylesheet.css"
run() { env -u XDG_DATA_HOME HOME="${T}/home" PATH="${T}/bin:${PATH}" \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null bash "${BROWSER}" https://wiki.example; }

echo "================ 1. first run writes the rule ========================="
run
assert_true "$([ -f "${UCSS}" ] && echo 0 || echo 1)" "the user stylesheet exists"
assert_eq "$(grep -cxF "${RULE}" "${UCSS}")" "1" "the stylesheet has the object rule once"
calls="$(cat "${T}/calls")"
assert_contains "${calls}" \
  "GSETTINGS set org.gnome.Epiphany.web:/org/gnome/epiphany/web/ enable-user-css true" \
  "user CSS is enabled through the relocatable schema path"
assert_contains "${calls}" "EPIPHANY https://wiki.example" "epiphany gets the requested URL"

echo
echo "================ 2. second run keeps existing CSS, no duplicate ========"
printf 'body{color:red}\n' >> "${UCSS}"
run
assert_eq "$(grep -cxF "${RULE}" "${UCSS}")" "1" "the rule is still present only once"
assert_contains "$(cat "${UCSS}")" "body{color:red}" "existing user CSS is kept"

echo
echo "================ 3. static: every web-schema call gives the path ========"
src="$(grep -v '^[[:space:]]*#' "${BROWSER}")"
assert_contains "${src}" \
  "gsettings set org.gnome.Epiphany.web:/org/gnome/epiphany/web/ homepage-url" \
  "homepage-url is set through the relocatable schema path"
assert_not_contains "${src}" "org.gnome.Epiphany.web " \
  "no gsettings call uses the web schema without its path"

assert_summary
