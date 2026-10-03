#!/usr/bin/env bash
# test-torrent-swarm.sh - autonomous test for the SHIPPED BitTorrent blob path.
#
# The aria2/torrent path under test:
#   * tracker      = server/bt_tracker.py           (unicast peer discovery)
#   * torrents     = scripts/build/gen-blob-torrents.sh (announce baked, NO web-seed)
#   * server seed  = the aria2c seeder in scripts/deploy/run-servers.sh
#   * client dl    = the aria2c call in get_blob() in the baked partyos-app
#   * client seed  = start_seed() in partyos-app + the baked partyos-seeder.service
#                    ("seed cached blobs on boot")
# A green run of this test proves production blob distribution, including
# client boot-seeding.
#
# WHAT IT PROVES (the swarm), end to end, with the REAL shipped components:
#   1. SERVER seeds a blob over the torrent path (real seeder flags + real tracker).
#   2. CLIENT A downloads the blob via the shipped client get_blob aria2 path and
#      the sha256 matches - the transfer path works.
#   3. The SERVER seeder is then STOPPED and A begins seeding with the EXACT
#      partyos-seeder.service invocation (start_seed's aria2 flags). This is the
#      "seed cached blobs on boot" behaviour.
#   4. CLIENT B downloads with the server seeder DEAD and the torrent carrying NO
#      web-seed, so the ONLY possible source is A's boot-seeder. B's sha256
#      matches -> B's bytes came from A. Provenance is corroborated by the
#      tracker's own peer log (A registered as a complete seeder, B as a leecher).
#
# Each client is a host aria2 process, not a QEMU guest: discovery uses a unicast tracker.
# The aria2 flags that affect the transfer are copied from the shipped call sites.
#
# Tunables: SWARM_BLOB_MB (blob size), SWARM_TIMEOUT (per-download seconds).
# Deps: aria2c, mktorrent (or docker for gen-blob-torrents.sh's container path),
#       python3, a sha256 tool. Missing deps -> a clear SKIP (exit 0), never a
#       false PASS.

set -uo pipefail

# config.sh probes a QEMU accelerator by launching a paused VM; this test never
# starts QEMU, so pre-set ACCEL to skip that probe (the value is unused here).
: "${ACCEL:=none}"; export ACCEL
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
BLOB_MB="${SWARM_BLOB_MB:-16}"          # test blob size (MiB); >1 piece so BT moves pieces
DL_TIMEOUT="${SWARM_TIMEOUT:-120}"      # per-download hard timeout (seconds)
BLOB_NAME="swarmtest.squashfs"          # gen-blob-torrents.sh globs *.squashfs
GEN_TORRENTS="${REPO_ROOT}/scripts/build/gen-blob-torrents.sh"
TRACKER="${REPO_ROOT}/server/bt_tracker.py"

# aria2 listen-port bands, one per role so a tracker announce's port= band tells
# the roles apart. Server seed + A download run concurrently but pick distinct
# free ports within their bands; A's boot-seeder uses the real 51413.. seeder band.
SRV_SEED_PORTS="6881-6889"
A_DL_PORTS="6890-6899"
A_SEED_PORTS="51413-51420"
B_DL_PORTS="6910-6929"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-swarm.XXXXXX")"
SERVER_DIR="${RUN}/server"              # server's blob + torrent (seeded)
A_DIR="${RUN}/clientA"                  # client A cache dir (downloads + then seeds)
B_DIR="${RUN}/clientB"                  # client B cache dir (downloads)
TRK_LOG="${RUN}/tracker.log"
SRV_SEED_LOG="${RUN}/server-seed.log"
A_DL_LOG="${RUN}/a-download.log"
A_SEED_LOG="${RUN}/a-seed.log"
B_DL_LOG="${RUN}/b-download.log"
mkdir -p "${SERVER_DIR}" "${A_DIR}" "${B_DIR}"

TRK_PID=""; SRV_SEED_PID=""; A_SEED_PID=""
GTIMEOUT="$(command -v gtimeout || command -v timeout || true)"

