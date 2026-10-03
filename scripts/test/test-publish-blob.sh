#!/usr/bin/env bash
# test-publish-blob.sh - hardware-FREE unit test for the mid-party publish path
# (scripts/deploy/publish-blob.sh + scripts/deploy/make-torrent.py). No VM, no
# docker, no network, no real blob build. A stub squashfs and a stub aria2 RPC
# server prove the PLUMBING: the bytes, the sidecar, the torrent, the RPC add and
# the atomic catalog publish.
#
# Asserts:
#   * make-torrent.py reproduces the info-hash of a torrent mktorrent already made,
#     so the pure-Python maker is a drop-in on the aarch64 party server.
#   * the torrent carries the tracker announce URL from deploy.conf. A blob with no
#     announce URL is undiscoverable, because blobs are BitTorrent-only.
#   * publish-blob.sh places the blob, the .sha256 sidecar and the .torrent, then
#     upserts a RECTANGULAR catalog row and renders catalog.json.
#   * the running seeder is fed over aria2 JSON-RPC (aria2.addTorrent), never
#     restarted, and a re-publish of the same info-hash SKIPS the add (idempotent).
#   * a re-publish leaves exactly one row and preserves an operator-tuned field.
#   * a re-publish keeps hidden, unlock_code, category, icon and RAM, unless a
#     flag sets them.
#   * --hidden and --unlock-code land in the same write as a new row, so no
#     catalog state shows the row visible. A bad code is refused before any write.
#   * a new row with no --icon gets the stock applications-games icon.
#   * a Proton blob gets proton, overlay, shm_mb, marker, exe_rel and save_rel
#     from its game.meta and bin/run.sh, and RAM 2048/4096 when game.meta has none.
#   * an RPC failure leaves the catalog UNCHANGED (catalog-last ordering).
#   * the LIVE server/games/catalog.v2.json is byte-identical before and after.
set -uo pipefail
# A publish waits for the seed. The stub seeds at once, so a short wait is enough.
export PARTYOS_PUBLISH_VERIFY_TIMEOUT=20
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

PUBLISH="${REPO_ROOT}/scripts/deploy/publish-blob.sh"
MAKE_TORRENT="${REPO_ROOT}/scripts/deploy/make-torrent.py"
LIVE_CATALOG="${REPO_ROOT}/server/games/catalog.v2.json"

