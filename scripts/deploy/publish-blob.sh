#!/usr/bin/env bash
# publish-blob.sh - add a blob to a LIVE party server with no restart.
#
# THE PROBLEM: today a new blob reaches players only after the server stack
# restarts. The running aria2 seeder reads its torrent list once per launch, so a
# torrent that appears later is invisible until the seeder respawns. A restart
# drops every peer that is downloading and every seed that is serving them.
#
# THE RULE: nothing restarts. This script adds the torrent to the RUNNING seeder
# over the aria2 JSON-RPC socket, then publishes the catalog row. The HTTPS
# server, the tracker and the seeder keep their process IDs.
#
# ORDER IS THE SAFETY MODEL. The steps run bytes-first, catalog-last:
#   1. make the .torrent with the tracker announce URL baked in
#   2. ask the running seeder which info-hashes it holds for this blob
#   3. place the squashfs, the .sha256 sidecar and the .torrent (atomic renames)
#   4. add the torrent to the running seeder over RPC and wait until it seeds
#   5. upsert the catalog row and render catalog.json (both atomic renames)
# A client can only learn the title from step 5, and step 5 runs only after a live
# seeder seeds the bytes. A failure at any step leaves the catalog untouched, so
# the previous state stays intact and a re-run is safe.
#
# A RE-PUBLISH WITH NEW BYTES replaces the old info-hash in the running seeder:
#   1. place the new bytes in the stage dir <games>/.publish/NAME-<sha12>
#   2. add the new torrent from the stage dir and wait until it seeds
#   3. remove the old info-hash from the seeder
#   4. move the bytes, sidecar and torrent to the games dir (a hard link)
# The swarm always has a server seed. aria2c does not accept two torrents for the
# same file, so the new torrent seeds from the stage dir until the seeder restarts.
# The next publish of the blob deletes a stage dir that no seeder entry uses.
# PARTYOS_PUBLISH_VERIFY_TIMEOUT sets the wait for the seed (default 1800 s).
#
# Usage:
#   publish-blob.sh <blob.squashfs> [options]
#
# Options:
#   --title TEXT        display name in the app store   (default: derived from the name)
#   --exec CMD          command the launcher runs       (default: the blob name)
#   --category CAT      game | app | tool               (default: game)
#   --id ID             catalog id                      (default: partyos.<name>)
#   --ram-min MB        minimum RAM in MB               (default: 512, Proton: game.meta or 2048)
#   --ram-max MB        maximum RAM in MB               (default: 2048, Proton: game.meta or 4096)
#   --entry PATH        entry script inside the blob    (default: bin/run.sh)
#   --icon PATH         icon name or path on the client (default: applications-games)
#   --hidden            publish the row hidden (no tile until a player types its code)
#   --unlock-code CODE  the code that shows a hidden row, A-Z a-z 0-9 . _ - (sets --hidden)
#   --conf FILE         deploy.conf to read             (default: <repo>/deploy.conf)
#   --games-dir DIR     served games dir                (default: <repo>/server/games)
#   --rpc-url URL       aria2 RPC endpoint              (default: http://127.0.0.1:6800/jsonrpc)
#   --rpc-secret TOKEN  aria2 RPC secret                (default: partyos)
#   --no-seed           skip the RPC step (the seeder picks the torrent up on its
#                       next respawn; the title is published without a live seed)
#   --dry-run           report what would change, write nothing
#
# A new row gets hidden and unlock_code in the same catalog write that adds it, so
# a hidden title is never visible, not even for one fetch.
#
# The script reads game.meta inside the blob (unsquashfs -cat). If game.meta says
# kind=proton, the row gets the Windows fields that build-proton-blob.sh records:
# proton, overlay, shm_mb and marker from game.meta, exe_rel and save_rel from
# bin/run.sh. A blob with no game.meta is published as a native blob.
#
# A re-publish of the same blob is a no-op on operator-tuned catalog fields: only
# the build-derived facts (sha256, size, blob path, and the Windows fields of a
# Proton blob) are overwritten, exactly as add-blob.sh does. hidden, unlock_code,
# category, icon and RAM change only with an explicit flag. Re-adding a torrent
# the seeder already holds is skipped. Only a live entry (active, waiting or
# paused) counts as held. A stopped entry, for example an error, does not seed.
#
# Run this ON the party server, because the RPC socket listens on localhost only.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
MAKE_TORRENT="${SELF_DIR}/make-torrent.py"
BUILD_GAME_BLOBS="${REPO_ROOT}/scripts/build/build-game-blobs.sh"

