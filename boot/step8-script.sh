#!/usr/bin/env bash
# step8-script.sh - autonomous in-guest game-blob CACHING bring-up + verifier for
# Step 8 (Game Blob Caching), fetched at boot via archiso's automated-script
# hook (partyos-step8.ipxe passes script=<server>/boot/step8-script.sh). Runs on
# the tty1 root autologin once the live system is up, with full control, and
# mirrors everything to the serial console the harness scrapes.
#
# Builds on Step 7 (game blob distribution): same catalog fetch + squashfs+overlay
# mount + dummy-game run. Step 8 adds four things:
#   1. A LOCAL CACHE for downloaded game blobs ON THE USB stick (LANPARTY_HOME,
#      mounted rw): blobs live under /mnt/usbhome/.partyos-cache/games/<name>.squashfs
#      so they SURVIVE a reboot (the USB persists; RAM does not).
#   2. CHECK THE CACHE BEFORE DOWNLOADING: if a valid (sha256-verified) cached blob
#      exists, USE IT and perform NO server GET for that blob. Only a cache MISS
#      hits the server, and the freshly downloaded blob is then WRITTEN to the cache.
#   3. CACHE MANAGEMENT: a size limit (CACHE_MAX_MB) with LRU cleanup - oldest
#      (by mtime) cached blobs are evicted until the cache fits under the limit.
#   4. OVERLAY MOUNTS PREFER THE CACHED BLOB: the squashfs lower layer is always
#      mounted from the cached copy on the USB (whether it was a hit or a
#      just-written miss), so mounts are served from the local cache.
#
# Cache HIT vs MISS is decided purely by what is already on the USB, so the SAME
# script proves both the cold (first) and warm (second) boot: boot 1 finds an
# empty cache (all MISS -> downloads + populates), boot 2 reuses the same USB and
# finds a full cache (all HIT -> no server GET). The harness confirms boot 2 made
# no blob GET against the timestamped http_access.log, and the HOST mounts the
# qcow2 to confirm the blobs really landed in the cache.
#
# Markers (greppable on serial):
#   PARTYOS-STEP8-CACHE-MOUNTED at=..        USB cache dir ready on LANPARTY_HOME
#   PARTYOS-STEP8-CATALOG-OK n=<count>       catalog fetched + parsed
#   PARTYOS-STEP8-CACHE-MISS name=..         no valid cached blob -> will download
#   PARTYOS-STEP8-BLOB-DOWNLOADED name=..    a blob downloaded from the server
#   PARTYOS-STEP8-CACHE-WRITE name=..        downloaded blob written to USB cache
#   PARTYOS-STEP8-CACHE-HIT name=..          valid cached blob found -> NO download
#   PARTYOS-STEP8-MOUNTED name=.. src=cache  blob mounted from the CACHED copy
#   PARTYOS-STEP8-GAME-RAN name=.. marker=   dummy game ran from its mounted blob
#   PARTYOS-STEP8-CACHE-EVICT name=..        a blob evicted by the size-limit LRU
#   PARTYOS-STEP8-CACHE-SUMMARY hits=.. miss=.. downloads=.. cached=..
#   PARTYOS-STEP8-READY                      all games mounted + ran - step passed
#   PARTYOS-STEP8-ALIVE                      heartbeats proving the system stays up
# HTTP callback (report_url injected by partyos-step8.ipxe, no hardcoded IP):
#   step=8 status=ok games=<n> hits=<n> miss=<n> downloads=<n> cached=<n> mounted=<n> ran=<n>

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

# server base + report base come from the kernel cmdline (no hardcoded IP).
report_base=""
boot_label="first"
for p in $(< /proc/cmdline); do case "$p" in
    report_url=*)  report_base="${p#*=}";;
    cache_boot=*)  boot_label="${p#*=}";;
esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-STEP8-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }
SERVER_BASE="${report_base}"   # same host serves the catalog + blobs

