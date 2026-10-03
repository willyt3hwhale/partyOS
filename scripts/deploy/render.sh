#!/usr/bin/env bash
# render.sh - render the served boot script from deploy.conf.
#
# Reads deploy.conf (the ONE file you edit for a real build) and writes
# boot/partyos.ipxe from boot/partyos.ipxe.prod.tmpl, injecting the PXE server URL
# plus the extra kernel params the in-guest scripts need. blob_urls=/blob_url=/
# mirror_url= are emitted ONLY when they point at a different machine than the PXE
# server (in the common single-box setup the in-guest scripts fall back to the
# PXE/report server, so no redundant params clutter the cmdline). blob_urls= is the
# ordered failover list the new in-guest consumer reads; blob_url= (singular, first
# base) is kept for back-compat. irc_server= + portal_url= are always emitted
# (genuinely separate services the client cannot derive).
#
# Usage: scripts/deploy/render.sh [deploy.conf]
#
# Output-path override envs (a non-apply / dry-run / verification run sets these so a
# TEST render NEVER clobbers the LIVE served outputs - the default = today's live paths,
# so a normal operator run is UNCHANGED):
#   BOOT_IPXE_OUT   rendered boot script path    (default: <repo>/boot/partyos.ipxe)
#   PORTAL_OUT      rendered portal/homepage      (default: <repo>/portal/index.html)
#   TORRENTS        'skip' to NOT (re)generate the per-blob web-seed torrents (a test
#                   render does not need real torrents, and regen would mutate the LIVE
#                   server/games/*.torrent). Any value but 'skip' = generate (default).
# Setting BOOT_IPXE_OUT (the "off the live paths" signal) without TORRENTS forces skip
# too, so a single redirect flips the WHOLE render off the live serving state.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
CONF="${1:-${REPO_ROOT}/deploy.conf}"
TMPL="${REPO_ROOT}/boot/partyos.ipxe.prod.tmpl"
OUT="${REPO_ROOT}/boot/partyos.ipxe"
# Output-path override: a redirected (non-live) render points OUT at a temp path so the
# live boot/partyos.ipxe is never touched. Default stays the live path (unchanged for a
# normal operator run). Whether OUT was redirected drives the portal + torrents redirect.
LIVE_OUT="${OUT}"
OUT="${BOOT_IPXE_OUT:-${OUT}}"
# A redirected boot output means a test/dry-run render: skip the live torrents unless the
# caller said otherwise so a test render never mutates the live server/games/*.torrent.
if [ "${OUT}" != "${LIVE_OUT}" ]; then
    TORRENTS="${TORRENTS:-skip}"
fi
TORRENTS="${TORRENTS:-generate}"
mkdir -p "$(dirname "${OUT}")"

[ -f "${CONF}" ] || { echo "render: deploy.conf not found: ${CONF}" >&2; exit 1; }
[ -f "${TMPL}" ] || { echo "render: template not found: ${TMPL}" >&2; exit 1; }

# Read KEY=value lines (ignore comments/blanks). Plain parse, never sourced.
get() { grep -E "^${1}=" "${CONF}" | tail -1 | cut -d= -f2- | tr -d '[:space:]'; }
PXE_SERVER="$(get PXE_SERVER)"
BLOB_SERVERS="$(get BLOB_SERVERS)"
BLOB_SERVER="$(get BLOB_SERVER)"
MIRROR_SERVER="$(get MIRROR_SERVER)"
IRC_SERVER="$(get IRC_SERVER)"
PORTAL_PATH="$(get PORTAL_PATH)"
BOOT_CONFIG_URL="$(get BOOT_CONFIG_URL)"
BLOB_CACHE_RESERVE_GB="$(get BLOB_CACHE_RESERVE_GB)"
BLOB_CACHE_MAX_GB="$(get BLOB_CACHE_MAX_GB)"
BLOB_SEEDING="$(get BLOB_SEEDING)"
BLOB_SEED_UP_LIMIT="$(get BLOB_SEED_UP_LIMIT)"
USB_HOME_LABELS="$(get USB_HOME_LABELS)"
USB_SHARE_LABELS="$(get USB_SHARE_LABELS)"

