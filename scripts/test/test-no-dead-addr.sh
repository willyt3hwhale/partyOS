#!/usr/bin/env bash
# test-no-dead-addr.sh - hardware-free guard against dead fallback addresses.
#
# The baked image once fell back to 10.0.2.2 (the QEMU user-mode NAT host of a dev VM)
# when a server parameter was missing from the kernel cmdline. At the event a client
# would silently dial a dead address. This test asserts:
#   1. No dead dev/lab literal remains in the rootfs, boot/, or the build phases.
#   2. A missing server parameter gives the named PARTYOS-<SCRIPT>-NO-SERVER error
#      and a non-zero exit (or, for report-only paths, the error and no dial).
#   3. The baked pacman mirror files carry no server, and partyos-pkg-install starts
#      partyos-mirror.service before it runs pacman.
#   4. systemd-resolved has no public FallbackDNS, and the build resolver cannot leak.
#   5. The bt_tracker default bind address is not a lab IP.
#   6. The dead lab DNS name partyos.lan is not in the image, the served boot
#      script template or the live deploy.conf keys.
#   7. No image file names a fixed stick partition label. Only the label helper
#      partyos-usb-labels.sh holds the defaults (the venue label, then the old one).
# No VM, no network, no hardware.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

ROOTFS="${REPO_ROOT}/scripts/build/files/rootfs"
BIN="${ROOTFS}/usr/local/bin"
PHASES="${REPO_ROOT}/scripts/build/phases"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-deadaddr-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# --- 1. no dead literal in the sources that reach a client -------------------
# Tracked and untracked-but-not-ignored files only: the rendered VM .ipxe outputs in
# boot/ are git-ignored harness artifacts, not served to real clients.
DEAD_RE='10\.0\.2\.2|10\.13\.37\.|192\.168\.0\.'
hits="$(cd "${REPO_ROOT}" && git ls-files -co --exclude-standard -- \
        scripts/build/files/rootfs boot scripts/build/phases \
        | while read -r f; do [ -f "$f" ] && grep -EHn "${DEAD_RE}" "$f"; done)"
assert_eq "${hits}" "" "no 10.0.2.2 / lab literal in rootfs/, boot/ or the build phases"

# --- 2. a missing server parameter fails loudly -------------------------------
# Rewrite only the file LOCATIONS (cmdline, config files, output dirs) to stand-ins.
# The script logic is the real code.
: > "${TMP}/cmdline"                       # a cmdline with no server parameter
mkdir -p "${TMP}/bin" "${TMP}/home" "${TMP}/queue" "${TMP}/pacman.d" "${TMP}/portal"
printf '#!/bin/sh\nexit 0\n' > "${TMP}/bin/logger"
# curl stub: record any dial. A dial means a guessed address was used.
printf '#!/bin/sh\necho "$@" >> "%s/dialled"\nexit 7\n' "${TMP}" > "${TMP}/bin/curl"
chmod +x "${TMP}/bin/"*
echo '{}' > "${TMP}/queue/x.json"

carve() {
    sed -e "s#/proc/cmdline#${TMP}/cmdline#g" \
        -e "s#/etc/partyos/appstore.conf#${TMP}/none.conf#g" \
        -e "s#/run/partyos-user.conf#${TMP}/none.conf#g" \
        -e "s#/mnt/usbhome/.partyos-reports#${TMP}/queue#g" \
        -e "s#/etc/pacman.d#${TMP}/pacman.d#g" \
        -e "s#/etc/pacman.conf#${TMP}/pacman.conf#g" \
        -e "s#/var/lib/partyos/portal#${TMP}/portal#g" \
        "${BIN}/$1" > "${TMP}/$1"
}

