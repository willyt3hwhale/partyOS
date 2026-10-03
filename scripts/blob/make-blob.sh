#!/usr/bin/env bash
# make-blob.sh - the CONTRIBUTOR-facing one-shot blob packager for partyOS.
#
# A trusted-but-non-core contributor uses THIS to turn a game/app into a complete,
# self-contained partyOS deliverable WITHOUT touching the operator's catalog or
# needing to know the build system. It wraps the existing builders (it does NOT
# duplicate any build logic):
#   - native blobs  -> scripts/build/build-app-blob.sh
#   - Windows/Wine   -> scripts/build/build-proton-blob.sh
# then runs gen-blob-torrents.sh and emits a single catalog-fragment + a HANDOFF.txt.
#
# Crucially it runs the builder with SKIP_CATALOG=1 + a TEMP CATALOG_V2 so the
# OPERATOR'S catalog.v2.json is never touched - the contributor produces a fragment,
# the operator vouches it in later with add-blob.sh. The sha256 in the operator's
# catalog is the trust root, so WHOEVER serves the bytes is
# irrelevant to integrity (get_blob verifies the downloaded bytes against the catalog
# sha256, fail-closed). Bytes can come from the operator's host OR the contributor's
# self-host (a web-seed) - same sha gate either way.
#
# Usage:
#   make-blob.sh native <name> <repo|aur> <pkgs> <exec> [title] [category] [ram_min] [ram_max]
#   make-blob.sh proton <name> <game-src> <exe-rel> [title] [ram_min] [ram_max]
#
# Options (before or after the positional args):
#   --webseed <url>   contributor self-host base URL for the torrent web-seed (BEP19).
#                     Advertise HTTP (not HTTPS): the sha256 in the operator catalog is
#                     the trust root, and the client's pinned-CA aria2 check would fail
#                     an HTTPS contributor web-seed. The bytes are integrity-checked
#                     regardless of transport.
#   --out <dir>       output dir (default ./blob-out/<name>).
#
# Output (the deliverable to hand to the operator), in <out>/:
#   <name>.squashfs            the blob
#   <name>.squashfs.sha256     its sha256 (the trust root the operator vouches in)
#   <name>.squashfs.torrent    BEP19 torrent (+ web-seed if --webseed)
#   <name>.catalog-fragment.json   ONE rectangular catalog row (real sha/size/ram/...)
#   HANDOFF.txt                what to send + sha + size + hosting note
#
# SNAPSHOT is HARD-PINNED to 2025/09/01 and cannot be overridden: a blob built
# against a different Arch snapshot would carry libs whose ABI does not match the
# client base image, so it could crash on a client. Refuse any override loudly.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"        # scripts/blob -> repo root is two up
BUILD_DIR="${REPO_ROOT}/scripts/build"

# --- hard-pin the snapshot, refuse override ------------------------------
PINNED_SNAPSHOT="2025/09/01"
if [ -n "${SNAPSHOT:-}" ] && [ "${SNAPSHOT}" != "${PINNED_SNAPSHOT}" ]; then
    echo "[make-blob] ERROR SNAPSHOT is hard-pinned to ${PINNED_SNAPSHOT} - refusing override '${SNAPSHOT}'." >&2
    echo "[make-blob] A blob built against another snapshot has libs whose ABI may not match the client base -> crashes on a client." >&2
    exit 1
fi
export SNAPSHOT="${PINNED_SNAPSHOT}"

usage() {
    sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

# --- parse options + mode ----------------------------------------------------
WEBSEED=""; OUT_DIR=""
POS=()
MODE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --webseed) WEBSEED="${2:?--webseed needs a url}"; shift 2;;
        --webseed=*) WEBSEED="${1#*=}"; shift;;
        --out) OUT_DIR="${2:?--out needs a dir}"; shift 2;;
        --out=*) OUT_DIR="${1#*=}"; shift;;
        -h|--help) usage 0;;
        --*) echo "[make-blob] ERROR unknown option: $1" >&2; usage 1;;
        *)
            if [ -z "${MODE}" ]; then MODE="$1"; else POS+=("$1"); fi
            shift;;
    esac
