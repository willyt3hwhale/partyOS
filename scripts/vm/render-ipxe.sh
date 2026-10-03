#!/usr/bin/env bash
# render-ipxe.sh - render an iPXE template, substituting {{SERVER_URL}} with the
# configured SERVER_URL so no IP address is hardcoded in any served script.
#
# Usage:
#   render-ipxe.sh [TEMPLATE] [OUTPUT]
# Defaults:
#   TEMPLATE = boot/partyos.ipxe.tmpl
#   OUTPUT   = boot/partyos.ipxe.vm  (the VM-served script - a SEPARATE path from
#              the LIVE prod boot/partyos.ipxe that scripts/deploy/render.sh writes,
#              so a VM render/test can NEVER clobber the served prod boot script).
#
# SERVER_URL comes from config.sh (10.0.2.2:8080 on SLIRP by default) but can be
# overridden via the environment for dnsmasq/vmnet networks.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

TMPL="${1:-${REPO_ROOT}/boot/partyos.ipxe.tmpl}"
# Default OUT is the VM-specific served path (config.sh VM_IPXE_OUT), NOT the live
# prod boot/partyos.ipxe - so a no-arg VM render can never overwrite the prod boot
# script. Explicit callers (test-stepN) still pass their own temp OUT.
OUT="${2:-${VM_IPXE_OUT:-${REPO_ROOT}/boot/partyos.ipxe.vm}}"

[ -f "${TMPL}" ] || die "render-ipxe: template not found: ${TMPL}"

# Substitute every placeholder. SERVER_URL is the single-hub default; the server
# split adds independent NETBOOT_URL + BLOB_URLS, so render those too. They
# default to SERVER_URL-derived values in config.sh but are overridable.
sed -e "s|{{SERVER_URL}}|${SERVER_URL}|g" \
    -e "s|{{NETBOOT_URL}}|${NETBOOT_URL:-${SERVER_URL}}|g" \
    -e "s|{{BLOB_URLS}}|${BLOB_URLS:-${SERVER_URL}}|g" \
    -e "s|{{HOMESVC_EXPECT}}|${HOMESVC_EXPECT:-service}|g" \
    -e "s|{{HOMESVC_NAME}}|${HOMESVC_NAME:-partysvc}|g" \
    -e "s|{{HOMESVC_PORT}}|${HOMESVC_PORT:-8099}|g" \
    -e "s|{{EXFATSPLIT_COMPAT}}|${EXFATSPLIT_COMPAT:-split}|g" \
    "${TMPL}" > "${OUT}"
log "rendered ${OUT} (SERVER_URL=${SERVER_URL} NETBOOT_URL=${NETBOOT_URL:-} BLOB_URLS=${BLOB_URLS:-} HOMESVC_EXPECT=${HOMESVC_EXPECT:-})"
