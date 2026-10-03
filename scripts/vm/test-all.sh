#!/usr/bin/env bash
# test-all.sh - the unattended acceptance gate: run step1..9 headless in sequence.
#
# Each step has its own `make test-stepN` that boots a full VM and asserts via
# serial markers + HTTP callbacks (and, where relevant, host-side qcow2 mounts).
# This runner just invokes them in order and stops on the first failure, so a
# single `make test-all` is a one-shot "is the whole 9-step pipeline green?".
#
# HEAVY: every step RAM-boots the ~1.6GB custom image (steps 3-9) under QEMU. On
# a host without KVM that is TCG (very slow); run this on a KVM host via
# scripts/vm/remote-test.sh test-all. Per-step timeouts come from each test's own
# STEP*_TIMEOUT; an overall wall-clock is printed. STEP_ALL_FROM / STEP_ALL_TO
# restrict the range (e.g. STEP_ALL_FROM=7 to run only 7..9).

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

FROM="${STEP_ALL_FROM:-1}"
TO="${STEP_ALL_TO:-9}"

echo "[test-all] running steps ${FROM}..${TO} in sequence (accel=${ACCEL})" >&2
START="$(date +%s)"
declare -a PASSED=() FAILED=()

for n in $(seq "${FROM}" "${TO}"); do
    echo "" >&2
    echo "============================================================" >&2
    echo "[test-all] === STEP ${n} ===" >&2
    echo "============================================================" >&2
    s_start="$(date +%s)"
    if make -C "${REPO_ROOT}" "test-step${n}" >&2; then
        s_dur=$(( $(date +%s) - s_start ))
        echo "[test-all] STEP ${n} PASS (${s_dur}s)" >&2
        PASSED+=("${n}")
    else
        s_dur=$(( $(date +%s) - s_start ))
        echo "[test-all] STEP ${n} FAIL (${s_dur}s)" >&2
        FAILED+=("${n}")
        echo "" >&2
        echo "[test-all] ABORTING: step ${n} failed; passed so far: ${PASSED[*]:-none}" >&2
        echo "TEST-ALL: FAIL at step ${n}" >&2
        exit 1
    fi
done

TOTAL=$(( $(date +%s) - START ))
echo "" >&2
echo "============================================================" >&2
echo "[test-all] ALL STEPS PASSED: ${PASSED[*]}" >&2
echo "[test-all] total wall-clock: ${TOTAL}s" >&2
echo "TEST-ALL: PASS (steps ${FROM}..${TO})" >&2
exit 0
