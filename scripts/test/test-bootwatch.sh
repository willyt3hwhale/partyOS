#!/usr/bin/env bash
# test-bootwatch.sh - hardware-FREE test for scripts/test/lib-bootwatch.sh, the
# boot-watch library with timeout + STALL detection. No VM, no network, no
# hardware: background appenders write to a temp log and each verdict path is
# exercised with short timeouts so the whole test runs in seconds.
#
# Covers: marker found (OK), fail-marker (immediate FAIL), hard TIMEOUT while
# the log stays ACTIVE (so it cannot be mistaken for a stall), STALL when the
# appender dies (distinct exit code, fires well before the hard timeout - the
# whole point: wedged is distinguishable from slow), --from-now skipping a
# stale marker from a "previous boot", heartbeat lines on stderr with elapsed +
# last-activity age, and usage errors.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"
# shellcheck source=lib-bootwatch.sh
source "${SELF_DIR}/lib-bootwatch.sh"

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-bootwatch.XXXXXX")"
cleanup() { pkill -P $$ 2>/dev/null; rm -rf "${TMPDIR_T}"; }
trap cleanup EXIT

echo "================ lib-bootwatch boot-watch library test ================"

# ----------------------------------------------------------------------------
echo
echo "---- 1. marker found -> BOOTWATCH_OK (0) ----"
LOG="${TMPDIR_T}/ok.log"
( sleep 0.3; echo "boot noise" >> "${LOG}"; sleep 0.3; echo "REPORT step=copytoram" >> "${LOG}" ) &
rc=0
bootwatch_wait --log "${LOG}" --marker "REPORT step=copytoram" \
    --timeout 10 --stall 5 --interval 0.1 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_OK}" "marker found returns BOOTWATCH_OK"
wait

# ----------------------------------------------------------------------------
echo
echo "---- 2. fail-marker -> BOOTWATCH_FAILMARKER (1), immediately ----"
LOG="${TMPDIR_T}/fail.log"
( sleep 0.3; echo "PANIC: kernel died" >> "${LOG}" ) &
rc=0
bootwatch_wait --log "${LOG}" --marker "never-appears" --fail-marker "PANIC" \
    --timeout 10 --stall 5 --interval 0.1 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_FAILMARKER}" "fail-marker returns BOOTWATCH_FAILMARKER"
wait

# ----------------------------------------------------------------------------
echo
echo "---- 3. hard timeout while the log stays ACTIVE -> BOOTWATCH_TIMEOUT (2) ----"
# The appender keeps writing past the deadline, so the stall detector must NOT
# fire - this proves TIMEOUT and STALL are genuinely distinct verdicts.
LOG="${TMPDIR_T}/timeout.log"
( for _ in $(seq 1 20); do echo "still alive" >> "${LOG}"; sleep 0.3; done ) &
APPENDER=$!
start="$(date +%s)"
rc=0
bootwatch_wait --log "${LOG}" --marker "never-appears" \
    --timeout 2 --stall 10 --interval 0.1 2>/dev/null || rc=$?
elapsed=$(( $(date +%s) - start ))
kill "${APPENDER}" 2>/dev/null; wait 2>/dev/null
assert_eq "${rc}" "${BOOTWATCH_TIMEOUT}" "active-but-markerless log returns BOOTWATCH_TIMEOUT"
assert_true "$([ "${elapsed}" -ge 2 ] && [ "${elapsed}" -le 5 ]; echo $?)" "timeout fired near the 2s deadline (elapsed=${elapsed}s)"

# ----------------------------------------------------------------------------
echo
echo "---- 4. appender dies -> BOOTWATCH_STALL (3), well before the timeout ----"
LOG="${TMPDIR_T}/stall.log"
echo "one burst of activity then silence" >> "${LOG}"
start="$(date +%s)"
rc=0
bootwatch_wait --log "${LOG}" --marker "never-appears" \
    --timeout 30 --stall 1 --interval 0.1 2>/dev/null || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "${rc}" "${BOOTWATCH_STALL}" "silent log returns BOOTWATCH_STALL"
assert_true "$([ "${elapsed}" -le 5 ]; echo $?)" "stall fired long before the 30s timeout (elapsed=${elapsed}s)"