[ -n "${PXE_SERVER}" ] || { echo "render: PXE_SERVER is required in ${CONF}" >&2; exit 1; }
PXE_URL="http://${PXE_SERVER}"
# SFS_URL is the HTTPS base the initramfs copytoram hook fetches airootfs.sfs from
# (archiso_http_srv=). It is computed below, after https_base() is defined.

# --- HTTPS port mapping ------------------------------------------------------
# All client fetches use HTTPS with the pinned CA baked into the image
# (/etc/partyos/ca.pem).
#
# https_base HOST[:PORT] -> https://HOST:(PORT+HTTPS_PORT_OFFSET). The offset (+363,
# 8080->8443) matches run-servers.sh, where each server's HTTPS listener
# sits at its HTTP port + offset. A bare host with no port assumes 8080 (the same
# default run-servers.sh/http_server.py use) -> 8443. The HTTPS leaf SAN pins the
# server IP, so clients verify host-vs-cert with the baked --cacert.
HTTPS_PORT_OFFSET="${HTTPS_PORT_OFFSET:-363}"   # 8080 -> 8443 by default
https_base() {
    local hp="$1" host port
    case "${hp}" in
        *:*) host="${hp%%:*}"; port="${hp##*:}";;
        *)   host="${hp}";     port="8080";;
    esac
    case "${port}" in ''|*[!0-9]*) port="8080";; esac   # tolerate a bad/empty port
    printf 'https://%s:%s' "${host}" "$(( port + HTTPS_PORT_OFFSET ))"
}

# --- resolve the ordered blob-server list ------------------------------------
# Canonical key BLOB_SERVERS (CSV of host:port, ordered failover). Fall back to the
# legacy singular BLOB_SERVER, then to PXE_SERVER (today's single-box behaviour).
# Build a parallel list of full https://host:port bases (BLOB_URLS) the client reads.
# The in-guest blob_fetch passes the baked --cacert. In the single-box case
# (BLOB == PXE) these params are omitted and the in-guest scripts fall back to
# report_url=.
BLOB_SET="${BLOB_SERVERS:-${BLOB_SERVER:-${PXE_SERVER}}}"
# PXE_HTTPS is the https mapping of the PXE server - used to decide whether the blob
# set collapses onto the PXE box (then the params are omitted, single-box optimisation).
PXE_HTTPS="$(https_base "${PXE_SERVER}")"
# SFS_URL: the initramfs copytoram sfs fetch (archiso_http_srv=) uses HTTPS, pinned to
# the CA bundled into the initramfs at /etc/partyos/ca.pem.
SFS_URL="${PXE_HTTPS}"
BLOB_URLS=""        # CSV of full base-URLs (blob_urls=)
BLOB_FIRST=""       # first base-URL (blob_url=, back-compat)
_oldifs="${IFS}"; IFS=','
for _bs in ${BLOB_SET}; do
    _bs="$(printf '%s' "${_bs}" | tr -d '[:space:]')"   # tolerate stray spaces in the CSV
    [ -n "${_bs}" ] || continue
    _url="$(https_base "${_bs}")"
    BLOB_URLS="${BLOB_URLS:+${BLOB_URLS},}${_url}"
    [ -n "${BLOB_FIRST}" ] || BLOB_FIRST="${_url}"
done
IFS="${_oldifs}"

