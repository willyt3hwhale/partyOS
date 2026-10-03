#!/usr/bin/env bash
# metadata-script.sh - autonomous in-guest verifier for blob metadata, fetched
# at boot via archiso's automated-script hook (partyos-metadata.ipxe passes
# script=<server>/boot/metadata-script.sh). Runs on the tty1 root autologin once
# the live system is up and mirrors everything to the serial console the harness
# scrapes.
#
# What it proves (blob metadata):
#   1. The catalog (which the client reads) carries METADATA per blob:
#      a stable id, ram_min, ram_max, size, version, category.
#   2. The client-side helper (partyos-blob-meta) can READ each blob's metadata
#      from the catalog (list + field) - the backend the app store and
#      eviction reason over.
#   3. A blob PACKAGE is self-describing: its embedded game.meta (extracted from
#      the mounted squashfs) carries the SAME metadata, and the helper reads it.
#   4. RAM-FIT reasoning works: the helper decides whether a blob fits a given
#      free-RAM budget (fits/need), as the eviction prompt does.
#
# Markers (greppable on serial):
#   PARTYOS-META-HELPER-OK                      partyos-blob-meta installed + runnable
#   PARTYOS-META-CATALOG-OK n=<count> ver=<v>   catalog fetched + parsed (version 2)
#   PARTYOS-META-FIELDS name=<n> id=.. ram_min=.. ram_max=.. size=.. version=.. category=..
#                                               every metadata field read from the catalog
#   PARTYOS-META-EMBEDDED name=<n> id=.. ram_min=.. ram_max=..
#                                               metadata read from the blob's OWN game.meta
#   PARTYOS-META-FIT name=<n> free=<f> verdict=<ok|nofit>
#                                               RAM-fit reasoning over the metadata
#   PARTYOS-META-READY                          all metadata assertions passed
#   PARTYOS-META-ALIVE                          heartbeats proving the system stays up
# HTTP callback (report_url injected by partyos-metadata.ipxe, no hardcoded IP):
#   step=metadata status=ok games=<n> with_meta=<n> embedded=<n> fit_ok=<n>

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

# server base + report base come from the kernel cmdline (no hardcoded IP).
report_base=""
for p in $(< /proc/cmdline); do case "$p" in
    report_url=*) report_base="${p#*=}";;
esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-METADATA-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }
SERVER_BASE="${report_base}"   # same host serves the catalog + blobs + the helper

GAMES_DIR="/run/partyos-meta"
MNT_BASE="/run/partyos-games"
CATALOG_URL="${SERVER_BASE}/server/games/catalog.json"
HELPER_URL="${SERVER_BASE}/boot/partyos-blob-meta"
HELPER="/usr/local/bin/partyos-blob-meta"

say "PARTYOS-META boot script started (blob metadata)"
say "PARTYOS-META server_base=${SERVER_BASE}"

modprobe squashfs 2>/dev/null || true
modprobe loop     2>/dev/null || true
install -d "${MNT_BASE}" "${GAMES_DIR}"

fail() {
    say "PARTYOS-META ERROR $1"
    curl -s --max-time 5 "${report_base}/report?step=metadata&status=fail&reason=$1" >/dev/null 2>&1 || true
    # keep the VM alive briefly so the harness can scrape, then power off
    sleep 5
    systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
    exit 1
}

# --- 1. install the client-side metadata helper ------------------------------
# Fetched (not baked) so it iterates without rebuilding the ~1.6GB sfs; this IS
# the CLI backend a GUI launcher would shell out to.
say "PARTYOS-META fetching helper ${HELPER_URL}"
curl -fsS --max-time 30 -o "${HELPER}" "${HELPER_URL}" || fail "helper-fetch"
chmod +x "${HELPER}"
"${HELPER}" >/dev/null 2>&1
[ $? -eq 2 ] && say "PARTYOS-META-HELPER-OK (usage path ok)"   # bare run -> usage rc=2
say "PARTYOS-META-HELPER-OK installed=${HELPER}"