usage() { sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

BLOB=""; TITLE=""; EXEC=""; CATEGORY=""; APP_ID=""; RAM_MIN=""; RAM_MAX=""
ENTRY=""; ICON=""; CONF=""; GAMES_DIR=""; NO_SEED=0; DRY_RUN=0; HIDDEN=0; UNLOCK_CODE=""
RPC_URL="${PARTYOS_ARIA2_RPC:-http://127.0.0.1:6800/jsonrpc}"
RPC_SECRET="${PARTYOS_ARIA2_SECRET:-partyos}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --title)      TITLE="${2:?--title needs a value}"; shift 2;;
        --exec)       EXEC="${2:?--exec needs a value}"; shift 2;;
        --category)   CATEGORY="${2:?--category needs a value}"; shift 2;;
        --id)         APP_ID="${2:?--id needs a value}"; shift 2;;
        --ram-min)    RAM_MIN="${2:?--ram-min needs a value}"; shift 2;;
        --ram-max)    RAM_MAX="${2:?--ram-max needs a value}"; shift 2;;
        --entry)      ENTRY="${2:?--entry needs a value}"; shift 2;;
        --icon)       ICON="${2:?--icon needs a value}"; shift 2;;
        --hidden)     HIDDEN=1; shift;;
        --unlock-code) UNLOCK_CODE="${2:?--unlock-code needs a value}"; HIDDEN=1; shift 2;;
        --conf)       CONF="${2:?--conf needs a value}"; shift 2;;
        --games-dir)  GAMES_DIR="${2:?--games-dir needs a value}"; shift 2;;
        --rpc-url)    RPC_URL="${2:?--rpc-url needs a value}"; shift 2;;
        --rpc-secret) RPC_SECRET="${2:?--rpc-secret needs a value}"; shift 2;;
        --no-seed)    NO_SEED=1; shift;;
        --dry-run)    DRY_RUN=1; shift;;
        -h|--help)    usage 0;;
        --*) echo "[publish] ERROR unknown option: $1" >&2; usage 1;;
        *) if [ -z "${BLOB}" ]; then BLOB="$1"; else echo "[publish] ERROR extra arg: $1" >&2; usage 1; fi; shift;;
    esac
done

[ -n "${BLOB}" ] || { echo "[publish] ERROR missing <blob.squashfs>" >&2; usage 1; }
[ -f "${BLOB}" ] || { echo "[publish] ERROR blob not found: ${BLOB}" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[publish] ERROR python3 required" >&2; exit 1; }
command -v unsquashfs >/dev/null 2>&1 || {
    echo "[publish] ERROR unsquashfs required to read game.meta (install squashfs-tools)" >&2; exit 1; }
# The store compares codes case-insensitive and trimmed. The no-jq catalog parser
# on the client must read the code, so only plain characters are allowed.
case "${UNLOCK_CODE}" in
    *[!A-Za-z0-9._-]*) echo "[publish] ERROR --unlock-code may only use A-Z a-z 0-9 . _ -" >&2; exit 1;;
esac
[ -f "${MAKE_TORRENT}" ] || { echo "[publish] ERROR missing ${MAKE_TORRENT}" >&2; exit 1; }

CONF="${CONF:-${REPO_ROOT}/deploy.conf}"
GAMES_DIR="${GAMES_DIR:-${REPO_ROOT}/server/games}"
[ -d "${GAMES_DIR}" ] || { echo "[publish] ERROR games dir not found: ${GAMES_DIR}" >&2; exit 1; }
CATALOG_V2="${GAMES_DIR}/catalog.v2.json"
[ -f "${CATALOG_V2}" ] || { echo "[publish] ERROR catalog not found: ${CATALOG_V2}" >&2; exit 1; }

