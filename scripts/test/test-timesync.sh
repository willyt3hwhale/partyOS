#!/usr/bin/env bash
# test-timesync.sh - hardware-free unit test for partyos-timesync.
#
# partyos-timesync sets the client clock from the LAN server's HTTP Date header (the
# party LAN is isolated, no NTP). It had ZERO coverage; a dead sync is a latent
# boot-breaker on a cold-CMOS/RTC-less box (a skewed clock previously broke the HTTPS
# boot chain). The fix adds a `--check` self-test and makes the apply path provably
# FAIL-SAFE (log + exit 0 on every failure - never wedge, never fail the unit).
#
# This test copies the baked partyos-timesync script from
# scripts/build/files/rootfs/usr/local/bin/ and drives it with a MOCK server (a `curl` stub returning a
# controlled Date header) and a CLOCK-SAFE `date` shim that intercepts `date -s`
# (records it, NEVER touches the real system clock - critical: this test may run as
# root in CI). It asserts:
#   --check:  good Date -> exit 0 "CHECK ok"; server down -> non-zero "CHECK fail";
#             garbage Date -> non-zero "unparseable". --check NEVER sets the clock.
#   apply:    good Date -> clock IS set (date -s @epoch recorded) + "set ... -> ..." log.
#   fail-safe: server unreachable -> exit 0 (boot continues), clock NOT set.
#              unparseable Date   -> exit 0 (boot continues), clock NOT set.
#   unit:     ExecStart is `-`-prefixed so a crash cannot fail the unit / block boot.
# No VM, no network, no hardware. Needs python3 (for the GNU-`date -d` emulation the
# script relies on) + coreutils-free; skips cleanly if python3 is absent.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

TSYNC="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-timesync"
TSUNIT="${REPO_ROOT}/scripts/build/files/rootfs/etc/systemd/system/partyos-timesync.service"
[ -f "${TSYNC}" ]  || { echo "FAIL: partyos-timesync baked file not found at ${TSYNC}"; exit 1; }
[ -f "${TSUNIT}" ] || { echo "FAIL: partyos-timesync.service unit not found at ${TSUNIT}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable (needed for the date-parse shim)"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/partyos-timesync-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# --- copy the baked partyos-timesync script -----------------------------------
SCRIPT="${TMP}/partyos-timesync"
cp "${TSYNC}" "${SCRIPT}"
[ -s "${SCRIPT}" ] || { echo "FAIL: partyos-timesync baked file is empty (${TSYNC})"; exit 1; }
chmod +x "${SCRIPT}"
grep -q 'fetch_date' "${SCRIPT}" || { echo "FAIL: carved script missing fetch_date"; exit 1; }

# --- source-level guards: the fix is in the carved code + the unit ------------
STXT="$(cat "${SCRIPT}")"
assert_contains "${STXT}" '"${1:-}" = "--check"' "script has a --check self-test mode"
assert_contains "${STXT}" "clock NOT modified" "--check explicitly does not touch the clock"
BTXT="$(cat "${TSUNIT}")"
assert_contains "${BTXT}" "ExecStart=-/usr/local/bin/partyos-timesync" "unit ExecStart is '-'-prefixed: a sync crash cannot fail the unit / block boot"

# --- clock-safe mocks ---------------------------------------------------------
BIN="${TMP}/bin"; mkdir -p "${BIN}"
SETLOG="${TMP}/date-s.log"          # every intercepted `date -s` lands here (proof of apply)

# curl stub: emulate `curl -sSI ... URL`. MOCK_MODE drives it:
#   good -> HTTP 200 + Date: ${MOCK_DATE}; down -> non-zero, no output.
cat > "${BIN}/curl" <<'CURL'
#!/usr/bin/env bash
[ "${MOCK_MODE:-good}" = "down" ] && exit 7          # curl "couldn't connect"
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nDate: %s\r\n\r\n' "${MOCK_DATE:-}"
exit 0
CURL
chmod +x "${BIN}/curl"

# date shim: intercept `date -s` (record, NEVER set the real clock); emulate the
# GNU `date -d` the script needs via python3 (BSD date on macOS has no -d, and
# a real GNU host would otherwise ACTUALLY set the clock as root). Everything else
# delegates to the real date.
cat > "${BIN}/date" <<DATESH
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then
    printf '%s\n' "\${2:-}" >> "${SETLOG}"           # apply proof; do NOT set the clock
    exit 0
fi
if [ "\${1:-}" = "-d" ]; then
    spec="\${2:-}"
    if [ "\${3:-}" = "+%s" ]; then
        python3 - "\${spec}" <<'PY'
import sys, email.utils
s = sys.argv[1]
if s.startswith('@'):
    print(int(float(s[1:])))
else:
    dt = email.utils.parsedate_to_datetime(s)
    if dt is None:
        sys.exit(1)
    print(int(dt.timestamp()))
PY
        exit \$?
    fi
    python3 - "\${spec#@}" <<'PY'
import sys, datetime
print(datetime.datetime.utcfromtimestamp(int(float(sys.argv[1]))).strftime('%a %b %e %H:%M:%S UTC %Y'))
PY
    exit \$?
fi
exec /bin/date "\$@"
DATESH
chmod +x "${BIN}/date"

# hwclock + sleep + systemd-detect-virt stubs (no clock write, fast, no serial log).
for t in hwclock sleep systemd-detect-virt; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/${t}"; chmod +x "${BIN}/${t}"
done

# run_ts MODE DATE [ARG] -> runs the carved script with the mocks; sets RC + OUT.
# MODE=good|down selects the curl behavior; DATE is the served Date header. ARG lets
# the caller pass --check. PARTYOS_SERVER is an http base so no --cacert is needed.
run_ts() {
    local _mode="$1" _date="$2" _arg="${3:-}"
    : > "${SETLOG}"
    OUT="$(PATH="${BIN}:${PATH}" PARTYOS_SERVER="http://127.0.0.1:9" \
           MOCK_MODE="${_mode}" MOCK_DATE="${_date}" \
           bash "${SCRIPT}" ${_arg} 2>&1)"
    RC=$?
}