for f in "${PUBLISH}" "${MAKE_TORRENT}" "${REPO_ROOT}/scripts/build/build-game-blobs.sh"; do
    [ -f "${f}" ] || { echo "FAIL: missing ${f}"; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-publish.XXXXXX")"
RPC_PID=""; WATCH_PID=""
cleanup() {
    [ -n "${RPC_PID}" ] && kill ${RPC_PID} 2>/dev/null
    [ -n "${WATCH_PID}" ] && kill "${WATCH_PID}" 2>/dev/null
    rm -rf "${TMP}"
}
trap cleanup EXIT

LIVE_SHA_BEFORE=""
[ -f "${LIVE_CATALOG}" ] && LIVE_SHA_BEFORE="$(shasum -a 256 "${LIVE_CATALOG}" | awk '{print $1}')"

# --- fixture: a temp games dir with a minimal catalog and a stub blob ---------
GAMES="${TMP}/games"; mkdir -p "${GAMES}"
cat > "${GAMES}/catalog.v2.json" <<'JSON'
{
  "version": 3,
  "games": [
    {
      "id": "partyos.existing", "name": "existing", "hidden": false,
      "title": "Existing", "source": "blob", "blob": "server/games/existing.squashfs",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "size": 1, "ram_min": 512, "ram_max": 1024, "version": "1.0.0",
      "category": "game", "icon": "/usr/share/pixmaps/partyos-games/existing.png",
      "exec": "existing", "pkg": "", "pkgs": "", "entry": "bin/run.sh",
      "marker": "", "needs_server": false, "config_dir": "existing"
    },
    {
      "id": "partyos.oldwin", "name": "oldwin", "hidden": true, "unlock_code": "NYET",
      "title": "Old Windows Game", "source": "blob", "blob": "server/games/oldwin.squashfs",
      "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
      "size": 1, "ram_min": 2048, "ram_max": 4096, "version": "1.0.0",
      "category": "game", "icon": "/usr/share/pixmaps/partyos-games/oldwin.png",
      "exec": "", "pkg": "", "pkgs": "", "entry": "bin/run.sh",
      "marker": "PARTYOS-BLOB-RUN oldwin", "needs_server": false, "proton": true,
      "exe_rel": "Old/old.exe", "save_rel": "", "overlay": true, "shm_mb": 0
    }
  ]
}
JSON

CONF="${TMP}/deploy.conf"
printf 'PXE_SERVER=partytest.lan:8080\nBLOB_SERVERS=partytest.lan:8080\n' > "${CONF}"

BLOB="${TMP}/newgame.squashfs"
head -c 700000 /dev/urandom > "${BLOB}"
BLOB_SHA="$(shasum -a 256 "${BLOB}" | awk '{print $1}')"

# --- a stub aria2 JSON-RPC server -------------------------------------------
# A small stateful fake of the aria2c RPC. It records every method it is asked
# for in RPC_LOG. Its entries live in RPC_STATE (JSON), so a test can preload a
# seeder state. addTorrent decodes the torrent for the info-hash and the file
# name. As the real aria2c does, it refuses a second info-hash for a file that a
# live entry uses (status error, errorCode 11). If RPC_STATE has "fail_add": true,
# a new entry goes to status error (a torrent that does not verify).
RPC_LOG="${TMP}/rpc.log"
RPC_STATE="${TMP}/rpc-state.json"
echo '{"entries": []}' > "${RPC_STATE}"
cat > "${TMP}/stub-rpc.py" <<'PY'
import hashlib, json, os, sys, base64
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.environ["RPC_LOG"]
STATE = os.environ["RPC_STATE"]


def bdecode(data, i=0):
    c = data[i:i + 1]
    if c == b"d":
        i += 1; out = {}; start = i
        while data[i:i + 1] != b"e":
            k, i = bdecode(data, i)
            vs = i
            v, i = bdecode(data, i)
            out[k] = v
            if k == b"info":
                out[b"__info_raw"] = data[vs:i]
        return out, i + 1
    if c == b"l":
        i += 1; out = []
        while data[i:i + 1] != b"e":
            v, i = bdecode(data, i); out.append(v)
        return out, i + 1
    if c == b"i":
        j = data.index(b"e", i); return int(data[i + 1:j]), j + 1
    j = data.index(b":", i); n = int(data[i:j])
    return data[j + 1:j + 1 + n], j + 1 + n


LIVE = ("active", "waiting", "paused")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method, params = body["method"], body["params"][1:]
        st = json.load(open(STATE))
        ents = st["entries"]
        with open(LOG, "a") as handle:
            handle.write(method + (" " + str(params[0]) if method in (
                "aria2.remove", "aria2.forceRemove", "aria2.removeDownloadResult") else "") + "\n")
        by_gid = {e["gid"]: e for e in ents}
        if method == "aria2.tellActive":
            result = [e for e in ents if e["status"] == "active"]
        elif method == "aria2.tellWaiting":
            result = [e for e in ents if e["status"] in ("waiting", "paused")]
        elif method == "aria2.tellStopped":
            result = [e for e in ents if e["status"] not in LIVE]
        elif method == "aria2.tellStatus":
            result = by_gid[params[0]]
        elif method == "aria2.addTorrent":
            meta, _ = bdecode(base64.b64decode(params[0]))
            info_hash = hashlib.sha1(meta[b"__info_raw"]).hexdigest()
            name = meta[b"info"][b"name"].decode()
            length = meta[b"info"][b"length"]
            path = os.path.join(params[2]["dir"], name)
            with open(LOG + ".addtorrent", "w") as handle:
                json.dump(params[2], handle)
            st["seq"] = st.get("seq", 0) + 1
            gid = "gid%d" % st["seq"]
            ent = {"gid": gid, "infoHash": info_hash, "status": "active", "seeder": "true",
                   "completedLength": str(length), "totalLength": str(length),
                   "files": [{"path": path}]}
            clash = any(e["status"] in LIVE and e["files"][0]["path"] == path for e in ents)
            if clash or st.get("fail_add"):
                ent.update({"status": "error", "seeder": "false", "completedLength": "0",
                            "errorCode": "11" if clash else "1",
                            "errorMessage": "File %s is being downloaded by other command." % path})
            ents.append(ent)
            result = gid
        elif method in ("aria2.remove", "aria2.forceRemove"):
            by_gid[params[0]]["status"] = "removed"
            result = params[0]
        elif method == "aria2.removeDownloadResult":
            st["entries"] = [e for e in ents if e["gid"] != params[0]]
            result = "OK"
        else:
            result = {}
        json.dump(st, open(STATE, "w"))
        out = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.environ["RPC_PORT_FILE"], "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY

RPC_PORT_FILE="${TMP}/rpc.port"
RPC_LOG="${RPC_LOG}" RPC_STATE="${RPC_STATE}" RPC_PORT_FILE="${RPC_PORT_FILE}" \
    python3 "${TMP}/stub-rpc.py" &
RPC_PID=$!
for _i in $(seq 1 50); do [ -s "${RPC_PORT_FILE}" ] && break; sleep 0.1; done
RPC_PORT="$(cat "${RPC_PORT_FILE}" 2>/dev/null)"
[ -n "${RPC_PORT}" ] || { echo "FAIL: stub RPC server did not start"; exit 1; }
RPC="http://127.0.0.1:${RPC_PORT}/jsonrpc"

# field FILE NAME KEY - print one field of one row as JSON ("MISSING" if absent).
field() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
row = next((g for g in d["games"] if g.get("name") == sys.argv[2]), None)
print("NOROW" if row is None else json.dumps(row.get(sys.argv[3], "MISSING")))
PY
}

# set_fields FILE NAME JSON - merge JSON into one row, as an operator does by hand.
set_fields() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
next(g for g in d["games"] if g["name"] == sys.argv[2]).update(json.loads(sys.argv[3]))
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
}