done

case "${MODE}" in
    native|proton) : ;;
    "") echo "[make-blob] ERROR missing mode (native|proton)" >&2; usage 1;;
    *) echo "[make-blob] ERROR unknown mode '${MODE}' (native|proton)" >&2; usage 1;;
esac

NAME="${POS[0]:-}"
[ -n "${NAME}" ] || { echo "[make-blob] ERROR missing <name>" >&2; usage 1; }
case "${NAME}" in
    *[!a-z0-9]*) echo "[make-blob] ERROR name must be [a-z0-9]: '${NAME}'" >&2; exit 1;;
esac

command -v docker >/dev/null || { echo "[make-blob] ERROR docker required (the builders run an amd64 Arch container)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "[make-blob] ERROR python3 required" >&2; exit 1; }

OUT_DIR="${OUT_DIR:-${PWD}/blob-out/${NAME}}"
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

# Private staging the builder writes the blob+sha into. We point OUT_DIR (the builder
# env var) here so server/games/ is NEVER written. A TEMP catalog + SKIP_CATALOG=1
# guarantee the operator catalog is untouched even if the builder's guard regressed.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/partyos-makeblob.XXXXXX")"
TEMP_CATALOG="${STAGE}/catalog.v2.json"
printf '{"version":3,"games":[]}\n' > "${TEMP_CATALOG}"
cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

echo "[make-blob] mode=${MODE} name=${NAME} snapshot=${SNAPSHOT}" >&2
echo "[make-blob] staging=${STAGE}  out=${OUT_DIR}" >&2
[ -n "${WEBSEED}" ] && echo "[make-blob] webseed=${WEBSEED} (advertise HTTP; sha256 is the trust root)" >&2

# --- run the right builder (SKIP_CATALOG=1 + temp CATALOG_V2 -> no operator catalog) --
HEART_LOG="${STAGE}/build.log"
echo "[make-blob] invoking builder (heartbeat below - docker build can take many minutes)..." >&2
START_TS=$(date +%s)
(
    while sleep 30; do
        now=$(date +%s)
        echo "[make-blob] ...still building ${NAME} ($(( (now - START_TS) / 60 ))m$(( (now - START_TS) % 60 ))s elapsed)" >&2
    done
) & HB=$!
stop_hb() { kill "${HB}" 2>/dev/null || true; }
trap 'stop_hb; cleanup' EXIT

set +e
case "${MODE}" in
    native)
        # native <name> <repo|aur> <pkgs> <exec> [title] [category] [ram_min] [ram_max]
        SOURCE="${POS[1]:?native needs <repo|aur>}"; PKGS="${POS[2]:?native needs <pkgs>}"
        EXEC="${POS[3]:?native needs <exec>}"
        TITLE="${POS[4]:-${NAME}}"; CATEGORY="${POS[5]:-game}"
        RAM_MIN="${POS[6]:-512}"; RAM_MAX="${POS[7]:-2048}"
        OUT_DIR="${STAGE}" SKIP_CATALOG=1 CATALOG_V2="${TEMP_CATALOG}" SNAPSHOT="${SNAPSHOT}" \
            bash "${BUILD_DIR}/build-app-blob.sh" \
            "${NAME}" "${SOURCE}" "${PKGS}" "${EXEC}" "${TITLE}" "${CATEGORY}" "partyos.${NAME}" "${RAM_MIN}" "${RAM_MAX}"
        ;;
    proton)
        # proton <name> <game-src> <exe-rel> [title] [ram_min] [ram_max]
        GAME_SRC="${POS[1]:?proton needs <game-src>}"; EXE_REL="${POS[2]:?proton needs <exe-rel>}"
        TITLE="${POS[3]:-${NAME}}"; CATEGORY="game"
        RAM_MIN="${POS[4]:-2048}"; RAM_MAX="${POS[5]:-4096}"
        EXEC=""
        OUT_DIR="${STAGE}" SKIP_CATALOG=1 CATALOG_V2="${TEMP_CATALOG}" SNAPSHOT="${SNAPSHOT}" \
            bash "${BUILD_DIR}/build-proton-blob.sh" \
            "${NAME}" "${GAME_SRC}" "${EXE_REL}" "${TITLE}" "${RAM_MIN}" "${RAM_MAX}"
        ;;
