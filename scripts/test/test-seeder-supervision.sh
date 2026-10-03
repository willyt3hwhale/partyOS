#!/usr/bin/env bash
# test-seeder-supervision.sh - guard the P2P seeder hardening in run-servers.sh
#
# run-servers.sh keeps blobs seeded with three changes:
#   (a) supervise + respawn the seeder (respawn loop, small backoff, logged).
#   (b) idempotent restart: pre-stop the prior instances the script owns so a
#       re-run never fails on an already-bound port.
#   (c) seed only real blobs: build the torrent list from list-seed-torrents.sh,
#       which drops orphan torrents that have no backing data blob.
#
# The seed-only-real-blobs FILTER is extracted into scripts/deploy/list-seed-torrents.sh
# and driven here with mock files. The supervision/idempotency wiring is pinned with
# static guards on run-servers.sh. Hardware-free: pure shell, no aria2, no network.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

LIST="${REPO_ROOT}/scripts/deploy/list-seed-torrents.sh"
RUNSRV="${REPO_ROOT}/scripts/deploy/run-servers.sh"
for f in "${LIST}" "${RUNSRV}"; do
  [ -f "${f}" ] || { echo "FAIL: expected script not found at ${f}"; exit 1; }
done

# --- (c) filter: seed only torrents that have a backing blob ------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-seedfilter-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
GAMES="${TMP}/games"
mkdir -p "${GAMES}"

# two real blobs (torrent WITH backing *.squashfs)
: > "${GAMES}/ddnet.squashfs";        : > "${GAMES}/ddnet.squashfs.torrent"
: > "${GAMES}/flatout2.squashfs";     : > "${GAMES}/flatout2.squashfs.torrent"
# an orphan hash-named torrent (no backing data file).
: > "${GAMES}/1698a7c705f791a5cb8d057497f6f0b88b8a369f.torrent"
# a torrent whose backing blob was removed (ghost.squashfs absent) - also an orphan.
: > "${GAMES}/ghost.squashfs.torrent"
# a .torrent.bak backup - must NOT match the *.torrent glob at all.
: > "${GAMES}/flatout2.squashfs.torrent.bak"

out="$(bash "${LIST}" "${GAMES}")"; rc=$?
assert_eq "${rc}" "0" "list-seed-torrents.sh exits 0"

lines="$(printf '%s\n' "${out}" | grep -c . || true)"
assert_eq "${lines}" "2" "exactly the 2 backed torrents are listed (orphans dropped)"

assert_contains "${out}" "ddnet.squashfs.torrent"    "backed torrent ddnet is seeded"
assert_contains "${out}" "flatout2.squashfs.torrent" "backed torrent flatout2 is seeded"
assert_not_contains "${out}" "1698a7c705f791a5cb8d057497f6f0b88b8a369f.torrent" \
  "orphan hash-named torrent (no backing blob) is NOT seeded"
assert_not_contains "${out}" "ghost.squashfs.torrent" \
  "torrent whose backing blob is gone is NOT seeded"
assert_not_contains "${out}" ".torrent.bak" \
  "a .torrent.bak backup never enters the seed list"

# empty / missing dir is not an error (empty list, rc 0).
empty_out="$(bash "${LIST}" "${TMP}/does-not-exist")"; erc=$?
assert_eq "${erc}" "0" "missing games dir exits 0 (not an error)"
assert_eq "$(printf '%s' "${empty_out}" | grep -c . || true)" "0" "missing games dir yields an empty list"

# --- (a) + (b) static wiring guards on run-servers.sh -------------------------
src="$(cat "${RUNSRV}")"

# (c) run-servers uses the extracted filter, not a blind *.torrent glob into aria2c.
assert_contains "${src}" "list-seed-torrents.sh" \
  "run-servers.sh builds the seed list via list-seed-torrents.sh (no blind glob)"

# (a) the seeder is supervised with a respawn loop that logs each respawn.
assert_contains "${src}" "respawn" \
  "run-servers.sh respawns the seeder when it exits (supervision loop present)"

# (b) idempotent restart: prior instances are pre-stopped so re-runs don't collide.
assert_contains "${src}" "pkill" \
  "run-servers.sh pre-stops prior instances it owns (idempotent restart)"

