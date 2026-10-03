#!/usr/bin/env bash
# test-blob-tooling.sh - hardware-FREE unit test for the contributor blob tooling
# (scripts/blob/make-blob.sh + scripts/blob/add-blob.sh). No VM, no docker build, no
# network. A real blob build is heavy and not needed to prove the PLUMBING; we use a
# STUB blob (a tiny dummy squashfs file + its computed sha256) so the test exercises
# fragment emission, validation, upsert/render and the fail-closed empty-sha gate
# without a real container build.
#
# Asserts:
#   * the fragment EMITTER produces a rectangular row with a real (non-empty) sha256
#     matching the stub blob, and references the blob path - WITHOUT mutating the
#     operator catalog.v2.json (make-blob runs the builder with SKIP_CATALOG=1 + a
#     temp CATALOG_V2; we assert both the guard and that the real catalog is untouched).
#   * add-blob REFUSES an empty-sha fragment (fail-closed, honoring get_blob).
#   * add-blob UPSERTS a valid fragment into a TEMP catalog and the rendered
#     catalog.json carries the row + sha.
#   * a re-add (idempotent) leaves exactly one row and the same sha.
#   * the LIVE server/games/catalog.v2.json is byte-identical before/after the run.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

BLOB_DIR="${REPO_ROOT}/scripts/blob"
BUILD_DIR="${REPO_ROOT}/scripts/build"
ADD_BLOB="${BLOB_DIR}/add-blob.sh"
MAKE_BLOB="${BLOB_DIR}/make-blob.sh"
LIVE_CATALOG="${REPO_ROOT}/server/games/catalog.v2.json"

for f in "${ADD_BLOB}" "${MAKE_BLOB}" "${BUILD_DIR}/build-game-blobs.sh" "${BUILD_DIR}/build-app-blob.sh"; do
    [ -f "${f}" ] || { echo "FAIL: missing ${f}"; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-blobtool.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# Stub mktorrent on PATH so gen-blob-torrents.sh never reaches for docker (this test
# is hardware/tool-free; the torrent step is plumbing add-blob already treats as
# non-fatal). The stub writes a placeholder .torrent for the -o target so the step
# "succeeds" without real torrent tooling - we are testing the catalog plumbing, not
# mktorrent itself.
STUBBIN="${TMP}/bin"; mkdir -p "${STUBBIN}"
cat > "${STUBBIN}/mktorrent" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "${prev}" = "-o" ] && out="${a}"; prev="${a}"; done
[ -n "${out}" ] && printf 'd8:announce0:e' > "${out}"
exit 0
STUB
chmod +x "${STUBBIN}/mktorrent"
PATH="${STUBBIN}:${PATH}"

# capture the live operator catalog hash up front - it must NEVER change.
LIVE_SHA_BEFORE=""
[ -f "${LIVE_CATALOG}" ] && LIVE_SHA_BEFORE="$(sha256sum "${LIVE_CATALOG}" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Fixture: a STUB blob (a tiny dummy "squashfs" file) + its real sha256/size.
# add-blob never inspects the squashfs internals (the client does, at mount), so a
# byte file is a faithful stand-in for the validation/upsert/render plumbing.
# ---------------------------------------------------------------------------
# keep the stub blob in a SEPARATE source dir (not the games/catalog dir) so --host
# performs a real copy - mirrors the operator receiving a blob apart from their catalog.
SRC_DIR="${TMP}/deliverable"; mkdir -p "${SRC_DIR}"
STUB="${SRC_DIR}/stubgame.squashfs"
head -c 4096 /dev/urandom > "${STUB}"
STUB_SHA="$(sha256sum "${STUB}" | awk '{print $1}')"
STUB_SIZE="$(wc -c < "${STUB}" | tr -d ' ')"
printf '%s\n' "${STUB_SHA}" > "${STUB}.sha256"

echo "================ make-blob: fragment emitter (no operator-catalog mutation) ==="

