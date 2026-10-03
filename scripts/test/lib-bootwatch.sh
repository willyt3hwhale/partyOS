#!/usr/bin/env bash
# lib-bootwatch.sh - reusable log-watch with a hard timeout AND a stall detector.
#
# Watch a log for a marker with a hard timeout and a stall detector. The library
# distinguishes FOUR outcomes with distinct exit codes:
#
#   BOOTWATCH_OK (0)          success marker appeared
#   BOOTWATCH_FAILMARKER (1)  the fail-marker appeared -> immediate FAIL
#   BOOTWATCH_TIMEOUT (2)     hard deadline passed (activity or not)
#   BOOTWATCH_STALL (3)       no new bytes AND no mtime change for --stall
#                             seconds - the target is wedged, distinct from a
#                             slow-but-alive boot that just needs more time
#
# It also emits heartbeat lines to stderr (elapsed + last-activity age) at a
# configurable interval, so a watcher can always
# tell "still working" from "dead". Source it; do not execute it directly.

BOOTWATCH_OK=0
BOOTWATCH_FAILMARKER=1
BOOTWATCH_TIMEOUT=2
BOOTWATCH_STALL=3
BOOTWATCH_USAGE=64

# mtime helper, portable across mac (stat -f) and Linux (stat -c).
_bootwatch_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# bootwatch_wait --log FILE --marker STR [options] - watch FILE until a verdict.
#
#   --log FILE         log file to watch (may not exist yet - counts as no activity)
#   --marker STR       success marker (fixed string, grep -F)
#   --fail-marker STR  if this appears, return BOOTWATCH_FAILMARKER immediately
#   --timeout SEC      hard deadline (default 300)
#   --stall SEC        no-new-bytes/no-mtime-change window that means STALL
#                      (default 60; must be shorter than the longest legitimate
#                      silent gap in the log, e.g. a large sfs transfer)
#   --heartbeat SEC    heartbeat interval on stderr (default 15)
#   --interval SEC     poll interval (default 0.5)
#   --from-now         only match log bytes appended AFTER this call starts
#                      (skip stale markers from a previous boot in a shared log)
#   --label STR        prefix for heartbeat/verdict lines (default bootwatch)
bootwatch_wait() {
    local log="" marker="" fail_marker="" timeout=300 stall=60 heartbeat=15
    local interval=0.5 from_now=0 label="bootwatch"
    while [ $# -gt 0 ]; do
        case "$1" in
            --log)         log="$2"; shift 2;;
            --marker)      marker="$2"; shift 2;;
            --fail-marker) fail_marker="$2"; shift 2;;
            --timeout)     timeout="$2"; shift 2;;
            --stall)       stall="$2"; shift 2;;
            --heartbeat)   heartbeat="$2"; shift 2;;
            --interval)    interval="$2"; shift 2;;
            --from-now)    from_now=1; shift;;
            --label)       label="$2"; shift 2;;
            *) echo "bootwatch_wait: unknown arg '$1'" >&2; return "${BOOTWATCH_USAGE}";;
        esac
    done
    if [ -z "${log}" ] || [ -z "${marker}" ]; then
        echo "bootwatch_wait: --log and --marker are required" >&2
        return "${BOOTWATCH_USAGE}"
    fi

    local start now elapsed size mtime offset=0
    start="$(date +%s)"
    local last_size=0 last_mtime=0 last_activity="${start}"
    if [ "${from_now}" -eq 1 ] && [ -f "${log}" ]; then
        offset="$(wc -c < "${log}" | tr -d ' ')"
        last_size="${offset}"
        last_mtime="$(_bootwatch_mtime "${log}")"
    fi
    local next_beat=$(( start + heartbeat ))

    echo "[${label}] watching ${log} for '${marker}' (timeout ${timeout}s, stall ${stall}s)" >&2
    while :; do
        now="$(date +%s)"
        elapsed=$(( now - start ))
        if [ -f "${log}" ]; then
            # Activity = the file grew OR its mtime moved. Either resets the
            # stall clock; neither extends the hard deadline.
            size="$(wc -c < "${log}" | tr -d ' ')"
            mtime="$(_bootwatch_mtime "${log}")"
            if [ "${size}" != "${last_size}" ] || [ "${mtime}" != "${last_mtime}" ]; then
                last_size="${size}"; last_mtime="${mtime}"; last_activity="${now}"
            fi
            # Truncation/rotation guard: if the file shrank below the --from-now
            # offset, the skipped bytes are gone and fresh markers land BELOW
            # the offset - invisible forever. Reset the offset so the rewritten
            # content is watched (the shrink itself already counted as activity).
            if [ "${size}" -lt "${offset}" ]; then
                offset=0
            fi
            # Grep only bytes past the offset so a stale marker from a previous
            # boot in a shared log can never fake a fresh success.
            if [ -n "${fail_marker}" ] && \
               tail -c +$(( offset + 1 )) "${log}" 2>/dev/null | grep -qF -- "${fail_marker}"; then
                echo "[${label}] FAIL-MARKER '${fail_marker}' observed after ${elapsed}s" >&2
                return "${BOOTWATCH_FAILMARKER}"
            fi
            if tail -c +$(( offset + 1 )) "${log}" 2>/dev/null | grep -qF -- "${marker}"; then
                echo "[${label}] OK: marker '${marker}' found after ${elapsed}s" >&2
                return "${BOOTWATCH_OK}"
            fi
        fi
        if [ "${elapsed}" -ge "${timeout}" ]; then
            echo "[${label}] TIMEOUT after ${elapsed}s (last activity $(( now - last_activity ))s ago)" >&2
            return "${BOOTWATCH_TIMEOUT}"
        fi
        if [ $(( now - last_activity )) -ge "${stall}" ]; then
            echo "[${label}] STALL: no log activity for $(( now - last_activity ))s (elapsed ${elapsed}s of ${timeout}s) - target looks wedged, not slow" >&2
            return "${BOOTWATCH_STALL}"
        fi
        if [ "${now}" -ge "${next_beat}" ]; then
            echo "[${label}] heartbeat: elapsed=${elapsed}s last-activity=$(( now - last_activity ))s ago (waiting for '${marker}')" >&2
            next_beat=$(( now + heartbeat ))
        fi
        sleep "${interval}"
    done
}
