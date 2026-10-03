#!/usr/bin/env bash
# run-servers.sh - launch the partyOS server ROLES per deploy.conf (server-split).
#
# Reads deploy.conf (the ONE file you edit, same plain parse as render.sh - never
# sourced) and starts the server processes for the roles it describes:
#   * NETBOOT / PXE role  - one http_server.py bound to PXE_SERVER (ip:port). Serves
#     the boot image + boot scripts + the /report callback. ONE address.
#   * BLOB role(s)        - one http_server.py per DISTINCT blob server (ip:port) from
#     BLOB_SERVERS (canonical CSV) or the legacy singular BLOB_SERVER. Serves the
#     catalog + game/tool blobs.
#
# http_server.py serves the whole repo root, so EVERY process can serve EVERY file;
# the split is about WHICH listener (ip/port) answers which role, so the per-listener
# access logs show boot vs blob traffic separately and the load spreads across hosts.
#
# Same-host-different-port and different-host both work:
#   * same host, different ports -> this one box runs N processes (PXE + each blob).
#   * different hosts            -> run this helper ON each host; it binds only the
#     ip:port listeners whose IP is local to that host and skips the rest (with a note).
# A single-box deploy.conf (BLOB == PXE) collapses to exactly ONE process (the blob
# listener is identical to the PXE listener, so it is not started twice).
#
# Usage: scripts/deploy/run-servers.sh [deploy.conf]
#   Runs in the foreground; Ctrl-C stops every process it started.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
CONF="${1:-${REPO_ROOT}/deploy.conf}"
HTTPD="${REPO_ROOT}/server/http_server.py"

[ -f "${CONF}" ]  || { echo "run-servers: deploy.conf not found: ${CONF}" >&2; exit 1; }
[ -f "${HTTPD}" ] || { echo "run-servers: http_server.py not found: ${HTTPD}" >&2; exit 1; }

# Boot-artifact guard: a clean rebuild
# that ran `make image` but not `make initramfs` serves a STALE initramfs - no
# bundled CA, no --cacert - and the all-HTTPS copytoram boot fails CLOSED. Refuse
# to start the party server on a stale/insecure served initramfs. HARD-fail by
# default; ALLOW_STALE_INITRAMFS=1 overrides (escape hatch for an intentional
# HTTP-only / dev run). This never touches an already-running server.
CHECK_IR="${SELF_DIR}/check-initramfs.sh"
if [ -f "${CHECK_IR}" ]; then
    if ! bash "${CHECK_IR}"; then
        if [ "${ALLOW_STALE_INITRAMFS:-0}" = "1" ]; then
            echo "[run-servers] WARNING: boot-artifact guard FAILED but ALLOW_STALE_INITRAMFS=1 - starting anyway" >&2
        else
            echo "[run-servers] refusing to start: served boot artifacts failed the guard above." >&2
            echo "[run-servers] fix: \`make image && make initramfs\` (or \`make boot-artifacts\`)." >&2
            echo "[run-servers] override (HTTP-only/dev): ALLOW_STALE_INITRAMFS=1 make servers" >&2
            exit 1
        fi
    fi
fi

# HTTPS dual-serve: http_server.py also opens a TLS listener (default
# :8443) when the gen-ca.sh leaf cert+key are present. Each role's process binds
# HTTPS on the SAME IP, port offset by HTTPS_PORT_OFFSET from its HTTP port (so a
# blob on :8081 gets HTTPS on :8444). HTTP is unchanged either way - a missing
# cert just degrades that process to HTTP-only with a warning.
HTTPS_PORT_OFFSET="${HTTPS_PORT_OFFSET:-363}"   # 8080 -> 8443 by default
TLS_CERT="${REPO_ROOT}/server/tls/partyos.crt"
TLS_KEY="${REPO_ROOT}/server/tls/partyos.key"
if [ -f "${TLS_CERT}" ] && [ -f "${TLS_KEY}" ]; then
    echo "[run-servers] HTTPS enabled (cert: ${TLS_CERT})"
else
    echo "[run-servers] NOTE: ${TLS_CERT} missing - HTTPS listeners will be DISABLED"
    echo "[run-servers]       run scripts/deploy/gen-ca.sh first to enable HTTPS (HTTP still works)"
fi

