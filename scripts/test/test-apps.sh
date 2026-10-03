#!/usr/bin/env bash
# test-apps.sh - automated launch harness for EVERY partyOS app/game/tool.
#
# Launch every non-hidden catalog entry through the real client path, and record whether it starts.
#
# RUNS ON A BOOTED partyOS CLIENT (a test box), as root, with a live X
# session for the desktop player. It is NOT a hardware-free unit test - it launches
# real games. Do a --dry-run first (enumeration only, no launches, works anywhere).
#
# Launch dispatch mirrors the desktop exactly (partyos-app / partyos-launch):
#   source=blob -> partyos-app install <id> ; partyos-app launch <id>
#                  (cmd_launch runs the blob entry bin/run.sh under the player's X;
#                   proton blobs go through bwrap+wine, native blobs run directly)
#   source=pkg  -> partyos-launch <name>
#                  (partyos-app launch is BLOB-ONLY; pkg apps install from the LAN
#                   mirror and exec their `exec` via partyos-launch - the same path a
#                   desktop icon click takes)
#
# Liveness is judged by MULTIPLE signals so "runs but renders wrong" is still caught:
#   (i)   the app process is up          (bracket-trick pgrep, never self-matches)
#   (ii)  an X window appeared           (wmctrl / xdotool / GTK window-stack count grew)
#   (iii) the launch log shows a marker  (catalog `marker`, e.g. PARTYOS-BLOB-RUN flatout2)
# Result per app: PASS (proc up + window) / WARN (proc up, no window / suspicious log) /
# FAIL-NOSTART (no proc, no window) / FAIL-INSTALL / SKIP-*.
#
# Output under a timestamped dir: per-app <id>.log + <id>.png, a machine-readable
# summary.json and a human summary.md table, plus a final PASS/FAIL/WARN tally.
#
# Sequential ONLY: two concurrent blob installs can freeze the box, and you cannot run a
# dozen games at once. A separate, OFF-BY-DEFAULT --concurrent-test mode deliberately
# races two installs to reproduce that freeze (it CAN wedge the box).
#
# Usage:
#   test-apps.sh --dry-run                       # enumerate only, print the plan
#   test-apps.sh --user alice                 # test ALL non-hidden entries
#   test-apps.sh --user alice --category games
#   test-apps.sh --user alice --only flatout2,xonotic
#   test-apps.sh --user alice --skip haloce,wc3 --timeout 45
#   test-apps.sh --user alice --concurrent-test flatout2,haloce   # DANGER, reproduces freeze
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." 2>/dev/null && pwd || echo "${SELF_DIR}")"

# --- defaults ---------------------------------------------------------------
PLAYER=""                       # desktop player user (auto-resolved if empty)
XDISPLAY=":0"
PER_TIMEOUT=35                  # seconds to wait for an app to come up
WALL_CLOCK=0                    # overall cap in seconds (0 = off)
CATALOG=""                      # override; else repo/runtime auto-resolve
RESULTS_BASE="${SELF_DIR}/results"
STAMP=""                        # results subdir name (default: date on the client)
ONLY=""                         # comma list of ids/names to test
SKIP=""                         # comma list of ids/names to skip
KLASS_FILTER=""                 # games|tools|apps
CLEAN_RUNCACHE=0                # rm /dev/shm/partyos-runcache/<id> after each app
SKIP_NEEDS_SERVER=0             # skip needs_server entries outright
NO_INSTALL=0                    # skip the blob install step (assume already cached)
INCLUDE_HIDDEN=0               # include hidden catalog rows (wc3, protonenv)
SERVER_PROBE=""                 # host[:port] to probe for needs_server reachability
DRY_RUN=0
CONCURRENT_TEST=""              # "id1,id2" -> run the danger mode instead of the suite

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- arg parse --------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)             PLAYER="$2"; shift 2;;
        --display)          XDISPLAY="$2"; shift 2;;
        --timeout)          PER_TIMEOUT="$2"; shift 2;;
        --wall-clock)       WALL_CLOCK="$2"; shift 2;;
        --catalog)          CATALOG="$2"; shift 2;;
        --results)          RESULTS_BASE="$2"; shift 2;;
        --stamp)            STAMP="$2"; shift 2;;
        --only)             ONLY="$2"; shift 2;;
        --skip)             SKIP="$2"; shift 2;;
        --category)         KLASS_FILTER="$2"; shift 2;;
        --clean-runcache)   CLEAN_RUNCACHE=1; shift;;
        --skip-needs-server) SKIP_NEEDS_SERVER=1; shift;;
        --no-install)       NO_INSTALL=1; shift;;
        --include-hidden)   INCLUDE_HIDDEN=1; shift;;
        --server-probe)     SERVER_PROBE="$2"; shift 2;;
        --dry-run)          DRY_RUN=1; shift;;
        --concurrent-test)  CONCURRENT_TEST="${2:-}"; shift 2 2>/dev/null || shift;;
        -h|--help)          usage; exit 0;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 2;;
    esac