# run_missing SCRIPT TAG - the script must exit non-zero, print TAG, and dial nothing.
run_missing() {
    local s="$1" tag="$2" out rc
    carve "${s}"
    rm -f "${TMP}/dialled"
    out="$(env -i PATH="${TMP}/bin:/usr/bin:/bin" HOME="${TMP}/home" \
           XDG_RUNTIME_DIR="${TMP}" bash "${TMP}/${s}" 2>&1)"; rc=$?
    assert_false "${rc}" "${s}: exits non-zero with no server parameter"
    assert_contains "${out}" "${tag}" "${s}: logs ${tag}"
    assert_false "$([ -e "${TMP}/dialled" ]; echo $?)" "${s}: dials no address"
}
run_missing partyos-mirror-setup     PARTYOS-MIRROR-SETUP-NO-SERVER
run_missing partyos-portal-fetch     PARTYOS-PORTAL-FETCH-NO-SERVER
run_missing partyos-messenger-config PARTYOS-MESSENGER-CONFIG-NO-SERVER
run_missing partyos-report-flush     PARTYOS-REPORT-FLUSH-NO-SERVER
run_missing partyos-notify-poll      PARTYOS-NOTIFY-POLL-NO-SERVER
run_missing partyos-timesync         PARTYOS-TIMESYNC-NO-SERVER
assert_false "$([ -e "${TMP}/pacman.d/partyos-mirror" ]; echo $?)" \
    "partyos-mirror-setup: writes no mirror file with no server parameter"

# Shared server_base()/report_base() resolvers: carve the function and call it.
fn_missing() {
    local s="$1" fn="$2" tag="$3" out rc
    carve "${s}"
    out="$(env -i PATH="${TMP}/bin:/usr/bin:/bin" bash -c \
           "$(sed -n "/^${fn}() {/,/^}/p" "${TMP}/${s}"); ${fn}" 2>"${TMP}/err")"; rc=$?
    assert_false "${rc}" "${s}: ${fn} returns non-zero with no server parameter"
    assert_eq "${out}" "" "${s}: ${fn} prints no guessed base on stdout"
    assert_contains "$(cat "${TMP}/err")" "${tag}:" "${s}: ${fn} logs ${tag} on stderr"
}
fn_missing partyos-app    server_base PARTYOS-APP-NO-SERVER
fn_missing partyos-launch server_base PARTYOS-LAUNCH-NO-SERVER
fn_missing partyos-report report_base PARTYOS-REPORT-NO-SERVER