# resolve the desktop user: identity-setup renames the uid-1000 account
# gamer->USER_NAME and publishes the name to /run/partyos-username. NEVER hardcode
# 'gamer' - after a rename it does not exist.
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
HOME_DIR="/home/${USER_NAME}"

LABEL="LANPARTY_HOME"
MNT="/mnt/usbhome"
CACHE_DIR="${MNT}/.partyos-cache/games"       # blobs cached HERE (survives reboot)
GAMES_DIR="${HOME_DIR}/games"
MNT_BASE="/run/partyos-games"                 # read-only squashfs mountpoints
CATALOG_URL="${SERVER_BASE}/server/games/catalog.json"
CACHE_MAX_MB="${CACHE_MAX_MB:-64}"            # cache size limit (LRU eviction)

say "PARTYOS-STEP8 boot script started (game blob caching, boot=${boot_label})"
say "PARTYOS-STEP8 user ${USER_NAME}: $(id "${USER_NAME}" 2>&1)"
say "PARTYOS-STEP8 server_base=${SERVER_BASE}"

modprobe squashfs 2>/dev/null || true
modprobe overlay  2>/dev/null || true
modprobe loop     2>/dev/null || true

install -d "${MNT_BASE}"
install -d -o "${USER_NAME}" -g "${USER_NAME}" "${GAMES_DIR}"

# --- 1. mount the LANPARTY_HOME USB stick READ-WRITE (the cache backing store) -
udevadm settle 2>/dev/null || true
DEV="$(bash /usr/local/lib/partyos-usb-labels.sh resolve home 2>/dev/null || blkid -L "${LABEL}" 2>/dev/null || true)"
if [ -z "${DEV}" ]; then
    for _ in $(seq 1 20); do
        DEV="$(bash /usr/local/lib/partyos-usb-labels.sh resolve home 2>/dev/null || blkid -L "${LABEL}" 2>/dev/null || true)"
        [ -n "${DEV}" ] && break
        sleep 1
        udevadm settle 2>/dev/null || true
    done
fi
if [ -z "${DEV}" ]; then
    say "PARTYOS-STEP8 ERROR no ${LABEL} device found (cache needs the USB stick)"
    curl -s --max-time 5 "${report_base}/report?step=8&status=fail&reason=no-usb" >/dev/null 2>&1 || true
    exit 1
fi
say "PARTYOS-STEP8 found ${LABEL} at ${DEV}"
install -d "${MNT}"
if ! mountpoint -q "${MNT}"; then
    mount -o rw "${DEV}" "${MNT}" 2>/dev/null || mount "${DEV}" "${MNT}" || {
        say "PARTYOS-STEP8 ERROR mount ${DEV} failed"
        curl -s --max-time 5 "${report_base}/report?step=8&status=fail&reason=mount" >/dev/null 2>&1 || true
        exit 1
    }
fi
mount -o remount,rw "${MNT}" 2>/dev/null || true
install -d "${CACHE_DIR}"
say "PARTYOS-STEP8-CACHE-MOUNTED at=${CACHE_DIR} dev=${DEV}"
say "PARTYOS-STEP8 cache contents at boot: $(ls -1 "${CACHE_DIR}" 2>/dev/null | tr '\n' ' ')"

# --- 2. fetch the catalog ----------------------------------------------------
CATALOG="/run/partyos-catalog.json"
say "PARTYOS-STEP8 fetching catalog ${CATALOG_URL}"
if ! curl -fsS --max-time 30 -o "${CATALOG}" "${CATALOG_URL}"; then
    say "PARTYOS-STEP8 ERROR catalog fetch failed"
    curl -s --max-time 5 "${report_base}/report?step=8&status=fail&reason=catalog" >/dev/null 2>&1 || true
    exit 1