NAME="$(basename "${BLOB}")"; NAME="${NAME%.squashfs}"
case "${NAME}" in
    ""|*/*|.*) echo "[publish] ERROR bad blob name: ${NAME}" >&2; exit 1;;
    *[!a-zA-Z0-9._-]*) echo "[publish] ERROR blob name has unsafe characters: ${NAME}" >&2; exit 1;;
esac

# --- the tracker announce URL -------------------------------------------------
# Derive it the same way render.sh does: the first blob server in deploy.conf, port
# stripped, at the fixed tracker port 6969. Blobs are BitTorrent-only, so a torrent
# without this announce URL is undiscoverable on a switch that drops LSD multicast.
get() { grep -E "^${1}=" "${CONF}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]'; }
if [ -f "${CONF}" ]; then
    BLOB_SET="$(get BLOB_SERVERS)"; BLOB_SET="${BLOB_SET:-$(get BLOB_SERVER)}"
    BLOB_SET="${BLOB_SET:-$(get PXE_SERVER)}"
else
    BLOB_SET=""
fi
ANNOUNCE_HOST="${BLOB_SET%%,*}"; ANNOUNCE_HOST="${ANNOUNCE_HOST%%:*}"
[ -n "${ANNOUNCE_HOST}" ] || { echo "[publish] ERROR cannot derive the tracker host from ${CONF} (set PXE_SERVER)" >&2; exit 1; }
ANNOUNCE="${PARTYOS_ANNOUNCE:-http://${ANNOUNCE_HOST}:6969/announce}"

# --- what the blob records about itself --------------------------------------
# build-app-blob.sh and build-proton-blob.sh write game.meta at the blob root.
# build-proton-blob.sh also bakes EXE_REL and SAVE_REL into bin/run.sh.
META="$(unsquashfs -cat "${BLOB}" game.meta 2>/dev/null)" || META=""
meta_get() { printf '%s\n' "${META}" | grep -m1 "^${1}=" | cut -d= -f2- || true; }
KIND="native"; META_OVERLAY=""; META_SHM=""; META_MARKER=""; META_RAM_MIN=""; META_RAM_MAX=""
EXE_REL=""; SAVE_REL=""
if [ -z "${META}" ]; then
    echo "[publish] WARN no game.meta in the blob - publishing it as a native blob" >&2
elif [ "$(meta_get kind)" = "proton" ]; then
    KIND="proton"
    META_OVERLAY="$(meta_get overlay)"
    META_SHM="$(meta_get shm_mb | tr -dc '0-9')"
    META_MARKER="$(meta_get marker)"
    META_RAM_MIN="$(meta_get ram_min | tr -dc '0-9')"
    META_RAM_MAX="$(meta_get ram_max | tr -dc '0-9')"
    RUNSH="$(unsquashfs -cat "${BLOB}" bin/run.sh 2>/dev/null)" || RUNSH=""
    EXE_REL="$(printf '%s\n' "${RUNSH}" | sed -n 's/^EXE_REL="\(.*\)"$/\1/p' | head -1)"
    SAVE_REL="$(printf '%s\n' "${RUNSH}" | sed -n 's/^SAVE_REL="\(.*\)"$/\1/p' | head -1)"
    [ -n "${EXE_REL}" ] || echo "[publish] WARN no EXE_REL in bin/run.sh - the row gets an empty exe_rel" >&2
fi

SHA="$(python3 - "${BLOB}" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
print(h.hexdigest())
PY
)"
SIZE="$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "${BLOB}")"
[ "${SIZE}" -gt 0 ] || { echo "[publish] ERROR blob is empty: ${BLOB}" >&2; exit 1; }

DEST="${GAMES_DIR}/${NAME}.squashfs"
TORRENT="${DEST}.torrent"

echo "[publish] blob     : ${NAME}  (${SIZE} bytes, sha ${SHA:0:12})"
echo "[publish] games dir: ${GAMES_DIR}"
echo "[publish] announce : ${ANNOUNCE}"
echo "[publish] rpc      : ${RPC_URL}"
echo "[publish] kind     : ${KIND}${EXE_REL:+  (exe ${EXE_REL})}"
[ "${HIDDEN}" = 1 ] && echo "[publish] hidden   : yes${UNLOCK_CODE:+  (unlock code ${UNLOCK_CODE})}"

if [ "${DRY_RUN}" = 1 ]; then
    echo "[publish] DRY RUN - would place ${DEST}, write ${TORRENT}, add it to the running seeder, and upsert the ${NAME} catalog row"
    exit 0
fi

# --- the seeder RPC helper ---------------------------------------------------
# seeder_rpc MODE [ARGS] talks to the running aria2 seeder over JSON-RPC.
#   live INFO_HASH DEST STAGE_ROOT NAME
#       print "held" if a live entry has INFO_HASH, then one "old GID HASH" line for
#       each live entry of this blob (file DEST, or a file under STAGE_ROOT/NAME-*)
#       with another info-hash. Live means active, waiting or paused. A stopped
#       entry (complete, error, removed) does not seed, so it does not count.
#   add TORRENT DIR TIMEOUT
#       add the torrent with its data in DIR, then wait until the entry seeds all
#       pieces (status active, seeder true). If it fails or does not seed in
#       TIMEOUT seconds, remove the new entry again and exit 1.
#   remove GID...
#       remove each entry, wait until it stops, and drop its stopped result.
#   cleanup STAGE_ROOT NAME
#       delete each STAGE_ROOT/NAME-* dir that no live entry uses.
seeder_rpc() {
    RPC_URL="${RPC_URL}" RPC_SECRET="${RPC_SECRET}" python3 - "$@" <<'PY'
import base64, json, os, shutil, sys, time, urllib.request

url = os.environ["RPC_URL"]
token = "token:" + os.environ["RPC_SECRET"]
mode, args = sys.argv[1], sys.argv[2:]


def rpc(method, *params):
    body = json.dumps({"jsonrpc": "2.0", "id": "publish",
                       "method": method, "params": [token] + list(params)}).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        out = json.load(resp)
    if "error" in out:
        raise RuntimeError("%s: %s" % (method, out["error"]))
    return out["result"]


KEYS = ["gid", "infoHash", "status", "files"]


def live():
    return rpc("aria2.tellActive", KEYS) + rpc("aria2.tellWaiting", 0, 1000, KEYS)


def paths(entry):
    return [os.path.realpath(f.get("path", "")) for f in entry.get("files", []) if f.get("path")]


def is_gone(gid):
    return all(e.get("gid") != gid for e in live())


if mode == "live":
    want, dest, stage_root, name = args
    dest = os.path.realpath(dest)
    stage_prefix = os.path.join(os.path.realpath(stage_root), name + "-")
    for entry in live():
        ih = (entry.get("infoHash") or "").lower()
        if ih == want.lower():
            print("held")
            continue
        if any(p == dest or p.startswith(stage_prefix) for p in paths(entry)):
            print("old %s %s" % (entry["gid"], ih))

elif mode == "add":
    torrent, data_dir, timeout = args[0], args[1], float(args[2])
    with open(torrent, "rb") as handle:
        payload = base64.b64encode(handle.read()).decode()
    # seed-ratio 0.0 seeds forever. check-integrity checks the bytes against the
    # piece hashes, so the seeder never advertises a blob it cannot verify.
    options = {"dir": data_dir, "seed-ratio": "0.0", "check-integrity": "true"}
    gid = rpc("aria2.addTorrent", payload, [], options)
    print("[publish] seeder took the torrent over RPC (gid %s, no restart); waiting until it seeds" % gid)
    keys = ["status", "seeder", "completedLength", "totalLength", "errorCode", "errorMessage"]
    deadline = time.time() + timeout
    next_note = time.time() + 30
    st = {}
    while True:
        st = rpc("aria2.tellStatus", gid, keys)
        total = int(st.get("totalLength") or 0)
        done = int(st.get("completedLength") or 0)
        if st.get("status") == "active" and st.get("seeder") == "true" and total > 0 and done == total:
            print("[publish] seeder verified the torrent and seeds it (gid %s, %d bytes)" % (gid, total))
            sys.exit(0)
        if st.get("status") in ("error", "removed", "complete") or time.time() > deadline:
            break
        if time.time() > next_note:
            print("[publish] ... seeder has %d of %d bytes verified" % (done, total))
            next_note = time.time() + 30
        time.sleep(1)
    print("[publish] ERROR the seeder does not seed the new torrent (status %s, error %s %s)"
          % (st.get("status"), st.get("errorCode", "-"), st.get("errorMessage", "")), file=sys.stderr)
    for method in ("aria2.forceRemove", "aria2.removeDownloadResult"):
        try:
            rpc(method, gid)
            if method == "aria2.forceRemove":
                for _ in range(30):
                    if is_gone(gid):
                        break
                    time.sleep(1)
        except Exception:
            pass
    sys.exit(1)

elif mode == "remove":
    rc = 0
    for gid in args:
        try:
            rpc("aria2.remove", gid)
        except Exception as exc:
            if is_gone(gid):
                continue
            print("[publish] WARN aria2.remove %s: %s" % (gid, exc), file=sys.stderr)
        # aria2.remove is asynchronous: the entry stays until aria2c closes the file.
        for i in range(90):
            if is_gone(gid):
                break
            if i == 60:
                try:
                    rpc("aria2.forceRemove", gid)
                except Exception:
                    pass
            time.sleep(1)
        if not is_gone(gid):
            print("[publish] ERROR old entry %s is still in the seeder" % gid, file=sys.stderr)
            rc = 1
            continue
        try:
            rpc("aria2.removeDownloadResult", gid)
        except Exception:
            pass
    sys.exit(rc)

elif mode == "cleanup":
    stage_root, name = args
    used = set()
    for entry in live():
        used.update(paths(entry))
    if os.path.isdir(stage_root):
        for d in sorted(os.listdir(stage_root)):
            full = os.path.realpath(os.path.join(stage_root, d))
            if not d.startswith(name + "-"):
                continue
            if any(p == full or p.startswith(full + os.sep) for p in used):
                continue
            shutil.rmtree(full, ignore_errors=True)
            print("[publish] removed the unused stage dir %s" % full)
PY
}

GAMES_ABS="$(cd "${GAMES_DIR}" && pwd)"
SRC_ABS="$(cd "$(dirname "${BLOB}")" && pwd)/$(basename "${BLOB}")"
DEST_ABS="${GAMES_ABS}/${NAME}.squashfs"
# A re-publish seeds the new bytes from a stage dir first (see step 4).
STAGE_ROOT="${GAMES_ABS}/.publish"
STAGE="${STAGE_ROOT}/${NAME}-${SHA:0:12}"
VERIFY_TIMEOUT="${PARTYOS_PUBLISH_VERIFY_TIMEOUT:-1800}"

# --- 1. the torrent -----------------------------------------------------------
# make-torrent.py needs no external tool, so this works on the aarch64 party
# server where mktorrent is absent. The info-hash does not depend on the dir of the
# file, only on its bytes and its name (NAME.squashfs). So the torrent is made from
# the source blob, before any byte in the games dir changes.
TORRENT_TMP="${GAMES_ABS}/.${NAME}.squashfs.torrent.publish"
INFO_HASH="$(python3 "${MAKE_TORRENT}" "${BLOB}" "${TORRENT_TMP}" \
    --announce "${ANNOUNCE}" --comment "partyOS blob ${NAME}")" || {
    rm -f "${TORRENT_TMP}"
    echo "[publish] ERROR torrent generation failed - catalog NOT touched" >&2; exit 1; }
trap 'rm -f "${TORRENT_TMP}"' EXIT
echo "[publish] torrent  : info-hash ${INFO_HASH}"

# place_bytes DIR - put the blob bytes at DIR/NAME.squashfs, with the sidecar and
# the torrent. Every file goes to a sibling temp and is renamed, and a rename inside
# one directory is atomic, so the seeder never opens a half-copied squashfs. A hard
# link from the stage dir costs no copy.
place_bytes() {
    local dir="$1" from="${2:-${BLOB}}" dst="$1/${NAME}.squashfs"
    if [ "$(cd "$(dirname "${from}")" && pwd)/$(basename "${from}")" != "${dst}" ]; then
        if [ "${from}" != "${BLOB}" ]; then
            ln -f "${from}" "${dst}.publish.tmp" 2>/dev/null || cp -f "${from}" "${dst}.publish.tmp"
        else
            cp -f "${from}" "${dst}.publish.tmp"
        fi
        mv -f "${dst}.publish.tmp" "${dst}"
    fi
    printf '%s\n' "${SHA}" > "${dst}.sha256.publish.tmp"
    mv -f "${dst}.sha256.publish.tmp" "${dst}.sha256"
    cp -f "${TORRENT_TMP}" "${dst}.torrent.publish.tmp"
    mv -f "${dst}.torrent.publish.tmp" "${dst}.torrent"
}

# --- 2. what the running seeder holds for this blob --------------------------
HELD=0; OLD_GIDS=""; OLD_HASHES=""
if [ "${NO_SEED}" = 0 ]; then
    LIVE="$(seeder_rpc live "${INFO_HASH}" "${DEST_ABS}" "${STAGE_ROOT}" "${NAME}")" || {
        echo "[publish] ERROR could not ask the running seeder over RPC - catalog NOT touched" >&2
        echo "[publish]       start the server stack, or re-run with --no-seed to publish without a live seed" >&2
        exit 1; }
    printf '%s\n' "${LIVE}" | grep -qx held && HELD=1
    OLD_GIDS="$(printf '%s\n' "${LIVE}" | awk '$1 == "old" { print $2 }' | tr '\n' ' ')"
    OLD_HASHES="$(printf '%s\n' "${LIVE}" | awk '$1 == "old" { print substr($3, 1, 12) }' | tr '\n' ' ')"
fi

# --- 3. and 4. the bytes and the seed ----------------------------------------
# aria2c refuses a second torrent for a file that a live entry already uses
# ("is being downloaded by other command", error 11). So:
#   - No old info-hash for this blob: place the bytes in the games dir, then add
#     the torrent to the running seeder (as for a new blob).
#   - An old info-hash seeds this blob (a re-publish with new bytes): place the new
#     bytes in the stage dir .publish/NAME-<sha>, add the new torrent from there and
#     wait until it seeds. Only then remove the old info-hash, and move the bytes to
#     the games dir. The swarm always has a server seed. If a step fails, the old
#     seed and the catalog stay as they are.
# The seeder does not restart, so the in-flight downloads of other blobs continue.
if [ "${NO_SEED}" = 1 ]; then
    place_bytes "${GAMES_ABS}"
    echo "[publish] placed ${DEST}"
    echo "[publish] --no-seed - skipping the RPC step (the seeder picks this up on its next respawn)"
elif [ "${HELD}" = 1 ]; then
    echo "[publish] seeder already holds ${INFO_HASH:0:12} - RPC add skipped (idempotent)"
    if [ -n "${OLD_GIDS}" ]; then
        seeder_rpc remove ${OLD_GIDS} || {
            echo "[publish] ERROR could not remove the old info-hash ${OLD_HASHES}from the seeder - catalog NOT touched, re-run" >&2; exit 1; }
        echo "[publish] removed the old info-hash ${OLD_HASHES}from the seeder"
    fi
    if [ -f "${STAGE}/${NAME}.squashfs" ]; then
        place_bytes "${GAMES_ABS}" "${STAGE}/${NAME}.squashfs"
    else
        place_bytes "${GAMES_ABS}"
    fi
    echo "[publish] placed ${DEST}"
elif [ -z "${OLD_GIDS}" ]; then
    place_bytes "${GAMES_ABS}"
    echo "[publish] placed ${DEST}"
    seeder_rpc add "${DEST}.torrent" "${GAMES_ABS}" "${VERIFY_TIMEOUT}" || {
        echo "[publish] ERROR the running seeder does not seed the torrent - catalog NOT touched" >&2
        echo "[publish]       start the server stack, or re-run with --no-seed to publish without a live seed" >&2
        exit 1; }
else
    echo "[publish] re-publish: the seeder holds the old info-hash ${OLD_HASHES}for ${NAME}"
    mkdir -p "${STAGE}"
    if [ "${SRC_ABS}" = "${DEST_ABS}" ]; then
        # The new bytes are already at the games dir path. Link them into the stage.
        place_bytes "${STAGE}" "${DEST_ABS}"
    else
        place_bytes "${STAGE}"
    fi
    echo "[publish] staged   : ${STAGE}"
    seeder_rpc add "${STAGE}/${NAME}.squashfs.torrent" "${STAGE}" "${VERIFY_TIMEOUT}" || {
        rm -rf "${STAGE}"
        echo "[publish] ERROR the running seeder does not seed the new torrent - the old seed and the catalog are NOT touched" >&2
        exit 1; }
    seeder_rpc remove ${OLD_GIDS} || {
        echo "[publish] ERROR could not remove the old info-hash ${OLD_HASHES}from the seeder - catalog NOT touched, re-run" >&2; exit 1; }
    echo "[publish] removed the old info-hash ${OLD_HASHES}from the seeder (the new one seeds from ${STAGE})"
    place_bytes "${GAMES_ABS}" "${STAGE}/${NAME}.squashfs"
    echo "[publish] placed ${DEST} (a hard link of the staged bytes)"
fi
rm -f "${TORRENT_TMP}"
if [ "${NO_SEED}" = 0 ]; then
    seeder_rpc cleanup "${STAGE_ROOT}" "${NAME}" || true
    rmdir "${STAGE_ROOT}" 2>/dev/null || true
fi
echo "[publish] torrent  : ${TORRENT}  (info-hash ${INFO_HASH})"

# --- 5. the catalog (last, and atomic) ---------------------------------------
# Upsert the row, then render catalog.json. Both writes go through a temp file,
# fsync and rename, so a client that fetches during the publish reads either the
# old catalog or the new one, never a truncated one.
NAME="${NAME}" SHA="${SHA}" SIZE="${SIZE}" TITLE="${TITLE}" EXEC="${EXEC}" \
CATEGORY="${CATEGORY}" APP_ID="${APP_ID}" RAM_MIN="${RAM_MIN}" RAM_MAX="${RAM_MAX}" \
ENTRY="${ENTRY}" ICON="${ICON}" HIDDEN="${HIDDEN}" UNLOCK_CODE="${UNLOCK_CODE}" \
KIND="${KIND}" META_OVERLAY="${META_OVERLAY}" META_SHM="${META_SHM}" META_MARKER="${META_MARKER}" \
META_RAM_MIN="${META_RAM_MIN}" META_RAM_MAX="${META_RAM_MAX}" EXE_REL="${EXE_REL}" SAVE_REL="${SAVE_REL}" \
python3 - "${CATALOG_V2}" <<'PY'
import json, os, sys

path = sys.argv[1]
name = os.environ["NAME"]
with open(path) as handle:
    catalog = json.load(handle)
games = catalog.setdefault("games", [])

# Keep every row rectangular. The no-jq parser in partyos-app reads the rows as
# parallel arrays, so a new row must carry the same key set as the existing blob
# rows. Build that key set from the rows already in the catalog.
keys = set()
for row in games:
    if row.get("source") == "blob":
        keys.update(row.keys())

env = os.environ.get
proton = env("KIND") == "proton"
# The Windows fields of a Proton blob come from the blob. They are build facts,
# the same values build-proton-blob.sh writes to its own catalog row.
windows = {}
if proton:
    windows = {
        "proton": True,
        "overlay": env("META_OVERLAY", "1") != "0",
        "shm_mb": int(env("META_SHM") or 0),
        "marker": env("META_MARKER") or "PARTYOS-BLOB-RUN " + name,
        "exe_rel": env("EXE_REL", ""),
        "save_rel": env("SAVE_REL", ""),
    }

defaults = {
    "id": env("APP_ID") or "partyos." + name,
    "name": name,
    "hidden": env("HIDDEN") == "1",
    "unlock_code": env("UNLOCK_CODE", ""),
    "title": os.environ.get("TITLE") or name.replace("-", " ").title(),
    "source": "blob",
    "blob": "server/games/%s.squashfs" % name,
    "sha256": os.environ["SHA"],
    "size": int(os.environ["SIZE"]),
    "ram_min": int(env("RAM_MIN") or env("META_RAM_MIN") or (2048 if proton else 512)),
    "ram_max": int(env("RAM_MAX") or env("META_RAM_MAX") or (4096 if proton else 2048)),
    "version": "1.0.0",
    "category": env("CATEGORY") or "game",
    # A stock theme icon: the image has no icon file for a title it does not know.
    "icon": env("ICON") or "applications-games",
    # A Proton blob starts from bin/run.sh, so it has no exec (as build-proton-blob.sh).
    "exec": env("EXEC") or ("" if proton else name),
    "pkg": "",
    "pkgs": "",
    "entry": env("ENTRY") or "bin/run.sh",
    "marker": "",
    "needs_server": False,
    "proton": False,
    "overlay": False,
    "shm_mb": 0,
}
defaults.update(windows)

existing = next((r for r in games if r.get("name") == name), None)
if existing is None:
    row = dict(defaults)
    # Fill every remaining key with a sentinel of the type the other blob rows
    # use for it: empty string for text, 0 for numbers, False for flags, [] for
    # lists. This keeps the row rectangular without inventing values.
    for key in keys - set(row):
        sample = next((r[key] for r in games
                       if r.get("source") == "blob" and key in r), "")
        if isinstance(sample, bool):
            row[key] = False
        elif isinstance(sample, (int, float)):
            row[key] = 0
        elif isinstance(sample, list):
            row[key] = []
        elif isinstance(sample, dict):
            row[key] = {}
        else:
            row[key] = ""
    games.append(row)
    action = "inserted"
else:
    # A re-publish updates only the build-derived facts. For a Proton blob these
    # include the Windows fields (proton, overlay, shm_mb, marker, exe_rel,
    # save_rel). Operator-tuned fields (config_*, needs_server, server_pkg,
    # version, hidden, unlock_code, category, icon, RAM) survive, the same
    # discipline add-blob.sh and build-app-blob.sh use.
    derived = {"sha256": defaults["sha256"], "size": defaults["size"],
               "blob": defaults["blob"], "source": "blob"}
    derived.update(windows)
    for key, value in derived.items():
        existing[key] = value
    if env("HIDDEN") == "1":
        existing["hidden"] = True
    if env("UNLOCK_CODE"):
        existing["unlock_code"] = env("UNLOCK_CODE")
    # An explicit flag on a re-publish is an operator decision, so it wins.
    for env_key, row_key in (("TITLE", "title"), ("EXEC", "exec"),
                             ("CATEGORY", "category"), ("APP_ID", "id"),
                             ("ENTRY", "entry"), ("ICON", "icon")):
        if os.environ.get(env_key):
            existing[row_key] = os.environ[env_key]
    for env_key, row_key in (("RAM_MIN", "ram_min"), ("RAM_MAX", "ram_max")):
        if os.environ.get(env_key):
            existing[row_key] = int(os.environ[env_key])
    for key, value in defaults.items():
        existing.setdefault(key, value)
    action = "updated"

tmp = path + ".publish.tmp"
with open(tmp, "w") as handle:
    json.dump(catalog, handle, indent=2)
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, path)
print("[publish] catalog.v2.json %s row %s (sha %s)" % (action, name, os.environ["SHA"][:12]),
      file=sys.stderr)
PY

bash "${BUILD_GAME_BLOBS}" "${GAMES_DIR}"

echo "[publish] DONE ${NAME} is live."
echo "[publish]   https server, tracker and seeder all kept running (no restart)."
echo "[publish]   clients refresh the store on the partyos-appstore timer, so the"
echo "[publish]   title appears within 180 seconds with no client reboot."
