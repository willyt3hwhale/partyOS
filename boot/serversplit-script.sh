#!/usr/bin/env bash
# serversplit-script.sh - autonomous in-guest verifier for server split, fetched
# at boot via archiso's automated-script hook (partyos-serversplit.ipxe passes
# script=<netboot>/boot/serversplit-script.sh). Runs on the tty1 root autologin
# once the live system is up, mirroring everything to the serial console the
# harness scrapes.
#
# The split it proves:
#   * The BOOT IMAGE (kernel/initramfs/squashfs) was already served by the NETBOOT
#     server (report_url=). This script does NOT touch the netboot server for any
#     blob - it fetches the catalog + every blob from the INDEPENDENT blob-server
#     URL list (blob_urls=URL1,URL2,...), trying each in order until one answers
#     (FAILOVER). The first blob URL that successfully serves a file wins.
#   * Because the blob URLs are a different listener (different port) than the
#     netboot/report server, the HOST can later show in its per-listener access
#     logs that boot came from the netboot listener and blobs from a blob listener.
#   * FAILOVER: if the first blob URL does not answer (server down / wrong port),
#     the client transparently uses the next URL. The harness drives this by
#     KILLING the first blob server on a later boot; this script reports which
#     blob URL actually served, so failover is observable end to end.
#
# Reuses the Step 7 squashfs+overlay mount + dummy-game run, only the SOURCE of
# the catalog + blobs changes (blob server list instead of the single hub).
#
# Markers (greppable on serial):
#   PARTYOS-SS-BLOB-URLS list=<csv>                    the configured failover list
#   PARTYOS-SS-CATALOG-OK n=<count> via=<blob-url>     catalog fetched (which URL won)
#   PARTYOS-SS-BLOB-DOWNLOADED name=.. via=<blob-url>  a blob downloaded (which URL won)
#   PARTYOS-SS-FAILOVER from=<dead-url> to=<live-url>  a blob URL was skipped, next used
#   PARTYOS-SS-MOUNTED name=.. at=..                   blob mounted via squashfs+overlay
#   PARTYOS-SS-GAME-RAN name=.. marker=..              the dummy game ran from its mount
#   PARTYOS-SS-READY                                   all blobs served from a blob server
#   PARTYOS-SS-ALIVE                                   heartbeats proving the system stays up
# HTTP callback (report_url = the NETBOOT/report server, no hardcoded IP):
#   step=serversplit status=ok games=<n> mounted=<n> ran=<n> blob_url=<url> failover=<0|1>

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

# netboot/report base + the INDEPENDENT blob-server URL list from the kernel
# cmdline (no hardcoded IP). report_url= is the netboot/report server; blob_urls=
# is the comma-separated failover list of blob-server base-URLs.
report_base=""
blob_urls_csv=""
for p in $(< /proc/cmdline); do case "$p" in
    report_url=*) report_base="${p#*=}";;
    blob_urls=*)  blob_urls_csv="${p#*=}";;
esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-SERVERSPLIT-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }
# If no blob list was passed, fall back to the report/netboot server (single-hub
# compatibility) so the script still works without the split configured.
[ -n "${blob_urls_csv}" ] || blob_urls_csv="${report_base}"

# Split the CSV into an ordered array of blob base-URLs.
IFS=',' read -r -a BLOB_URLS <<< "${blob_urls_csv}"

# resolve the desktop user: identity-setup renames the uid-1000 account
# gamer->USER_NAME and publishes the name to /run/partyos-username. NEVER hardcode
# 'gamer' - after a rename it does not exist.
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
HOME_DIR="/home/${USER_NAME}"

GAMES_DIR="${HOME_DIR}/games"
CACHE_DIR="/var/cache/partyos/games"
MNT_BASE="/run/partyos-games"
CATALOG_REL="server/games/catalog.json"

say "PARTYOS-SS boot script started (server split: netboot vs blob)"
say "PARTYOS-SS report/netboot base=${report_base}"
say "PARTYOS-SS-BLOB-URLS list=${blob_urls_csv} count=${#BLOB_URLS[@]}"

install -d "${CACHE_DIR}" "${MNT_BASE}"
install -d -o "${USER_NAME}" -g "${USER_NAME}" "${GAMES_DIR}"

modprobe squashfs 2>/dev/null || true
modprobe overlay  2>/dev/null || true
modprobe loop     2>/dev/null || true