fi
mapfile -t NAMES   < <(grep -oE '"name":[[:space:]]*"[^"]*"'   "${CATALOG}" | sed -E 's/.*"name":[[:space:]]*"([^"]*)".*/\1/')
mapfile -t BLOBS   < <(grep -oE '"blob":[[:space:]]*"[^"]*"'   "${CATALOG}" | sed -E 's/.*"blob":[[:space:]]*"([^"]*)".*/\1/')
mapfile -t ENTRIES < <(grep -oE '"entry":[[:space:]]*"[^"]*"'  "${CATALOG}" | sed -E 's/.*"entry":[[:space:]]*"([^"]*)".*/\1/')
mapfile -t MARKERS < <(grep -oE '"marker":[[:space:]]*"[^"]*"' "${CATALOG}" | sed -E 's/.*"marker":[[:space:]]*"([^"]*)".*/\1/')
mapfile -t SHAS    < <(grep -oE '"sha256":[[:space:]]*"[^"]*"' "${CATALOG}" | sed -E 's/.*"sha256":[[:space:]]*"([^"]*)".*/\1/')

NGAMES="${#NAMES[@]}"
say "PARTYOS-STEP8-CATALOG-OK n=${NGAMES} games=$(IFS=,; echo "${NAMES[*]}")"
if [ "${NGAMES}" -lt 1 ]; then
    say "PARTYOS-STEP8 ERROR empty catalog"
    curl -s --max-time 5 "${report_base}/report?step=8&status=fail&reason=empty-catalog" >/dev/null 2>&1 || true
    exit 1
fi

# --- cache helpers -----------------------------------------------------------
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# cache_valid BLOB SHA -> 0 if the cached blob exists and (when a sha is known)
# matches. A corrupt/truncated cached blob is treated as a miss.
cache_valid() {
    local blob="$1" sha="$2"
    [ -s "${blob}" ] || return 1
    if [ -n "${sha}" ]; then
        [ "$(sha_of "${blob}")" = "${sha}" ] || return 1
    fi
    return 0
}

# Track per-game outcomes for the summary + callback.
declare -a MOUNTED=() RAN=() RAN_MARKERS=()
HITS=0; MISS=0; DOWNLOADS=0; WRITES=0

# get_blob runs in the MAIN shell (not a subshell) so its HITS/MISS/DOWNLOADS/
# WRITES increments stick. It sets BLOB_PATH to the cached blob path on success.
# CHECK CACHE FIRST: a valid cached blob = HIT, NO server GET. Otherwise MISS:
# download from the server and WRITE it into the cache.
BLOB_PATH=""
get_blob() {
    local name="$1" blobpath="$2" sha="$3"
    local cached="${CACHE_DIR}/${name}.squashfs"
    local url="${SERVER_BASE}/${blobpath}"
    BLOB_PATH=""

    if cache_valid "${cached}" "${sha}"; then
        # touch -a updates atime so LRU eviction keeps recently-used blobs.
        touch -a "${cached}" 2>/dev/null || true
        say "PARTYOS-STEP8-CACHE-HIT name=${name} (using cached blob, NO download)"
        HITS=$((HITS+1))
        BLOB_PATH="${cached}"
        return 0
    fi

    say "PARTYOS-STEP8-CACHE-MISS name=${name} (no valid cached blob)"
    MISS=$((MISS+1))
    # download to a temp file on the USB, verify, then atomically place in cache.
    local tmp="${cached}.dl.$$"
    if ! curl -fsS --max-time 60 -o "${tmp}" "${url}"; then
        say "PARTYOS-STEP8 ERROR download ${name} failed"
        rm -f "${tmp}"; return 1
    fi
    DOWNLOADS=$((DOWNLOADS+1))
    if [ -n "${sha}" ]; then
        local got; got="$(sha_of "${tmp}")"
        if [ "${got}" != "${sha}" ]; then
            say "PARTYOS-STEP8 ERROR ${name} sha mismatch got=${got} want=${sha}"
            rm -f "${tmp}"; return 1
        fi
    fi
    say "PARTYOS-STEP8-BLOB-DOWNLOADED name=${name} bytes=$(wc -c < "${tmp}" | tr -d ' ') sha_ok=1"
    mv -f "${tmp}" "${cached}"
    sync
    WRITES=$((WRITES+1))
    say "PARTYOS-STEP8-CACHE-WRITE name=${name} -> ${cached} (cached on USB, survives reboot)"
    BLOB_PATH="${cached}"
    return 0
}

