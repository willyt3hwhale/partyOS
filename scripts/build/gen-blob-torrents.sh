#!/bin/bash
# gen-blob-torrents.sh - make a single-file .torrent for every game blob.
# If ANNOUNCE is set, bake the tracker URL into it.
#
# Output: server/games/<name>.squashfs.torrent next to each blob. Cheap to regen
# (mktorrent hashes at ~1GB/s), so this runs as part of the blob/catalog build.
#
# Needs mktorrent; macOS host has none, so it re-execs in an archlinux container.
set -euo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GDIR="${1:-$(cd "${SD}/../../server/games" && pwd)}"

if ! command -v mktorrent >/dev/null 2>&1; then
    if command -v pacman >/dev/null 2>&1; then
        printf '\nDisableSandbox\n' >> /etc/pacman.conf 2>/dev/null || true
        pacman -Sy --noconfirm --needed mktorrent >/dev/null 2>&1 || true
    fi
fi
if ! command -v mktorrent >/dev/null 2>&1; then
    echo "[torrents] no mktorrent -> running in archlinux container..."
    exec docker run --rm --platform linux/amd64 \
        -e WEBSEED="${WEBSEED:-}" -e ANNOUNCE="${ANNOUNCE:-}" \
        -v "$(cd "${SD}/../../server/games" && pwd):/g" -v "${SD}:/s:ro" archlinux:latest \
        bash /s/gen-blob-torrents.sh /g
fi

# piece_l SIZE_BYTES -> mktorrent -l exponent, scaled to blob size. A fixed -l 18
# (256 KiB) bloats the .torrent and the hashing on multi-GB proton blobs (a 4 GB blob =
# ~16k pieces = ~320 KiB of piece hashes). Tier it so the torrent + hash pass stay sane:
#   <1 GiB  -> 18 (256 KiB)   1-4 GiB -> 20 (1 MiB)   >4 GiB -> 21 (2 MiB)
# Conservative tiers. NB: re-generating an existing blob's torrent at a new piece size
# changes its info-hash (mktorrent hashes piece-size into the metadata) - expected; the
# new torrent supersedes the old one served next to the blob.
piece_l() {
    local b="${1:-0}"
    if   [ "${b}" -ge $((4*1024*1024*1024)) ]; then echo 21
    elif [ "${b}" -ge $((1*1024*1024*1024)) ]; then echo 20
    else echo 18; fi
}

# --- work --------------------------------------------------------------------
made=0
for sq in "${GDIR}"/*.squashfs; do
    [ -f "${sq}" ] || continue
    tor="${sq}.torrent"
    # Skip only when there's no web-seed / tracker to (re)bake and the torrent is
    # already fresh (blob not newer). With WEBSEED or ANNOUNCE set (deploy), always
    # regen - those deploy-specific URLs can change (both are top-level siblings of
    # `info`, so re-baking them does NOT change the info-hash).
    if [ -z "${WEBSEED:-}" ] && [ -z "${ANNOUNCE:-}" ] && [ -f "${tor}" ] && [ "${tor}" -nt "${sq}" ]; then
        continue
    fi
    # piece size scales with blob size; the announce URL comes from ANNOUNCE.
    # Overwrite any stale torrent.
    # WEBSEED is optional; make-blob.sh and add-blob.sh set it from --webseed. render.sh does not.
    # WEBSEED may be a COMMA-SEPARATED list (one per blob server in the failover set);
    # each becomes its own BEP19 -w entry so a client can web-seed from ANY blob host.
    # ATOMIC regen: never rm the live torrent before its replacement exists. A
    # destroy-before-create left a P2P-only blob unfetchable if mktorrent failed mid-hash
    # (no web-seed fallback), and opened a 404/partial window even on success. Hash into a
    # sibling .tmp (info-hash-stable: announce/web-seed are top-level siblings of info), then
    # mv -f (atomic rename, same dir) over the live file only on success. The stale-tmp rm
    # clears a prior crash's leftover, NOT the live torrent.
    tmp="${tor}.tmp"
    rm -f "${tmp}"
    ws=()
    if [ -n "${WEBSEED:-}" ]; then
        _oldifs="${IFS}"; IFS=','
        for _w in ${WEBSEED}; do
            _w="$(printf '%s' "${_w}" | tr -d '[:space:]')"
            [ -n "${_w}" ] && ws+=(-w "${_w%/}/$(basename "${sq}")")
        done
        IFS="${_oldifs}"
    fi
    # ANNOUNCE (BEP3 tracker): when set, embed the partyOS tracker as the announce URL
    # so clients discover peers over UNICAST (switch-independent, unlike LSD multicast).
    # The announce key is a top-level sibling of `info`, so it does NOT change the
    # info-hash. render.sh passes ANNOUNCE=http://<host>:6969/announce at deploy time.
    an=()
    [ -n "${ANNOUNCE:-}" ] && an=(-a "${ANNOUNCE}")
    L="$(piece_l "$(wc -c < "${sq}" | tr -d ' ')")"
    mktorrent -l "${L}" -n "$(basename "${sq}")" \
        -c "partyOS blob $(basename "${sq}" .squashfs)" \
        "${an[@]}" "${ws[@]}" -o "${tmp}" "${sq}" >/dev/null 2>&1 || { echo "[torrents] FAILED ${sq}"; rm -f "${tmp}"; continue; }
    mv -f "${tmp}" "${tor}"
    made=$((made+1))
    echo "[torrents] $(basename "${tor}")  ($(wc -c < "${tor}" | tr -d ' ') bytes)"
done
echo "[torrents] done: ${made} (re)generated in ${GDIR}"
