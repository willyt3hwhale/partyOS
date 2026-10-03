#!/usr/bin/env bash
# lib-assert.sh - tiny PASS/FAIL assertion helpers shared by the hardware-free
# prod-path unit/integration tests (scripts/test/*). No VM, no network, no
# hardware - pure shell, runnable locally and in CI.
#
# Each assertion prints "  PASS: <msg>" or "  FAIL: <msg>" and bumps a counter.
# A test sources this, runs assertions, then calls assert_summary which exits
# non-zero if any assertion failed. Source it; do not execute it directly.

ASSERT_PASS=0
ASSERT_FAIL=0

_assert_ok()   { ASSERT_PASS=$((ASSERT_PASS+1)); printf '  PASS: %s\n' "$1"; }
_assert_bad()  { ASSERT_FAIL=$((ASSERT_FAIL+1)); printf '  FAIL: %s\n' "$1"; }

# assert_contains HAYSTACK NEEDLE MSG  - MSG passes if NEEDLE is a substring of HAYSTACK.
assert_contains() {
    case "$1" in
        *"$2"*) _assert_ok "$3";;
        *)      _assert_bad "$3 (expected to find: [$2])";;
    esac
}

# assert_not_contains HAYSTACK NEEDLE MSG - MSG passes if NEEDLE is ABSENT from HAYSTACK.
assert_not_contains() {
    case "$1" in
        *"$2"*) _assert_bad "$3 (did NOT expect to find: [$2])";;
        *)      _assert_ok "$3";;
    esac
}

# assert_eq ACTUAL EXPECTED MSG
assert_eq() {
    if [ "$1" = "$2" ]; then _assert_ok "$3"
    else _assert_bad "$3 (got [$1] expected [$2])"; fi
}

# assert_true RC MSG  - pass if RC (an exit status, 0 = success) is 0.
assert_true()  { if [ "$1" -eq 0 ]; then _assert_ok "$2"; else _assert_bad "$2 (rc=$1)"; fi; }
# assert_false RC MSG - pass if RC is NON-zero.
assert_false() { if [ "$1" -ne 0 ]; then _assert_ok "$2"; else _assert_bad "$2 (rc=$1, expected non-zero)"; fi; }

# assert_summary NAME - print a tally and exit non-zero if any assertion failed.
assert_summary() {
    echo
    echo "  ---- ${1:-test}: ${ASSERT_PASS} passed, ${ASSERT_FAIL} failed ----"
    [ "${ASSERT_FAIL}" -eq 0 ] || return 1
    return 0
}