# mount_from_cache NAME CACHEDBLOB -> squashfs(ro from cache)+overlay(tmpfs upper)
# at /home/gamer/games/<name>. The lower layer comes from the CACHED blob on the
# USB, so the overlay mount prefers the cache (Step 8).
mount_from_cache() {
    local name="$1" blob="$2"
    local lower="${MNT_BASE}/${name}"
    local scratch="${MNT_BASE}/${name}.rw"
    local dest="${GAMES_DIR}/${name}"
    install -d "${lower}" "${scratch}"
    install -d -o "${USER_NAME}" -g "${USER_NAME}" "${dest}"
    if ! mountpoint -q "${lower}"; then
        mount -t squashfs -o ro,loop "${blob}" "${lower}" 2>/dev/null \
          || mount -t squashfs -o ro "${blob}" "${lower}" 2>/dev/null \
          || { say "PARTYOS-STEP8 ERROR squashfs mount ${name} failed"; return 1; }
    fi
    mountpoint -q "${scratch}" || mount -t tmpfs -o size=16M tmpfs "${scratch}" || true
    install -d "${scratch}/upper" "${scratch}/work"
    if ! mountpoint -q "${dest}"; then
        mount -t overlay overlay \
          -o "lowerdir=${lower},upperdir=${scratch}/upper,workdir=${scratch}/work" \
          "${dest}" 2>/dev/null \
          || { say "PARTYOS-STEP8 ERROR overlay mount ${name} failed"; return 1; }
    fi
    chown "${USER_NAME}:${USER_NAME}" "${dest}" 2>/dev/null || true
    say "PARTYOS-STEP8-MOUNTED name=${name} at=${dest} src=cache+squashfs+overlay"
    return 0
}

# --- 3. per-game: cache-check -> (hit | miss+download+write) -> mount -> run ---
i=0
while [ "${i}" -lt "${NGAMES}" ]; do
    name="${NAMES[$i]}"; blob="${BLOBS[$i]}"; entry="${ENTRIES[$i]:-bin/run.sh}"
    marker="${MARKERS[$i]:-}"; sha="${SHAS[$i]:-}"
    i=$((i+1))

    get_blob "${name}" "${blob}" "${sha}" || { say "PARTYOS-STEP8 WARN ${name} unavailable"; continue; }
    cached="${BLOB_PATH}"
    mount_from_cache "${name}" "${cached}" || continue
    MOUNTED+=("${name}")

    dest="${GAMES_DIR}/${name}"
    out=""
    if [ -f "${dest}/${entry}" ]; then
        out="$(sudo -u "${USER_NAME}" bash "${dest}/${entry}" 2>&1 || true)"
    else
        out="(no entry ${entry} in ${name})"
    fi
    say "PARTYOS-STEP8 game ${name} output: ${out}"
    if [ -n "${marker}" ] && echo "${out}" | grep -qF "${marker}"; then
        RAN+=("${name}"); RAN_MARKERS+=("${marker}")
        say "PARTYOS-STEP8-GAME-RAN name=${name} marker=${marker}"
    else
        say "PARTYOS-STEP8 WARN game ${name} did not emit expected marker"
    fi
done

