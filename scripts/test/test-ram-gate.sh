#!/usr/bin/env bash
# test-ram-gate.sh - hardware-FREE unit test for the BAKED partyos-ram RAM-gate
# projection (regression guard). The image bakes partyos-ram from
# scripts/build/files/rootfs/usr/local/bin/partyos-ram.
# This test sed/awk-extracts the catalog-parse + projection functions
# (required_mb / effective_shm_mb / blob_squashfs_mb and their helpers) from that
# file, sources them, and unit-tests the projection against a synthetic
# catalog. No VM, no real memory pressure, no hardware.
#
# Asserts:
#   * a blob WITH shm_mb= in the catalog uses that value,
#   * a blob WITHOUT shm_mb= uses the max(ram_max, on-disk squashfs MB, 4096) fallback,
#   * required = effective_shm + runtime_headroom(1024) + squashfs_mb,
#   * an 8GB-free scenario REFUSES a ~6.5GB game, and a 16GB-free scenario FITS it.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

PRAM="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-ram"
[ -f "${PRAM}" ] || { echo "FAIL: partyos-ram baked file not found at ${PRAM}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-ramtest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- the baked partyos-ram is the body; carve out the projection functions ----
PRAM_BODY="${PRAM}"
[ -s "${PRAM_BODY}" ] || { echo "FAIL: partyos-ram baked file is empty (${PRAM_BODY})"; exit 1; }

# Carve from the _block() catalog parser down to the end of required_mb(). This
# contiguous region holds every function the projection needs: _block, _val,
# ram_min_of, ram_max_of, shm_mb_of, blob_squashfs_path, blob_squashfs_mb,
# effective_shm_mb, required_mb - and NOTHING that runs at top level. We stop after
# required_mb()'s closing brace.
RAMLIB="${TMPDIR_T}/ramlib.sh"
awk '
    /^_block\(\) \{/ {grab=1}
    grab {print}
    /^required_mb\(\) \{/ {inrq=1}
    inrq && /^\}/ {grab=0; inrq=0}
' "${PRAM_BODY}" > "${RAMLIB}"
[ -s "${RAMLIB}" ] || { echo "FAIL: could not carve projection functions out of PRAM"; exit 1; }

# sanity: the three projection functions + their key helpers are present
for fn in _block _val ram_max_of shm_mb_of blob_squashfs_mb effective_shm_mb required_mb; do
    grep -q "^${fn}() {" "${RAMLIB}" || grep -q "^${fn}()" "${RAMLIB}" \
        || { echo "FAIL: ${fn} missing from carve"; exit 1; }
done

# --- harness: RUNTIME_HEADROOM_MB + a stubbed blob_squashfs_path/du -----------
# The carved code references RUNTIME_HEADROOM_MB (defined later in PRAM) and
# blob_squashfs_path scans real cache dirs. We provide the same headroom default
# (1024) and a controllable squashfs-size stub so the test is deterministic and
# needs no real squashfs on disk.
RUNTIME_HEADROOM_MB=1024
SQUASHFS_MB=0      # the synthetic on-disk squashfs size the stub reports
# Re-define blob_squashfs_mb to return our controllable size (overrides the carved
# du/path version). This isolates the projection arithmetic from the filesystem.
blob_squashfs_mb() { printf '%s\n' "${SQUASHFS_MB}"; }
# blob_squashfs_path isn't needed once blob_squashfs_mb is stubbed, but define a
# no-op so any stray call is harmless.
blob_squashfs_path() { return 1; }

# shellcheck disable=SC1090
source "${RAMLIB}"
# our stub must win over the carved one (source order): re-stub AFTER sourcing.
blob_squashfs_mb() { printf '%s\n' "${SQUASHFS_MB}"; }

# --- synthetic catalog --------------------------------------------------------
# flatout2: PROTON, NO shm_mb (an OLD proton blob) -> fallback max(ram_max,squashfs,4096).
# proton-new: HAS shm_mb=5120 (a NEW blob) -> uses it verbatim.
# ncdc: NATIVE (non-proton) blob - runs straight from squashfs under bwrap, no /dev/shm
#   copy -> shm need is genuinely 0, required = ram_min(floored) + headroom. This is the
#   case that was wrongly charged the 4096 proton fallback and refused on 8GB boxes.
CATALOG="${TMPDIR_T}/catalog.json"
cat > "${CATALOG}" <<'JSON'
{
  "version": 2,
  "games": [
    { "name": "flatout2", "ram_min": 2048, "ram_max": 4096, "proton": true },
    { "name": "proton-new", "ram_min": 3000, "ram_max": 6000, "shm_mb": 5120, "proton": true },
    { "name": "ncdc", "ram_min": 128, "ram_max": 256 }
  ]
}
JSON

echo "================ effective_shm_mb ============================="

# proton-new: shm_mb present -> used verbatim
SQUASHFS_MB=1200
assert_eq "$(effective_shm_mb "${CATALOG}" proton-new)" "5120" "shm_mb present -> effective_shm = catalog shm_mb"

# flatout2: NO shm_mb -> fallback max(ram_max=4096, squashfs=1200, 4096) = 4096
SQUASHFS_MB=1200
assert_eq "$(effective_shm_mb "${CATALOG}" flatout2)" "4096" "no shm_mb, small squashfs -> fallback = max(ram_max,sq,4096)=4096"

# flatout2 with a BIG on-disk squashfs (6500MB) -> fallback rises to the squashfs size
SQUASHFS_MB=6500
assert_eq "$(effective_shm_mb "${CATALOG}" flatout2)" "6500" "no shm_mb, big squashfs -> fallback tracks squashfs MB"

# ncdc: NATIVE (non-proton), no shm_mb -> shm need is 0 (NOT the 4096 proton fallback).
# This is the bug fix: native games make no /dev/shm copy.
SQUASHFS_MB=1200
assert_eq "$(effective_shm_mb "${CATALOG}" ncdc)" "0" "native (non-proton) blob -> effective_shm = 0 (no /dev/shm copy)"

echo
echo "================ required_mb projection ======================="

# required = effective_shm + headroom(1024) + squashfs
# proton-new with squashfs=1200: 5120 + 1024 + 1200 = 7344
SQUASHFS_MB=1200
assert_eq "$(required_mb "${CATALOG}" proton-new)" "7344" "required = shm(5120) + headroom(1024) + squashfs(1200) = 7344"

# flatout2 with squashfs=1200: effective_shm = max(4096,1200,4096)=4096; req = 4096+1024+1200 = 6320
SQUASHFS_MB=1200
assert_eq "$(required_mb "${CATALOG}" flatout2)" "6320" "required(flatout2) = 4096 + 1024 + 1200 = 6320"

# ncdc: NATIVE blob -> light path = ram_min(128, floored to 1024) + headroom(1024) = 2048.
# NOT the old 4096+1024+squashfs over-charge that refused it on 8GB. squashfs size is
# irrelevant here (reclaimable page cache), so a big squashfs must NOT inflate required.
SQUASHFS_MB=6500
assert_eq "$(required_mb "${CATALOG}" ncdc)" "2048" "required(ncdc native) = ram_min floored(1024) + headroom(1024) = 2048 (fits 8GB)"

echo
echo "================ RAM gate: 8GB refuses, 16GB fits ========"
# Model the launch gate decision (free >= required) directly with the projection,
# exactly as partyos-ram's ensure_room/fits compares. Use proton-new at a big
# squashfs so required ~= 6.5GB+, then check an 8GB-free box vs a 16GB-free box.
SQUASHFS_MB=1024
REQ="$(required_mb "${CATALOG}" proton-new)"   # 5120 + 1024 + 1024 = 7168 MB (~7GB)
# 8GB box: MemAvailable is well under 8192 in practice (OS in RAM + squashfs already
# paged); model a realistic ~6000MB free on an 8GB box -> MUST refuse a 7168MB launch.
FREE_8GB=6000
if [ "${FREE_8GB}" -ge "${REQ}" ]; then GATE_8="fit"; else GATE_8="refuse"; fi
assert_eq "${GATE_8}" "refuse" "RAM gate: 8GB box (~6000MB free) REFUSES the ${REQ}MB game"

# 16GB box: ~13000MB free -> the same game FITS (gate is honest, not just paranoid).
FREE_16GB=13000
if [ "${FREE_16GB}" -ge "${REQ}" ]; then GATE_16="fit"; else GATE_16="refuse"; fi
assert_eq "${GATE_16}" "fit" "RAM gate: 16GB box (~13000MB free) FITS the same ${REQ}MB game"

# A gate that compares free RAM against ram_min only (3000 for proton-new) admits it.
RAM_MIN="$(grep 'proton-new' "${CATALOG}" | grep -oE '"ram_min":[[:space:]]*[0-9]+' | grep -oE '[0-9]+')"
if [ "${FREE_8GB}" -ge "${RAM_MIN}" ]; then OLD_GATE="fit"; else OLD_GATE="refuse"; fi
assert_eq "${OLD_GATE}" "fit" "RAM gate: a ram_min-only gate admits it on the 8GB box"

assert_summary "test-ram-gate" || exit 1
echo "test-ram-gate: ALL PASS"