# Prod default: HTTPS-ONLY. We export PARTYOS_HTTP_DISABLE=1 to each child
# http_server.py so it drops the plaintext :PORT listener and serves TLS only.
# Reversible recovery escape hatch: PARTYOS_HTTP_ENABLE=1 re-enables :8080
# (dual-serve http+https, the old behaviour). If certs are missing the child's
# safety net falls back to HTTP regardless (see the cert note above).
if [ "${PARTYOS_HTTP_ENABLE:-0}" = "1" ]; then
    HTTP_DISABLE=""   # children dual-serve http+https (recovery mode)
    echo "[run-servers] MODE: dual-serve http+https (PARTYOS_HTTP_ENABLE=1) - plaintext :8080 ENABLED"
else
    HTTP_DISABLE="1"  # children serve HTTPS-only (prod default)
    echo "[run-servers] MODE: HTTPS-ONLY (plaintext :8080 disabled) - re-enable http with PARTYOS_HTTP_ENABLE=1"
fi

# Plain KEY=value parse (ignore comments/blanks), same as render.sh. Never sourced.
get() { grep -E "^${1}=" "${CONF}" | tail -1 | cut -d= -f2- | tr -d '[:space:]'; }
PXE_SERVER="$(get PXE_SERVER)"
BLOB_SERVERS="$(get BLOB_SERVERS)"
BLOB_SERVER="$(get BLOB_SERVER)"

[ -n "${PXE_SERVER}" ] || { echo "run-servers: PXE_SERVER is required in ${CONF}" >&2; exit 1; }

# Resolve the ordered blob set (canonical CSV -> legacy singular -> PXE), same
# precedence as render.sh.
BLOB_SET="${BLOB_SERVERS:-${BLOB_SERVER:-${PXE_SERVER}}}"

# _addr_on_iface ADDR -> 0 if the literal ADDR is assigned to a local interface on
# THIS host, 1 otherwise. Portable: Linux `ip -o addr show`, mac/BSD `ifconfig`.
# grep -w so a .10 needle never matches a .100 interface line.
_addr_on_iface() {
    local a="$1"
    [ -n "${a}" ] || return 1
    if command -v ip >/dev/null 2>&1; then
        ip -o addr show 2>/dev/null | grep -qw "${a}" && return 0
    fi
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -qw "${a}" && return 0
    fi
    return 1
}

# resolve_host HOST -> print HOST's IPv4 address(es), one per line (nothing if it
# cannot be resolved). deploy.conf roles may be pinned by HOSTNAME (render.sh/setup.sh
# accept both), so we must resolve before comparing against local interface IPs. This
# runs on the party SERVER which is macOS - there is NO `getent hosts` - so try the
# resolvers macOS actually ships in turn (dig, host, dscacheutil) and fall back to
# python3 (always present here, it runs http_server.py). First to answer wins; each is
# guarded so an absent tool is skipped, and `|| true` keeps a no-match from tripping
# set -e.
resolve_host() {
    local host="$1" out=""
    if command -v dig >/dev/null 2>&1; then
        out="$(dig +short "${host}" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)"
    fi
    if [ -z "${out}" ] && command -v host >/dev/null 2>&1; then
        out="$(host "${host}" 2>/dev/null | awk '/has address/ {print $NF}' || true)"
    fi
    if [ -z "${out}" ] && command -v dscacheutil >/dev/null 2>&1; then
        out="$(dscacheutil -q host -a name "${host}" 2>/dev/null | awk '/^ip_address:/ {print $2}' || true)"
    fi
    if [ -z "${out}" ] && command -v python3 >/dev/null 2>&1; then
        out="$(python3 - "${host}" 2>/dev/null <<'PY' || true
import socket, sys
try:
    print("\n".join(sorted({i[4][0]
        for i in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)})))
except Exception:
    pass
PY
)"
    fi
    printf '%s\n' "${out}"
}