GOOD_DATE="Wed, 18 Jul 2029 12:00:00 GMT"
# expected epoch for the assertions (via the same python path the shim uses).
EXP_EPOCH="$(python3 - "${GOOD_DATE}" <<'PY'
import sys, email.utils
print(int(email.utils.parsedate_to_datetime(sys.argv[1]).timestamp()))
PY
)"

# --- --check: good server -> exit 0, no clock write ---------------------------
run_ts good "${GOOD_DATE}" --check
assert_eq "${RC}" "0" "--check (server up, good Date): exits 0"
assert_contains "${OUT}" "CHECK ok" "--check: reports the mechanism works"
assert_eq "$(wc -l < "${SETLOG}" | tr -d ' ')" "0" "--check: NEVER writes the clock (no date -s)"

# --- --check: server down -> non-zero, no clock write -------------------------
run_ts down "" --check
assert_false "${RC}" "--check (server down): exits NON-zero (diagnostic surfaces the fault)"
assert_contains "${OUT}" "CHECK fail" "--check down: names the unreachable server"
assert_eq "$(wc -l < "${SETLOG}" | tr -d ' ')" "0" "--check down: no clock write"

# --- --check: garbage Date -> non-zero "unparseable" --------------------------
run_ts good "total nonsense not-a-date" --check
assert_false "${RC}" "--check (garbage Date): exits NON-zero"
assert_contains "${OUT}" "unparseable" "--check garbage: names the unparseable Date"

# --- apply: good Date -> clock IS set, exit 0 ---------------------------------
run_ts good "${GOOD_DATE}"
assert_eq "${RC}" "0" "apply (good Date): exits 0"
assert_contains "${OUT}" "PARTYOS-TIMESYNC set" "apply: logs the clock change"
assert_contains "$(cat "${SETLOG}")" "@${EXP_EPOCH}" "apply: date -s called with the server epoch (@${EXP_EPOCH})"

# --- fail-safe: server unreachable -> exit 0, clock NOT set --------------------
run_ts down ""
assert_eq "${RC}" "0" "fail-safe (server down): exits 0 - boot CONTINUES, never wedges"
assert_contains "${OUT}" "skip" "fail-safe down: logs a skip"
assert_eq "$(wc -l < "${SETLOG}" | tr -d ' ')" "0" "fail-safe down: clock left as-is (no date -s)"

# --- fail-safe: unparseable Date -> exit 0, clock NOT set ---------------------
run_ts good "garbage garbage"
assert_eq "${RC}" "0" "fail-safe (unparseable Date): exits 0 - boot CONTINUES"
assert_contains "${OUT}" "unparseable" "fail-safe garbage: logs the unparseable Date"
assert_eq "$(wc -l < "${SETLOG}" | tr -d ' ')" "0" "fail-safe garbage: clock left as-is"

assert_summary "test-timesync"