esac
BUILD_RC=$?
set -e
stop_hb
trap cleanup EXIT

if [ "${BUILD_RC}" -ne 0 ]; then
    echo "[make-blob] ERROR builder failed (rc=${BUILD_RC}) - no deliverable produced" >&2
    exit 1
fi

BLOB="${STAGE}/${NAME}.squashfs"
[ -s "${BLOB}" ] || { echo "[make-blob] ERROR no blob at ${BLOB}" >&2; exit 1; }
[ -s "${BLOB}.sha256" ] || { echo "[make-blob] ERROR no sha at ${BLOB}.sha256" >&2; exit 1; }
SHA="$(cat "${BLOB}.sha256" | tr -d '[:space:]')"
SIZE="$(wc -c < "${BLOB}" | tr -d ' ')"
[ -n "${SHA}" ] || { echo "[make-blob] ERROR empty sha - refusing to emit (fail-closed)" >&2; exit 1; }

# proton emits a shm_mb sidecar across the /out bind; recover it if present.
SHM_MB=""
if [ -f "${STAGE}/${NAME}.shm_mb" ]; then
    SHM_MB="$(tr -dc '0-9' < "${STAGE}/${NAME}.shm_mb")"
    rm -f "${STAGE}/${NAME}.shm_mb"
fi

# --- torrent (reuse gen-blob-torrents.sh verbatim) ---------------------------
# It globs *.squashfs in the dir it is given, so point it at the staging dir.
echo "[make-blob] generating torrent..." >&2
if [ -n "${WEBSEED}" ]; then
    WEBSEED="${WEBSEED}" bash "${BUILD_DIR}/gen-blob-torrents.sh" "${STAGE}" || \
        echo "[make-blob] WARN torrent generation failed (non-fatal)" >&2
else
    bash "${BUILD_DIR}/gen-blob-torrents.sh" "${STAGE}" || \
        echo "[make-blob] WARN torrent generation failed (non-fatal)" >&2
fi

# --- emit the rectangular catalog fragment -----------------------------------
# One row, the EXACT rectangular field set the builders write (build-app-blob.sh
# / build-proton-blob.sh) so add-blob.sh's rectangularity check passes. The blob
# path is the canonical server path the operator will host it under; if the operator
# instead self-points the row at a web-seed, add-blob keeps blob as the local path
# only when --host is used. proton rows carry shm_mb/proton; native rows carry exec.
FRAG="${STAGE}/${NAME}.catalog-fragment.json"
MODE="${MODE}" NAME="${NAME}" TITLE="${TITLE}" CAT="${CATEGORY}" \
SHA="${SHA}" SIZE="${SIZE}" RMIN="${RAM_MIN}" RMAX="${RAM_MAX}" \
EXECV="${EXEC}" SHM="${SHM_MB}" WEBSEED="${WEBSEED}" python3 - "${FRAG}" <<'PY'
import json, os, sys
out = sys.argv[1]
mode = os.environ["MODE"]; name = os.environ["NAME"]
row = dict(
    id="partyos.%s" % name, name=name, hidden=False, title=os.environ["TITLE"],
    source="blob", blob="server/games/%s.squashfs" % name,
    sha256=os.environ["SHA"], size=int(os.environ["SIZE"]),
    ram_min=int(os.environ["RMIN"]), ram_max=int(os.environ["RMAX"]),
    version="1.0.0", category=os.environ["CAT"],
    entry="bin/run.sh",
)
if mode == "proton":
    row.update(
        icon="/usr/share/pixmaps/partyos-games/%s.png" % name,
        exec="", pkg="", pkgs="", marker="PARTYOS-BLOB-RUN %s" % name,
        needs_server=False, proton=True,
    )
    shm = os.environ.get("SHM", "")
    if shm.isdigit() and int(shm) > 0:
        row["shm_mb"] = int(shm)