# all the load-bearing seeder flags are preserved (seed-forever P2P contract).
assert_contains "${src}" "--seed-ratio=0.0"                "seeder keeps --seed-ratio=0.0 (seed forever)"
assert_contains "${src}" "--bt-detach-seed-only"           "seeder keeps --bt-detach-seed-only (all blobs seed at once)"
assert_contains "${src}" "--check-integrity"               "seeder keeps --check-integrity"
assert_contains "${src}" '--bt-external-ip=${BLOB_FIRST_IP}'  "seeder advertises the configured blob first-IP via BLOB_FIRST_IP (no hardcode)"
assert_contains "${src}" "--rpc-secret=partyos"            "seeder keeps RPC secret partyos"

# --- FILE log level: not DEBUG -------------
# --console-log-level only sets the console (stderr) verbosity; the --log FILE
# verbosity is a SEPARATE knob that defaults to DEBUG. A DEBUG file log reached
# ~720MB and kept growing -> disk-fill -> P2P outage. Both must be pinned to notice.
assert_contains "${src}" "--console-log-level=notice" \
  "seeder keeps --console-log-level=notice (console level unchanged)"
assert_contains "${src}" " --log-level=notice" \
  "seeder sets --log-level=notice so the FILE log stops recording DEBUG (720MB disk-fill)"

# --- log size cap: seeder log can't fill the disk over a long party -----------
# (a) run-servers wires the cap helper before each (re)launch.
assert_contains "${src}" "cap-log.sh" \
  "run-servers.sh caps the seeder log before (re)launch (cap-log.sh wired in)"

CAP="${REPO_ROOT}/scripts/deploy/cap-log.sh"
assert_true "$([ -f "${CAP}" ]; echo $?)" "cap-log.sh helper exists"

# (b) functional: the real cap-log.sh rotates an OVERSIZED log to <log>.1 and leaves
# a SMALL one untouched (mock oversized log, no aria2, no network).
CAPD="${TMP}/cap"; mkdir -p "${CAPD}"
big="${CAPD}/seeder.log"
head -c 200 /dev/zero > "${big}" 2>/dev/null || printf '%200s' '' > "${big}"   # 200 bytes
bash "${CAP}" "${big}" 100; caprc=$?
assert_eq "${caprc}" "0" "cap-log.sh exits 0 after rotating an oversized log"
assert_true "$([ -f "${big}.1" ]; echo $?)" "oversized seeder log is rotated to <log>.1 past the cap"
assert_false "$([ -f "${big}" ] && [ "$(wc -c < "${big}" 2>/dev/null || echo 0)" -gt 100 ]; echo $?)" \
  "active seeder log no longer exceeds the cap after rotation"
assert_eq "$(wc -c < "${big}.1" | tr -d '[:space:]')" "200" "the rotated <log>.1 keeps the old log's content (one generation)"

small="${CAPD}/small.log"
head -c 10 /dev/zero > "${small}" 2>/dev/null || printf '%10s' '' > "${small}"  # 10 bytes
bash "${CAP}" "${small}" 100; srrc=$?
assert_eq "${srrc}" "0" "cap-log.sh exits 0 on a small log"
assert_false "$([ -f "${small}.1" ]; echo $?)" "a small seeder log (under the cap) is NOT rotated"
assert_eq "$(wc -c < "${small}" | tr -d '[:space:]')" "10" "a small seeder log is left untouched"