cleanup() {
    local rc=$?
    [ -n "${A_SEED_PID}" ]  && kill "${A_SEED_PID}"  2>/dev/null || true
    [ -n "${SRV_SEED_PID}" ] && kill "${SRV_SEED_PID}" 2>/dev/null || true
    [ -n "${TRK_PID}" ]     && kill "${TRK_PID}"     2>/dev/null || true
    # any stray aria2c leechers/seeders spawned from this run dir
    pkill -f "aria2c .*${RUN}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[swarm] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

log()  { printf '[swarm] %s\n' "$*" >&2; }
skip() { echo "TEST-TORRENT-SWARM: SKIP - $*" >&2; exit 0; }

# portable sha256 (Linux sha256sum / macOS shasum -a 256).
_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
# free loopback TCP port (avoid colliding with anything already bound on the host).
_free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
# run a foreground command under a hard timeout (gtimeout if present, else a
# bash watchdog). Returns the command's rc (124-ish on timeout kill).
_run_timeout() {
    local secs="$1"; shift
    if [ -n "${GTIMEOUT}" ]; then "${GTIMEOUT}" "${secs}" "$@"; return $?; fi
    "$@" & local p=$!
    ( sleep "${secs}"; kill -9 "$p" 2>/dev/null ) & local w=$!
    local rc=0; wait "$p" 2>/dev/null || rc=$?
    kill "$w" 2>/dev/null || true; wait "$w" 2>/dev/null || true
    return "${rc}"
}

# --- 0. dependencies (SKIP, never false-PASS, when tooling is absent) --------
command -v aria2c  >/dev/null 2>&1 || skip "aria2c not installed"
command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
{ command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; } || skip "no sha256 tool"
[ -f "${TRACKER}" ]      || skip "missing tracker ${TRACKER}"
[ -x "${GEN_TORRENTS}" ] || [ -f "${GEN_TORRENTS}" ] || skip "missing ${GEN_TORRENTS}"
# gen-blob-torrents.sh needs mktorrent OR docker (its container fallback).
command -v mktorrent >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 \
    || skip "neither mktorrent nor docker (gen-blob-torrents.sh cannot build the torrent)"

# --- 1. build the test blob + REAL torrent (announce baked, NO web-seed) -----
# Incompressible random data so the .torrent has real distinct pieces to move.
log "creating ${BLOB_MB} MiB test blob ${BLOB_NAME}..."
dd if=/dev/urandom of="${SERVER_DIR}/${BLOB_NAME}" bs=1048576 count="${BLOB_MB}" status=none 2>/dev/null \
    || { echo "TEST-TORRENT-SWARM: FAIL - blob create failed" >&2; exit 1; }
BLOB_SHA="$(_sha256 "${SERVER_DIR}/${BLOB_NAME}")"
log "blob sha256=${BLOB_SHA}"

# Pick the tracker port FIRST so we can bake its announce URL into the torrent,
# then start the tracker on that exact port. NO WEBSEED (unset) => the shipped
# torrents' "P2P only, no HTTP source" property, which is exactly the lever that
# makes client B's completion proof that its bytes came from a peer.
TRK_PORT="$(_free_port)"
TRK_URL="http://127.0.0.1:${TRK_PORT}/announce"
log "generating torrent via the shipped gen-blob-torrents.sh (announce=${TRK_URL}, no web-seed)..."
ANNOUNCE="${TRK_URL}" WEBSEED="" bash "${GEN_TORRENTS}" "${SERVER_DIR}" >&2 \
    || { echo "TEST-TORRENT-SWARM: FAIL - torrent generation failed" >&2; exit 1; }
TORRENT="${SERVER_DIR}/${BLOB_NAME}.torrent"
[ -s "${TORRENT}" ] || { echo "TEST-TORRENT-SWARM: FAIL - no torrent produced" >&2; exit 1; }

# Assert torrent shape with a tiny bdecode: announce == our tracker, NO url-list
# (web-seed). This is a static guard that the shipped generator kept the P2P-only
# contract for this run (a stray web-seed would invalidate the peer-provenance proof).
TORRENT_OK="$(python3 - "${TORRENT}" "${TRK_URL}" <<'PY'
import sys
def bdecode(b, i=0):
    c = b[i:i+1]
    if c == b'i':
        j = b.index(b'e', i); return int(b[i+1:j]), j+1
    if c == b'l':
        i += 1; out = []
        while b[i:i+1] != b'e':
            v, i = bdecode(b, i); out.append(v)
        return out, i+1
    if c == b'd':
        i += 1; out = {}
        while b[i:i+1] != b'e':
            k, i = bdecode(b, i); v, i = bdecode(b, i); out[k] = v
        return out, i+1
    j = b.index(b':', i); n = int(b[i:j]); s = b[j+1:j+1+n]; return s, j+1+n
data = open(sys.argv[1], 'rb').read()
d, _ = bdecode(data)
ann = d.get(b'announce', b'').decode('utf-8', 'ignore')
has_ws = (b'url-list' in d)
print("announce=%s webseed=%s" % (ann, has_ws))
sys.exit(0 if (ann == sys.argv[2] and not has_ws) else 1)
PY
)" && TORRENT_SHAPE_OK=1 || TORRENT_SHAPE_OK=0
log "torrent: ${TORRENT_OK}"