publish() {
    bash "${PUBLISH}" "$@" --games-dir "${GAMES}" --conf "${CONF}" --rpc-url "${RPC}" 2>&1
}

# ---------------------------------------------------------------------------
# 1. make-torrent.py matches mktorrent on a torrent mktorrent already produced.
# ---------------------------------------------------------------------------
REF_BLOB=""
for cand in "${REPO_ROOT}"/server/games/*.squashfs; do
    [ -f "${cand}" ] && [ -f "${cand}.torrent" ] && { REF_BLOB="${cand}"; break; }
done
if [ -n "${REF_BLOB}" ]; then
    REF_OUT="$(REF="${REF_BLOB}" MT="${MAKE_TORRENT}" TMPD="${TMP}" python3 - <<'PY'
import hashlib, importlib.util, os, sys

spec = importlib.util.spec_from_file_location("mt", os.environ["MT"])
mt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mt)


def decode(data, i=0):
    c = data[i:i + 1]
    if c == b"d":
        i += 1
        out = {}
        while data[i:i + 1] != b"e":
            k, i = decode(data, i)
            v, i = decode(data, i)
            out[k] = v
        return out, i + 1
    if c == b"l":
        i += 1
        out = []
        while data[i:i + 1] != b"e":
            v, i = decode(data, i)
            out.append(v)
        return out, i + 1
    if c == b"i":
        j = data.index(b"e", i)
        return int(data[i + 1:j]), j + 1
    j = data.index(b":", i)
    n = int(data[i:j])
    return data[j + 1:j + 1 + n], j + 1 + n


ref = os.environ["REF"]
meta, _ = decode(open(ref + ".torrent", "rb").read())
want = hashlib.sha1(mt.bencode({k.decode(): v for k, v in meta[b"info"].items()})).hexdigest()
got = mt.make_torrent(ref, os.path.join(os.environ["TMPD"], "ref.torrent"))
print("MATCH" if got == want else "MISMATCH %s != %s" % (got, want))
PY
)"
    assert_eq "${REF_OUT}" "MATCH" "make-torrent.py reproduces the mktorrent info-hash"
else
    echo "SKIP: no reference blob+torrent pair in server/games to compare against"
fi

# ---------------------------------------------------------------------------
# 2. first publish
# ---------------------------------------------------------------------------
OUT="$(bash "${PUBLISH}" "${BLOB}" --games-dir "${GAMES}" --conf "${CONF}" \
        --rpc-url "${RPC}" --title "New Game" --category game 2>&1)"
RC=$?
assert_true "${RC}" "publish-blob.sh succeeds on a fresh blob"
[ "${RC}" = 0 ] || { echo "--- output ---"; echo "${OUT}"; }

assert_true "$([ -f "${GAMES}/newgame.squashfs" ]; echo $?)"         "blob placed in the games dir"
assert_true "$([ -f "${GAMES}/newgame.squashfs.sha256" ]; echo $?)"  "sha256 sidecar written"
assert_true "$([ -f "${GAMES}/newgame.squashfs.torrent" ]; echo $?)" "torrent written"
assert_eq "$(cat "${GAMES}/newgame.squashfs.sha256")" "${BLOB_SHA}" "sidecar holds the real sha256"

# no temp files left behind by the atomic writes
LEFTOVER="$(ls "${GAMES}"/*.tmp 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "${LEFTOVER}" "0" "no .tmp files left in the games dir"

# the torrent carries the tracker announce URL derived from deploy.conf
assert_contains "$(cat "${GAMES}/newgame.squashfs.torrent")" \
    "http://partytest.lan:6969/announce" "torrent announces to the partyOS tracker"

# the running seeder was fed over RPC, and the add named the games dir
assert_contains "$(cat "${RPC_LOG}")" "aria2.addTorrent" "the torrent was added over aria2 RPC"
assert_contains "$(cat "${RPC_LOG}.addtorrent")" "\"dir\"" "the RPC add sets the seeder download dir"
assert_contains "$(cat "${RPC_LOG}.addtorrent")" "0.0" "the RPC add seeds forever (seed-ratio 0.0)"

# the catalog row landed, is rectangular, and catalog.json was rendered
assert_true "$([ -f "${GAMES}/catalog.json" ]; echo $?)" "catalog.json rendered"
ROWCHECK="$(BLOB_SHA="${BLOB_SHA}" python3 - "${GAMES}/catalog.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
games = d["games"]
row = next((g for g in games if g.get("name") == "newgame"), None)
if row is None:
    print("NOROW"); sys.exit(0)
if row.get("sha256") != os.environ["BLOB_SHA"]:
    print("BADSHA"); sys.exit(0)
if row.get("source") != "blob" or row.get("title") != "New Game":
    print("BADFIELDS"); sys.exit(0)
# rectangular: the new row must carry every key the other blob rows carry
keys = set()
for g in games:
    if g.get("source") == "blob" and g.get("name") != "newgame":
        keys.update(g.keys())
missing = keys - set(row)
print("OK" if not missing else "MISSING:" + ",".join(sorted(missing)))
PY
)"
assert_eq "${ROWCHECK}" "OK" "catalog row is present, carries the real sha and is rectangular"

# a new row with no --icon gets an icon that every client has
assert_eq "$(field "${GAMES}/catalog.json" newgame icon)" '"applications-games"' \
    "a new row with no --icon gets the stock applications-games icon"
# with no --hidden, a new row is visible, and a blob with no game.meta is native
assert_eq "$(field "${GAMES}/catalog.json" newgame hidden)" "false" "a new row with no --hidden is visible"
assert_eq "$(field "${GAMES}/catalog.json" newgame proton)" "false" "a blob with no game.meta is published as native"
assert_eq "$(field "${GAMES}/catalog.json" newgame ram_min)" "512" "a native row gets the native RAM default"

# ---------------------------------------------------------------------------
# 3. re-publish is idempotent, and the RPC add is SKIPPED for a held info-hash
# ---------------------------------------------------------------------------
# The stub seeder holds this info-hash since the first publish, as a real seeder does.
python3 "${MAKE_TORRENT}" "${GAMES}/newgame.squashfs" "${TMP}/probe.torrent" \
    --announce "http://partytest.lan:6969/announce" --comment "partyOS blob newgame" \
    > "${TMP}/infohash.txt"
assert_contains "$(cat "${RPC_STATE}")" "$(cat "${TMP}/infohash.txt")" "the stub seeder holds the first publish"

# operator-tuned field that a re-publish must preserve
python3 - "${GAMES}/catalog.v2.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["games"]:
    if g["name"] == "newgame":
        g["config_dir"] = "operator-tuned"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY

: > "${RPC_LOG}"
rm -f "${RPC_LOG}.addtorrent"
OUT2="$(bash "${PUBLISH}" "${GAMES}/newgame.squashfs" --games-dir "${GAMES}" \
        --conf "${CONF}" --rpc-url "${RPC}" 2>&1)"
assert_true "$?" "re-publish of the same blob succeeds"
assert_contains "${OUT2}" "already holds" "re-publish SKIPS the RPC add (idempotent)"
[ -f "${RPC_LOG}.addtorrent" ] && { echo "FAIL: re-publish re-added a torrent the seeder already holds"; exit 1; }

DUP="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for g in d["games"] if g["name"]=="newgame"))' "${GAMES}/catalog.v2.json")"
assert_eq "${DUP}" "1" "re-publish leaves exactly one catalog row"
KEPT="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(g["config_dir"] for g in d["games"] if g["name"]=="newgame"))' "${GAMES}/catalog.v2.json")"
assert_eq "${KEPT}" "operator-tuned" "re-publish preserves an operator-tuned field"

# ---------------------------------------------------------------------------
# 3a. a re-publish keeps the operator-tuned access, store and RAM fields
# ---------------------------------------------------------------------------
set_fields "${GAMES}/catalog.v2.json" newgame \
    '{"hidden": true, "unlock_code": "KEEP", "category": "tool", "icon": "/x/tuned.png", "ram_min": 777, "ram_max": 888}'
OUT3="$(publish "${GAMES}/newgame.squashfs")"
assert_true "$?" "re-publish with no flags succeeds"
for pair in 'hidden=true' 'unlock_code="KEEP"' 'category="tool"' 'icon="/x/tuned.png"' 'ram_min=777' 'ram_max=888'; do
    assert_eq "$(field "${GAMES}/catalog.json" newgame "${pair%%=*}")" "${pair#*=}" \
        "re-publish with no flags keeps the tuned ${pair%%=*}"
done
OUT3="$(publish "${GAMES}/newgame.squashfs" --ram-min 1024)"
assert_true "$?" "re-publish with --ram-min succeeds"
assert_eq "$(field "${GAMES}/catalog.json" newgame ram_min)" "1024" "an explicit --ram-min on a re-publish wins"
assert_eq "$(field "${GAMES}/catalog.json" newgame ram_max)" "888" "an explicit --ram-min leaves the tuned ram_max"
assert_eq "$(field "${GAMES}/catalog.json" newgame unlock_code)" '"KEEP"' "an explicit --ram-min leaves the tuned unlock_code"

# ---------------------------------------------------------------------------
# 3b. --hidden and --unlock-code land in the SAME catalog write as the row
# ---------------------------------------------------------------------------
# A watcher polls both catalogs during the publish. It records every state in
# which the new row is visible. An implementation that inserts the row and hides
# it in a second write shows the row as visible between the two writes.
HID_BLOB="${TMP}/hidgame.squashfs"
head -c 200000 /dev/urandom > "${HID_BLOB}"
WATCH_LOG="${TMP}/watch.log"; WATCH_STOP="${TMP}/watch.stop"
: > "${WATCH_LOG}"; rm -f "${WATCH_STOP}"
python3 - "${GAMES}" "${WATCH_LOG}" "${WATCH_STOP}" <<'PY' &
import json, os, sys, time
games, log, stop = sys.argv[1:4]
seen = 0
while not os.path.exists(stop):
    for name in ("catalog.v2.json", "catalog.json"):
        try:
            d = json.load(open(os.path.join(games, name)))
        except (OSError, ValueError):
            continue
        for g in d.get("games", []):
            if g.get("name") == "hidgame":
                seen += 1
                if g.get("hidden") is not True:
                    open(log, "a").write("VISIBLE in %s\n" % name)
    time.sleep(0.001)
open(log, "a").write("SEEN %d\n" % seen)
PY
WATCH_PID=$!
OUT4="$(publish "${HID_BLOB}" --title "Hidden Game" --hidden --unlock-code Party-1)"
RC4=$?
sleep 0.2; touch "${WATCH_STOP}"; wait "${WATCH_PID}"
assert_true "${RC4}" "publish with --hidden --unlock-code succeeds"
assert_eq "$(field "${GAMES}/catalog.json" hidgame hidden)" "true" "--hidden publishes the row hidden"
assert_eq "$(field "${GAMES}/catalog.json" hidgame unlock_code)" '"Party-1"' "--unlock-code sets the row code"
assert_not_contains "$(cat "${WATCH_LOG}")" "VISIBLE" "the row is never visible in any catalog state during the publish"
assert_not_contains "$(cat "${WATCH_LOG}")" "SEEN 0" "the watcher saw the new row (it observed the publish)"
assert_eq "$(printf '%s\n' "${OUT4}" | grep -c 'catalog.v2.json inserted row hidgame')" "1" \
    "the hidden row is written to catalog.v2.json in exactly one write"
assert_eq "$(printf '%s\n' "${OUT4}" | grep -c '\[blobs\] catalog.json:')" "1" \
    "catalog.json is rendered exactly once, with the row already hidden"

# --unlock-code alone hides the row: a code on a visible row has no use
CODE_BLOB="${TMP}/codegame.squashfs"
head -c 150000 /dev/urandom > "${CODE_BLOB}"
publish "${CODE_BLOB}" --unlock-code LAN >/dev/null
assert_true "$?" "publish with only --unlock-code succeeds"
assert_eq "$(field "${GAMES}/catalog.json" codegame hidden)" "true" "--unlock-code alone publishes the row hidden"

# --hidden on a re-publish hides a visible row, --unlock-code replaces the code
EXIST_BLOB="${TMP}/existing.squashfs"
head -c 100000 /dev/urandom > "${EXIST_BLOB}"
publish "${EXIST_BLOB}" --hidden >/dev/null
assert_true "$?" "re-publish of a visible row with --hidden succeeds"
assert_eq "$(field "${GAMES}/catalog.json" existing hidden)" "true" "--hidden on a re-publish hides the row"
publish "${HID_BLOB}" --unlock-code NEWCODE >/dev/null
assert_eq "$(field "${GAMES}/catalog.json" hidgame unlock_code)" '"NEWCODE"' "--unlock-code on a re-publish replaces the code"

# a code with unsafe characters is refused before any write
CAT_BEFORE_BAD="$(shasum -a 256 "${GAMES}/catalog.v2.json" | awk '{print $1}')"
BAD_BLOB="${TMP}/badcode.squashfs"
head -c 100000 /dev/urandom > "${BAD_BLOB}"
publish "${BAD_BLOB}" --unlock-code 'a "b' >/dev/null
assert_false "$?" "publish refuses an unlock code with unsafe characters"
assert_eq "$(shasum -a 256 "${GAMES}/catalog.v2.json" | awk '{print $1}')" "${CAT_BEFORE_BAD}" \
    "a refused unlock code leaves the catalog untouched"
assert_true "$([ ! -e "${GAMES}/badcode.squashfs" ]; echo $?)" "a refused unlock code places no bytes"

# ---------------------------------------------------------------------------
# 3c. a Proton blob fills the Windows fields from its own game.meta and run.sh
# ---------------------------------------------------------------------------
# mk_proton NAME META_RAM_LINES - build a small squashfs with the layout that
# build-proton-blob.sh writes: game.meta at the root, bin/run.sh with EXE_REL.
mk_proton() {
    local name="$1" ram="$2" root="${TMP}/root-$1"
    mkdir -p "${root}/bin"
    printf 'id=partyos.%s\nname=%s\nentry=bin/run.sh\nkind=proton\noverlay=1\n%bshm_mb=0\ntitle=Stub %s\nmarker=PARTYOS-BLOB-RUN %s\n' \
        "${name}" "${name}" "${ram}" "${name}" "${name}" > "${root}/game.meta"
    printf '#!/bin/bash\nset -u\nNAME="%s"\nEXE_REL="Stub Dir/stub.exe"\nSAVE_REL="Saves"\n' "${name}" > "${root}/bin/run.sh"
    head -c 50000 /dev/urandom > "${root}/pad"
    mksquashfs "${root}" "${TMP}/${name}.squashfs" -noappend -no-xattrs -quiet >/dev/null 2>&1
}
if command -v mksquashfs >/dev/null 2>&1 && command -v unsquashfs >/dev/null 2>&1; then
    mk_proton wingame 'ram_min=3072\nram_max=6144\n'
    OUT5="$(publish "${TMP}/wingame.squashfs" --title "Win Game" --ram-max 8192)"
    assert_true "$?" "publish of a Proton blob succeeds"
    assert_contains "${OUT5}" "kind     : proton" "publish reports the blob kind from game.meta"
    for pair in 'proton=true' 'overlay=true' 'shm_mb=0' 'marker="PARTYOS-BLOB-RUN wingame"' \
                'exe_rel="Stub Dir/stub.exe"' 'save_rel="Saves"' 'exec=""' 'entry="bin/run.sh"' \
                'title="Win Game"' 'ram_min=3072' 'ram_max=8192' 'icon="applications-games"'; do
        assert_eq "$(field "${GAMES}/catalog.json" wingame "${pair%%=*}")" "${pair#*=}" \
            "a Proton row gets ${pair%%=*} from the blob or the flags"
    done

    # no RAM in game.meta: the Proton default is 2048/4096, not the native 512/2048
    mk_proton winnoram ''
    publish "${TMP}/winnoram.squashfs" >/dev/null
    assert_true "$?" "publish of a Proton blob with no RAM in game.meta succeeds"
    assert_eq "$(field "${GAMES}/catalog.json" winnoram ram_min)" "2048" "a Proton row defaults ram_min to 2048"
    assert_eq "$(field "${GAMES}/catalog.json" winnoram ram_max)" "4096" "a Proton row defaults ram_max to 4096"

    # a Proton re-publish keeps the tuned fields and keeps the Windows fields
    set_fields "${GAMES}/catalog.v2.json" wingame \
        '{"hidden": true, "unlock_code": "WIN", "ram_min": 2500, "icon": "/x/win.png", "category": "app"}'
    publish "${GAMES}/wingame.squashfs" >/dev/null
    assert_true "$?" "re-publish of a Proton blob succeeds"
    for pair in 'hidden=true' 'unlock_code="WIN"' 'ram_min=2500' 'ram_max=8192' 'icon="/x/win.png"' \
                'category="app"' 'proton=true' 'overlay=true' 'exe_rel="Stub Dir/stub.exe"'; do
        assert_eq "$(field "${GAMES}/catalog.json" wingame "${pair%%=*}")" "${pair#*=}" \
            "a Proton re-publish keeps ${pair%%=*}"
    done
else
    echo "SKIP: mksquashfs/unsquashfs not found - no Proton stub blob"
fi

# ---------------------------------------------------------------------------
# 3d. a re-publish with NEW bytes replaces the old info-hash in the seeder
# ---------------------------------------------------------------------------
# hashes_live - the info-hashes of the live stub entries of newgame, one per line.
hashes_live() {
    python3 -c 'import json,sys; [print(e["infoHash"]) for e in json.load(open(sys.argv[1]))["entries"] if e["status"] in ("active","waiting","paused") and e["files"][0]["path"].endswith("/newgame.squashfs")]' "${RPC_STATE}"
}
OLD_HASH="$(cat "${TMP}/infohash.txt")"
REPUB="${TMP}/repub/newgame.squashfs"; mkdir -p "${TMP}/repub"
head -c 800000 /dev/urandom > "${REPUB}"
REPUB_SHA="$(shasum -a 256 "${REPUB}" | awk '{print $1}')"
NEW_HASH="$(python3 "${MAKE_TORRENT}" "${REPUB}" "${TMP}/probe2.torrent" \
    --announce "http://partytest.lan:6969/announce" --comment "partyOS blob newgame")"
: > "${RPC_LOG}"
OUT6="$(publish "${REPUB}")"; RC6=$?
assert_true "${RC6}" "re-publish with new bytes succeeds"
[ "${RC6}" = 0 ] || printf '%s\n' "${OUT6}"
assert_contains "$(hashes_live)" "${NEW_HASH}" "re-publish: the seeder seeds the new info-hash"
assert_not_contains "$(hashes_live)" "${OLD_HASH}" "re-publish: the old info-hash is removed from the seeder"
assert_contains "${OUT6}" "removed the old info-hash ${OLD_HASH:0:12}" "re-publish: logs the removal of the old info-hash"
# The new entry seeds BEFORE the old one goes: addTorrent comes before aria2.remove.
ADD_LINE="$(grep -n '^aria2.addTorrent' "${RPC_LOG}" | head -1 | cut -d: -f1)"
RM_LINE="$(grep -n '^aria2.remove ' "${RPC_LOG}" | head -1 | cut -d: -f1)"
assert_true "$([ -n "${ADD_LINE}" ] && [ -n "${RM_LINE}" ] && [ "${ADD_LINE}" -lt "${RM_LINE}" ]; echo $?)" \
    "re-publish: the new torrent is added before the old info-hash is removed"
assert_contains "$(cat "${RPC_LOG}")" "aria2.removeDownloadResult" "re-publish: the stopped old entry is dropped from the seeder"
assert_not_contains "$(cat "${RPC_STATE}")" '"errorCode": "11"' "re-publish: the new torrent is not refused for the busy file (aria2 error 11)"
assert_eq "$(shasum -a 256 "${GAMES}/newgame.squashfs" | awk '{print $1}')" "${REPUB_SHA}" "re-publish: the games dir has the new bytes"
assert_eq "$(cat "${GAMES}/newgame.squashfs.sha256")" "${REPUB_SHA}" "re-publish: the sidecar has the new sha256"
assert_eq "$(python3 "${MAKE_TORRENT}" "${GAMES}/newgame.squashfs" "${TMP}/probe3.torrent" --announce "http://partytest.lan:6969/announce" --comment "partyOS blob newgame")" \
    "${NEW_HASH}" "re-publish: the games dir torrent matches the new bytes"
assert_eq "$(field "${GAMES}/catalog.json" newgame sha256)" "\"${REPUB_SHA}\"" "re-publish: the catalog has the new sha256"
STAGE_DIR="${GAMES}/.publish/newgame-${REPUB_SHA:0:12}"
assert_true "$([ -f "${STAGE_DIR}/newgame.squashfs" ]; echo $?)" "re-publish: the new entry seeds from the stage dir"
assert_eq "$(ls -i "${STAGE_DIR}/newgame.squashfs" | awk '{print $1}')" "$(ls -i "${GAMES}/newgame.squashfs" | awk '{print $1}')" \
    "re-publish: the games dir file is a hard link of the staged file (no second copy)"
LEFTOVER="$(find "${GAMES}" -name '*.publish.tmp' -o -name '.*.torrent.publish' | wc -l | tr -d ' ')"
assert_eq "${LEFTOVER}" "0" "re-publish: no temp files left"

echo "--- 3d-2. the same re-publish again is a no-op on the seeder ---"
: > "${RPC_LOG}"
OUT7="$(publish "${REPUB}")"
assert_true "$?" "a second run of the same re-publish succeeds"
assert_contains "${OUT7}" "already holds" "a second run skips the add"
assert_not_contains "$(cat "${RPC_LOG}")" "aria2.addTorrent" "a second run adds no torrent"
assert_not_contains "$(cat "${RPC_LOG}")" "aria2.remove " "a second run removes no entry"
assert_eq "$(hashes_live | grep -c .)" "1" "a second run leaves one live entry for the blob"

echo "--- 3d-3. the new torrent does not seed: the old seed and the catalog stay ---"
REPUB2="${TMP}/repub2/newgame.squashfs"; mkdir -p "${TMP}/repub2"
head -c 600000 /dev/urandom > "${REPUB2}"
python3 - "${RPC_STATE}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["fail_add"] = True; json.dump(d, open(sys.argv[1], "w"))
PY
CAT_BEFORE6="$(shasum -a 256 "${GAMES}/catalog.v2.json" | awk '{print $1}')"
OUT8="$(publish "${REPUB2}")"; RC8=$?
assert_false "${RC8}" "re-publish fails when the new torrent does not seed"
assert_contains "$(hashes_live)" "${NEW_HASH}" "failed re-publish: the previous info-hash still seeds"
assert_eq "$(hashes_live | grep -c .)" "1" "failed re-publish: the failed new entry is removed from the seeder"
assert_eq "$(shasum -a 256 "${GAMES}/catalog.v2.json" | awk '{print $1}')" "${CAT_BEFORE6}" "failed re-publish: the catalog is untouched"
assert_eq "$(shasum -a 256 "${GAMES}/newgame.squashfs" | awk '{print $1}')" "${REPUB_SHA}" "failed re-publish: the games dir bytes are untouched"
python3 - "${RPC_STATE}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d.pop("fail_add", None); json.dump(d, open(sys.argv[1], "w"))
PY

echo "--- 3d-4. a stopped (error) entry with the new info-hash does not count as held ---"
# The state after an old publish-blob that got aria2 error 11: the new info-hash is
# only a stopped error entry, and the old one still seeds.
python3 - "${RPC_STATE}" "$(python3 "${MAKE_TORRENT}" "${REPUB2}" "${TMP}/probe4.torrent" --announce "http://partytest.lan:6969/announce" --comment "partyOS blob newgame")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["entries"].append({"gid": "gidstale", "infoHash": sys.argv[2], "status": "error", "errorCode": "11",
                     "files": [{"path": "x"}], "seeder": "false", "completedLength": "0", "totalLength": "0"})
json.dump(d, open(sys.argv[1], "w"))
PY
OUT9="$(publish "${REPUB2}")"
assert_true "$?" "re-publish over a stale error entry succeeds"
assert_not_contains "${OUT9}" "already holds" "a stopped error entry is not taken as a held seed"
assert_eq "$(hashes_live | grep -c .)" "1" "after the re-publish over a stale error entry, one live entry"
assert_true "$([ ! -d "${STAGE_DIR}" ]; echo $?)" "the next re-publish deletes the unused stage dir of the previous one"

# ---------------------------------------------------------------------------
# 3e. the same re-publish against a REAL aria2c (skipped if aria2c is absent)
# ---------------------------------------------------------------------------
if command -v aria2c >/dev/null 2>&1; then
    RG="${TMP}/real/games"; mkdir -p "${RG}"
    cp "${GAMES}/catalog.v2.json" "${RG}/catalog.v2.json"
    RPORT=$(( 20000 + RANDOM % 20000 ))
    aria2c --enable-rpc --rpc-listen-all=false --rpc-listen-port="${RPORT}" --rpc-secret=partyos \
        --enable-dht=false --bt-enable-lpd=false --seed-ratio=0.0 --check-integrity=true \
        --dir="${RG}" --quiet=true > "${TMP}/real-aria2.log" 2>&1 &
    RPC_PID="${RPC_PID} $!"
    REAL_RPC="http://127.0.0.1:${RPORT}/jsonrpc"
    for _i in $(seq 1 50); do curl -s "${REAL_RPC}" >/dev/null 2>&1 && break; sleep 0.1; done
    real_live() {
        curl -s "${REAL_RPC}" -d '{"jsonrpc":"2.0","id":1,"method":"aria2.tellActive","params":["token:partyos",["infoHash","seeder"]]}' \
            | python3 -c 'import json,sys; [print(e["infoHash"], e.get("seeder")) for e in json.load(sys.stdin)["result"]]'
    }
    mkdir -p "${TMP}/real/a" "${TMP}/real/b"
    head -c 900000 /dev/urandom > "${TMP}/real/a/realgame.squashfs"
    head -c 950000 /dev/urandom > "${TMP}/real/b/realgame.squashfs"
    RA="$(python3 "${MAKE_TORRENT}" "${TMP}/real/a/realgame.squashfs" "${TMP}/ra.torrent" --announce "http://partytest.lan:6969/announce" --comment "partyOS blob realgame")"
    RB="$(python3 "${MAKE_TORRENT}" "${TMP}/real/b/realgame.squashfs" "${TMP}/rb.torrent" --announce "http://partytest.lan:6969/announce" --comment "partyOS blob realgame")"
    PARTYOS_PUBLISH_VERIFY_TIMEOUT=60 bash "${PUBLISH}" "${TMP}/real/a/realgame.squashfs" --games-dir "${RG}" --conf "${CONF}" --rpc-url "${REAL_RPC}" > "${TMP}/real-a.out" 2>&1
    assert_true "$?" "real aria2c: the first publish succeeds"
    assert_eq "$(real_live)" "${RA} true" "real aria2c: the first publish seeds the first info-hash"
    PARTYOS_PUBLISH_VERIFY_TIMEOUT=60 bash "${PUBLISH}" "${TMP}/real/b/realgame.squashfs" --games-dir "${RG}" --conf "${CONF}" --rpc-url "${REAL_RPC}" > "${TMP}/real-b.out" 2>&1
    RCB=$?
    assert_true "${RCB}" "real aria2c: the re-publish with new bytes succeeds"
    [ "${RCB}" = 0 ] || cat "${TMP}/real-b.out"
    assert_eq "$(real_live)" "${RB} true" "real aria2c: after the re-publish only the new info-hash seeds"
    assert_eq "$(shasum -a 256 "${RG}/realgame.squashfs" | awk '{print $1}')" \
        "$(shasum -a 256 "${TMP}/real/b/realgame.squashfs" | awk '{print $1}')" "real aria2c: the games dir has the new bytes"
else
    echo "SKIP: aria2c not found - the real-seeder re-publish check is skipped"
fi

# ---------------------------------------------------------------------------
# 4. an RPC failure must leave the catalog UNCHANGED (catalog-last ordering)
# ---------------------------------------------------------------------------
CAT_BEFORE="$(shasum -a 256 "${GAMES}/catalog.v2.json" | awk '{print $1}')"
BLOB2="${TMP}/failgame.squashfs"
head -c 300000 /dev/urandom > "${BLOB2}"
bash "${PUBLISH}" "${BLOB2}" --games-dir "${GAMES}" --conf "${CONF}" \
    --rpc-url "http://127.0.0.1:1/jsonrpc" >/dev/null 2>&1
RC_FAIL=$?
assert_false "${RC_FAIL}" "publish FAILS when the running seeder cannot be reached"
CAT_AFTER="$(shasum -a 256 "${GAMES}/catalog.v2.json" | awk '{print $1}')"
assert_eq "${CAT_AFTER}" "${CAT_BEFORE}" "a failed publish leaves the catalog untouched"
NOROW="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for g in d["games"] if g["name"]=="failgame"))' "${GAMES}/catalog.json")"
assert_eq "${NOROW}" "0" "a failed publish never advertises the title to clients"

# ---------------------------------------------------------------------------
# 5. the LIVE operator catalog was never touched
# ---------------------------------------------------------------------------
if [ -n "${LIVE_SHA_BEFORE}" ]; then
    LIVE_SHA_AFTER="$(shasum -a 256 "${LIVE_CATALOG}" | awk '{print $1}')"
    assert_eq "${LIVE_SHA_AFTER}" "${LIVE_SHA_BEFORE}" "the live catalog.v2.json is untouched"
fi

assert_summary "publish-blob"