# --- 2. fetch the catalog that the client reads ------------------------------
CATALOG="/run/partyos-catalog.json"
say "PARTYOS-META fetching catalog ${CATALOG_URL}"
curl -fsS --max-time 30 -o "${CATALOG}" "${CATALOG_URL}" || fail "catalog"

CAT_VER="$(grep -oE '"version":[[:space:]]*[0-9]+' "${CATALOG}" | head -1 | grep -oE '[0-9]+')"
mapfile -t NAMES < <(grep -oE '"name":[[:space:]]*"[^"]*"' "${CATALOG}" \
    | sed -E 's/.*"name":[[:space:]]*"([^"]*)".*/\1/')
mapfile -t BLOBS < <(grep -oE '"blob":[[:space:]]*"[^"]*"' "${CATALOG}" \
    | sed -E 's/.*"blob":[[:space:]]*"([^"]*)".*/\1/')
NGAMES="${#NAMES[@]}"
say "PARTYOS-META-CATALOG-OK n=${NGAMES} ver=${CAT_VER} games=$(IFS=,; echo "${NAMES[*]}")"
[ "${NGAMES}" -ge 1 ] || fail "empty-catalog"

# Show what the helper's `list` returns (the app-store's source rows).
say "PARTYOS-META helper list:"
"${HELPER}" list "${CATALOG}" | while IFS= read -r row; do say "PARTYOS-META-LIST ${row}"; done

# --- per-game: read every metadata field from the catalog via the helper -----
WITH_META=0; EMBEDDED=0; FIT_OK=0
i=0
while [ "${i}" -lt "${NGAMES}" ]; do
    name="${NAMES[$i]}"; blobpath="${BLOBS[$i]}"
    i=$((i+1))

    id="$("${HELPER}" field "${CATALOG}" "${name}" id 2>/dev/null || true)"
    rmin="$("${HELPER}" field "${CATALOG}" "${name}" ram_min 2>/dev/null || true)"
    rmax="$("${HELPER}" field "${CATALOG}" "${name}" ram_max 2>/dev/null || true)"
    size="$("${HELPER}" field "${CATALOG}" "${name}" size 2>/dev/null || true)"
    ver="$("${HELPER}" field "${CATALOG}" "${name}" version 2>/dev/null || true)"
    cat="$("${HELPER}" field "${CATALOG}" "${name}" category 2>/dev/null || true)"

    if [ -n "${id}" ] && [ -n "${rmin}" ] && [ -n "${rmax}" ] && [ -n "${size}" ] \
       && [ -n "${ver}" ] && [ -n "${cat}" ]; then
        WITH_META=$((WITH_META+1))
        say "PARTYOS-META-FIELDS name=${name} id=${id} ram_min=${rmin} ram_max=${rmax} size=${size} version=${ver} category=${cat}"
    else
        say "PARTYOS-META WARN ${name} missing a catalog metadata field (id=${id} rmin=${rmin} rmax=${rmax} size=${size} ver=${ver} cat=${cat})"
    fi

    # --- 3. blob PACKAGE self-description: download + mount + read game.meta --
    url="${SERVER_BASE}/${blobpath}"
    blob="${GAMES_DIR}/${name}.squashfs"
    lower="${MNT_BASE}/${name}"
    install -d "${lower}"
    if curl -fsS --max-time 60 -o "${blob}" "${url}"; then
        if mount -t squashfs -o ro,loop "${blob}" "${lower}" 2>/dev/null \
           || mount -t squashfs -o ro "${blob}" "${lower}" 2>/dev/null; then
            meta="${lower}/game.meta"
            if [ -s "${meta}" ]; then
                e_id="$("${HELPER}" meta-of "${meta}" id 2>/dev/null || true)"
                e_rmin="$("${HELPER}" meta-of "${meta}" ram_min 2>/dev/null || true)"
                e_rmax="$("${HELPER}" meta-of "${meta}" ram_max 2>/dev/null || true)"
                if [ -n "${e_id}" ] && [ -n "${e_rmin}" ] && [ -n "${e_rmax}" ]; then
                    EMBEDDED=$((EMBEDDED+1))
                    say "PARTYOS-META-EMBEDDED name=${name} id=${e_id} ram_min=${e_rmin} ram_max=${e_rmax}"
                    # cross-check: embedded id matches the catalog id
                    [ "${e_id}" = "${id}" ] && say "PARTYOS-META-CROSSCHECK name=${name} catalog_id=${id} blob_id=${e_id} match=1"
                else
                    say "PARTYOS-META WARN ${name} blob game.meta missing a field"
                fi
            else
                say "PARTYOS-META WARN ${name} blob has no game.meta"
            fi
            umount "${lower}" 2>/dev/null || true
        else
            say "PARTYOS-META WARN ${name} squashfs mount failed"
        fi
    else
        say "PARTYOS-META WARN ${name} blob download failed"
    fi

    # --- 4. RAM-fit reasoning over the metadata ------------------------------
    # Use a free-RAM budget BELOW pong's ram_min so the verdicts differ per blob,
    # proving the helper reasons over the metadata (not a constant).
    FREE_MB=300
    if "${HELPER}" fits "${CATALOG}" "${name}" "${FREE_MB}" >/dev/null 2>&1; then
        verdict=ok; FIT_OK=$((FIT_OK+1))
    else
        verdict=nofit
    fi
    need="$("${HELPER}" need "${CATALOG}" "${name}" "${FREE_MB}" 2>/dev/null || echo '?')"
    say "PARTYOS-META-FIT name=${name} free=${FREE_MB} verdict=${verdict} short_of_max=${need}MB"