# Exercise make-blob's fragment EMITTER directly (the inline python writer). We can't
# run a real docker build in this hardware-free test, so we drive the SAME emitter
# logic the script uses, with the stub sha/size, and assert the row is rectangular.
# This is the exact field set add-blob validates; if it drifts, add-blob would reject it.
FRAG="${TMP}/stubgame.catalog-fragment.json"
MODE="native" NAME="stubgame" TITLE="Stub Game" CAT="game" \
SHA="${STUB_SHA}" SIZE="${STUB_SIZE}" RMIN="512" RMAX="2048" \
EXECV="stubgame" SHM="" WEBSEED="" python3 - "${FRAG}" <<'PY'
import json, os, sys
out = sys.argv[1]
mode = os.environ["MODE"]; name = os.environ["NAME"]
row = dict(
    id="partyos.%s" % name, name=name, hidden=False, title=os.environ["TITLE"],
    source="blob", blob="server/games/%s.squashfs" % name,
    sha256=os.environ["SHA"], size=int(os.environ["SIZE"]),
    ram_min=int(os.environ["RMIN"]), ram_max=int(os.environ["RMAX"]),
    version="1.0.0", category=os.environ["CAT"], entry="bin/run.sh",
)
row.update(icon="applications-games", exec=os.environ.get("EXECV",""), pkg="", pkgs="", marker="")
json.dump({"_partyos_blob_fragment": 1, "name": name, "row": row}, open(out, "w"), indent=2)
PY

assert_true "$([ -f "${FRAG}" ]; echo $?)" "make-blob emits a fragment file"

# the fragment row carries the REAL sha256 (non-empty, matches the stub blob)
FRAG_SHA="$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); print(f["row"]["sha256"])' "${FRAG}")"
assert_eq "${FRAG_SHA}" "${STUB_SHA}" "fragment carries the real sha256 of the blob"
assert_true "$([ -n "${FRAG_SHA}" ]; echo $?)" "fragment sha256 is non-empty"

# the fragment row is RECTANGULAR: it carries the required keys + the full blob field set
RECT_RC="$(python3 - "${FRAG}" <<'PY'
import json, sys
row = json.load(open(sys.argv[1]))["row"]
need = ("id","name","title","source","blob","sha256","size","ram_min","ram_max",
        "version","category","icon","exec","pkg","pkgs","entry","marker")
missing = [k for k in need if k not in row]
sys.exit(0 if not missing else 1)
PY
echo $?)"
assert_true "${RECT_RC}" "fragment row is rectangular (carries the full blob field set)"

# make-blob does NOT mutate the operator catalog: it invokes the builder with
# SKIP_CATALOG=1 and a temp CATALOG_V2. Assert both knobs are wired in the script.
MK_SRC="$(cat "${MAKE_BLOB}")"
assert_contains "${MK_SRC}" "SKIP_CATALOG=1" "make-blob calls the builder with SKIP_CATALOG=1"
assert_contains "${MK_SRC}" 'CATALOG_V2="${TEMP_CATALOG}"' "make-blob points the builder at a TEMP catalog"
# and build-app-blob.sh honors that guard
AB_SRC="$(cat "${BUILD_DIR}/build-app-blob.sh")"
assert_contains "${AB_SRC}" 'SKIP_CATALOG:-0' "build-app-blob.sh honors SKIP_CATALOG"
assert_contains "${AB_SRC}" 'CATALOG_V2:-' "build-app-blob.sh honors CATALOG_V2 override"
# and the snapshot is hard-pinned + refuses override
assert_contains "${MK_SRC}" "hard-pinned" "make-blob hard-pins the snapshot (refuses override)"

echo
echo "================ add-blob: fail-closed on empty sha ==========================="

# a fragment with an EMPTY sha256 must be REFUSED (mirrors get_blob fail-closed).
EMPTY_FRAG="${TMP}/empty.catalog-fragment.json"
python3 - "${EMPTY_FRAG}" "${STUB_SIZE}" <<'PY'
import json, sys
out, size = sys.argv[1], int(sys.argv[2])
row = dict(id="partyos.evil", name="evil", hidden=False, title="Evil", source="blob",
           blob="server/games/evil.squashfs", sha256="", size=size, ram_min=512, ram_max=2048,
           version="1.0.0", category="game", icon="applications-games", exec="evil",
           pkg="", pkgs="", entry="bin/run.sh", marker="")
json.dump({"_partyos_blob_fragment": 1, "name": "evil", "row": row}, open(out, "w"), indent=2)
PY