# fetch_from_blobs REL_PATH OUT_FILE -> tries each blob base-URL in order; on the
# first success sets WON_URL to the base-URL that served it and returns 0. Tracks
# whether a FAILOVER happened (an earlier URL in the list did not answer). Returns
# 1 if NO blob URL answered.
WON_URL=""
DID_FAILOVER=0
fetch_from_blobs() {
    local rel="$1" out="$2"
    local skipped=""
    WON_URL=""
    local base
    for base in "${BLOB_URLS[@]}"; do
        [ -n "${base}" ] || continue
        if curl -fsS --max-time 20 --connect-timeout 5 -o "${out}" "${base}/${rel}" 2>/dev/null; then
            WON_URL="${base}"
            if [ -n "${skipped}" ]; then
                DID_FAILOVER=1
                say "PARTYOS-SS-FAILOVER from=${skipped} to=${base} (first blob URL did not answer)"
            fi
            return 0
        fi
        # this URL did not answer; remember it and fail over to the next.
        skipped="${base}"
    done
    return 1
}

# --- 1. fetch the catalog from a BLOB server (NOT the netboot server) ---------
CATALOG="/run/partyos-catalog.json"
say "PARTYOS-SS fetching catalog from blob server list (failover order)"
if ! fetch_from_blobs "${CATALOG_REL}" "${CATALOG}"; then
    say "PARTYOS-SS ERROR no blob server served the catalog"
    curl -s --max-time 5 "${report_base}/report?step=serversplit&status=fail&reason=catalog" >/dev/null 2>&1 || true
    sleep 5
    systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
    exit 1
fi
CATALOG_URL_USED="${WON_URL}"

mapfile -t NAMES   < <(grep -oE '"name":[[:space:]]*"[^"]*"'   "${CATALOG}" | sed -E 's/.*"name":[[:space:]]*"([^"]*)".*/\1/')
mapfile -t BLOBS   < <(grep -oE '"blob":[[:space:]]*"[^"]*"'   "${CATALOG}" | sed -E 's/.*"blob":[[:space:]]*"([^"]*)".*/\1/')
mapfile -t ENTRIES < <(grep -oE '"entry":[[:space:]]*"[^"]*"'  "${CATALOG}" | sed -E 's/.*"entry":[[:space:]]*"([^"]*)".*/\1/')
mapfile -t MARKERS < <(grep -oE '"marker":[[:space:]]*"[^"]*"' "${CATALOG}" | sed -E 's/.*"marker":[[:space:]]*"([^"]*)".*/\1/')
mapfile -t SHAS    < <(grep -oE '"sha256":[[:space:]]*"[^"]*"' "${CATALOG}" | sed -E 's/.*"sha256":[[:space:]]*"([^"]*)".*/\1/')

NGAMES="${#NAMES[@]}"
say "PARTYOS-SS-CATALOG-OK n=${NGAMES} via=${CATALOG_URL_USED} games=$(IFS=,; echo "${NAMES[*]}")"
if [ "${NGAMES}" -lt 1 ]; then
    say "PARTYOS-SS ERROR empty catalog"
    curl -s --max-time 5 "${report_base}/report?step=serversplit&status=fail&reason=empty-catalog" >/dev/null 2>&1 || true
    sleep 5
    systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
    exit 1
fi

# --- download + verify + mount one game from the blob server list ------------
mount_game() {
    local name="$1" blobpath="$2" sha="$3"
    local blob="${CACHE_DIR}/${name}.squashfs"
    local lower="${MNT_BASE}/${name}"
    local scratch="${MNT_BASE}/${name}.rw"
    local dest="${GAMES_DIR}/${name}"

    say "PARTYOS-SS downloading ${name} from blob server list"
    if ! fetch_from_blobs "${blobpath}" "${blob}"; then
        say "PARTYOS-SS ERROR no blob server served ${name}"; return 1
    fi
    local blob_url_used="${WON_URL}"
    if [ -n "${sha}" ] && command -v sha256sum >/dev/null 2>&1; then
        local got; got="$(sha256sum "${blob}" | awk '{print $1}')"
        if [ "${got}" != "${sha}" ]; then
            say "PARTYOS-SS ERROR ${name} sha mismatch got=${got} want=${sha}"; return 1
        fi
    fi
    say "PARTYOS-SS-BLOB-DOWNLOADED name=${name} via=${blob_url_used} bytes=$(wc -c < "${blob}" | tr -d ' ') sha_ok=1"

    install -d "${lower}" "${scratch}"
    install -d -o "${USER_NAME}" -g "${USER_NAME}" "${dest}"
    if ! mountpoint -q "${lower}"; then
        mount -t squashfs -o ro,loop "${blob}" "${lower}" 2>/dev/null \
          || mount -t squashfs -o ro "${blob}" "${lower}" 2>/dev/null \
          || { say "PARTYOS-SS ERROR squashfs mount ${name} failed"; return 1; }
    fi
    mountpoint -q "${scratch}" || mount -t tmpfs -o size=16M tmpfs "${scratch}" || true
    install -d "${scratch}/upper" "${scratch}/work"
    if ! mountpoint -q "${dest}"; then
        mount -t overlay overlay \
          -o "lowerdir=${lower},upperdir=${scratch}/upper,workdir=${scratch}/work" \
          "${dest}" 2>/dev/null \
          || { say "PARTYOS-SS ERROR overlay mount ${name} failed"; return 1; }
    fi
    chown "${USER_NAME}:${USER_NAME}" "${dest}" 2>/dev/null || true
    say "PARTYOS-SS-MOUNTED name=${name} at=${dest} src=squashfs+overlay"
    return 0
}