done

# --- logging ----------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date +%H:%M:%S 2>/dev/null || echo '--:--:--')" "$*"; }

# --- catalog resolution -----------------------------------------------------
# Priority: --catalog -> repo copy (dry-run on the build host) -> runtime fetched copy on a
# booted client -> force a fetch via `partyos-app list`. On the client the repo is
# not present (RAM boot); partyos-app fetches the live catalog to XDG_RUNTIME_DIR.
resolve_catalog() {
    if [ -n "${CATALOG}" ]; then [ -s "${CATALOG}" ] && return 0
        log "ERROR: --catalog ${CATALOG} missing/empty"; return 1; fi
    local c
    for c in "${REPO_ROOT}/server/games/catalog.json" \
             "${REPO_ROOT}/server/games/catalog.v2.json"; do
        [ -s "${c}" ] && { CATALOG="${c}"; return 0; }
    done
    # runtime fetched copies (booted client)
    local uid=""; [ -n "${PLAYER}" ] && uid="$(id -u "${PLAYER}" 2>/dev/null || true)"
    for c in "/run/user/${uid}/partyos-app-catalog.json" \
             "/run/user/${uid}/partyos-launch-catalog.json" \
             "/tmp/partyos-app-catalog.json"; do
        [ -n "${uid}" ] || continue
        [ -s "${c}" ] && { CATALOG="${c}"; return 0; }
    done
    # force a fetch as the player, then re-check
    if command -v partyos-app >/dev/null 2>&1 && [ -n "${PLAYER}" ]; then
        log "no local catalog; forcing a fetch via 'partyos-app list'..."
        run_as_player partyos-app list >/dev/null 2>&1 || true
        for c in "/run/user/${uid}/partyos-app-catalog.json" "/tmp/partyos-app-catalog.json"; do
            [ -s "${c}" ] && { CATALOG="${c}"; return 0; }
        done
    fi
    log "ERROR: could not locate a catalog (tried repo, runtime, live fetch)"
    return 1
}

