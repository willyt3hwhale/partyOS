#!/usr/bin/env bash
# test-report-feedback.sh - hardware-FREE unit + integration test for the in-session
# "Report an Issue" player INBOX feature. Opt-in context: a plain message carries
# nick + message ONLY; a bug report (opt-in) ALSO carries build_id + log_tail. Three
# parts, no VM, no real hardware:
#
#   1. SERVER PERSIST (end-to-end-ish): start the REAL server/http_server.py on a
#      free port and POST BOTH shapes to /feedback - (a) a message-ONLY report and
#      (b) a bug report with system info - and assert each lands as a timestamped
#      JSON file under server/reports/. Assert the message-only entry has NO
#      system-context fields and the bug entry DOES (build_id + log_tail). Also
#      assert the legacy /report endpoint is UNCHANGED (still logs the REPORT line,
#      writes nothing) - the regression guard.
#
#   2. CLIENT CONTEXT (carve + run): copy the baked partyos-report from
#      scripts/build/files/rootfs/usr/local/bin/, source ONLY its helpers
#      (PARTYOS_REPORT_LIB=1 makes the script return before the zenity GUI), and run
#      collect_context / current_game against fake /run + /proc fixtures. The opt-in
#      context is the LEAN set - build_id + game + mem_free + log_tail (no hostname/
#      nick/uptime; those are not the system-info bundle). Asserts the log tail is
#      BOUNDED (flattened to one line, <= 50 entries).
#
#   3. OFFLINE-QUEUE DRAIN DECISION: extract partyos-report-flush and assert the
#      reachability gate leaves the queue INTACT when the server is down (a failed
#      probe must NOT delete queued reports - that was the data-loss trap to avoid),
#      and that with no queue it is a clean no-op.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