# a log file that NEVER appears is also a stall, not a hang.
rc=0
bootwatch_wait --log "${TMPDIR_T}/never-created.log" --marker "x" \
    --timeout 30 --stall 1 --interval 0.1 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_STALL}" "never-created log file returns BOOTWATCH_STALL"

# ----------------------------------------------------------------------------
echo
echo "---- 5. --from-now ignores a stale marker from a previous boot ----"
LOG="${TMPDIR_T}/stale.log"
echo "REPORT step=copytoram" >> "${LOG}"   # stale marker, previous boot
# Without --from-now the stale marker is (correctly) found immediately.
rc=0
bootwatch_wait --log "${LOG}" --marker "REPORT step=copytoram" \
    --timeout 5 --stall 5 --interval 0.1 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_OK}" "without --from-now the pre-existing marker matches"
# With --from-now it must NOT match -> stall (nothing new arrives).
rc=0
bootwatch_wait --log "${LOG}" --marker "REPORT step=copytoram" --from-now \
    --timeout 30 --stall 1 --interval 0.1 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_STALL}" "--from-now skips the stale marker (stalls instead)"
# And a FRESH marker appended after the watch starts DOES match under --from-now.
( sleep 0.4; echo "REPORT step=copytoram" >> "${LOG}" ) &
rc=0
bootwatch_wait --log "${LOG}" --marker "REPORT step=copytoram" --from-now \
    --timeout 10 --stall 5 --interval 0.1 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_OK}" "--from-now matches a marker appended after the watch started"
wait
# TRUNCATION guard: the log is truncated/rotated mid-watch and the fresh marker
# lands BELOW the recorded offset. The offset must reset, not stay blind forever.
LOG="${TMPDIR_T}/truncate.log"
printf 'old boot line one\nold boot line two\nold boot line three\n' > "${LOG}"
( sleep 0.4; : > "${LOG}"; echo "fresh-marker-after-truncate" >> "${LOG}" ) &
rc=0
bootwatch_wait --log "${LOG}" --marker "fresh-marker-after-truncate" --from-now \
    --timeout 10 --stall 5 --interval 0.1 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_OK}" "truncation resets the --from-now offset (fresh marker below old offset found)"
wait

# ----------------------------------------------------------------------------
echo
echo "---- 6. heartbeat lines on stderr: elapsed + last-activity age ----"
LOG="${TMPDIR_T}/beat.log"
( for _ in $(seq 1 12); do echo "tick" >> "${LOG}"; sleep 0.3; done ) &
APPENDER=$!
rc=0
BEAT_ERR="$(bootwatch_wait --log "${LOG}" --marker "never-appears" \
    --timeout 3 --stall 10 --heartbeat 1 --interval 0.1 --label beat-test 2>&1 >/dev/null)" || rc=$?
kill "${APPENDER}" 2>/dev/null; wait 2>/dev/null
assert_eq "${rc}" "${BOOTWATCH_TIMEOUT}" "heartbeat run ends in TIMEOUT as arranged"
assert_contains "${BEAT_ERR}" "[beat-test] heartbeat: elapsed=" "heartbeat line emitted with elapsed"
assert_contains "${BEAT_ERR}" "last-activity=" "heartbeat line carries last-activity age"
beats="$(printf '%s\n' "${BEAT_ERR}" | grep -c "heartbeat:")"
assert_true "$([ "${beats}" -ge 2 ]; echo $?)" "at least 2 heartbeats over a 3s watch at 1s interval (got ${beats})"

# ----------------------------------------------------------------------------
echo
echo "---- 7. usage errors -> BOOTWATCH_USAGE (64) ----"
rc=0; bootwatch_wait --marker "x" 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_USAGE}" "missing --log is a usage error"
rc=0; bootwatch_wait --log "${TMPDIR_T}/x" 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_USAGE}" "missing --marker is a usage error"
rc=0; bootwatch_wait --log "${TMPDIR_T}/x" --marker "x" --bogus 2>/dev/null || rc=$?
assert_eq "${rc}" "${BOOTWATCH_USAGE}" "unknown flag is a usage error"

assert_summary "test-bootwatch" || exit 1
echo "test-bootwatch: ALL PASS"
