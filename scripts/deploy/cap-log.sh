#!/usr/bin/env bash
# cap-log.sh - bound a log file's size by rotating it to <log>.1 when it grows past
# a cap, so a long-running appender can't fill the server disk.
#
# aria2 has no log rotation. Call this only when no process holds the log open.
#
# Usage: cap-log.sh <logfile> [max-bytes]
#   max-bytes defaults to 104857600 (100 MiB). Exit 0 always (a cap is advisory).
set -euo pipefail

LOG="${1:?usage: cap-log.sh <logfile> [max-bytes]}"
MAX="${2:-104857600}"

[ -f "${LOG}" ] || exit 0

# portable byte size: mac `stat -f%z`, GNU `stat -c%s`; anything else -> leave it.
sz="$(stat -f%z "${LOG}" 2>/dev/null || stat -c%s "${LOG}" 2>/dev/null || echo 0)"
case "${sz}" in ''|*[!0-9]*) exit 0;; esac

if [ "${sz}" -gt "${MAX}" ]; then
    mv -f "${LOG}" "${LOG}.1" 2>/dev/null || : > "${LOG}"
    echo "cap-log: rotated ${LOG} (${sz} bytes > ${MAX}) -> ${LOG}.1" >&2
fi
exit 0
