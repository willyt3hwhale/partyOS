#!/usr/bin/env bash
# remote-test.sh - run a harness target on an x86 KVM host.
#
# Edit + commit on the local host. QEMU runs on the KVM host where /dev/kvm gives
# native acceleration (a host without KVM only has slow TCG for x86 guests).
# This script rsyncs the working tree to the KVM host and runs `make <target>` there,
# inside the kvm group, streaming output back.
#
# Usage:  scripts/vm/remote-test.sh <make-target> [VAR=val ...]
# Example: scripts/vm/remote-test.sh test-step2 STEP2_RAM_MB=5120
#
# Env:
#   REMOTE_HOST   ssh host of the KVM machine (required)
#   REMOTE_DIR    path on remote (default: ~/partyOS)
#   REMOTE_TIMEOUT  hard timeout in seconds for the remote make (default: 900)
#   GUEST_RAM_CAP_MB  cap applied to STEP*_RAM_MB if caller did not set one
#                     (default: 5120, for a 7GB host)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOTE_HOST="${REMOTE_HOST:?set REMOTE_HOST to the ssh host of the KVM machine}"
REMOTE_DIR="${REMOTE_DIR:-partyOS}"        # relative to remote $HOME
REMOTE_TIMEOUT="${REMOTE_TIMEOUT:-900}"
GUEST_RAM_CAP_MB="${GUEST_RAM_CAP_MB:-5120}"

TARGET="${1:?usage: remote-test.sh <make-target> [VAR=val ...]}"; shift || true
EXTRA_VARS=("$@")

echo "[remote-test] syncing $REPO_ROOT -> ${REMOTE_HOST}:${REMOTE_DIR}/" >&2
rsync -a --delete \
  --exclude='.git/' --exclude='.DS_Store' --exclude='*.serial' \
  --exclude='*.qmp' --exclude='*.pid' \
  "${REPO_ROOT}/" "${REMOTE_HOST}:${REMOTE_DIR}/"

# Default a RAM cap for the step under test if the caller did not pass one, so
# guests fit in a 7GB host.
step_num="$(printf '%s' "$TARGET" | grep -oE '[0-9]+' | head -1 || true)"
if [ -n "$step_num" ] && ! printf '%s ' "${EXTRA_VARS[@]:-}" | grep -q "STEP${step_num}_RAM_MB="; then
  EXTRA_VARS+=("STEP${step_num}_RAM_MB=${GUEST_RAM_CAP_MB}")
fi

echo "[remote-test] running on ${REMOTE_HOST}: make ${TARGET} ${EXTRA_VARS[*]:-}" >&2
# Run the remote make with ALL of its output (and that of any backgrounded
# child it spawns - http server, qemu, watchdog) redirected to a remote logfile
# and stdin closed. This is what stops ssh from hanging: if the harness leaves a
# daemon briefly alive, that daemon inherits the logfile fd, NOT the ssh channel,
# so ssh returns as soon as `make` exits instead of blocking on the open pipe.
# We then cat the log back (a clean, child-free foreground command) and exit with
# the make's real return code.
REMOTE_LOG="/tmp/remote-test-${TARGET}.log"
ssh "${REMOTE_HOST}" \
  "cd '${REMOTE_DIR}' && { sg kvm -c 'env ${EXTRA_VARS[*]:-} timeout ${REMOTE_TIMEOUT} make ${TARGET}'; echo \"REMOTE_TEST_RC=\$?\"; } >'${REMOTE_LOG}' 2>&1 </dev/null; cat '${REMOTE_LOG}'; grep -q 'REMOTE_TEST_RC=0' '${REMOTE_LOG}'"
