#!/usr/bin/env bash
# show-reports.sh - read the player INBOX (server/reports/).
#
# server/reports/ IS the inbox: each *.json is one entry a player filed from the
# in-session "Report an Issue" tile. The shape varies by opt-in - a plain message
# (nick + message only) or a bug report (also build_id + a journal tail). This is a
# read-only operator convenience; it lists the inbox, or shows one entry in full.
#
#   scripts/deploy/show-reports.sh            # list all reports, newest last
#   scripts/deploy/show-reports.sh <file>     # pretty-print one entry in full
#   make reports                              # = list
#   make reports REPORT=<file>                # = show one
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
RDIR="${REPO_ROOT}/server/reports"

# pull one top-level JSON string field out of a file (best-effort, python preferred).
field() { # file key
    python3 - "$1" "$2" 2>/dev/null <<'PY' || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    v = d.get(sys.argv[2], "")
    print(str(v).replace("\n", " ")[:80])
except Exception:
    pass
PY
}

[ -d "${RDIR}" ] || { echo "no inbox yet (${RDIR} does not exist - no reports filed)"; exit 0; }

# show one entry in full (pretty JSON if python is around, else raw cat).
if [ -n "${1:-}" ]; then
    f="$1"; [ -f "${f}" ] || f="${RDIR}/$1"
    [ -f "${f}" ] || { echo "no such report: $1" >&2; exit 1; }
    echo "=== ${f} ==="
    python3 -m json.tool "${f}" 2>/dev/null || cat "${f}"
    exit 0
fi

# list mode: one line per entry, oldest->newest (filenames sort chronologically).
shopt -s nullglob
files=( "${RDIR}"/*.json )
if [ "${#files[@]}" -eq 0 ]; then
    echo "inbox empty (${RDIR} has no reports)"
    exit 0
fi
echo "player inbox: ${#files[@]} report(s) under ${RDIR}"
printf '%-30s  %-14s  %-4s  %s\n' "FILE" "NICK" "BUG" "MESSAGE"
for f in "${files[@]}"; do
    nick="$(field "${f}" nick)"
    bug="$(field "${f}" is_bug)"
    msg="$(field "${f}" message)"
    # legacy partyos-report-1 fallbacks (category/details), so old entries still read.
    [ -n "${msg}" ] || msg="$(field "${f}" details)"
    [ -n "${nick}" ] || nick="$(field "${f}" hostname)"
    case "${bug}" in true|True|1) bug="yes";; *) bug="-";; esac
    printf '%-30s  %-14s  %-4s  %s\n' "$(basename "${f}")" "${nick:--}" "${bug}" "${msg:--}"
done