# Build the extra kernel params (each piece leads with a space).
# Emit the blob params ONLY when the blob set is non-empty AND not just the PXE
# server (the single-box optimisation - then the in-guest scripts fall back to the
# PXE/report server and the cmdline stays clean). blob_urls= is the failover list
# the new consumer reads; blob_url= (first base) is kept for back-compat consumers.
EXTRA=""
# Single-box collapse compares the https-mapped blob list against the https-mapped PXE
# base (BLOB_URLS is https now, so compare https-vs-https, not against the http PXE_URL).
if [ -n "${BLOB_URLS}" ] && [ "${BLOB_URLS}" != "${PXE_HTTPS}" ]; then
    EXTRA="${EXTRA} blob_urls=${BLOB_URLS}"
    EXTRA="${EXTRA} blob_url=${BLOB_FIRST}"
fi
# mirror_url= / portal_url= use HTTPS: pacman trusts the baked CA via the
# system trust anchor; portal-fetch passes the baked --cacert.
[ -n "${MIRROR_SERVER}" ] && [ "${MIRROR_SERVER}" != "${PXE_SERVER}" ] && EXTRA="${EXTRA} mirror_url=$(https_base "${MIRROR_SERVER}")"
[ -n "${IRC_SERVER}" ]    && EXTRA="${EXTRA} irc_server=${IRC_SERVER}"
[ -n "${PORTAL_PATH}" ]   && EXTRA="${EXTRA} portal_url=$(https_base "${PXE_SERVER}")${PORTAL_PATH}"
# Operator boot-config hook: emit config_url= only when BOOT_CONFIG_URL is set in
# deploy.conf. If it is unset, step3-script.sh never fetches it. The value is a
# host:port[/path]. step3-script.sh fetches it over HTTPS with the baked --cacert and
# runs it as root before the desktop, and tolerates any failure. https_base maps the
# host:port; a trailing /path is kept.
if [ -n "${BOOT_CONFIG_URL}" ]; then
    case "${BOOT_CONFIG_URL}" in
        */*) _bc_hp="${BOOT_CONFIG_URL%%/*}"; _bc_path="/${BOOT_CONFIG_URL#*/}";;
        *)   _bc_hp="${BOOT_CONFIG_URL}";     _bc_path="";;
    esac
    EXTRA="${EXTRA} config_url=$(https_base "${_bc_hp}")${_bc_path}"
fi
# USB blob-cache budget: only emit when set (in-guest defaults apply otherwise).
[ -n "${BLOB_CACHE_RESERVE_GB}" ] && EXTRA="${EXTRA} blob_cache_reserve_gb=${BLOB_CACHE_RESERVE_GB}"
[ -n "${BLOB_CACHE_MAX_GB}" ]     && EXTRA="${EXTRA} blob_cache_max_gb=${BLOB_CACHE_MAX_GB}"
[ -n "${BLOB_SEEDING}" ]          && EXTRA="${EXTRA} blob_seeding=${BLOB_SEEDING}"
[ -n "${BLOB_SEED_UP_LIMIT}" ]    && EXTRA="${EXTRA} blob_seed_up_limit=${BLOB_SEED_UP_LIMIT}"
# Partition labels of the player stick (partyos-usb-labels.sh reads them): only emit
# when set (the image has the same defaults baked in). An ordered comma list of
# labels. Refuse other characters: they would break the kernel cmdline.
for _lk in USB_HOME_LABELS USB_SHARE_LABELS; do
    _lv="${!_lk}"
    [ -n "${_lv}" ] || continue
    [[ "${_lv}" =~ ^[A-Za-z0-9_-]{1,16}(,[A-Za-z0-9_-]{1,16})*$ ]] \
        || { echo "render: ${_lk} must be a comma list of labels (A-Z a-z 0-9 _ -, 1 to 16 characters each): '${_lv}'" >&2; exit 1; }
    EXTRA="${EXTRA} $(printf '%s' "${_lk}" | tr '[:upper:]' '[:lower:]')=${_lv}"
done