# --- enumeration (python3, no jq - matches the test-suite convention) --------
# Emits one record per catalog row, fields separated by the unit separator (0x1f):
#   id name title source category klass entry marker exe_rel exec pkg pkgs proton needs_server hidden procpats
# A NON-whitespace separator is required: bash `read` with IFS=$'\t' collapses
# consecutive tabs (tab is IFS-whitespace), which would desync rows that have empty
# fields. partyos-app's own load_catalog uses 0x1f for the same reason.
# klass = games|tools|apps. procpats = comma-separated candidate process names for the
# bracket-trick liveness check.
enumerate() {
    INCLUDE_HIDDEN="${INCLUDE_HIDDEN}" python3 - "${CATALOG}" <<'PY'
import json, os, sys
cat = json.load(open(sys.argv[1]))
inc_hidden = os.environ.get("INCLUDE_HIDDEN", "0") == "1"
rows = cat.get("games", []) if isinstance(cat, dict) else []
STOP = {"", "bash", "sh", "env", "sudo", "xterm", "java", "python3", "python"}
def klass(c):
    c = (c or "").lower()
    if c == "game": return "games"
    if c == "tool": return "tools"
    return "apps"
def procpats(row):
    cands = []
    exe_rel = row.get("exe_rel", "") or ""
    if exe_rel:
        cands.append(os.path.basename(exe_rel))
    exec_s = row.get("exec", "") or row.get("exe", "") or ""
    if exec_s:
        parts = exec_s.split()
        if "-e" in parts:
            i = parts.index("-e")
            if i + 1 < len(parts):
                cands.append(os.path.basename(parts[i + 1]))
        elif parts:
            cands.append(os.path.basename(parts[0]))
    pkg = row.get("pkg", "") or ""
    if pkg:
        cands.append(pkg)
    cands.append(row.get("name", "") or "")
    seen = []
    for c in cands:
        c = c.strip()
        if c and c.lower() not in STOP and c not in seen:
            seen.append(c)
    return ",".join(seen)
def clean(v):
    return str(v).replace("\x1f", " ").replace("\t", " ").replace("\n", " ").strip()
for row in rows:
    if not isinstance(row, dict):
        continue
    name = row.get("name", "")
    if not name:
        continue
    hidden = bool(row.get("hidden", False))
    if hidden and not inc_hidden:
        continue
    fields = [
        row.get("id", ""), name, row.get("title", ""),
        row.get("source", "blob") or "blob", row.get("category", ""),
        klass(row.get("category", "")), row.get("entry", "bin/run.sh") or "bin/run.sh",
        row.get("marker", ""), row.get("exe_rel", ""), row.get("exec", "") or row.get("exe", ""),
        row.get("pkg", ""), row.get("pkgs", ""),
        "1" if row.get("proton") else "0",
        "1" if row.get("needs_server") else "0",
        "1" if hidden else "0", procpats(row),
    ]
    print("\x1f".join(clean(f) for f in fields))
PY
}

# in-list helper: is $1 present in comma list $2 (matches id or bare name)
in_csv() {
    local needle="$1" list="$2" item
    IFS=',' read -r -a _arr <<< "${list}"
    for item in "${_arr[@]}"; do
        [ -n "${item}" ] || continue
        [ "${item}" = "${needle}" ] && return 0
    done
    return 1
}

# --- print the enumeration plan, grouped by class (used by --dry-run) -------
print_plan() {
    local total=0
    local -a games=() tools=() apps=() hiddenrows=()
    while IFS=$'\x1f' read -r id name title source category klass entry marker exe_rel execf pkg pkgs proton needs hidden procpats; do
        [ -n "${name}" ] || continue
        # honour the same filters the real run applies, so the plan is what it WOULD test
        if [ -n "${KLASS_FILTER}" ] && [ "${klass}" != "${KLASS_FILTER}" ]; then continue; fi
        if [ -n "${ONLY}" ] && ! in_csv "${id}" "${ONLY}" && ! in_csv "${name}" "${ONLY}"; then continue; fi
        if in_csv "${id}" "${SKIP}" || in_csv "${name}" "${SKIP}"; then continue; fi
        local tag=""
        [ "${source}" = "blob" ] && tag="blob" || tag="pkg"
        [ "${proton}" = "1" ] && tag="${tag},proton"
        [ "${needs}" = "1" ] && tag="${tag},needs-server"
        [ "${hidden}" = "1" ] && tag="${tag},hidden"
        local line="$(printf '  %-22s %-26s [%s]' "${name}" "${id}" "${tag}")"
        case "${klass}" in
            games) games+=("${line}");;
            tools) tools+=("${line}");;
            *)     apps+=("${line}");;
        esac
        [ "${hidden}" = "1" ] && hiddenrows+=("${name}")
        total=$((total+1))
    done < <(enumerate)

    echo "==== partyOS app/game launch plan (catalog: ${CATALOG}) ===="
    echo
    echo "GAMES (${#games[@]}):"
    printf '%s\n' "${games[@]}"
    echo
    echo "TOOLS (${#tools[@]}):"
    printf '%s\n' "${tools[@]}"
    echo
    echo "APPS (${#apps[@]}):"
    printf '%s\n' "${apps[@]}"
    echo
    echo "TOTAL entries to test: ${total}"
    [ "${#hiddenrows[@]}" -gt 0 ] && echo "(hidden rows included: ${hiddenrows[*]})"
}