# --- 4. cache management: enforce the size limit with LRU eviction ------------
# Sum the cached blob sizes; while over CACHE_MAX_MB, evict the LEAST-recently-
# used (oldest atime) blob. Blobs in use this boot were just touched, so a real
# eviction only happens when the cache genuinely exceeds the budget.
cache_total_kb() { du -sk "${CACHE_DIR}" 2>/dev/null | awk '{print $1}'; }
limit_kb=$(( CACHE_MAX_MB * 1024 ))
guard=0
while [ "$(cache_total_kb)" -gt "${limit_kb}" ] && [ "${guard}" -lt 100 ]; do
    guard=$((guard+1))
    # oldest by access time (LRU): -u sorts by atime, oldest last in ls -1tu
    victim="$(ls -1tu "${CACHE_DIR}"/*.squashfs 2>/dev/null | tail -1)"
    [ -n "${victim}" ] || break
    vname="$(basename "${victim}" .squashfs)"
    rm -f "${victim}"
    say "PARTYOS-STEP8-CACHE-EVICT name=${vname} (LRU, cache over ${CACHE_MAX_MB}MB limit)"
done
CACHED_NOW="$(ls -1 "${CACHE_DIR}"/*.squashfs 2>/dev/null | wc -l | tr -d ' ')"
CACHE_KB="$(cache_total_kb)"
sync

NMOUNTED="${#MOUNTED[@]}"; NRAN="${#RAN[@]}"
say "PARTYOS-STEP8-CACHE-SUMMARY hits=${HITS} miss=${MISS} downloads=${DOWNLOADS} writes=${WRITES} cached=${CACHED_NOW} cache_kb=${CACHE_KB} mounted=${NMOUNTED} ran=${NRAN}"

# simultaneous-mount sanity (same as Step 7: both games live at once)
live=0
for n in "${MOUNTED[@]:-}"; do
    [ -z "${n}" ] && continue
    mountpoint -q "${GAMES_DIR}/${n}" && live=$((live+1))
done
say "PARTYOS-STEP8 live simultaneous mounts: ${live}"

# --- ready + callback --------------------------------------------------------
markers_csv="$(IFS=,; echo "${RAN_MARKERS[*]:-}")"
ready=0
if [ "${NMOUNTED}" -ge 2 ] && [ "${NRAN}" -ge 2 ] && [ "${CACHED_NOW}" -ge 2 ]; then
    ready=1
    say "PARTYOS-STEP8-READY all games served from cache-backed flow; cached=${CACHED_NOW} boot=${boot_label}"
    curl -s --max-time 5 \
      "${report_base}/report?step=8&status=ok&boot=${boot_label}&games=${NGAMES}&hits=${HITS}&miss=${MISS}&downloads=${DOWNLOADS}&cached=${CACHED_NOW}&mounted=${NMOUNTED}&ran=${NRAN}&markers=${markers_csv}" \
      >/dev/null 2>&1 || say "PARTYOS-STEP8 callback-failed (non-fatal)"
else
    say "PARTYOS-STEP8 NOT ready (mounted=${NMOUNTED} ran=${NRAN} cached=${CACHED_NOW})"
    curl -s --max-time 5 \
      "${report_base}/report?step=8&status=fail&boot=${boot_label}&games=${NGAMES}&hits=${HITS}&miss=${MISS}&downloads=${DOWNLOADS}&cached=${CACHED_NOW}&mounted=${NMOUNTED}&ran=${NRAN}" \
      >/dev/null 2>&1 || true
fi

# Final sync so the cache writes are flushed to the qcow2 before the host reads it.
sync
umount "${MNT}" 2>/dev/null || mount -o remount,ro "${MNT}" 2>/dev/null || true

# --- heartbeats: prove the system stays up with games mounted ----------------
i=0
while [ "${i}" -lt 20 ]; do
    sleep 2; i=$((i+1))
    live_now=0
    for n in "${MOUNTED[@]:-}"; do
        [ -z "${n}" ] && continue
        mountpoint -q "${GAMES_DIR}/${n}" && live_now=$((live_now+1))
    done
    say "PARTYOS-STEP8-ALIVE heartbeat ${i} mounted=${live_now} ready=${ready}"
    [ "${ready}" -eq 1 ] && [ "${i}" -ge 6 ] && break
done

say "PARTYOS-STEP8 stay-up window complete, powering off"
sync
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