# ip_is_local VALUE -> 0 if VALUE is "" / 0.0.0.0 / localhost, is an IP assigned to a
# local interface, is THIS box's hostname, or is a HOSTNAME that resolves to a local
# interface IP (so we can bind it on THIS host); 1 otherwise. VALUE may be a bare IP
# OR a hostname - render.sh/setup.sh accept both, so a role can be pinned by name.
# Order: cheap literal/interface check, then hostname-equality, then DNS resolution
# (a hostname never appears in raw
# interface output, so the old literal-only grep skipped EVERY hostname-pinned role
# and the server started nothing).
ip_is_local() {
    local ip="$1"
    case "${ip}" in ""|0.0.0.0|127.0.0.1|localhost) return 0;; esac

    # Fast path: a literal IP already assigned to a local interface. Unchanged, so
    # IP-configured roles keep working exactly as before.
    _addr_on_iface "${ip}" && return 0

    # A role pinned to THIS box by NAME should start here: accept the value if it is
    # this host's hostname (plain), short name, or FQDN.
    local hn
    for hn in "$(hostname 2>/dev/null || true)" \
              "$(hostname -s 2>/dev/null || true)" \
              "$(hostname -f 2>/dev/null || true)"; do
        [ -n "${hn}" ] && [ "${ip}" = "${hn}" ] && return 0
    done

    # Configured by HOSTNAME (contains a char that is not an IP digit/dot): resolve it
    # and check whether ANY resolved IP is one of this host's local interface
    # addresses. A bare remote IP has no non-IP char, so it falls straight through to
    # the non-local return below (nothing to resolve). Fail LOUD if a hostname cannot
    # be resolved - a silent skip here is exactly what made the server start nothing.
    case "${ip}" in
        *[!0-9.]*)
            local resolved rip
            resolved="$(resolve_host "${ip}")"
            if [ -z "${resolved}" ]; then
                echo "[run-servers] WARN: could not resolve host '${ip}' to an IP (tried dig/host/dscacheutil/python3) - treating as NON-local; this role will be skipped" >&2
                return 1
            fi
            for rip in ${resolved}; do
                _addr_on_iface "${rip}" && return 0
            done
            ;;
    esac
    return 1
}

declare -a PIDS=()
cleanup() {
    local p
    for p in "${PIDS[@]:-}"; do [ -n "${p}" ] && kill "${p}" 2>/dev/null || true; done
}
trap cleanup INT TERM EXIT

# stop_prior_instances - idempotent restart: cleanly stop any server processes a
# PRIOR run of this script left behind (http_server.py listeners, bt_tracker.py, the
# aria2 seeder) before we bind, so re-running never dies on an already-bound port
# (:8080/:8443 http, :6969 tracker, :6800 aria2 RPC, :6881-6889 BT). Matches only the
# exact command signatures THIS script launches, so it reaps its own processes and
# nothing else. No-op when none are running.
#
# The interpreter part is matched interpreter-agnostically ([Pp]ython[0-9.]*) so the
# same pattern reaps BOTH forms the child can show as argv[0]: the macOS Homebrew
# FRAMEWORK python (/opt/homebrew/.../MacOS/Python -u <script> ...) AND the plain
# Linux/rpi5 form (python3 -u <script> ...). A literal `python3` never appears in the
# macOS argv, so the old `python3 -u ...` pattern matched NOTHING there and the re-run
# hit a port fight instead of a clean restart. The absolute ${HTTPD}/${TRACKER} script
# path after `-u` keeps each pattern specific to our own listener (won't match an
# unrelated python). [...]/* are identical in basic+extended regex, so this is robust
# across BSD/macOS pgrep and Linux procps pgrep.
stop_prior_instances() {
    command -v pkill >/dev/null 2>&1 || {
        echo "[run-servers] NOTE: pkill unavailable - skipping pre-stop of prior instances"; return 0; }
    local killed=0
    pkill -f "[Pp]ython[0-9.]* -u ${HTTPD}"                            2>/dev/null && killed=1 || true
    pkill -f "[Pp]ython[0-9.]* -u ${REPO_ROOT}/server/bt_tracker.py"   2>/dev/null && killed=1 || true
    pkill -f "aria2c .*--log=/tmp/partyos-seeder.log"                  2>/dev/null && killed=1 || true
    if [ "${killed}" -eq 1 ]; then
        echo "[run-servers] pre-stopped prior server instance(s) this script owns (idempotent restart)"
        sleep 1   # brief grace so the OS releases the bound ports before we re-bind
    fi
}