# --- run something as the desktop player with its X session -----------------
run_as_player() {
    sudo -u "${PLAYER}" env \
        DISPLAY="${XDISPLAY}" \
        XAUTHORITY="${XAUTH}" \
        XDG_RUNTIME_DIR="${XRUN}" \
        PARTYOS_DISPLAY="${XDISPLAY}" \
        PARTYOS_XAUTHORITY="${XAUTH}" \
        PARTYOS_XDG_RUNTIME_DIR="${XRUN}" \
        "$@"
}

# --- window count as the player (wmctrl -> xdotool -> GTK window-stack) ------
detect_win_tool() {
    WIN_TOOL="gtk"
    if run_as_player bash -c 'command -v wmctrl >/dev/null 2>&1'; then WIN_TOOL="wmctrl"
    elif run_as_player bash -c 'command -v xdotool >/dev/null 2>&1'; then WIN_TOOL="xdotool"; fi
    log "window tool: ${WIN_TOOL}"
}
window_count() {
    case "${WIN_TOOL}" in
        wmctrl)  run_as_player wmctrl -l 2>/dev/null | grep -c . ;;
        xdotool) run_as_player xdotool search --onlyvisible --name '' 2>/dev/null | grep -c . ;;
        *)       run_as_player python3 - <<'PY'
import gi
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk
s = Gdk.Screen.get_default()
print(len(s.get_window_stack() or []) if s else 0)
PY
            ;;
    esac
}

# --- screenshot of the X root as the player (GTK pixbuf; slim image has no scrot) ---
screenshot() {
    local out="$1"
    run_as_player python3 - "${out}" <<'PY' 2>/dev/null || true
import sys
import gi
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk
w = Gdk.get_default_root_window()
pb = Gdk.pixbuf_get_from_window(w, 0, 0, w.get_width(), w.get_height())
if pb is not None:
    pb.savev(sys.argv[1], "png", [], [])
PY
}