# --- 2. start the REAL tracker (server/bt_tracker.py) on the baked port -------
log "starting tracker (server/bt_tracker.py) on 127.0.0.1:${TRK_PORT}..."
python3 -u "${TRACKER}" "${TRK_PORT}" 127.0.0.1 >"${TRK_LOG}" 2>&1 &
TRK_PID=$!
for _ in $(seq 1 40); do
    curl -s -o /dev/null "http://127.0.0.1:${TRK_PORT}/health" 2>/dev/null && break
    kill -0 "${TRK_PID}" 2>/dev/null || { echo "TEST-TORRENT-SWARM: FAIL - tracker died on start" >&2; cat "${TRK_LOG}" >&2; exit 1; }
    sleep 0.2
done
curl -fsS -o /dev/null "http://127.0.0.1:${TRK_PORT}/health" 2>/dev/null \
    || { echo "TEST-TORRENT-SWARM: FAIL - tracker not answering /health" >&2; exit 1; }
log "tracker up pid=${TRK_PID}"

# --- 3. SERVER seeder: the shipped run-servers.sh aria2 seeder flags ----------
# Verbatim from scripts/deploy/run-servers.sh:286-293, with host-only adjustments:
#   * --bt-external-ip=127.0.0.1 (the shipped seeder uses BLOB_FIRST_IP, which is
#     not reachable in this loopback test - the tracker must advertise a reachable address for loopback peers)
#   * dropped --enable-rpc/--rpc-* (an extra listener the transfer does not need)
#   * --summary-interval=0 (no periodic summary noise); --log captured for asserts.
log "starting SERVER seeder (shipped seeder flags)..."
aria2c --enable-dht=false --bt-enable-lpd=true --enable-peer-exchange=true \
    --seed-ratio=0.0 --check-integrity=true --bt-external-ip=127.0.0.1 \
    --max-concurrent-downloads=64 --bt-detach-seed-only=true \
    --listen-port="${SRV_SEED_PORTS}" --console-log-level=notice --log-level=notice \
    --summary-interval=0 --log="${SRV_SEED_LOG}" \
    -d "${SERVER_DIR}" "${TORRENT}" >/dev/null 2>&1 &
SRV_SEED_PID=$!
# let the seeder announce to the tracker before A leeches.
for _ in $(seq 1 25); do
    grep -q "left=0" "${TRK_LOG}" 2>/dev/null && break
    kill -0 "${SRV_SEED_PID}" 2>/dev/null || break
    sleep 0.2
done
kill -0 "${SRV_SEED_PID}" 2>/dev/null \
    || { echo "TEST-TORRENT-SWARM: FAIL - server seeder exited early" >&2; cat "${SRV_SEED_LOG}" >&2; exit 1; }
log "server seeder up pid=${SRV_SEED_PID} (announced to tracker)"

# --- 4. CLIENT A downloads via the shipped get_blob aria2 path ----------------
# Verbatim from get_blob() in the baked partyos-app (the catalog install download),
# minus --ca-certificate (no HTTPS web-seed here). console-log-level raised to
# notice + a --log file for the assertions; transfer flags are unchanged.
log "CLIENT A downloading (shipped client get_blob flags)..."
cp "${TORRENT}" "${A_DIR}/${BLOB_NAME}.torrent"   # clients cache the torrent beside the blob
_run_timeout "${DL_TIMEOUT}" \
    aria2c --bt-enable-lpd=true --enable-dht=false --enable-peer-exchange=true \
    --listen-port="${A_DL_PORTS}" \
    --seed-time=0 --seed-ratio=0.0 --bt-detach-seed-only=true --bt-stop-timeout=180 \
    --file-allocation=none --allow-overwrite=true --auto-file-renaming=false \
    --console-log-level=notice --summary-interval=0 \
    --log="${A_DL_LOG}" -d "${A_DIR}" "${A_DIR}/${BLOB_NAME}.torrent" >/dev/null 2>&1 || true
