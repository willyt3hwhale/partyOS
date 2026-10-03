#!/usr/bin/env bash
# test-lan-bcast-route.sh - hardware-free test of the routes that partyos-lpd-route adds.
#
# If DHCP gives no gateway, there is no default route. Then a sendto() to
# 255.255.255.255 fails with ENETUNREACH, and the Warcraft III LAN game list
# stays empty. partyos-lpd-route must add 255.255.255.255/32 and 239.0.0.0/8
# on the LAN interface. This test asserts:
#   1. With no routes, the script adds both routes on the carrier-up LAN NIC.
#   2. If 239.0.0.0/8 is already present, the script still adds the broadcast route.
#   3. If both routes are present, the script adds nothing.
#   4. A "File exists" error from ip is a success, and the script exits 0.
# The script logic is the real code. Only /sys and the error file path are rewritten.
# A stub ip on PATH records each call. No network, no root.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

SRC="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-lpd-route"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-bcast-route-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/bin" "${TMP}/sys/enp1s0"
echo up > "${TMP}/sys/enp1s0/operstate"
echo 1 > "${TMP}/sys/enp1s0/carrier"
sed -e "s#/sys/class/net#${TMP}/sys#g" \
    -e "s#/tmp/.lpd-route.err#${TMP}/route.err#g" \
    "${SRC}" > "${TMP}/lpd-route"

# Stub ip. ${TMP}/routes holds the present routes, one "<dst> dev <if>" per line.
# If ${TMP}/add-fails exists, "ip route add" fails with "File exists".
cat > "${TMP}/bin/ip" <<EOF
#!/bin/bash
echo "ip \$*" >> "${TMP}/calls"
case "\$*" in
  "-o -4 route show default") exit 0 ;;
  "-o -4 addr show scope global")
    echo "2: enp1s0    inet 192.0.2.10/22 brd 192.0.2.255 scope global enp1s0"; exit 0 ;;
  "route show "*) grep -F "\$3 dev" "${TMP}/routes" 2>/dev/null; exit 0 ;;
  "route add "*)
    if [ -e "${TMP}/add-fails" ]; then echo "RTNETLINK answers: File exists" >&2; exit 2; fi
    echo "\$3 dev \$5" >> "${TMP}/routes"; exit 0 ;;
esac
exit 0
EOF
chmod +x "${TMP}/bin/ip"

run() { : > "${TMP}/calls"; out="$(PATH="${TMP}/bin:${PATH}" bash "${TMP}/lpd-route" 2>&1)"; rc=$?; }

# --- 1. no routes: both are added on the LAN NIC ----------------------------
: > "${TMP}/routes"
run
assert_true "${rc}" "exit 0 with no routes present"
assert_contains "$(cat "${TMP}/calls")" "ip route add 255.255.255.255/32 dev enp1s0" \
    "adds the limited broadcast route on the LAN NIC"
assert_contains "$(cat "${TMP}/calls")" "ip route add 239.0.0.0/8 dev enp1s0" \
    "still adds the LPD multicast route"
assert_contains "${out}" "added 255.255.255.255/32 dev enp1s0" "logs the broadcast route add"

# --- 2. 239/8 present: the broadcast route is still added -------------------
echo "239.0.0.0/8 dev enp1s0" > "${TMP}/routes"
run
assert_true "${rc}" "exit 0 with only the LPD route present"
assert_not_contains "$(cat "${TMP}/calls")" "ip route add 239.0.0.0/8" "does not re-add the LPD route"
assert_contains "$(cat "${TMP}/calls")" "ip route add 255.255.255.255/32 dev enp1s0" \
    "adds the broadcast route when the LPD route already exists"

# --- 3. both present: nothing is added ---------------------------------------
printf '239.0.0.0/8 dev enp1s0\n255.255.255.255/32 dev enp1s0\n' > "${TMP}/routes"
run
assert_true "${rc}" "exit 0 with both routes present"
assert_not_contains "$(cat "${TMP}/calls")" "route add" "adds no route when both are present"

# --- 4. "File exists" from ip is a success ----------------------------------
: > "${TMP}/routes"; touch "${TMP}/add-fails"
run
assert_true "${rc}" "exit 0 when ip route add reports File exists"
assert_contains "${out}" "255.255.255.255/32 dev enp1s0 already existed" \
    "a concurrent broadcast route is logged as present"
rm -f "${TMP}/add-fails"

assert_summary test-lan-bcast-route