# --- is any of the comma-separated process patterns running? (bracket trick) ---
proc_up() {
    local pats="$1" pat first rest
    IFS=',' read -r -a _p <<< "${pats}"
    for pat in "${_p[@]}"; do
        [ -n "${pat}" ] || continue
        first="${pat:0:1}"; rest="${pat:1}"
        # [x]yz never matches the pgrep command line itself
        if pgrep -f "[${first}]${rest}" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

# --- kill an app's whole process tree (bracket trick), clean its runcache ----
kill_app() {
    local launch_pid="$1" pats="$2" id="$3" pat first rest
    if [ -n "${launch_pid}" ] && kill -0 "${launch_pid}" 2>/dev/null; then
        pkill -TERM -P "${launch_pid}" 2>/dev/null || true
        kill -TERM "${launch_pid}" 2>/dev/null || true
    fi
    IFS=',' read -r -a _p <<< "${pats}"
    for pat in "${_p[@]}"; do
        [ -n "${pat}" ] || continue
        first="${pat:0:1}"; rest="${pat:1}"
        pkill -TERM -f "[${first}]${rest}" 2>/dev/null || true
    done
    # give them a moment, then hard-kill stragglers (bwrap/wine can be stubborn)
    sleep 2
    if [ -n "${launch_pid}" ] && kill -0 "${launch_pid}" 2>/dev/null; then
        pkill -KILL -P "${launch_pid}" 2>/dev/null || true
        kill -KILL "${launch_pid}" 2>/dev/null || true
    fi
    for pat in "${_p[@]}"; do
        [ -n "${pat}" ] || continue
        first="${pat:0:1}"; rest="${pat:1}"
        pkill -KILL -f "[${first}]${rest}" 2>/dev/null || true
    done
    if [ "${CLEAN_RUNCACHE}" -eq 1 ]; then
        rm -rf "/dev/shm/partyos-runcache/${id}" 2>/dev/null || true
        # also the bare-name variant, and the per-game run scratch
        rm -rf "/dev/shm/partyos-runcache/${id#partyos.}" 2>/dev/null || true
    fi
}

# --- server reachability probe (for needs_server entries) -------------------
server_reachable() {
    [ -n "${SERVER_PROBE}" ] || return 0   # no probe requested -> assume reachable
    local host="${SERVER_PROBE%%:*}" port="${SERVER_PROBE##*:}"
    [ "${host}" = "${port}" ] && port=""
    if [ -n "${port}" ]; then
        (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null && return 0 || return 1
    fi
    ping -c1 -W2 "${host}" >/dev/null 2>&1
}

# --- state for the cleanup trap ---------------------------------------------
CUR_ID=""; CUR_PROCPATS=""; CUR_LAUNCH_PID=""
RUN_DIR=""
cleanup() {
    local rc=$?
    if [ -n "${CUR_ID}" ]; then
        log "cleanup: tearing down '${CUR_ID}'"
        kill_app "${CUR_LAUNCH_PID}" "${CUR_PROCPATS}" "${CUR_ID}"
    fi
    exit "${rc}"
}

# =====================  DRY RUN: enumerate + print, then stop  ===============
# Dry-run needs only the repo catalog (no player, no X, runs anywhere).
if [ "${DRY_RUN}" -eq 1 ]; then
    resolve_catalog || exit 1
    print_plan
    exit 0
fi

# ==================  everything below needs a booted client  ================
[ "$(id -u)" -eq 0 ] || { log "ERROR: must run as root on the client"; exit 1; }

# --- resolve the desktop player (mirror partyos-app: /run/partyos-username,
#     else an active graphical session, else uid 1000, else 'gamer') ---------
resolve_player() {
    [ -n "${PLAYER}" ] && { id "${PLAYER}" >/dev/null 2>&1 && return 0
        log "ERROR: --user ${PLAYER} does not exist"; return 1; }
    if [ -r /run/partyos-username ]; then
        PLAYER="$(tr -d '[:space:]' < /run/partyos-username)"
        id "${PLAYER}" >/dev/null 2>&1 && return 0
    fi
    # an active seat/graphical session
    if command -v loginctl >/dev/null 2>&1; then
        local u
        u="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v '^root$' | head -1)"
        [ -n "${u}" ] && id "${u}" >/dev/null 2>&1 && { PLAYER="${u}"; return 0; }
    fi
    # whoever owns the :0 X session
    local u; u="$(who 2>/dev/null | awk '/\(:0\)/{print $1; exit}')"
    [ -n "${u}" ] && id "${u}" >/dev/null 2>&1 && { PLAYER="${u}"; return 0; }
    # uid 1000, else gamer
    u="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
    [ -n "${u}" ] && { PLAYER="${u}"; return 0; }
    id gamer >/dev/null 2>&1 && { PLAYER="gamer"; return 0; }
    log "ERROR: could not resolve a desktop player (pass --user)"; return 1
}
resolve_player || exit 1

PLAYER_UID="$(id -u "${PLAYER}")"
PLAYER_HOME="$(getent passwd "${PLAYER}" 2>/dev/null | cut -d: -f6)"; [ -n "${PLAYER_HOME}" ] || PLAYER_HOME="/home/${PLAYER}"
XAUTH="${PLAYER_HOME}/.Xauthority"
XRUN="/run/user/${PLAYER_UID}"
log "player=${PLAYER} uid=${PLAYER_UID} home=${PLAYER_HOME} display=${XDISPLAY}"

# now the player + X env are known: resolve the catalog (repo, runtime copy, or a
# live 'partyos-app list' fetch as the player).
resolve_catalog || exit 1
log "catalog: ${CATALOG}"

# results dir
[ -n "${STAMP}" ] || STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
RUN_DIR="${RESULTS_BASE}/${STAMP}"
mkdir -p "${RUN_DIR}"
RESULTS_TSV="${RUN_DIR}/results.tsv"
: > "${RESULTS_TSV}"
log "results -> ${RUN_DIR}"

trap cleanup EXIT INT TERM

detect_win_tool

# --- concurrent-test danger mode (OFF by default) ---------------------------
# Deliberately race TWO blob installs to reproduce the concurrent-mount
# freeze. This CAN wedge the box; only runs when --concurrent-test id1,id2 is given.
if [ -n "${CONCURRENT_TEST}" ]; then
    IFS=',' read -r c1 c2 <<< "${CONCURRENT_TEST}"
    log "!!! CONCURRENT-TEST: racing installs of '${c1}' and '${c2}' - this may FREEZE the box"
    ( run_as_player partyos-app install "${c1}" >"${RUN_DIR}/concurrent-${c1}.log" 2>&1 ) &
    P1=$!
    ( run_as_player partyos-app install "${c2}" >"${RUN_DIR}/concurrent-${c2}.log" 2>&1 ) &
    P2=$!
    log "concurrent installs launched (pids ${P1} ${P2}); waiting up to ${PER_TIMEOUT}s"
    waited=0
    while kill -0 "${P1}" 2>/dev/null || kill -0 "${P2}" 2>/dev/null; do
        sleep 1; waited=$((waited+1))
        [ "${waited}" -ge "${PER_TIMEOUT}" ] && { log "concurrent-test: still running at ${waited}s (possible freeze) - killing"; break; }
    done
    kill -KILL "${P1}" "${P2}" 2>/dev/null || true
    CUR_ID="${c1}"; CUR_PROCPATS=""; kill_app "" "" "${c1}"; kill_app "" "" "${c2}"; CUR_ID=""
    log "concurrent-test done; logs in ${RUN_DIR}/concurrent-*.log"
    trap - EXIT INT TERM
    exit 0
fi

# =========================  the sequential suite  ===========================
SUITE_START="$(date +%s 2>/dev/null || echo 0)"
n_pass=0; n_warn=0; n_fail=0; n_skip=0
declare -a fail_lines=()

test_one() {
    local id="$1" name="$2" title="$3" source="$4" klass="$5" entry="$6" marker="$7" \
          exe_rel="$8" execf="$9" pkg="${10}" pkgs="${11}" proton="${12}" needs="${13}" procpats="${14}"
    local log_file="${RUN_DIR}/${name}.log" shot="${RUN_DIR}/${name}.png"
    local result="" reason="" elapsed=0
    : > "${log_file}"

    CUR_ID="${id}"; CUR_PROCPATS="${procpats}"; CUR_LAUNCH_PID=""

    # skip filters
    if in_csv "${id}" "${SKIP}" || in_csv "${name}" "${SKIP}"; then
        record "${id}" "${name}" "${klass}" "${source}" "SKIP-USER" "0" "skipped via --skip" ""
        n_skip=$((n_skip+1)); CUR_ID=""; return
    fi
    if [ "${needs}" = "1" ]; then
        if [ "${SKIP_NEEDS_SERVER}" -eq 1 ]; then
            record "${id}" "${name}" "${klass}" "${source}" "SKIP-NOSERVER" "0" "needs_server, --skip-needs-server set" ""
            n_skip=$((n_skip+1)); CUR_ID=""; return
        fi
        if [ -n "${SERVER_PROBE}" ] && ! server_reachable; then
            record "${id}" "${name}" "${klass}" "${source}" "SKIP-NOSERVER" "0" "needs_server, ${SERVER_PROBE} unreachable" ""
            n_skip=$((n_skip+1)); CUR_ID=""; return
        fi
    fi

    log "=== [${klass}] ${name} (${id}) source=${source} ==="
    local win_before; win_before="$(window_count)"; win_before="${win_before:-0}"
    local t0; t0="$(date +%s 2>/dev/null || echo 0)"

    # ----- step a: ensure available (blob install; pkg installs at launch) -----
    if [ "${source}" = "blob" ] && [ "${NO_INSTALL}" -eq 0 ]; then
        log "  install ${name}..."
        if ! run_as_player partyos-app install "${id}" >>"${log_file}" 2>&1; then
            reason="$(tail -n 20 "${log_file}" | tr '\n' ' ' | tr '\t' ' ' | cut -c1-300)"
            record "${id}" "${name}" "${klass}" "${source}" "FAIL-INSTALL" "0" "${reason}" ""
            n_fail=$((n_fail+1)); fail_lines+=("${name}: FAIL-INSTALL")
            kill_app "" "${procpats}" "${id}"; CUR_ID=""; return
        fi
    fi

    # ----- step b: launch in the background, capture stdout+stderr -------------
    log "  launch ${name}..."
    if [ "${source}" = "blob" ]; then
        ( run_as_player partyos-app launch "${id}" >>"${log_file}" 2>&1 ) &
    else
        # pkg: partyos-launch installs from the LAN mirror + execs the app
        ( run_as_player partyos-launch "${name}" >>"${log_file}" 2>&1 ) &
    fi
    CUR_LAUNCH_PID=$!

    # ----- step c: bounded wait for liveness -----------------------------------
    local up=0 win_now="${win_before}" waited=0
    while [ "${waited}" -lt "${PER_TIMEOUT}" ]; do
        sleep 2; waited=$((waited+2))
        if proc_up "${procpats}"; then up=1; fi
        win_now="$(window_count)"; win_now="${win_now:-0}"
        # early exit once we clearly have both signals
        if [ "${up}" -eq 1 ] && [ "${win_now}" -gt "${win_before}" ]; then break; fi
        # the backgrounded launch died AND nothing is up -> stop waiting early
        if ! kill -0 "${CUR_LAUNCH_PID}" 2>/dev/null && [ "${up}" -eq 0 ]; then
            # for pkg apps the exec'd app may have replaced the pid; re-check proc
            proc_up "${procpats}" && up=1
            [ "${up}" -eq 0 ] && break
        fi
    done
    local t1; t1="$(date +%s 2>/dev/null || echo 0)"; elapsed=$((t1-t0))

    # ----- step d: screenshot the screen ---------------------------------------
    screenshot "${shot}"
    [ -s "${shot}" ] || shot=""

    # ----- step e: classify -----------------------------------------------------
    local marker_hit=0
    if [ -n "${marker}" ] && grep -qF "${marker}" "${log_file}" 2>/dev/null; then marker_hit=1; fi
    local fatal=""
    fatal="$(grep -iE 'ERROR|not installed|failed|no entry|command not found|cannot open display' "${log_file}" 2>/dev/null | tail -1 | tr '\t' ' ' | cut -c1-200)"

    local win_grew=0; [ "${win_now}" -gt "${win_before}" ] && win_grew=1

    if [ "${up}" -eq 1 ] && [ "${win_grew}" -eq 1 ]; then
        result="PASS"; reason="proc up, window +$((win_now-win_before))${marker_hit:+, marker}"
        [ "${marker_hit}" -eq 1 ] && reason="${reason} (marker matched)"
        n_pass=$((n_pass+1))
    elif [ "${up}" -eq 1 ]; then
        result="WARN"; reason="proc up but NO new window (win ${win_before}->${win_now})"
        [ -n "${fatal}" ] && reason="${reason}; log: ${fatal}"
        n_warn=$((n_warn+1)); fail_lines+=("${name}: WARN (${reason})")
    elif [ "${marker_hit}" -eq 1 ]; then
        result="WARN"; reason="marker matched but no live proc/window (short-lived or self-exited)"
        n_warn=$((n_warn+1)); fail_lines+=("${name}: WARN (${reason})")
    else
        result="FAIL-NOSTART"
        reason="no proc, no new window"
        [ -n "${fatal}" ] && reason="${reason}; log: ${fatal}"
        [ -z "${fatal}" ] && reason="${reason}; last: $(tail -n 3 "${log_file}" | tr '\n' ' ' | tr '\t' ' ' | cut -c1-200)"
        n_fail=$((n_fail+1)); fail_lines+=("${name}: FAIL-NOSTART (${reason})")
    fi

    log "  -> ${result} (${elapsed}s) ${reason}"
    record "${id}" "${name}" "${klass}" "${source}" "${result}" "${elapsed}" "${reason}" "${shot}"

    # ----- step f: cleanup before the next app ---------------------------------
    kill_app "${CUR_LAUNCH_PID}" "${procpats}" "${id}"
    CUR_ID=""; CUR_LAUNCH_PID=""; CUR_PROCPATS=""
}

# append one TSV result row (fields are pre-sanitised of tabs/newlines)
record() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" \
        "$(printf '%s' "$7" | tr '\t\n' '  ')" "$8" >> "${RESULTS_TSV}"
}

# --- main loop --------------------------------------------------------------
while IFS=$'\x1f' read -r id name title source category klass entry marker exe_rel execf pkg pkgs proton needs hidden procpats; do
    [ -n "${name}" ] || continue
    # class filter
    if [ -n "${KLASS_FILTER}" ] && [ "${klass}" != "${KLASS_FILTER}" ]; then continue; fi
    # only filter
    if [ -n "${ONLY}" ] && ! in_csv "${id}" "${ONLY}" && ! in_csv "${name}" "${ONLY}"; then continue; fi
    # wall-clock cap
    if [ "${WALL_CLOCK}" -gt 0 ]; then
        now="$(date +%s 2>/dev/null || echo 0)"
        if [ "$((now-SUITE_START))" -ge "${WALL_CLOCK}" ]; then
            log "wall-clock cap ${WALL_CLOCK}s reached; stopping"
            break
        fi
    fi
    test_one "${id}" "${name}" "${title}" "${source}" "${klass}" "${entry}" "${marker}" \
             "${exe_rel}" "${execf}" "${pkg}" "${pkgs}" "${proton}" "${needs}" "${procpats}"
done < <(enumerate)

# --- write summary.json + summary.md ----------------------------------------
python3 - "${RESULTS_TSV}" "${RUN_DIR}/summary.json" "${RUN_DIR}/summary.md" "${STAMP}" <<'PY'
import json, sys, os
tsv, js, md, stamp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
rows = []
with open(tsv) as f:
    for ln in f:
        ln = ln.rstrip("\n")
        if not ln:
            continue
        p = ln.split("\t")
        while len(p) < 8:
            p.append("")
        rows.append(dict(id=p[0], name=p[1], klass=p[2], source=p[3],
                         result=p[4], elapsed=p[5], reason=p[6], screenshot=p[7]))
tally = {}
for r in rows:
    tally[r["result"]] = tally.get(r["result"], 0) + 1
json.dump({"stamp": stamp, "tally": tally, "results": rows}, open(js, "w"), indent=2)
with open(md, "w") as f:
    f.write("# partyOS app launch report - %s\n\n" % stamp)
    f.write("| id | class | source | result | time-to-up | reason | screenshot |\n")
    f.write("|----|-------|--------|--------|-----------|--------|------------|\n")
    for r in rows:
        shot = os.path.basename(r["screenshot"]) if r["screenshot"] else "-"
        reason = r["reason"].replace("|", "\\|")
        f.write("| %s | %s | %s | %s | %ss | %s | %s |\n" % (
            r["id"], r["klass"], r["source"], r["result"], r["elapsed"], reason, shot))
    f.write("\n## Tally\n\n")
    for k in sorted(tally):
        f.write("- %s: %d\n" % (k, tally[k]))
PY

# --- final tally + FAIL list ------------------------------------------------
echo
echo "==== SUITE COMPLETE (${STAMP}) ===="
echo "  PASS=${n_pass}  WARN=${n_warn}  FAIL=${n_fail}  SKIP=${n_skip}"
if [ "${#fail_lines[@]}" -gt 0 ]; then
    echo "  --- attention ---"
    printf '    %s\n' "${fail_lines[@]}"
fi
echo "  summary: ${RUN_DIR}/summary.md  |  ${RUN_DIR}/summary.json"

trap - EXIT INT TERM
[ "${n_fail}" -eq 0 ]
