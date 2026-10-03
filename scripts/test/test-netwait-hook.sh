#!/usr/bin/env bash
# test-netwait-hook.sh - hardware-free unit test for the initramfs partyos_netwait
# link-wait hook.
#
# The hook reads the mkinitcpio parse_cmdline variables (${ip}, ${netwait:-30}).
# `getarg` is a dracut helper and is not defined under mkinitcpio.
#
# This test carves the run_hook body out of the baked hook
# scripts/build/files/rootfs/usr/lib/initcpio/hooks/partyos_netwait (the same
# carve-and-mock idiom as the other prod tests), points
# its hardcoded /sys/class/net at a MOCK sysfs tree (a writable stand-in carrier file)
# and stubs `ip`/`msg`, then asserts the hook's REAL behavior:
#   * no ip= on the cmdline  -> returns immediately (the guard reads ${ip}; not a netboot).
#   * ip=dhcp + carrier DOWN -> enters a BOUNDED wait of ~netwait s, then WARNs and
#                               proceeds.
#   * ip=dhcp + carrier UP   -> returns promptly (< 1s) with a "link up" log.
#   * netwait= is honored (a smaller value waits less) and garbage is sanitised.
# No VM, no network, no hardware - pure shell.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

BUILD="${REPO_ROOT}/scripts/build/files/rootfs/usr/lib/initcpio/hooks/partyos_netwait"
[ -f "${BUILD}" ] || { echo "FAIL: partyos_netwait hook not found at ${BUILD}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-netwait-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# --- point at the baked partyos_netwait hook ----------------------------------
RAW="${BUILD}"
[ -s "${RAW}" ] || { echo "FAIL: partyos_netwait baked hook is empty (${RAW})"; exit 1; }
grep -q 'run_hook()' "${RAW}" || { echo "FAIL: carved block missing run_hook()"; exit 1; }

# --- source-level guards: the fix is actually in the carved code --------------
RAWTXT="$(cat "${RAW}")"
assert_not_contains "${RAWTXT}" '$(getarg' "hook no longer CALLS the undefined dracut getarg helper (the comment may still name it)"
assert_contains     "${RAWTXT}" '${ip:-}'      "hook reads the mkinitcpio parse_cmdline \${ip} var (netboot guard)"
assert_contains     "${RAWTXT}" '${netwait:-30}' "hook reads the mkinitcpio parse_cmdline \${netwait} var (default 30s)"
assert_contains     "${RAWTXT}" '*[!0-9]*'    "hook sanitises a non-numeric netwait= so it cannot wedge the bounded wait"
# The whole-build fix: the copytoram diagnostic (now emitted by the a5-eggs-splash-initramfs
# phase) + the netwait hook both drop ALL getarg calls. Scan the hook AND that phase.
A5="${REPO_ROOT}/scripts/build/phases/a5-eggs-splash-initramfs.sh"
[ -f "${A5}" ] || { echo "FAIL: a5-eggs-splash-initramfs.sh not found at ${A5}"; exit 1; }
BUILDTXT="$(cat "${RAW}" "${A5}")"
assert_not_contains "${BUILDTXT}" '$(getarg' "build emits NO getarg calls anywhere (netwait + copytoram diagnostic both fixed)"
assert_contains     "${BUILDTXT}" '_preport=\"${report_url:-}\"' "copytoram diagnostic reads report_url via parse_cmdline var, not getarg"

# --- mock sysfs + tools: rewrite the hardcoded /sys/class/net to a writable stand-in
# so we can drive the carrier state the hook polls. Only the sysfs ROOT (a filesystem location) is redirected; the hook LOGIC is
# byte-for-byte the real code. `#` delimiter: mktemp dirs never contain it.
MOCK_NET="${TMP}/sys-net"
HOOK="${TMP}/netwait-hook.sh"
RESOLV="${TMP}/resolv.conf"
sed -e "s#/sys/class/net#${MOCK_NET}#g" -e "s#/etc/resolv.conf#${RESOLV}#g" "${RAW}" > "${HOOK}"

# stub `ip` (the hook runs `ip link set <if> up`); no-op, always succeeds.
BIN="${TMP}/bin"; mkdir -p "${BIN}"
cat > "${BIN}/ip" <<'IPSTUB'
#!/usr/bin/env bash
exit 0
IPSTUB
chmod +x "${BIN}/ip"

# set_carrier IFACE VALUE  - create ${MOCK_NET}/IFACE/carrier holding VALUE (0|1).
set_carrier() {
    rm -rf "${MOCK_NET}"
    mkdir -p "${MOCK_NET}/$1"
    printf '%s\n' "$2" > "${MOCK_NET}/$1/carrier"
}

# run_case  - source the hook, set the mkinitcpio cmdline vars ($ip,$netwait), call
# run_hook under the ip stub, and record elapsed seconds + rc + captured msg log.
# Globals set: RC, ELAPSED, MSGLOG(file).
run_case() {
    local _ip="$1" _netwait="$2"
    MSGLOG="${TMP}/msg.log"; : > "${MSGLOG}"
    (
        PATH="${BIN}:${PATH}"
        msg() { printf '%s\n' "$*" >> "${MSGLOG}"; }
        ip="${_ip}"; netwait="${_netwait}"; partyos_dns="${3:-}"
        # shellcheck disable=SC1090
        . "${HOOK}"
        _s="$(date +%s)"
        run_hook; _rc=$?
        _e="$(date +%s)"
        printf '%s %s\n' "${_rc}" "$((_e - _s))" > "${TMP}/result"
    )
    RC="$(cut -d' ' -f1 "${TMP}/result")"
    ELAPSED="$(cut -d' ' -f2 "${TMP}/result")"
}

# --- CASE 1: no ip= on the cmdline -> immediate return (reads ${ip} guard) -----
set_carrier eth0 0
run_case "" 5
assert_eq "${RC}" "0" "no ip= (not a netboot): run_hook returns 0"
assert_true "$([ "${ELAPSED}" -le 1 ] && echo 0 || echo 1)" "no ip=: returns immediately (${ELAPSED}s) - the netboot guard reads \${ip}"

# --- CASE 2: ip=dhcp + carrier DOWN -> BOUNDED wait, then WARN (NOT a no-op) ---
set_carrier eth0 0
run_case "dhcp" 2
assert_eq "${RC}" "0" "carrier down: run_hook still returns 0 (best-effort, never bricks boot)"
assert_true "$([ "${ELAPSED}" -ge 2 ] && echo 0 || echo 1)" "carrier down: actually WAITED ~netwait=2s (${ELAPSED}s) - proves the hook is NO LONGER a no-op"
assert_true "$([ "${ELAPSED}" -le 5 ] && echo 0 || echo 1)" "carrier down: the wait is BOUNDED (${ELAPSED}s <= netwait+slack), not an infinite hang"
assert_contains "$(cat "${MSGLOG}")" "WARN no carrier after 2s" "carrier down: logs the bounded-timeout WARN and proceeds to DHCP"

# --- CASE 3: ip=dhcp + carrier UP -> prompt return with "link up" log ----------
set_carrier eth0 1
run_case "dhcp" 30
assert_eq "${RC}" "0" "carrier up: run_hook returns 0"
assert_true "$([ "${ELAPSED}" -le 1 ] && echo 0 || echo 1)" "carrier up: returns PROMPTLY (${ELAPSED}s) even with netwait=30 - does not wait once link is present"
assert_contains "$(cat "${MSGLOG}")" "link up on eth0" "carrier up: logs the detected link"

# --- CASE 4: netwait= is honored - a smaller value waits less ------------------
set_carrier eth0 0
run_case "dhcp" 1
assert_true "$([ "${ELAPSED}" -ge 1 ] && [ "${ELAPSED}" -le 3 ] && echo 0 || echo 1)" "netwait=1 honored: bounded wait scales with the parsed param (${ELAPSED}s)"

# --- CASE 5: garbage netwait= is sanitised to the default (does not wedge/error)
# carrier UP so we don't sit through the 30s default; we only prove run_hook does not
# error out on a non-numeric netwait (the old `[ "" -lt "abc" ]` would throw).
set_carrier eth0 1
run_case "dhcp" "abc"
assert_eq "${RC}" "0" "garbage netwait=abc: sanitised, run_hook returns 0 (no arithmetic error)"

# --- CASE 6: partyos_dns= writes the lease DNS server to resolv.conf ---------
set_carrier eth0 1; rm -f "${RESOLV}"
run_case "10.0.0.5::10.0.0.1:255.255.255.0::eth0:none" 5 "10.0.0.53"
assert_eq "$(cat "${RESOLV}" 2>/dev/null)" "nameserver 10.0.0.53" "partyos_dns=10.0.0.53: resolv.conf gets that nameserver"

# --- CASE 7: empty partyos_dns= (no DNS in the lease) writes nothing ----------
set_carrier eth0 1; rm -f "${RESOLV}"
run_case "10.0.0.5::10.0.0.1:255.255.255.0::eth0:none" 5 ""
assert_true "$([ ! -e "${RESOLV}" ]; echo $?)" "empty partyos_dns=: resolv.conf is not written"

# ============================================================================
# partyos_routes hook: DHCP option 121
# ============================================================================
ROUTES="${REPO_ROOT}/scripts/build/files/rootfs/usr/lib/initcpio/hooks/partyos_routes"
[ -s "${ROUTES}" ] || { echo "FAIL: partyos_routes hook not found at ${ROUTES}"; exit 1; }
assert_contains "$(cat "${A5}")" 'archiso_pxe_common partyos_routes' "build inserts partyos_routes AFTER archiso_pxe_common"
assert_contains "$(cat "${REPO_ROOT}/scripts/build/files/rootfs.manifest")" 'usr/lib/initcpio/hooks/partyos_routes' "partyos_routes hook is in the rootfs manifest"
# The ip= of the BOOTIF handoff has no device field. systemd-network-generator rejects
# that form and fails on every boot, so the image masks it.
NETPROV="${REPO_ROOT}/scripts/build/phases/50-net-provision.sh"
assert_contains "$(grep -v '^[[:space:]]*#' "${NETPROV}")" 'ln -sf /dev/null "${ROOTFS}/etc/systemd/system/systemd-network-generator.service"' \
    "the image masks systemd-network-generator (it cannot parse the BOOTIF ip= form)"

# decode HEX - run the real decoder under POSIX sh; prints the routes, then rc=N.
decode() {
    sh -c '. "$1"; partyos_decode_routes "$2"; echo "rc=$?"' _ "${ROUTES}" "$1"
}
assert_eq "$(decode '18:0a:0d:24:0a:0d:25:65')" "10.13.36.0/24 10.13.37.101
rc=0" "decode: one /24 route (an example option 121)"
assert_eq "$(decode '00:0a:00:00:01')" "0.0.0.0/0 10.0.0.1
rc=0" "decode: a /0 default route"
assert_eq "$(decode '10:ac:10:c0:a8:01:01')" "172.16.0.0/16 192.168.1.1
rc=0" "decode: a /16 route"
assert_eq "$(decode '18:0a:0d:24:0a:0d:25:65:10:ac:10:0a:0d:25:01:00:0a:0d:25:01')" "10.13.36.0/24 10.13.37.101
172.16.0.0/16 10.13.37.1
0.0.0.0/0 10.13.37.1
rc=0" "decode: several routes (/24 + /16 + /0)"
assert_eq "$(decode '20:0a:01:02:03:0a:00:00:01')" "10.1.2.3/32 10.0.0.1
rc=0" "decode: a /32 host route"
assert_eq "$(decode '')" "rc=0" "decode: empty input gives no routes"
assert_eq "$(decode '18:0a:0d:24:0a:0d:25')" "rc=1" "decode: truncated router is malformed"
assert_eq "$(decode '21:0a:00:00:00:01:02:03:04:05')" "rc=1" "decode: width > 32 is malformed"
assert_eq "$(decode 'zz:00')" "rc=1" "decode: non-hex input is malformed"
assert_eq "$(decode '18:0a:0d:124:0a:0d:25:65')" "rc=1" "decode: a 3-digit byte is malformed"

# run_hook with a recording ip stub: the routes it adds and what it logs.
IPLOG="${TMP}/ip.log"
cat > "${BIN}/ip" <<IPSTUB
#!/usr/bin/env bash
echo "\$*" >> "${IPLOG}"
exit 0
IPSTUB
chmod +x "${BIN}/ip"
run_routes() {
    : > "${IPLOG}"; MSGLOG="${TMP}/msg.log"; : > "${MSGLOG}"
    ( PATH="${BIN}:${PATH}"
      msg() { printf '%s\n' "$*" >> "${MSGLOG}"; }
      ip="$1"; partyos_routes="$2"; bootif_dev="${3:-}"
      # shellcheck disable=SC1090
      . "${ROUTES}"; run_hook; echo "$?" > "${TMP}/result" )
    RC="$(cat "${TMP}/result")"
}
IPARG="10.13.37.56:::255.255.255.0::eth0:none"
run_routes "${IPARG}" "18:0a:0d:24:0a:0d:25:65:00:0a:0d:25:01"
assert_eq "${RC}" "0" "run_hook: returns 0 with routes"
assert_eq "$(cat "${IPLOG}")" "route del default
route replace 10.13.36.0/24 via 10.13.37.101
route replace default via 10.13.37.1" "run_hook: drops the option 3 default, adds the /24 and the default"
run_routes "${IPARG}" ""
assert_eq "$(cat "${IPLOG}")" "" "run_hook: empty partyos_routes= touches no routes"
run_routes "" "18:0a:0d:24:0a:0d:25:65"
assert_eq "$(cat "${IPLOG}")" "" "run_hook: no ip= (not a netboot) touches no routes"
run_routes "${IPARG}" "18:0a:0d"
assert_eq "${RC}" "0" "run_hook: malformed input still returns 0 (never aborts the boot)"
assert_eq "$(cat "${IPLOG}")" "" "run_hook: malformed input touches no routes (option 3 default kept)"
assert_contains "$(cat "${MSGLOG}")" "WARN bad partyos_routes=18:0a:0d" "run_hook: malformed input logs a named WARN"

# On-link route (router 0.0.0.0): the device comes from bootif_dev, which
# archiso_pxe_common sets from BOOTIF=. The cmdline ip= then has no device field.
ONLINK="18:0a:0d:24:00:00:00:00"
run_routes "10.13.37.65:::255.255.0.0" "${ONLINK}" "eth1"
assert_eq "$(cat "${IPLOG}")" "route del default
route replace 10.13.36.0/24 dev eth1" "run_hook: on-link route uses the BOOTIF device (eth1), not eth0"
run_routes "${IPARG}" "${ONLINK}"
assert_eq "$(cat "${IPLOG}")" "route del default
route replace 10.13.36.0/24 dev eth0" "run_hook: without bootif_dev, the device field of ip= is used"
run_routes "10.13.37.65:::255.255.0.0" "${ONLINK}"
assert_eq "$(cat "${IPLOG}")" "route del default
route replace 10.13.36.0/24 dev eth0" "run_hook: no bootif_dev and no device field falls back to eth0"

assert_summary "test-netwait-hook"