# Substitute (| delimiter so URLs with / are safe). The boot template's iPXE-level
# fetches (kernel/initrd/script/report) use {{PXE_HTTPS}}, so the whole boot chain is
# HTTPS with the pinned CA. The portal template below also uses {{PXE_URL}}.
# Self-guard: log the ABSOLUTE path we are about to overwrite so an accidental LIVE
# clobber (a test/dry-run render that escaped its redirect) is unmistakable in the output.
echo "render: writing $(cd "$(dirname "${OUT}")" && pwd)/$(basename "${OUT}")" >&2
sed -e "s|{{PXE_HTTPS}}|${PXE_HTTPS}|g" \
    -e "s|{{PXE_URL}}|${PXE_URL}|g" \
    -e "s|{{SFS_URL}}|${SFS_URL}|g" \
    -e "s|{{EXTRA_PARAMS}}|${EXTRA}|g" \
    "${TMPL}" > "${OUT}"

# Render the portal/homepage too (served at ${PXE_HTTPS}${PORTAL_PATH}). PORTAL_OUT can be
# overridden to a temp path (a redirected boot render points it off the live portal too).
PORTAL_TMPL="${REPO_ROOT}/portal/index.html.tmpl"
PORTAL_OUT="${PORTAL_OUT:-${REPO_ROOT}/portal/index.html}"
mkdir -p "$(dirname "${PORTAL_OUT}")"
if [ -f "${PORTAL_TMPL}" ]; then
    echo "render: writing $(cd "$(dirname "${PORTAL_OUT}")" && pwd)/$(basename "${PORTAL_OUT}")" >&2
    # Every portal link goes HTTPS: the browser opens these and trusts the baked CA
    # through the system trust store. {{PXE_URL}} gets the HTTPS base too, because
    # run-servers.sh disables the plaintext :8080 listener by default. A plaintext
    # link on the portal is a dead link.
    sed -e "s|{{PXE_URL}}|${PXE_HTTPS}|g" \
        -e "s|{{IRC_SERVER}}|${IRC_SERVER:-<unset>}|g" \
        -e "s|{{MIRROR_URL}}|$(https_base "${MIRROR_SERVER:-$PXE_SERVER}")|g" \
        -e "s|{{BLOB_URL}}|${BLOB_FIRST:-$PXE_HTTPS}|g" \
        "${PORTAL_TMPL}" > "${PORTAL_OUT}"
    echo "render: wrote ${PORTAL_OUT}"
fi

# Regenerate the SERVED game catalog from its tracked source. catalog.v2.json is the
# source of truth; catalog.json is what the client fetches (partyos-app, partyos-seed).
# Every path that edits the catalog - the event wizard's "drop titles", a blob build, a
# hand edit - has to be followed by this render, and each one is a chance to forget. The
# render is the step nobody skips before serving, so it owns the regeneration. The
# `build-game-blobs.sh --check` drift guard in `make test-prod` is the backstop.
# A redirected (test/dry-run) render must not touch the live catalog, so it is skipped
# when BOOT_IPXE_OUT points off the live path. TORRENTS=skip alone does NOT skip it: the
# catalog render reads only catalog.v2.json, never deploy.conf, so it cannot carry a test
# address into the served file - it can only ever write the correct current content.
CATALOG_V2_SRC="${REPO_ROOT}/server/games/catalog.v2.json"
if [ "${OUT}" != "${LIVE_OUT}" ]; then
    echo "render: SKIP catalog render (redirected render; live server/games/catalog.json untouched)" >&2
elif [ -f "${CATALOG_V2_SRC}" ]; then
    bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" "${REPO_ROOT}/server/games" >/dev/null \
        || { echo "render: catalog render FAILED from ${CATALOG_V2_SRC}" >&2; exit 1; }
    echo "render: rendered server/games/catalog.json from catalog.v2.json"
else
    echo "render: no catalog.v2.json - nothing to render into catalog.json" >&2
fi

