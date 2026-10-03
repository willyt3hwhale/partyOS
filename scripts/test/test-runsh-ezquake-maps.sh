#!/usr/bin/env bash
# test-runsh-ezquake-maps.sh - hardware-free test for the ezquake data seed in run.sh.
#
# The shareware pak0 has no dm1 to dm6. The blob bakes the free nQuake maps in
# /opt/quake-extra, and the run.sh seed copies them into ~/quake on every launch.
# The seed keys on the files and not on the ready marker, so an old home gets them.
# It skips gpl_maps.pk3 when pak1.pak is present, and it never overwrites a file.
#
# This carves the real EZ_SEED block from build-app-blob.sh. It runs the block
# against a fake blob root and a fake HOME, with a stub zenity, then checks ~/quake.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"
assert_file_exists() { if [ -f "$1" ]; then r=0; else r=1; fi; assert_true "${r}" "$2"; }

B="${REPO_ROOT}/scripts/build/build-app-blob.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-ezq.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

echo "================ 1. the builder pins and checks every map ============="
build="$(cat "${B}")"
assert_contains "${build}" "nQuake/distfiles/cb5085cfc4ad8aaab1411de030c17517302693be" "builder: pins the nQuake commit"
for f in "id1/gpl_maps.pk3 6e409cab705ea6046872383149a222fe76a351f03ac48055b3e5f1faaec9d6c6" \
         "qw/maps/aerowalk.bsp 6c297aaa5ccb8f10f6f7ee4991ba6663f887414e31e6eac8358510e14e4ec98b" \
         "qw/maps/ztndm3.bsp 4ae63e8d82f6439d79cbde4d1a7b46dbbc46a34eb30839ba2db24e1fd0778fbe" \
         "qw/maps/ztndm4.bsp 192647cd29d7901d6d71fea7114c7168315f5b13a8b5e0beeac535d29000d2d7" \
         "qw/maps/ztndm6.bsp b0039ac2d4ea83661e0cc7fb769537e25496007d152c2550b18b5f68df5a351f" \
         "qw/maps/schloss.bsp 947d6a01e293d27f387080011fea0bfecda55c574cb664494c7dd21af71eb2dd"; do
    assert_contains "${build}" "${f}" "builder: pins ${f%% *}"
done
assert_contains "${build}" 'FATAL ${QDST} sha256 mismatch' "builder: a sha mismatch is FATAL"

echo
echo "================ 2. run the REAL carved seed block ===================="
awk '/^EZ_SEED=\x27$/ { c=1; next } c && /^\x27$/ { exit } c { print }' "${B}" > "${T}/seed.sh"
bash -n "${T}/seed.sh"; assert_true $? "carved seed: bash -n"
seed="$(cat "${T}/seed.sh")"
assert_contains "${seed}" "quake-extra" "carved seed: has the map step"
assert_not_contains "${seed}" "classic deathmatch maps (dm1 to dm6) are in pak1.pak" "notice: no longer says dm1-dm6 are missing"

# Fake blob root: engine dir, shareware data and the extra maps.
R="${T}/root"
mkdir -p "${R}/opt/quake/id1" "${R}/opt/quake-shareware/id1" "${R}/opt/quake-extra/id1" "${R}/opt/quake-extra/qw/maps" "${T}/bin"
echo sw > "${R}/opt/quake-shareware/id1/pak0.pak"
echo gpl > "${R}/opt/quake-extra/id1/gpl_maps.pk3"
for m in aerowalk ztndm3 ztndm4 ztndm6 schloss; do echo "${m}" > "${R}/opt/quake-extra/qw/maps/${m}.bsp"; done
echo credits > "${R}/opt/quake-extra/qw/maps/ztndm3.txt"
echo readme > "${R}/opt/quake-extra/README-partyos-maps.txt"
# The stub zenity records the notice text, so no window opens.
printf '#!/bin/bash\nprintf "%%s\\n" "$@" >> "%s/zenity.log"\n' "${T}" > "${T}/bin/zenity"
chmod +x "${T}/bin/zenity"

# run_seed <home>: run the seed as run.sh does, print its output.
run_seed() { ( HOME="$1"; ROOT="${R}"; PATH="${T}/bin:${PATH}"; source "${T}/seed.sh" ) 2>&1; }

# a) A new home on shareware data gets every map.
H="${T}/h-new"; mkdir -p "${H}"
out="$(run_seed "${H}")"
assert_contains "${out}" "PARTYOS-EZQUAKE-DATA shareware" "new home: shareware data"
assert_file_exists "${H}/quake/id1/gpl_maps.pk3" "new home: gpl_maps.pk3 seeded"
for m in aerowalk ztndm3 ztndm4 ztndm6 schloss; do
    assert_file_exists "${H}/quake/qw/maps/${m}.bsp" "new home: ${m}.bsp seeded"
done
assert_file_exists "${H}/quake/qw/maps/ztndm3.txt" "new home: the author text file travels with the map"
assert_file_exists "${H}/quake/README-partyos-maps.txt" "new home: the maps readme is seeded"
assert_contains "$(cat "${T}/zenity.log")" "dm1 to dm6 (free GPL versions from nQuake)" "notice: names the free dm maps"

# b) An old home that already has the ready marker still gets the maps.
H="${T}/h-old"; mkdir -p "${H}/quake/id1"
echo sw > "${H}/quake/id1/pak0.pak"; touch "${H}/quake/.partyos-ezquake-ready" "${H}/quake/.partyos-quake-data-notice"
run_seed "${H}" >/dev/null
assert_file_exists "${H}/quake/id1/gpl_maps.pk3" "old home with the marker: gpl_maps.pk3 seeded"
assert_file_exists "${H}/quake/qw/maps/aerowalk.bsp" "old home with the marker: aerowalk.bsp seeded"

# c) A retail home (pak1.pak present) gets no gpl_maps.pk3, but still the QW maps.
H="${T}/h-retail"; mkdir -p "${H}/quake/id1"
echo sw > "${H}/quake/id1/pak0.pak"; echo retail > "${H}/quake/id1/pak1.pak"
out="$(run_seed "${H}")"
assert_contains "${out}" "PARTYOS-EZQUAKE-DATA retail" "retail home: retail data"
if [ -e "${H}/quake/id1/gpl_maps.pk3" ]; then r=1; else r=0; fi
assert_eq "${r}" "0" "retail home: no gpl_maps.pk3 next to pak1.pak"
assert_file_exists "${H}/quake/qw/maps/ztndm6.bsp" "retail home: ztndm6.bsp seeded"

# d) The seed never overwrites a file the player has, and a second launch is a no-op.
H="${T}/h-own"; mkdir -p "${H}/quake/qw/maps"
echo mine > "${H}/quake/qw/maps/aerowalk.bsp"
run_seed "${H}" >/dev/null; run_seed "${H}" >/dev/null
assert_eq "$(cat "${H}/quake/qw/maps/aerowalk.bsp")" "mine" "own file: aerowalk.bsp is not overwritten"
assert_file_exists "${H}/quake/qw/maps/schloss.bsp" "own file: the other maps are still seeded"

assert_summary