else:
    row.update(
        icon="applications-games", exec=os.environ.get("EXECV", ""),
        pkg="", pkgs="", marker="",
    )
ws = os.environ.get("WEBSEED", "")
frag = {"_partyos_blob_fragment": 1, "name": name, "row": row}
if ws:
    frag["webseed"] = ws.rstrip("/")
json.dump(frag, open(out, "w"), indent=2)
print("[make-blob] fragment written for %s (sha %s)" % (name, os.environ["SHA"][:12]), file=sys.stderr)
PY

# --- assemble the deliverable in OUT_DIR -------------------------------------
cp -f "${BLOB}" "${OUT_DIR}/${NAME}.squashfs"
cp -f "${BLOB}.sha256" "${OUT_DIR}/${NAME}.squashfs.sha256"
[ -f "${STAGE}/${NAME}.squashfs.torrent" ] && cp -f "${STAGE}/${NAME}.squashfs.torrent" "${OUT_DIR}/"
cp -f "${FRAG}" "${OUT_DIR}/${NAME}.catalog-fragment.json"

HUMAN_SIZE="$(du -h "${OUT_DIR}/${NAME}.squashfs" | cut -f1)"
{
    echo "partyOS blob deliverable: ${NAME}"
    echo "==============================================="
    echo
    echo "Built $(date -u '+%Y-%m-%d %H:%M:%S UTC') against Arch snapshot ${SNAPSHOT} (pinned)."
    echo
    echo "Files to send to the operator (everything in this directory):"
    echo "  ${NAME}.squashfs                 the blob (${HUMAN_SIZE})"
    echo "  ${NAME}.squashfs.sha256          its sha256 - THIS is what the operator vouches in"
    [ -f "${OUT_DIR}/${NAME}.squashfs.torrent" ] && echo "  ${NAME}.squashfs.torrent         BEP19 torrent for P2P/web-seed distribution"
    echo "  ${NAME}.catalog-fragment.json    one catalog row the operator merges with add-blob.sh"
    echo
    echo "sha256: ${SHA}"
    echo "size:   ${SIZE} bytes (${HUMAN_SIZE})"
    echo
    echo "Hosting - two models (the operator chooses; either is fine):"
    echo "  A. Operator hosts (default): send ALL files above. The operator runs"
    echo "       scripts/blob/add-blob.sh ${NAME}.catalog-fragment.json --host ${NAME}.squashfs"
    echo "     which copies the blob into their server/games/ and re-bakes the torrent web-seed."
    if [ -n "${WEBSEED}" ]; then
        echo "  B. You self-host (--webseed was set): host the blob at"
        echo "       ${WEBSEED%/}/${NAME}.squashfs   (over HTTP - the sha256 is the trust root)"
        echo "     and send ONLY the fragment + sha256. The operator runs"
        echo "       scripts/blob/add-blob.sh ${NAME}.catalog-fragment.json --webseed ${WEBSEED%/}"
        echo "     The catalog sha256 verifies your bytes regardless of where they come from."
    else
        echo "  B. You self-host: re-run make-blob.sh with --webseed <your-http-base-url> so the"
        echo "     torrent carries your web-seed, then send the fragment + sha256 and host the blob"
        echo "     at <your-http-base-url>/${NAME}.squashfs over HTTP."
    fi
    echo
    echo "Trust: the operator's catalog sha256 is the integrity root. WHOEVER serves the"
    echo "bytes is irrelevant - a client verifies the downloaded blob against the catalog"
    echo "sha256 and fails closed on a mismatch or an empty sha. Do not edit the .squashfs"
    echo "after this build or the sha will no longer match."
} > "${OUT_DIR}/HANDOFF.txt"

echo "[make-blob] DONE ${NAME}" >&2
echo "[make-blob] deliverable: ${OUT_DIR}" >&2
ls -la "${OUT_DIR}" >&2
echo "[make-blob] sha=${SHA}  size=${SIZE}" >&2