A_SHA=""; [ -s "${A_DIR}/${BLOB_NAME}" ] && A_SHA="$(_sha256 "${A_DIR}/${BLOB_NAME}")"
A_DL_OK=0; [ -n "${A_SHA}" ] && [ "${A_SHA}" = "${BLOB_SHA}" ] && A_DL_OK=1
log "client A download: sha=${A_SHA:-<none>} ok=${A_DL_OK}"
[ "${A_DL_OK}" -eq 1 ] || { echo "TEST-TORRENT-SWARM: FAIL - client A never got the blob from the server swarm" >&2; tail -20 "${A_DL_LOG}" >&2 2>/dev/null || true; exit 1; }

# --- 5. A becomes the boot-seeder; SERVER seeder is STOPPED -------------------
# This is EXACTLY what partyos-seeder.service does at boot: partyos-seed-cached ->
# partyos-app seed-cached -> start_seed per cached blob. Flags verbatim from
# start_seed() in the baked partyos-app, minus --ca-certificate and the
# systemd-run --scope wrapper (a shutdown-teardown/cgroup concern, not transfer).
log "CLIENT A boot-seeding its cached blob (partyos-seeder.service start_seed flags)..."
aria2c --bt-enable-lpd=true --enable-dht=false --enable-peer-exchange=true \
    --listen-port="${A_SEED_PORTS}" \
    --seed-ratio=0.0 --max-upload-limit=0 --check-integrity=true \
    --console-log-level=notice --summary-interval=0 \
    --log="${A_SEED_LOG}" -d "${A_DIR}" "${A_DIR}/${BLOB_NAME}.torrent" >/dev/null 2>&1 &
A_SEED_PID=$!
# wait until A's seeder has announced to the tracker as a complete peer (left=0
# from the seeder band), so B is guaranteed to be handed A on its first announce.
for _ in $(seq 1 25); do
    grep -Eq "peer=127\.0\.0\.1:5141[0-9] .*left=0" "${TRK_LOG}" 2>/dev/null && break
    kill -0 "${A_SEED_PID}" 2>/dev/null || break
    sleep 0.2
done
kill -0 "${A_SEED_PID}" 2>/dev/null \
    || { echo "TEST-TORRENT-SWARM: FAIL - client A boot-seeder exited early" >&2; cat "${A_SEED_LOG}" >&2; exit 1; }

# STOP the server seeder (SIGTERM), so the swarm's ONLY LIVE source is A. The
# torrent also has no web-seed, so there is no HTTP source either. The load-bearing fact for provenance is that the
# server aria2 PROCESS is confirmed dead before B runs (a still-listed but dead peer
# in the tracker cannot serve a byte) - we verify the PID is gone, not that it
# managed to send a 'stopped' announce in the sub-second window.
log "stopping SERVER seeder so A is the ONLY source for B..."
kill "${SRV_SEED_PID}" 2>/dev/null || true
for _ in $(seq 1 25); do kill -0 "${SRV_SEED_PID}" 2>/dev/null || break; sleep 0.2; done
SERVER_DEAD_FOR_B=0; kill -0 "${SRV_SEED_PID}" 2>/dev/null || SERVER_DEAD_FOR_B=1
SRV_SEED_PID=""   # reaped; don't re-kill in cleanup
log "server seeder dead before B: ${SERVER_DEAD_FOR_B}"

# --- 6. CLIENT B downloads with ONLY A seeding -> proves peer + boot-seeding ---
log "CLIENT B downloading (server dead, no web-seed; only source is A's boot-seeder)..."
cp "${TORRENT}" "${B_DIR}/${BLOB_NAME}.torrent"
_run_timeout "${DL_TIMEOUT}" \
    aria2c --bt-enable-lpd=true --enable-dht=false --enable-peer-exchange=true \
    --listen-port="${B_DL_PORTS}" \
    --seed-time=0 --seed-ratio=0.0 --bt-detach-seed-only=true --bt-stop-timeout=180 \
    --file-allocation=none --allow-overwrite=true --auto-file-renaming=false \
    --console-log-level=notice --summary-interval=0 \
    --log="${B_DL_LOG}" -d "${B_DIR}" "${B_DIR}/${BLOB_NAME}.torrent" >/dev/null 2>&1 || true