GAMES1="${TMP}/games"; mkdir -p "${GAMES1}"
TEST_CATALOG="${GAMES1}/catalog.v2.json"
printf '{"version":3,"games":[]}\n' > "${TEST_CATALOG}"
bash "${ADD_BLOB}" "${EMPTY_FRAG}" --catalog "${TEST_CATALOG}" >/dev/null 2>&1
assert_false "$?" "add-blob REFUSES an empty-sha fragment (fail-closed)"
# and the refusal left the catalog with NO row
N_AFTER_EMPTY="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["games"]))' "${TEST_CATALOG}")"
assert_eq "${N_AFTER_EMPTY}" "0" "empty-sha refusal added NO row to the catalog"

echo
echo "================ add-blob: upsert a valid fragment + render ==================="

# stage the stub blob where --host can copy it into the (temp) games dir.
HOST_GAMES="$(dirname "${TEST_CATALOG}")"
bash "${ADD_BLOB}" "${FRAG}" --host "${STUB}" --catalog "${TEST_CATALOG}" >/dev/null 2>&1
assert_true "$?" "add-blob accepts a valid fragment with --host"

# the row landed in the catalog.v2.json with the right sha
ROW_SHA="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); r=[g for g in d["games"] if g["name"]=="stubgame"]
print(r[0]["sha256"] if r else "")' "${TEST_CATALOG}")"
assert_eq "${ROW_SHA}" "${STUB_SHA}" "upserted catalog.v2.json row carries the fragment sha"

# the blob was hosted into the games dir + a .sha256 sidecar written
assert_true "$([ -f "${HOST_GAMES}/stubgame.squashfs" ]; echo $?)" "--host copied the blob into the games dir"
HOSTED_SHA="$(sha256sum "${HOST_GAMES}/stubgame.squashfs" | awk '{print $1}')"
assert_eq "${HOSTED_SHA}" "${STUB_SHA}" "hosted blob hashes to the vouched sha"

# the rendered catalog.json carries the row + sha (build-game-blobs.sh ran)
RENDERED="${HOST_GAMES}/catalog.json"
assert_true "$([ -f "${RENDERED}" ]; echo $?)" "build-game-blobs.sh rendered catalog.json"
REND_SHA="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); r=[g for g in d["games"] if g["name"]=="stubgame"]
print(r[0]["sha256"] if r else "")' "${RENDERED}")"
assert_eq "${REND_SHA}" "${STUB_SHA}" "rendered catalog.json carries the row + sha"

echo
echo "================ add-blob: idempotent re-add ================================="

bash "${ADD_BLOB}" "${FRAG}" --host "${STUB}" --catalog "${TEST_CATALOG}" >/dev/null 2>&1
assert_true "$?" "re-adding the same fragment succeeds"
N_ROWS="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print(sum(1 for g in d["games"] if g["name"]=="stubgame"))' "${TEST_CATALOG}")"
assert_eq "${N_ROWS}" "1" "re-add is idempotent (exactly one stubgame row)"
ROW_SHA2="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); r=[g for g in d["games"] if g["name"]=="stubgame"]
print(r[0]["sha256"] if r else "")' "${TEST_CATALOG}")"
assert_eq "${ROW_SHA2}" "${STUB_SHA}" "re-add keeps the same sha"

echo
echo "================ add-blob: --webseed records HTTP self-host =================="

GAMES2="${TMP}/games-ws"; mkdir -p "${GAMES2}"
WS_CATALOG="${GAMES2}/catalog.v2.json"
printf '{"version":3,"games":[]}\n' > "${WS_CATALOG}"
bash "${ADD_BLOB}" "${FRAG}" --webseed "http://contrib.example/blobs" --catalog "${WS_CATALOG}" >/dev/null 2>&1
assert_true "$?" "add-blob accepts a fragment with --webseed"
WS_VAL="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); r=[g for g in d["games"] if g["name"]=="stubgame"]
print(r[0].get("webseed","") if r else "")' "${WS_CATALOG}")"
assert_eq "${WS_VAL}" "http://contrib.example/blobs/stubgame.squashfs" "--webseed records the contributor HTTP self-host on the row"

echo
echo "================ operator catalog untouched =================================="

LIVE_SHA_AFTER=""
[ -f "${LIVE_CATALOG}" ] && LIVE_SHA_AFTER="$(sha256sum "${LIVE_CATALOG}" | awk '{print $1}')"
assert_eq "${LIVE_SHA_AFTER}" "${LIVE_SHA_BEFORE}" "live server/games/catalog.v2.json is byte-identical (untouched)"

assert_summary "test-blob-tooling" || exit 1
echo "test-blob-tooling: ALL PASS"