# --- (b) stop_prior_instances pkill patterns are interpreter-PORTABLE ----------
# THE BUG: the pkill patterns matched the interpreter literally (`python3 -u ...`).
# On a macOS Homebrew host the python child's argv[0] is the framework path
# (/opt/homebrew/.../MacOS/Python), so `python3` never appears and the pattern
# reaped NOTHING - a re-run then hit a :8443/:6969 port fight instead of a clean
# idempotent restart. The fix matches the interpreter agnostically so BOTH forms
# reap: macOS `.../Python -u <script>` AND Linux/rpi5 `python3 -u <script>`.
#
# Extract the ACTUAL patterns run-servers.sh uses (not a hand-copy) so this test
# regresses if the pattern ever reverts to a literal `python3`. The stored pattern
# still holds the ${HTTPD}/${REPO_ROOT} placeholders - expand them against this
# checkout, exactly as the script does at runtime, then match with grep -E (ERE,
# what Linux pgrep uses; the [...]/* pattern is identical under BSD pgrep too).
HTTPD="${REPO_ROOT}/server/http_server.py"
http_pat="$(grep -oE 'pkill -f "[^"]*-u \$\{HTTPD\}"' "${RUNSRV}" | head -1 | sed -E 's/^pkill -f "//; s/"$//')"
trk_pat="$(grep -oE 'pkill -f "[^"]*-u \$\{REPO_ROOT\}/server/bt_tracker\.py"' "${RUNSRV}" | head -1 | sed -E 's/^pkill -f "//; s/"$//')"
assert_true "$([ -n "${http_pat}" ]; echo $?)" "extracted the http_server pkill pattern from run-servers.sh"
assert_true "$([ -n "${trk_pat}" ]; echo $?)"  "extracted the bt_tracker pkill pattern from run-servers.sh"

# Guard the fix directly: the interpreter part must be agnostic, not a literal python3.
assert_contains "${http_pat}" "[Pp]ython[0-9.]*" "http_server pkill matches the interpreter agnostically ([Pp]ython[0-9.]*)"
assert_contains "${trk_pat}"  "[Pp]ython[0-9.]*" "bt_tracker pkill matches the interpreter agnostically ([Pp]ython[0-9.]*)"

# Expand the placeholders the same way run-servers.sh does at runtime.
http_re="${http_pat/'${HTTPD}'/${HTTPD}}"
trk_re="${trk_pat/'${REPO_ROOT}'/${REPO_ROOT}}"

# Two representative cmdlines for the SAME http_server listener plus a decoy.
mac_cmd="/opt/homebrew/Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python -u ${HTTPD} 8080 192.168.0.10 8443"
lin_cmd="python3 -u ${HTTPD} 8080 192.168.0.10 8443"
decoy_cmd="python3 -u /some/other/thing.py 8080 192.168.0.10 8443"

assert_true  "$(printf '%s\n' "${mac_cmd}"   | grep -Eq -- "${http_re}"; echo $?)" \
  "http pattern matches the macOS framework-python cmdline (the bug that reaped nothing)"
assert_true  "$(printf '%s\n' "${lin_cmd}"   | grep -Eq -- "${http_re}"; echo $?)" \
  "http pattern matches the plain python3 cmdline (Linux/rpi5 server host)"
assert_false "$(printf '%s\n' "${decoy_cmd}" | grep -Eq -- "${http_re}"; echo $?)" \
  "http pattern does NOT match an unrelated python -u /some/other/thing.py (no over-match)"

# The OLD literal-python3 pattern would have MISSED the macOS form - prove the fix matters.
assert_false "$(printf '%s\n' "${mac_cmd}"   | grep -Eq -- "python3 -u ${HTTPD}"; echo $?)" \
  "old literal 'python3 -u' pattern misses the macOS framework-python cmdline (why the fix was needed)"

# Same for the tracker pattern: both interpreter forms of the SAME tracker match.
mac_trk="/opt/homebrew/Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python -u ${REPO_ROOT}/server/bt_tracker.py 6969 192.168.0.10"
lin_trk="python3 -u ${REPO_ROOT}/server/bt_tracker.py 6969 192.168.0.10"
assert_true  "$(printf '%s\n' "${mac_trk}"   | grep -Eq -- "${trk_re}"; echo $?)" \
  "tracker pattern matches the macOS framework-python cmdline"
assert_true  "$(printf '%s\n' "${lin_trk}"   | grep -Eq -- "${trk_re}"; echo $?)" \
  "tracker pattern matches the plain python3 cmdline"
assert_false "$(printf '%s\n' "${decoy_cmd}" | grep -Eq -- "${trk_re}"; echo $?)" \
  "tracker pattern does NOT match an unrelated python process (no over-match)"

assert_summary "test-seeder-supervision"