# --- 2-3. download + mount every catalog game from the blob servers ----------
declare -a MOUNTED=() RAN=() RAN_MARKERS=()
i=0
while [ "${i}" -lt "${NGAMES}" ]; do
    name="${NAMES[$i]}"; blob="${BLOBS[$i]}"; entry="${ENTRIES[$i]:-bin/run.sh}"
    marker="${MARKERS[$i]:-}"; sha="${SHAS[$i]:-}"
    i=$((i+1))
    if mount_game "${name}" "${blob}" "${sha}"; then
        MOUNTED+=("${name}")
        dest="${GAMES_DIR}/${name}"
        out=""
        if [ -f "${dest}/${entry}" ]; then
            out="$(sudo -u "${USER_NAME}" bash "${dest}/${entry}" 2>&1 || true)"
        else
            out="(no entry ${entry} in ${name})"
        fi
        say "PARTYOS-SS game ${name} output: ${out}"
        if [ -n "${marker}" ] && echo "${out}" | grep -qF "${marker}"; then
            RAN+=("${name}"); RAN_MARKERS+=("${marker}")
            say "PARTYOS-SS-GAME-RAN name=${name} marker=${marker}"
        else
            say "PARTYOS-SS WARN game ${name} did not emit expected marker"
        fi
    fi
done

NMOUNTED="${#MOUNTED[@]}"; NRAN="${#RAN[@]}"
say "PARTYOS-SS summary mounted=${NMOUNTED}/${NGAMES} ran=${NRAN}/${NGAMES} catalog_via=${CATALOG_URL_USED} failover=${DID_FAILOVER}"

# simultaneous-mount sanity (same as Step 7)
live=0
for n in "${MOUNTED[@]:-}"; do
    [ -z "${n}" ] && continue
    mountpoint -q "${GAMES_DIR}/${n}" && live=$((live+1))
done

# --- ready + callback (to the NETBOOT/report server) -------------------------
markers_csv="$(IFS=,; echo "${RAN_MARKERS[*]:-}")"
ready=0
if [ "${NMOUNTED}" -ge 2 ] && [ "${NRAN}" -ge 2 ] && [ "${live}" -ge 2 ]; then
    ready=1
    say "PARTYOS-SS-READY all blobs served from a blob server (catalog_via=${CATALOG_URL_USED} failover=${DID_FAILOVER})"
    curl -s --max-time 5 \
      "${report_base}/report?step=serversplit&status=ok&games=${NGAMES}&mounted=${NMOUNTED}&ran=${NRAN}&blob_url=${CATALOG_URL_USED}&failover=${DID_FAILOVER}&markers=${markers_csv}" \
      >/dev/null 2>&1 || say "PARTYOS-SS callback-failed (non-fatal)"
else
    say "PARTYOS-SS NOT ready (mounted=${NMOUNTED} ran=${NRAN} live=${live})"
    curl -s --max-time 5 \
      "${report_base}/report?step=serversplit&status=fail&games=${NGAMES}&mounted=${NMOUNTED}&ran=${NRAN}&blob_url=${CATALOG_URL_USED}&failover=${DID_FAILOVER}" \
      >/dev/null 2>&1 || true
fi

# --- heartbeats: prove the system stays up with games mounted ----------------
i=0
while [ "${i}" -lt 20 ]; do
    sleep 2; i=$((i+1))
    live_now=0
    for n in "${MOUNTED[@]:-}"; do
        [ -z "${n}" ] && continue
        mountpoint -q "${GAMES_DIR}/${n}" && live_now=$((live_now+1))
    done
    say "PARTYOS-SS-ALIVE heartbeat ${i} mounted=${live_now} ready=${ready}"
    [ "${ready}" -eq 1 ] && [ "${i}" -ge 6 ] && break
done

say "PARTYOS-SS stay-up window complete, powering off"
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