# Report-only paths: the error tag is in the source (the boot stage still runs).
for f in "${BIN}/partyos-identity-setup" "${BIN}/partyos-desktop-ready" "${REPO_ROOT}"/boot/*-script.sh; do
    grep -q 'report_url=' "$f" || continue
    assert_contains "$(cat "$f")" "-NO-SERVER" "$(basename "$f"): logs a NO-SERVER error if report_url= is missing"
done

# --- 3. mirror: nothing baked, and pacman waits for mirror-setup ---------------
R85="$(cat "${PHASES}/85-repo-runtime.sh")"
assert_not_contains "${R85}" "printf 'Server =" "85-repo-runtime bakes no Server= line into the mirror files"
PKG="$(cat "${BIN}/partyos-pkg-install")"
assert_contains "${PKG}" "systemctl start partyos-mirror.service" "partyos-pkg-install starts partyos-mirror.service first"
start_ln="$(grep -n 'systemctl start partyos-mirror.service' "${BIN}/partyos-pkg-install" | head -1 | cut -d: -f1)"
pac_ln="$(grep -n 'pacman -Sy' "${BIN}/partyos-pkg-install" | head -1 | cut -d: -f1)"
assert_true "$([ "${start_ln:-99999}" -lt "${pac_ln:-0}" ]; echo $?)" "partyos-pkg-install: mirror start comes before pacman -Sy"
assert_contains "${R85}" "multi-user.target.wants/partyos-mirror.service" "partyos-mirror.service is enabled"

# --- 4. resolver ----------------------------------------------------------------
DROPIN="${ROOTFS}/etc/systemd/resolved.conf.d/10-partyos-no-fallback.conf"
assert_true "$([ -f "${DROPIN}" ]; echo $?)" "resolved drop-in exists"
assert_eq "$(grep -E '^FallbackDNS' "${DROPIN}" 2>/dev/null)" "FallbackDNS=" "resolved drop-in sets FallbackDNS= empty"
assert_eq "$(grep -cE '^\[Resolve\]' "${DROPIN}" 2>/dev/null)" "1" "resolved drop-in has a [Resolve] section"
assert_contains "$(cat "${PHASES}/50-net-provision.sh")" 'bake "etc/systemd/resolved.conf.d/10-partyos-no-fallback.conf"' "the drop-in is baked"
assert_contains "$(cat "${REPO_ROOT}/scripts/build/files/rootfs.manifest")" "etc/systemd/resolved.conf.d/10-partyos-no-fallback.conf" "the drop-in is in the manifest"
C0="$(cat "${PHASES}/c0-finalize.sh")"
assert_contains "${C0}" 'ln -sf /run/systemd/resolve/stub-resolv.conf "${ROOTFS}/etc/resolv.conf"' "finalize restores the resolved stub symlink"
assert_contains "${C0}" "FATAL: /etc/resolv.conf is not the resolved stub symlink" "finalize fails the build if the build resolver would leak"
BC="$(cat "${REPO_ROOT}/server/boot-config.sh")"
assert_contains "${BC}" '#[ -n "${_dns_if}" ] && resolvectl dns' "boot-config.sh has the DNS pin example"
assert_true "$(grep -qE '^[^#]*resolvectl' "${REPO_ROOT}/server/boot-config.sh"; [ $? -ne 0 ]; echo $?)" "the DNS pin in boot-config.sh is commented out"

# --- 5. bt_tracker default bind -------------------------------------------------
assert_eq "$(grep -E '^    bind_ip = ' "${REPO_ROOT}/server/bt_tracker.py")" '    bind_ip = "0.0.0.0"' "bt_tracker default bind_ip is 0.0.0.0"

# --- 6. the dead DNS name ----------------------------------------------------
# Ban partyos.lan and 10.13.37.101. Comment lines may mention the old name.
lan_hits="$(cd "${REPO_ROOT}" && for f in $(git ls-files -co --exclude-standard -- \
        scripts/build/files/rootfs scripts/build/phases) boot/partyos.ipxe.prod.tmpl \
        boot/step3-script.sh deploy.conf deploy.conf.tmpl; do
        [ -f "$f" ] && grep -EHn 'partyos\.lan|10\.13\.37\.101' "$f" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
    done)"
assert_eq "${lan_hits}" "" "no partyos.lan / 10.13.37.101 in the image, the boot template or deploy.conf keys"

# --- 7. no fixed stick partition label ---------------------------------------
# A consumer with its own fixed label finds nothing on a stick with the other
# layout (the venue sticks use PARTYOSHOME/PARTYDATA, the legacy sticks
# LANPARTY_HOME/PARTYSHARE). Every consumer asks partyos-usb-labels.sh.
label_hits="$(cd "${REPO_ROOT}" && git ls-files -co --exclude-standard -- \
        scripts/build/files/rootfs scripts/build/phases \
        | grep -v 'usr/local/lib/partyos-usb-labels.sh$' \
        | while read -r f; do [ -f "$f" ] && grep -EHn 'LANPARTY_HOME|PARTYSHARE|PARTYOSHOME|PARTYDATA' "$f"; done \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
assert_eq "${label_hits}" "" "no fixed stick partition label outside partyos-usb-labels.sh"
assert_contains "$(cat "${ROOTFS}/usr/local/lib/partyos-usb-labels.sh")" 'PARTYOS_HOME_LABELS_DEFAULT="PARTYOSHOME,LANPARTY_HOME"' \
    "the helper default: the venue home label first, the legacy label second"
assert_contains "$(cat "${ROOTFS}/usr/local/lib/partyos-usb-labels.sh")" 'PARTYOS_SHARE_LABELS_DEFAULT="PARTYDATA,PARTYSHARE"' \
    "the helper default: the venue share label first, the legacy label second"

assert_summary test-no-dead-addr