# Per-blob torrents announce to the partyOS BitTorrent TRACKER for UNICAST peer
# discovery (switch-independent, unlike LSD multicast which some managed switches
# drop). Blob distribution is P2P ONLY: the BEP19 web-seed is DELIBERATELY DROPPED,
# so a completed download is unambiguous proof of a live swarm - there is no HTTP
# source that could mask a dead one. The tracker runs on the blob/PXE host at the
# fixed port 6969 (see run-servers.sh + server/bt_tracker.py). The announce key is a
# top-level sibling of `info`, so baking it does NOT change any blob's info-hash.
ANNOUNCE_HOST="${BLOB_SET%%,*}"         # first blob server (host[:port])
ANNOUNCE_HOST="${ANNOUNCE_HOST%%:*}"    # strip the port -> bare host
[ -n "${ANNOUNCE_HOST}" ] || ANNOUNCE_HOST="${PXE_SERVER%%:*}"
ANNOUNCE="http://${ANNOUNCE_HOST}:6969/announce"
if [ "${TORRENTS}" = skip ]; then
    # A redirected (test/dry-run) render must NOT touch the live server/games/*.torrent,
    # so the torrent step is skipped entirely. Self-guard: say so unmistakably.
    echo "render: SKIP blob torrents (TORRENTS=skip; live server/games/*.torrent untouched)" >&2
elif ls "${REPO_ROOT}/server/games"/*.squashfs >/dev/null 2>&1; then
    echo "render: writing tracker-announced (P2P-only, no web-seed) torrents in $(cd "${REPO_ROOT}/server/games" && pwd)/*.torrent" >&2
    if ANNOUNCE="${ANNOUNCE}" bash "${REPO_ROOT}/scripts/build/gen-blob-torrents.sh" >/dev/null 2>&1; then
        echo "render: generated blob torrents (announce ${ANNOUNCE}, no web-seed - P2P only)"
    else
        echo "render: WARN blob torrent generation failed (P2P off; clients cannot fetch blobs)"
    fi
fi

# The whole boot chain (iPXE chain, kernel, initrd, sfs, step3 script, report channel)
# uses HTTPS, validated against the party CA embedded in the EFI binary, the initramfs
# and the rootfs. Recovery: point PXE_HTTPS at http://, re-render and re-serve. No
# re-flash is needed.
echo "render: wrote ${OUT}"
echo "  kernel/initrd : ${PXE_HTTPS} (HTTPS - iPXE-level fetches, pinned CA)"
echo "  script/report : ${PXE_HTTPS} (HTTPS - step3 script= + report channel)"
echo "  sfs fetch     : ${SFS_URL}/server/images/custom/ (HTTPS - initramfs copytoram, pinned CA)"
echo "  sfs check     : checksum (archiso verifies airootfs.sfs vs served airootfs.sha512, defense-in-depth)"
echo "  blobs         : ${BLOB_URLS:-$PXE_HTTPS}$([ "${BLOB_URLS}" = "${PXE_HTTPS}" ] || [ -z "${BLOB_URLS}" ] && echo ' (= PXE, params omitted; in-guest falls back to report_url= HTTPS)' || echo " (HTTPS failover order; blob_urls= emitted)")"
echo "  mirror        : $(https_base "${MIRROR_SERVER:-$PXE_SERVER}")$([ "${MIRROR_SERVER:-$PXE_SERVER}" = "${PXE_SERVER}" ] && echo ' (= PXE, param omitted)')"
echo "  irc           : ${IRC_SERVER:-<unset>}"
echo "  portal        : $(https_base "${PXE_SERVER}")${PORTAL_PATH:-<unset>}"
echo "  stick labels  : home ${USB_HOME_LABELS:-<baked default>}, share ${USB_SHARE_LABELS:-<baked default>}"
echo "  boot-config   : $([ -n "${BOOT_CONFIG_URL}" ] && echo "config_url=HTTPS (operator hook ON)" || echo '<unset> (config_url= omitted, operator hook OFF)')"
echo "  -> NOTHING on plain HTTP in the boot chain (chain+kernel+initrd+sfs+script+report all HTTPS:8443, pinned CA)"