# role_supervisor LABEL CMD ARGS... - run ONE long-lived server process (an
# http_server.py listener or the bt_tracker) under a respawn loop, so its death
# (crash / OOM / a bind failure) can never SILENTLY leave the stack half-up (the same silent-failure class
# that killed the seeder). http_server.py now EXITS NON-ZERO when it cannot bind (an
# HTTPS-only listener that hits an already-bound port no longer exits 0 with zero
# listeners), so a bind collision surfaces HERE as a logged respawn instead of a
# stale process quietly serving OLD artifacts. Backs off between respawns and logs
# each one. Stops cleanly - no respawn, no orphan - on TERM/INT (the parent's
# cleanup kills this subshell with TERM). Mirrors seeder_supervisor().
role_supervisor() {
    local label="$1"; shift
    local cpid="" stop=0 backoff=2 rc=0
    trap 'stop=1; [ -n "${cpid}" ] && kill "${cpid}" 2>/dev/null; exit 0' TERM INT
    trap - EXIT   # don't re-run the parent cleanup() when this subshell exits
    while [ "${stop}" -eq 0 ]; do
        "$@" &
        cpid=$!
        echo "[run-servers] ${label} (supervised) -> pid ${cpid}" >&2
        if wait "${cpid}"; then rc=0; else rc=$?; fi
        cpid=""
        [ "${stop}" -eq 1 ] && break
        echo "[run-servers] ${label} exited rc=${rc}, respawning in ${backoff}s" >&2
        sleep "${backoff}" & wait "$!" 2>/dev/null || true
    done
}

# start_role LABEL IP PORT - launch one http_server.py bound to IP:PORT (IP may be
# "" = all interfaces) UNDER role_supervisor (respawns on death/bind failure).
# Records the supervisor pid and prints the role->URL mapping. Skips (with a note)
# when the IP is not local to this host - run the helper there instead.
start_role() {
    local label="$1" ip="$2" port="$3"
    if ! ip_is_local "${ip}"; then
        echo "[run-servers] SKIP ${label} ${ip}:${port} (IP not local to this host - run run-servers.sh on ${ip})"
        return 0
    fi
    # Derive this role's HTTPS port from its HTTP port (default 8080->8443). Each
    # process serves HTTP on ${port} and, if the cert exists, HTTPS on ${hport}.
    local hport=$(( port + HTTPS_PORT_OFFSET ))
    # HTTP_DISABLE (computed above) flips the child to HTTPS-only by default;
    # PARTYOS_HTTP_ENABLE=1 leaves it empty so the child dual-serves http+https.
    # Supervised: if the listener dies OR fails to bind (http_server.py now exits
    # non-zero on a bind collision instead of silently leaving zero listeners),
    # role_supervisor logs it and respawns with backoff. `env` carries the
    # PARTYOS_HTTP_DISABLE setting through to the child (the exec'd process is still
    # `<python> -u ${HTTPD} ...`, so stop_prior_instances' interpreter-agnostic pkill
    # signature `[Pp]ython[0-9.]* -u ${HTTPD}` matches it on both macOS and Linux).
    role_supervisor "${label} ${ip}:${hport}" \
        env PARTYOS_HTTP_DISABLE="${HTTP_DISABLE}" python3 -u "${HTTPD}" "${port}" "${ip}" "${hport}" &
    local pid=$!
    PIDS+=("${pid}")
    if [ -f "${TLS_CERT}" ] && [ -f "${TLS_KEY}" ]; then
        if [ -n "${HTTP_DISABLE}" ]; then
            echo "[run-servers] ${label} -> https://${ip}:${hport}  (HTTPS-only, plaintext :${port} disabled)  (pid ${pid})"
        else
            echo "[run-servers] ${label} -> http://${ip}:${port}  https://${ip}:${hport}  (pid ${pid})"
        fi
    else
        # No cert: child safety net serves HTTP regardless of HTTP_DISABLE.
        echo "[run-servers] ${label} -> http://${ip}:${port}  (https disabled - no cert)  (pid ${pid})"
    fi
}

# split host:port into IP + PORT (default port 8080 if none given).
hp_ip()   { printf '%s' "${1%%:*}"; }
hp_port() { case "$1" in *:*) printf '%s' "${1##*:}";; *) printf '%s' "8080";; esac; }

echo "[run-servers] deploy.conf: ${CONF}"

# Idempotent restart: stop any prior instances this script owns before binding, so a
# re-run never dies on an already-bound port. Safe no-op when nothing prior is running.
stop_prior_instances

# --- netboot / PXE role -------------------------------------------------------
PXE_IP="$(hp_ip "${PXE_SERVER}")"; PXE_PORT="$(hp_port "${PXE_SERVER}")"
start_role "NETBOOT/PXE" "${PXE_IP}" "${PXE_PORT}"