B_SHA=""; [ -s "${B_DIR}/${BLOB_NAME}" ] && B_SHA="$(_sha256 "${B_DIR}/${BLOB_NAME}")"
B_DL_OK=0; [ -n "${B_SHA}" ] && [ "${B_SHA}" = "${BLOB_SHA}" ] && B_DL_OK=1

A_SEEDER_ALIVE=0; [ -n "${A_SEED_PID}" ] && kill -0 "${A_SEED_PID}" 2>/dev/null && A_SEEDER_ALIVE=1

# --- provenance from the tracker's own peer log ------------------------------
# Read each peer's ACTUAL BitTorrent listen port from its aria2 log ("listening on
# TCP port N") rather than assuming which port in the band aria2 grabbed, then grep
# the tracker log for that exact peer. Single torrent in play, so any announce line
# is for our blob - no info-hash correlation needed.
_listen_port() { grep -oE 'BitTorrent: listening on TCP port [0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+$' | head -1; }
A_SEED_PORT="$(_listen_port "${A_SEED_LOG}")"
B_PORT="$(_listen_port "${B_DL_LOG}")"

# A registered as a COMPLETE seeder (left=0) on its boot-seeder port.
TRK_SAW_A_SEED=0
[ -n "${A_SEED_PORT}" ] && grep -Eq "peer=127\.0\.0\.1:${A_SEED_PORT} .*left=0" "${TRK_LOG}" 2>/dev/null && TRK_SAW_A_SEED=1
# B announced as a LEECHER (left>0) AND the tracker reported >=1 complete seeder to
# hand it - i.e. A was in the peer list B received. That is the "bytes came from A"
# tracker-side corroboration (the server process was already confirmed dead above).
TRK_SAW_B_LEECH=0
[ -n "${B_PORT}" ] && grep -Eq "peer=127\.0\.0\.1:${B_PORT} .*left=[1-9].*complete=[1-9]" "${TRK_LOG}" 2>/dev/null && TRK_SAW_B_LEECH=1

echo "----- tracker peer log (tail; A-seed port=${A_SEED_PORT:-?} B port=${B_PORT:-?}) -----" >&2
tail -15 "${TRK_LOG}" >&2 2>/dev/null || true
echo "-----------------------------------" >&2

# ===================== VERDICT ============================================
echo "================= TEST-TORRENT-SWARM VERDICT =================" >&2
echo "torrent shape ok (announce=tracker, no web-seed)   : ${TORRENT_SHAPE_OK}" >&2
echo "client A downloaded blob (sha match, shipped path)  : ${A_DL_OK}" >&2
echo "client A boot-seeder alive (partyos-seeder path)    : ${A_SEEDER_ALIVE}" >&2
echo "SERVER seeder DEAD before/through B's download       : ${SERVER_DEAD_FOR_B}" >&2
echo "client B downloaded blob (sha match, integrity)     : ${B_DL_OK}" >&2
echo "tracker saw A as a COMPLETE seeder (left=0)          : ${TRK_SAW_A_SEED}" >&2
echo "tracker saw B announce as a leecher                  : ${TRK_SAW_B_LEECH}" >&2
echo "blob sha256                                          : ${BLOB_SHA}" >&2
echo "  A sha256=${A_SHA:-<none>}  B sha256=${B_SHA:-<none>}" >&2

if [ "${TORRENT_SHAPE_OK}" -eq 1 ] && [ "${A_DL_OK}" -eq 1 ] && \
   [ "${A_SEEDER_ALIVE}" -eq 1 ] && [ "${SERVER_DEAD_FOR_B}" -eq 1 ] && \
   [ "${B_DL_OK}" -eq 1 ] && [ "${TRK_SAW_A_SEED}" -eq 1 ] && \
   [ "${TRK_SAW_B_LEECH}" -eq 1 ]; then
    echo "TEST-TORRENT-SWARM: PASS (B pulled ${BLOB_NAME} from A's boot-seeder; server stopped, no web-seed)" >&2
    exit 0
fi
echo "TEST-TORRENT-SWARM: FAIL - not all swarm assertions met" >&2
tail -20 "${B_DL_LOG}" >&2 2>/dev/null || true
exit 1