RFS="${REPO_ROOT}/scripts/build/files/rootfs"
SERVER="${REPO_ROOT}/server/http_server.py"
[ -d "${RFS}" ]    || { echo "FAIL: baked rootfs tree not found at ${RFS}"; exit 1; }
[ -f "${SERVER}" ] || { echo "FAIL: http_server.py not found at ${SERVER}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-reporttest.XXXXXX")"
SRV_PID=""
cleanup() {
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    rm -rf "${TMPDIR_T}"
    # remove only the report files this test created (the dir is gitignored anyway).
    rm -rf "${REPO_ROOT}/server/reports" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
echo "================ 1. server /feedback persists a report ========"
# ----------------------------------------------------------------------------
# A clean reports dir so we count only what this run writes.
rm -rf "${REPO_ROOT}/server/reports" 2>/dev/null || true

# pick a free-ish high port and start the REAL server.
PORT=$(( (RANDOM % 2000) + 18080 ))
python3 -u "${SERVER}" "${PORT}" 127.0.0.1 >"${TMPDIR_T}/srv.log" 2>&1 &
SRV_PID=$!

# wait for the listener (bounded: ~5s) - poll /report which always 200s.
up=0
for _ in $(seq 1 50); do
    if curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:${PORT}/report?step=probe" 2>/dev/null; then
        up=1; break
    fi
    sleep 0.1
done
assert_true "$([ "${up}" = 1 ]; echo $?)" "http_server.py came up on 127.0.0.1:${PORT}"

if [ "${up}" = 1 ]; then
    rdir="${REPO_ROOT}/server/reports"

    # 1a. POST a MESSAGE-ONLY report (checkbox UNticked): nick + message, NO context.
    msg_body='{"schema":"partyos-report-2","nick":"speedrunner","message":"the snacks ran out","is_bug":false}'
    curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' \
        --data-binary "${msg_body}" "http://127.0.0.1:${PORT}/feedback" > "${TMPDIR_T}/msg.out" 2>/dev/null
    rc=$?
    assert_true "${rc}" "POST /feedback (message-only) returned 200"
    assert_contains "$(cat "${TMPDIR_T}/msg.out" 2>/dev/null)" "saved " "message-only response names the saved file"
    msg_file="$(printf '%s' "$(cat "${TMPDIR_T}/msg.out")" | sed -n 's/^saved //p' | tr -d '\n')"

    # 1b. POST a BUG report (checkbox TICKED): nick + message + build_id + log_tail.
    bug_body='{"schema":"partyos-report-2","nick":"laggard","message":"game crashes on launch","is_bug":true,"build_id":"20260616T120000Z-builder","game":"hexen2","mem_free":"4096 MB","log_tail":"logline-1\nlogline-2\nlogline-3"}'
    curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' \
        --data-binary "${bug_body}" "http://127.0.0.1:${PORT}/feedback" > "${TMPDIR_T}/bug.out" 2>/dev/null
    assert_true "$?" "POST /feedback (bug + system info) returned 200"
    bug_file="$(printf '%s' "$(cat "${TMPDIR_T}/bug.out")" | sed -n 's/^saved //p' | tr -d '\n')"

    # 1c. both files landed under server/reports/ as JSON.
    nfiles=$(ls -1 "${rdir}"/*.json 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "${nfiles}" "2" "two report files persisted under server/reports/"

    # 1d. the MESSAGE-ONLY entry: has nick + message, but NO system-context fields.
    msgjson="$(cat "${rdir}/${msg_file}" 2>/dev/null)"
    assert_contains "${msgjson}" "speedrunner"      "message-only entry contains the nick"
    assert_contains "${msgjson}" "the snacks ran out" "message-only entry contains the message"
    assert_contains "${msgjson}" "received_at"       "server stamped received_at on the message-only entry"
    assert_not_contains "${msgjson}" "build_id"  "message-only entry has NO build_id (no system info attached)"
    assert_not_contains "${msgjson}" "log_tail"  "message-only entry has NO log_tail (no system info attached)"
    assert_not_contains "${msgjson}" "hostname"  "message-only entry has NO hostname (no system info attached)"
    assert_not_contains "${msgjson}" "mem_free"  "message-only entry has NO mem_free (no system info attached)"

    # 1e. the BUG entry: has nick + message AND the opted-in system context.
    bugjson="$(cat "${rdir}/${bug_file}" 2>/dev/null)"
    assert_contains "${bugjson}" "laggard"             "bug entry contains the nick"
    assert_contains "${bugjson}" "game crashes on launch" "bug entry contains the message"
    assert_contains "${bugjson}" "20260616T120000Z-builder" "bug entry carries the attached build_id"
    assert_contains "${bugjson}" "log_tail"            "bug entry carries the attached log_tail"
    assert_contains "${bugjson}" "logline-2"           "bug entry log_tail holds the journal lines"
    assert_contains "${bugjson}" "received_at"         "server stamped received_at on the bug entry"

    # 1f. REGRESSION GUARD: legacy /report still logs + writes NOTHING new on disk.
    before=$(ls -1 "${rdir}"/*.json 2>/dev/null | wc -l | tr -d ' ')
    curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${PORT}/report?step=7&status=ok" 2>/dev/null
    after=$(ls -1 "${rdir}"/*.json 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "${after}" "${before}" "/report wrote no report file (logs only - unchanged)"
    assert_contains "$(cat "${TMPDIR_T}/srv.log" 2>/dev/null)" "REPORT step=7 status=ok" "/report still emits the greppable REPORT marker"
    assert_contains "$(cat "${TMPDIR_T}/srv.log" 2>/dev/null)" "FEEDBACK saved=" "/feedback emits its own greppable FEEDBACK marker"
fi
kill "${SRV_PID}" 2>/dev/null || true; SRV_PID=""

# ============================================================================
echo
echo "================ 2. client collect_context (carve + run) ======"
# ----------------------------------------------------------------------------
REPORT_BODY="${TMPDIR_T}/partyos-report.sh"
cp "${RFS}/usr/local/bin/partyos-report" "${REPORT_BODY}"
[ -s "${REPORT_BODY}" ] || { echo "FAIL: partyos-report baked file is empty"; exit 1; }
grep -q 'collect_context()' "${REPORT_BODY}" || { echo "FAIL: collect_context missing from PREPORT carve"; exit 1; }
grep -q 'current_game()'    "${REPORT_BODY}" || { echo "FAIL: current_game missing from PREPORT carve"; exit 1; }
bash -n "${REPORT_BODY}" || { echo "FAIL: PREPORT carve is not valid bash"; exit 1; }

# The opt-in system info bundle is LEAN: build_id + game + mem_free + log_tail. The
# script reads /etc/partyos-build-id, /proc/meminfo, /run/partyos-games, journalctl/
# dmesg. We can't redirect absolute paths from a sourced function, so we shim the
# journalctl COMMAND and accept the real /proc reads (a dev host has plausible
# values; we assert structure, not exact host content). To keep this hermetic we
# assert on the FIELDS the function emits and the BOUNDEDNESS of the log tail.

# shim journalctl to a deterministic 200-line stream so we can prove the 50-line bound.
JBIN="${TMPDIR_T}/bin"; install -d "${JBIN}"
cat > "${JBIN}/journalctl" <<'JC'
#!/usr/bin/env bash
# emit 200 numbered lines regardless of args; the helper asks for -n 50.
# (the real journalctl applies -n; here we honor it so the bound is exercised.)
n=200
for a in "$@"; do case "${prev:-}" in -n) n="$a";; esac; prev="$a"; done
for i in $(seq 1 "${n}"); do echo "logline-${i}"; done
JC
chmod +x "${JBIN}/journalctl"

# source ONLY the helpers (PARTYOS_REPORT_LIB makes the script return pre-GUI).
# shellcheck disable=SC1090
( PATH="${JBIN}:${PATH}" PARTYOS_REPORT_LIB=1 bash -c '
    source "'"${REPORT_BODY}"'"
    collect_context
' ) > "${TMPDIR_T}/ctx.out" 2>/dev/null
ctx="$(cat "${TMPDIR_T}/ctx.out" 2>/dev/null)"

# the LEAN opt-in bundle: build + game + mem_free + log_tail (the bug debugging set).
assert_contains "${ctx}" "build_id=" "context attaches the image build_id"
assert_contains "${ctx}" "game="     "context attaches the current/last game"
assert_contains "${ctx}" "mem_free=" "context attaches free RAM"
assert_contains "${ctx}" "log_tail=" "context attaches a log tail"
# nick is NOT part of the opt-in bundle (it is attached to every report separately);
# hostname/uptime are deliberately dropped from the bug context (lean, not a dump).
assert_not_contains "${ctx}" "hostname=" "context does NOT include hostname (lean bug bundle)"
assert_not_contains "${ctx}" "uptime="   "context does NOT include uptime (lean bug bundle)"

# BOUNDEDNESS: the whole context is one line per key (the log tail is flattened),
# so the emitted block must have exactly 4 lines - NOT 50+ from an unflattened tail.
nlines=$(printf '%s\n' "${ctx}" | grep -c '=')
assert_eq "${nlines}" "4" "context is 4 key=value lines (log tail flattened, not dumped raw)"
# and the flattened tail must carry <= 50 records (the bound), proven via the RS sep.
logline="$(printf '%s\n' "${ctx}" | grep '^log_tail=' | head -1)"
nrec=$(printf '%s' "${logline}" | tr '\036' '\n' | grep -c 'logline-')
assert_true "$([ "${nrec}" -le 50 ]; echo $?)" "log tail is BOUNDED to <=50 records (got ${nrec})"
assert_true "$([ "${nrec}" -ge 1 ]; echo $?)"  "log tail is non-empty (got ${nrec} records)"

# ============================================================================
echo
echo "================ 3. offline-queue flush: no-clobber gate ======="
# ----------------------------------------------------------------------------
FLUSH_BODY="${TMPDIR_T}/partyos-report-flush.sh"
cp "${RFS}/usr/local/bin/partyos-report-flush" "${FLUSH_BODY}"
[ -s "${FLUSH_BODY}" ] || { echo "FAIL: partyos-report-flush baked file is empty"; exit 1; }
bash -n "${FLUSH_BODY}" || { echo "FAIL: PRFLUSH carve is not valid bash"; exit 1; }

# Run the flush against a FAKE queue dir with the server pointed at a dead port. The
# reachability probe must fail -> the queue files must SURVIVE (no delete-on-failure).
# Mix both shapes in the queue (a plain message + a bug report) - the flush relays
# either verbatim, so the opt-in shape change must not affect the no-clobber gate.
FAKE_QUEUE="${TMPDIR_T}/fakeq"; install -d "${FAKE_QUEUE}"
printf '{"schema":"partyos-report-2","nick":"partygoer","message":"queued while offline","is_bug":false}\n' \
    > "${FAKE_QUEUE}/20260616T010101Z-1.json"
printf '{"schema":"partyos-report-2","nick":"partygoer","message":"second queued","is_bug":true,"build_id":"x","log_tail":"l"}\n' \
    > "${FAKE_QUEUE}/20260616T020202Z-2.json"

# A dead port (nothing listening) -> the bounded probe fails fast.
DEAD_PORT=$(( (RANDOM % 2000) + 28080 ))
# Patch the hard-coded QUEUE_DIR + base for this hermetic run via sed into a copy.
RUN_FLUSH="${TMPDIR_T}/flush-run.sh"
# Force the base to the dead port with a stand-in appstore.conf (SERVER_BASE= wins over
# /proc/cmdline). The script has no fallback address, so the base must be explicit.
printf 'SERVER_BASE=http://127.0.0.1:%s\n' "${DEAD_PORT}" > "${TMPDIR_T}/appstore.conf"
sed -e "s#QUEUE_DIR=\"/mnt/usbhome/.partyos-reports\"#QUEUE_DIR=\"${FAKE_QUEUE}\"#" \
    -e "s#/etc/partyos/appstore.conf#${TMPDIR_T}/appstore.conf#g" \
    "${FLUSH_BODY}" > "${RUN_FLUSH}"
bash "${RUN_FLUSH}" > "${TMPDIR_T}/flush.out" 2>&1
left=$(ls -1 "${FAKE_QUEUE}"/*.json 2>/dev/null | wc -l | tr -d ' ')
assert_eq "${left}" "2" "server unreachable -> BOTH queued reports SURVIVE (no delete-on-failure)"
assert_contains "$(cat "${TMPDIR_T}/flush.out" 2>/dev/null)" "unreachable" "flush logged that it left the queue intact"

# empty-queue fast path: no files -> clean no-op exit 0.
EMPTY_QUEUE="${TMPDIR_T}/emptyq"; install -d "${EMPTY_QUEUE}"
RUN_FLUSH2="${TMPDIR_T}/flush-run2.sh"
sed -e "s#QUEUE_DIR=\"/mnt/usbhome/.partyos-reports\"#QUEUE_DIR=\"${EMPTY_QUEUE}\"#" \
    "${FLUSH_BODY}" > "${RUN_FLUSH2}"
bash "${RUN_FLUSH2}" > "${TMPDIR_T}/flush2.out" 2>&1
assert_true "$?" "empty queue -> flush is a clean no-op (exit 0)"

assert_summary "test-report-feedback" || exit 1
echo "test-report-feedback: ALL PASS"