# --- blob role(s) -------------------------------------------------------------
# One process per DISTINCT blob ip:port. A blob listener identical to the PXE
# listener is NOT started twice (single-box deploy collapses to one process).
declare -a SEEN=("${PXE_IP}:${PXE_PORT}")
n=0
_oldifs="${IFS}"; IFS=','
for bs in ${BLOB_SET}; do
    bs="$(printf '%s' "${bs}" | tr -d '[:space:]')"
    [ -n "${bs}" ] || continue
    bip="$(hp_ip "${bs}")"; bport="$(hp_port "${bs}")"
    key="${bip}:${bport}"
    dup=0
    for s in "${SEEN[@]}"; do [ "${s}" = "${key}" ] && { dup=1; break; }; done
    if [ "${dup}" -eq 1 ]; then
        echo "[run-servers] BLOB ${key} already served by an earlier listener (not started twice)"
        continue
    fi
    SEEN+=("${key}")
    n=$((n+1))
    start_role "BLOB-${n}" "${bip}" "${bport}"
done
IFS="${_oldifs}"

if [ "${#PIDS[@]}" -eq 0 ]; then
    echo "[run-servers] nothing to start on this host (all roles bind non-local IPs)" >&2
    exit 1
fi

# seeder_supervisor - run the persistent aria2 blob seeder under a respawn loop so
# a seeder death (crash / OOM / graceful teardown) can never SILENTLY stop P2P blob
# distribution. partyOS is P2P-ONLY, so a
# dead seeder = zero downloads. Rebuilds the seed list each (re)launch (via
# list-seed-torrents.sh) so a blob added mid-party is picked up on the next respawn,
# backs off between respawns, and logs each one. Stops cleanly - no respawn, no
# orphaned aria2c - on TERM/INT (the parent's cleanup kills this subshell with TERM).
seeder_supervisor() {
    local apid="" stop=0 backoff=2 rc=0
    trap 'stop=1; [ -n "${apid}" ] && kill "${apid}" 2>/dev/null; exit 0' TERM INT
    trap - EXIT   # don't re-run the parent cleanup() when this subshell exits
    while [ "${stop}" -eq 0 ]; do
        local torrents=()
        while IFS= read -r _t; do [ -n "${_t}" ] && torrents+=("${_t}"); done \
            < <(bash "${LIST_SEED}" "${GAMES_DIR}" 2>/dev/null)
        if [ "${#torrents[@]}" -eq 0 ]; then
            echo "[run-servers] SEEDER: no backed torrent(s) right now - retry in ${backoff}s" >&2
            sleep "${backoff}" & wait "$!" 2>/dev/null || true
            continue
        fi
        # Cap the seeder log before (re)launch so a multi-hour party can't fill the
        # disk. Safe here: the prior aria2c has
        # exited, so nothing holds the log fd open; cap-log.sh rotates to <log>.1 past
        # the cap. This is the backstop; --log-level=notice below is the primary cut.
        bash "${CAP_LOG}" "${SEEDER_LOG}" "${SEEDER_LOG_MAX_BYTES}" 2>/dev/null || true
        # Flags are load-bearing (see the seed-forever P2P contract): --seed-ratio=0.0
        # + --bt-detach-seed-only + --max-concurrent-downloads let ALL blobs seed at
        # once; --bt-external-ip advertises the reachable LAN IP; --check-integrity
        # revalidates the data each launch. --console-log-level sets the console
        # (stderr) verbosity; --log-level sets the FILE (--log) verbosity - a SEPARATE
        # knob that defaults to DEBUG when unset. Both pinned to notice so the file log
        # does not record every BT choke round / peer message (700MB+ disk-fill).
        aria2c --enable-dht=false --bt-enable-lpd=true --enable-peer-exchange=true \
            --seed-ratio=0.0 --check-integrity=true --bt-external-ip=${BLOB_FIRST_IP} \
            --max-concurrent-downloads=64 --bt-detach-seed-only=true \
            --listen-port=6881-6889 --console-log-level=notice --log-level=notice \
            --summary-interval=120 \
            --enable-rpc --rpc-listen-all=false --rpc-secret=partyos \
            --log="${SEEDER_LOG}" \
            -d "${GAMES_DIR}" "${torrents[@]}" &
        apid=$!
        echo "[run-servers] SEEDER (supervised) -> seeding ${#torrents[@]} blob torrent(s), pid ${apid} (log /tmp/partyos-seeder.log)" >&2
        if wait "${apid}"; then rc=0; else rc=$?; fi
        apid=""
        [ "${stop}" -eq 1 ] && break
        echo "[run-servers] SEEDER exited rc=${rc}, respawning in ${backoff}s" >&2
        sleep "${backoff}" & wait "$!" 2>/dev/null || true
    done
}