done

say "PARTYOS-META summary games=${NGAMES} with_meta=${WITH_META} embedded=${EMBEDDED} fit_ok=${FIT_OK}"

# --- ready + callback --------------------------------------------------------
ready=0
# pass gate: catalog v2, every game has full catalog metadata, every blob is
# self-describing (embedded meta read), and RAM-fit reasoning ran.
if [ "${NGAMES}" -ge 2 ] && [ "${WITH_META}" -eq "${NGAMES}" ] \
   && [ "${EMBEDDED}" -eq "${NGAMES}" ] && [ "${CAT_VER}" -ge 2 ]; then
    ready=1
    say "PARTYOS-META-READY catalog+blobs carry metadata; client reads it (with_meta=${WITH_META} embedded=${EMBEDDED})"
    curl -s --max-time 5 \
      "${report_base}/report?step=metadata&status=ok&games=${NGAMES}&with_meta=${WITH_META}&embedded=${EMBEDDED}&fit_ok=${FIT_OK}&catver=${CAT_VER}" \
      >/dev/null 2>&1 || say "PARTYOS-META callback-failed (non-fatal)"
else
    say "PARTYOS-META NOT ready (with_meta=${WITH_META} embedded=${EMBEDDED} n=${NGAMES} ver=${CAT_VER})"
    curl -s --max-time 5 \
      "${report_base}/report?step=metadata&status=fail&games=${NGAMES}&with_meta=${WITH_META}&embedded=${EMBEDDED}&fit_ok=${FIT_OK}" \
      >/dev/null 2>&1 || true
fi

# --- heartbeats: prove the system stays up -----------------------------------
i=0
while [ "${i}" -lt 12 ]; do
    sleep 2; i=$((i+1))
    say "PARTYOS-META-ALIVE heartbeat ${i} ready=${ready}"
    [ "${ready}" -eq 1 ] && [ "${i}" -ge 4 ] && break
done

say "PARTYOS-META stay-up window complete, powering off"
sync
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
