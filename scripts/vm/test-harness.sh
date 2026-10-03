#!/usr/bin/env bash
# test-harness.sh - self-test of the autonomous VM test harness.
#
# Proves the autonomous feedback loop works before any later step relies on it:
#   POSITIVE: boot a trivial VM that prints a known marker on serial; the harness
#             must detect it and exit 0.
#   NEGATIVE: ask the harness for a marker the VM will NEVER print; the harness
#             must time out and exit non-zero.
#
# Both outcomes are asserted here. Exit 0 only if BOTH behave as expected.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

MARKER="PARTYOS-HARNESS-SELFTEST-OK"
WRONG_MARKER="THIS-STRING-WILL-NEVER-APPEAR-ON-SERIAL"
IMG="$(mktemp "${TMPDIR:-/tmp}/partyos-selftest.XXXXXX.img")"
NEG_TIMEOUT="${NEG_TIMEOUT:-20}"

cleanup() { rm -f "${IMG}"; }
trap cleanup EXIT

log "building trivial self-test boot image"
python3 "${SELF_DIR}/make-selftest-image.py" "${IMG}" "${MARKER}" >&2

echo
echo "================ POSITIVE CASE (expect exit 0) ================"
# No HTTP server needed for the serial-marker self-test; --no-server keeps it
# fast and self-contained. Unset RUN_DIR so each harness invocation allocates
# its own isolated scratch dir (otherwise the first run's cleanup would delete
# the shared dir out from under the second run).
env -u RUN_DIR bash "${SELF_DIR}/harness.sh" \
    --marker "${MARKER}" \
    --fail-marker "BOGUS-FAIL-MARKER" \
    --timeout "${BOOT_TIMEOUT}" \
    --no-server \
    --name selftest-pos \
    -- --fda "${IMG}" --ram 64 --timeout "${BOOT_TIMEOUT}"
POS_RC=$?
echo "POSITIVE exit code: ${POS_RC}"

echo
echo "================ NEGATIVE CASE (expect non-zero) =============="
env -u RUN_DIR bash "${SELF_DIR}/harness.sh" \
    --marker "${WRONG_MARKER}" \
    --timeout "${NEG_TIMEOUT}" \
    --no-server \
    --name selftest-neg \
    -- --fda "${IMG}" --ram 64 --timeout "$((NEG_TIMEOUT + 10))"
NEG_RC=$?
echo "NEGATIVE exit code: ${NEG_RC}"

echo
echo "================ SELF-TEST VERDICT ==========================="
echo "positive case rc=${POS_RC} (want 0)"
echo "negative case rc=${NEG_RC} (want non-zero)"

if [ "${POS_RC}" -eq 0 ] && [ "${NEG_RC}" -ne 0 ]; then
    echo "HARNESS SELF-TEST: PASS"
    exit 0
else
    echo "HARNESS SELF-TEST: FAIL"
    exit 1
fi