# --- P2P blob distribution: tracker + server seed -----------------------------
# Blobs are distributed BitTorrent P2P ONLY (no HTTP download path). On the host
# that owns the blob/LAN IP we run TWO extra processes, both covered by the trap
# cleanup above (their PIDs go into PIDS):
#   * TRACKER - a lightweight unicast BitTorrent tracker (server/bt_tracker.py) on
#     :6969, so clients discover peers switch-independently (LSD multicast dies on
#     some managed switches). The torrents' baked announce= URL points here.
#   * SEEDER  - a persistent aria2 seed of every blob, forever, announcing to the
#     tracker (baked into each torrent) AND advertising the reachable LAN IP via
#     --bt-external-ip so peers/tracker learn the LAN IP of the server, not a container/NAT IP.
TRACKER="${REPO_ROOT}/server/bt_tracker.py"
LIST_SEED="${SELF_DIR}/list-seed-torrents.sh"
GAMES_DIR="${REPO_ROOT}/server/games"
# Seeder log + its disk-fill guard. aria2 has no
# built-in rotation, so cap-log.sh rotates the log to <log>.1 past the cap on each
# (re)launch (see seeder_supervisor). Override the cap with SEEDER_LOG_MAX_BYTES.
CAP_LOG="${SELF_DIR}/cap-log.sh"
SEEDER_LOG="/tmp/partyos-seeder.log"
SEEDER_LOG_MAX_BYTES="${SEEDER_LOG_MAX_BYTES:-104857600}"   # 100 MiB
BLOB_FIRST_IP="$(hp_ip "${BLOB_SET%%,*}")"
# If the blob server is a DNS name, use its IP here. aria2c --bt-external-ip needs an IP.
# If the name does not resolve, keep it: ip_is_local below then warns and skips.
case "${BLOB_FIRST_IP}" in
    *[!0-9.]*) _rip="$(resolve_host "${BLOB_FIRST_IP}" | head -1)"
               [ -n "${_rip}" ] && BLOB_FIRST_IP="${_rip}";;
esac
if ip_is_local "${BLOB_FIRST_IP}"; then
    if [ -f "${TRACKER}" ]; then
        # Supervised: the tracker is the ONLY switch-independent peer-discovery path
        # (P2P-only blobs), so its silent death would stop all blob downloads. If it
        # dies or fails to bind :6969, role_supervisor logs it and respawns.
        role_supervisor "TRACKER ${BLOB_FIRST_IP}:6969" \
            python3 -u "${TRACKER}" 6969 "${BLOB_FIRST_IP}" &
        tpid=$!
        PIDS+=("${tpid}")
        echo "[run-servers] TRACKER -> http://${BLOB_FIRST_IP}:6969/announce  (supervised, pid ${tpid})"
    else
        echo "[run-servers] NOTE: ${TRACKER} missing - P2P tracker DISABLED"
    fi
    # Seed only REAL blobs: list-seed-torrents.sh returns only *.torrent that have
    # a backing data blob, so orphan hash-named torrents (no *.squashfs behind them)
    # are never handed to aria2c as failed/leech entries.
    declare -a SEED_TORRENTS=()
    if [ -f "${LIST_SEED}" ]; then
        while IFS= read -r _t; do [ -n "${_t}" ] && SEED_TORRENTS+=("${_t}"); done \
            < <(bash "${LIST_SEED}" "${GAMES_DIR}")
    fi
    if [ "${#SEED_TORRENTS[@]}" -gt 0 ]; then
        # Supervised launch: if the seeder dies it is respawned.
        # The supervisor rebuilds its own seed list
        # per (re)launch, so it stays authoritative even as blobs are added.
        seeder_supervisor &
        spid=$!
        PIDS+=("${spid}")
        echo "[run-servers] SEEDER -> supervising seed of ${#SEED_TORRENTS[@]} blob torrent(s) (respawns on exit, external-ip ${BLOB_FIRST_IP}, log /tmp/partyos-seeder.log)  (pid ${spid})"
    else
        echo "[run-servers] SEEDER skipped (no backed server/games/*.torrent present)"
    fi
fi

echo "[run-servers] started ${#PIDS[@]} process(es); Ctrl-C to stop all."
wait
