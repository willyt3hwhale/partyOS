#!/usr/bin/env bash
# boot-config.sh - per-boot script that the server gives to each client.
# The client fetches and runs it before the desktop starts. A failure is not fatal.
# Edit this file on the server to change the clients without an image rebuild.
# The last line prints the PARTYOS-SERVER-CONFIG marker that step9-script.sh checks.

set -u

# Operator value sent back in the client callback. Keep it URL-safe (no spaces).
PARTYOS_ANNOUNCE="${PARTYOS_ANNOUNCE:-GLHF-LANPARTY}"
PARTYOS_MOTD="${PARTYOS_MOTD:-Welcome to the LAN party - GLHF}"
CONFIG_TAG="server-boot-$(date +%Y%m%d)"

# 1. Apply a server-driven config change on the client (the "effect").
#    /etc/partyos is a live tmpfs path on the RAM-booted system.
install -d /etc/partyos 2>/dev/null || mkdir -p /etc/partyos
{
    echo "ANNOUNCE=${PARTYOS_ANNOUNCE}"
    echo "CONFIG_TAG=${CONFIG_TAG}"
    echo "APPLIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > /etc/partyos/server-config

# A server-driven message-of-the-day - a concrete, visible config change.
echo "${PARTYOS_MOTD}" > /etc/motd 2>/dev/null || true

# OPTIONAL: pin the DNS server on every client (off by default).
# By default the client uses the DNS server from its DHCP lease (the venue DNS).
# The image has no public fallback DNS. If the venue DHCP gives a wrong DNS server,
# pin the correct one here. No image rebuild is necessary.
# To use it:
#   1. Set VENUE_DNS to the IP address of the venue DNS server.
#   2. Remove the "#" from the 3 lines below.
#   3. Save this file on the server. Each client applies it at its next boot.
# The setting lives in RAM only. It applies to the interface of the default route.
#VENUE_DNS="192.0.2.53"
#_dns_if="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
#[ -n "${_dns_if}" ] && resolvectl dns "${_dns_if}" "${VENUE_DNS}" && resolvectl domain "${_dns_if}" "~."

# 2. Print the marker line that step9-script.sh checks.
echo "PARTYOS-SERVER-CONFIG announce=${PARTYOS_ANNOUNCE} tag=${CONFIG_TAG}"

exit 0
