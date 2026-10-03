#!/usr/bin/env bash
# prepare-event.sh - interactive setup wizard for one LAN event.
#
# This is the documented way to prepare an event. It implements the decision
# checklist in docs/PREPARE-LAN.md. It runs a pre-flight, asks FIVE questions, prints a
# summary, takes ONE confirmation, and then writes.
#
# PREREQUISITE: a running Docker daemon, plus openssl 3.3+. The apply step calls
# setup.sh, which builds the iPXE EFI in a linux/amd64 container. The pre-flight checks
# both BEFORE the first question, by running setup.sh's own prereq gate under
# --dry-run, so a missing prerequisite can never leave a half-applied event.
#
# The wizard does not reimplement the tools. It calls them:
#   * the server address     -> scripts/deploy/setup.sh (same as `make server-name`)
#   * the boot script/portal -> scripts/deploy/render.sh (offered at the end)
#
# DEFAULTS THE WIZARD DOES NOT ASK ABOUT:
#   * Every stick is provisioned fresh. There is no stick reuse and no keep-home
#     question.
#   * Clients use DHCP. The wizard writes no static IP, gateway or DNS.
#   * The keyboard default is SE and the timezone is Europe/Stockholm. The
#     first-boot wizard still lets a player change the keyboard and set the
#     password.
#   * The venue runs DHCP and DNS, and gives a working DNS name and record. The
#     certificate carries that name, so the wizard asks for no fallback IP.
#   * The client VLAN has no internet. Dedicated game servers and bootloader NIC
#     coverage are out of scope.
#
# The wizard registers no players. Each stick carries the player identity in
# internyet.env on its shared exFAT partition. If your venue provisions the
# sticks, it writes that file. gen-user-config.sh and users/ stay for self-provisioned events only.
#
# The five questions, each with a default that Enter accepts:
#   1. Server address (host[:port]). Default: PXE_SERVER from deploy.conf.
#   2. Blob server address(es). Default: BLOB_SERVERS from deploy.conf, else the
#      main server.
#   3. Package mirror address. Default: MIRROR_SERVER from deploy.conf, else the
#      main server.
#   4. Chat/IRC server address. Default: IRC_SERVER from deploy.conf, else the
#      main server host on port 6667.
#   5. Party name. Default: PARTY_NAME from deploy.conf, else Internyet.
#
# Usage:
#   scripts/deploy/prepare-event.sh                 # interactive
#   scripts/deploy/prepare-event.sh --answers FILE  # replay, no TTY needed
#   scripts/deploy/prepare-event.sh --non-interactive
#
# Flags:
#   --answers FILE        read the answers from FILE (KEY=value). Implies
#                         --non-interactive.
#   --non-interactive     never prompt. Every answer comes from the environment,
#                         the answers file, deploy.conf, or the default.
#   --yes                 same as CONFIRM=yes.
#   --skip-server-name    do not run setup.sh. Write deploy.conf keys only. The
#                         certificate and the EFI then keep the old name.
#   --dry-run             print the plan and write nothing.
#   -h | --help           this help.
#
# Answer keys (answers file, or the environment; the environment wins):
#   SERVER_NAME     host[:port] of the PXE/netboot server.
#   BLOB_SERVERS    comma-separated host[:port] failover list.
#   MIRROR_SERVER   host[:port] of the Arch package mirror.
#   IRC_SERVER      host[:port] of the chat server.
#   PARTY_NAME      the party name.
#   DROP_TITLES     comma-separated catalog names to remove (empty = keep all).
#   ROTATE_CA       yes|no. yes runs setup.sh --fresh and invalidates every
#                   flashed stick. Only offered when a CA already exists.
#   CONFIRM         yes applies the plan. Anything else aborts before writing.
#   RUN_COMMANDS    comma-separated safe follow-up steps to run: render, test.
#                   Empty = run none.
#
# Test/override environment:
#   PARTYOS_DEPLOY_CONF   deploy.conf path       (default <repo>/deploy.conf)
#   PARTYOS_CATALOG       catalog SOURCE path    (default server/games/catalog.v2.json).
#                         The wizard re-renders catalog.json beside it after an edit.
#   PARTYOS_CA_DIR        CA directory           (default <repo>/ca)
#   PARTYOS_SETUP_CMD     the setup.sh to call   (default <repo>/scripts/deploy/setup.sh)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"

CONF="${PARTYOS_DEPLOY_CONF:-${REPO_ROOT}/deploy.conf}"
CATALOG="${PARTYOS_CATALOG:-${REPO_ROOT}/server/games/catalog.v2.json}"
CA_DIR="${PARTYOS_CA_DIR:-${REPO_ROOT}/ca}"
SETUP_CMD="${PARTYOS_SETUP_CMD:-${SELF_DIR}/setup.sh}"
RENDER="${SELF_DIR}/render.sh"

DEFAULT_SERVER="partyos.lan:8080"
DEFAULT_PARTY_NAME="Internyet"

ANSWERS=""
INTERACTIVE=1
DRY_RUN=0
SKIP_SERVER_NAME=0
YES=0

die()  { echo "prepare-event: $*" >&2; exit 1; }
# Where the pre-flight keeps setup.sh's output, so a failure can be read back.
PREFLIGHT_LOG="${PARTYOS_PREFLIGHT_LOG:-${TMPDIR:-/tmp}/partyos-prepare-event-preflight.log}"
say()  { echo "[prepare] $*"; }
sect() { echo; echo "==== $* ===="; }

while [ $# -gt 0 ]; do
    case "$1" in
        --answers)          ANSWERS="${2:-}"; INTERACTIVE=0; shift 2;;
        --answers=*)        ANSWERS="${1#*=}"; INTERACTIVE=0; shift;;
        --non-interactive)  INTERACTIVE=0; shift;;
        --yes|-y)           YES=1; shift;;
        --skip-server-name) SKIP_SERVER_NAME=1; shift;;
        --dry-run)          DRY_RUN=1; shift;;
        -h|--help)          sed -n '2,77p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
        *)                  die "unknown argument '$1' (see --help)";;
    esac
done

[ -z "${ANSWERS}" ] || [ -f "${ANSWERS}" ] || die "answers file not found: ${ANSWERS}"

# ---------------------------------------------------------------------------
# answer resolution: environment, then the answers file, then the fallback
# ---------------------------------------------------------------------------
# conf_get KEY FILE - echo the value of KEY=... The file is parsed, never sourced.
conf_get() {
    [ -f "$2" ] || return 0
    grep -E "^[[:space:]]*$1=" "$2" 2>/dev/null | grep -v '^[[:space:]]*#' \
        | tail -1 | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

# answer_of KEY - echo the value from the environment or the answers file.
answer_of() {
    local key="$1" v=""
    eval "v=\${${key}:-}"
    if [ -n "${v}" ]; then printf '%s' "${v}"; return 0; fi
    [ -n "${ANSWERS}" ] && conf_get "${key}" "${ANSWERS}"
}

# ask KEY PROMPT DEFAULT - echo the answer. The answer source order is the
# environment, the answers file, the prompt, then the default.
ask() {
    local key="$1" prompt="$2" def="$3" v reply
    v="$(answer_of "${key}")"
    if [ -n "${v}" ]; then printf '%s' "${v}"; return 0; fi
    if [ "${INTERACTIVE}" -eq 0 ]; then printf '%s' "${def}"; return 0; fi
    read -r -p "${prompt} [${def}]: " reply </dev/tty
    printf '%s' "${reply:-${def}}"
}

# ---------------------------------------------------------------------------
# address helpers (same permissive rules as setup.sh)
# ---------------------------------------------------------------------------
looks_like_hostport() {
    local hp="$1" host port
    [ -n "${hp}" ] || return 1
    case "${hp}" in
        *:*) host="${hp%:*}"; port="${hp##*:}";;
        *)   host="${hp}";    port="";;
    esac
    [ -n "${host}" ] || return 1
    [ -z "${port}" ] || case "${port}" in ''|*[!0-9]*) return 1;; esac
    case "${host}" in
        *[!0-9.]*) case "${host}" in *[!A-Za-z0-9.-]*) return 1;; *) return 0;; esac;;
        *.*.*.*)   return 0;;
        *)         case "${host}" in *[!A-Za-z0-9-]*) return 1;; *) return 0;; esac;;
    esac
}
with_port() { case "$1" in *:*) printf '%s' "$1";; *) printf '%s:%s' "$1" "$2";; esac; }
host_of()   { printf '%s' "${1%%:*}"; }

# ---------------------------------------------------------------------------
# pre-flight: everything the APPLY step needs, checked BEFORE the first question
# ---------------------------------------------------------------------------
# The apply step calls setup.sh, which needs a running Docker daemon (it builds the
# iPXE EFI in a linux/amd64 container) and openssl 3.3+. Without them setup.sh exits
# mid-apply - after deploy.conf is backed up and rewritten - and leaves a half-applied
# event. So the check runs FIRST, before any
# question and before anything is written.
#
# The check is setup.sh's OWN prereq gate, run through --dry-run so it writes nothing.
# Doing it this way means the wizard cannot drift from what setup.sh really requires.
sect "pre-flight"
if [ "${SKIP_SERVER_NAME}" -eq 1 ]; then
    say "--skip-server-name: setup.sh is not called, so its prerequisites are not needed."
else
    echo "The apply step runs setup.sh. It needs:"
    echo "  * a RUNNING Docker daemon (it builds the iPXE EFI in a linux/amd64 container)"
    echo "  * openssl 3.3+ (for the clock-tolerant certificates)"
    echo "Checking them now, before any question is asked."
    if bash "${SETUP_CMD}" --dry-run --non-interactive --skip-build > "${PREFLIGHT_LOG}" 2>&1; then
        say "pre-flight OK - the apply step can run"
    elif [ "${DRY_RUN}" -eq 1 ]; then
        say "WARNING: the pre-flight failed, but --dry-run writes nothing. Continuing."
        say "         log: ${PREFLIGHT_LOG}"
    else
        sed -n '1,40p' "${PREFLIGHT_LOG}" >&2
        echo >&2
        die "pre-flight failed - fix the prerequisites above and re-run. Nothing was written (log: ${PREFLIGHT_LOG})"
    fi
fi

# ---------------------------------------------------------------------------
# the fixed policy banner
# ---------------------------------------------------------------------------
sect "partyOS event wizard"
cat <<'EOF'
Fixed policy for this event (not asked):
  * Every stick is provisioned fresh. No stick reuse, no keep-home question.
  * Clients use DHCP. No static IP, gateway or DNS is written.
  * Keyboard SE, timezone Europe/Stockholm. The first-boot wizard still lets a
    player change the keyboard and set the password.
  * The venue runs DHCP and DNS and provides the DNS name and record. The
    certificate carries the name, so no fallback IP is asked for.
  * The client VLAN has no internet. Dedicated game servers and bootloader NIC
    coverage are out of scope.

Five questions follow. Enter accepts the default.
EOF

# ---------------------------------------------------------------------------
# 1. server address
# ---------------------------------------------------------------------------
sect "1/5 server address"
CUR_SERVER="$(conf_get PXE_SERVER "${CONF}")"
SERVER="$(ask SERVER_NAME "Server address (DNS name[:port])" "${CUR_SERVER:-${DEFAULT_SERVER}}")"
looks_like_hostport "${SERVER}" || die "invalid server address '${SERVER}'"
SERVER="$(with_port "${SERVER}" 8080)"
SERVER_HOST="$(host_of "${SERVER}")"

# ---------------------------------------------------------------------------
# 2. blob servers
# ---------------------------------------------------------------------------
sect "2/5 blob server(s)"
echo "The blob servers carry the app catalog and the game blobs. They may be"
echo "other hosts. Enter = the current deploy.conf value, else the main server."
CUR_BLOBS="$(conf_get BLOB_SERVERS "${CONF}")"
[ -n "${CUR_BLOBS}" ] || CUR_BLOBS="$(conf_get BLOB_SERVER "${CONF}")"
BLOBS="$(ask BLOB_SERVERS "Blob server(s), comma separated" "${CUR_BLOBS:-${SERVER}}")"
BLOB_CSV=""
_oldifs="${IFS}"; IFS=','
for _b in ${BLOBS}; do
    _b="$(printf '%s' "${_b}" | tr -d '[:space:]')"
    [ -n "${_b}" ] || continue
    looks_like_hostport "${_b}" || { IFS="${_oldifs}"; die "invalid blob server '${_b}'"; }
    _b="$(with_port "${_b}" 8080)"
    BLOB_CSV="${BLOB_CSV:+${BLOB_CSV},}${_b}"
done
IFS="${_oldifs}"
[ -n "${BLOB_CSV}" ] || die "the blob server list is empty"

# ---------------------------------------------------------------------------
# 3. package mirror
# ---------------------------------------------------------------------------
sect "3/5 package mirror"
echo "The mirror carries the LAN pacman repo. Clients install the native-package"
echo "games and tools from it. It may be its own host. Enter = the current"
echo "deploy.conf value, else the main server."
CUR_MIRROR="$(conf_get MIRROR_SERVER "${CONF}")"
MIRROR="$(ask MIRROR_SERVER "Package mirror address" "${CUR_MIRROR:-${SERVER}}")"
looks_like_hostport "${MIRROR}" || die "invalid mirror address '${MIRROR}'"
MIRROR="$(with_port "${MIRROR}" 8080)"

# ---------------------------------------------------------------------------
# 4. chat / IRC server
# ---------------------------------------------------------------------------
sect "4/5 chat server"
echo "The chat server runs the LAN IRC daemon. Your venue can host it."
echo "Enter = the current deploy.conf value, else the main server on port 6667."
CUR_IRC="$(conf_get IRC_SERVER "${CONF}")"
IRC="$(ask IRC_SERVER "Chat/IRC server address" "${CUR_IRC:-${SERVER_HOST}:6667}")"
looks_like_hostport "${IRC}" || die "invalid chat server address '${IRC}'"
IRC="$(with_port "${IRC}" 6667)"

# ---------------------------------------------------------------------------
# 5. party name
# ---------------------------------------------------------------------------
sect "5/5 party name"
CUR_PARTY="$(conf_get PARTY_NAME "${CONF}")"
PARTY="$(ask PARTY_NAME "Party name" "${CUR_PARTY:-${DEFAULT_PARTY_NAME}}")"
[ -n "${PARTY}" ] || die "the party name is empty"
case "${PARTY}" in *$'\n'*) die "the party name has a newline";; esac

# ---------------------------------------------------------------------------
# information: the game roster, with the payload size
# ---------------------------------------------------------------------------
sect "game roster (information)"
DROP="$(answer_of DROP_TITLES)"
CATALOG_OK=0
if [ -f "${CATALOG}" ] && command -v python3 >/dev/null 2>&1; then
    CATALOG_OK=1
    python3 - "${CATALOG}" <<'PY'
import json, sys
cat = sys.argv[1]
rows = json.load(open(cat)).get("games", [])
total = 0
print("  %-16s %-7s %9s  %s" % ("name", "source", "size", "notes"))
for r in rows:
    size = int(r.get("size") or 0)
    total += size
    notes = []
    if r.get("hidden"):
        notes.append("hidden, unlock code %s" % (r.get("unlock_code") or "none"))
    human = "%.1f GB" % (size / 2**30) if size else "-"
    print("  %-16s %-7s %9s  %s" % (r.get("name"), r.get("source"), human, ", ".join(notes)))
print()
print("  %d rows, blob payload %.1f GB" % (len(rows), total / 2**30))
PY
    echo
    echo "  Warning: the hidden rows need their unlock code at the store."
    DROP="$(ask DROP_TITLES "Titles to DROP, comma separated (Enter = keep all)" "")"
else
    say "catalog not readable (${CATALOG}) or python3 is missing - skipping the roster view"
fi

# ---------------------------------------------------------------------------
# information: stick share size and the blob-cache reserve
# ---------------------------------------------------------------------------
sect "stick sizing (information, defaults kept)"
RESERVE="$(conf_get BLOB_CACHE_RESERVE_GB "${CONF}")"
case "${RESERVE}" in ''|*[!0-9]*) RESERVE=8;; esac
cat <<EOF
  Current defaults: 512 MB ESP, 4096 MB PARTYSHARE, BLOB_CACHE_RESERVE_GB=${RESERVE}.
  Arithmetic for a 16 GB stick: 16 - 0.5 ESP - 4 share = about 11 GB of home.
  The ${RESERVE} GB free-space reserve then leaves about $(( 11 - RESERVE )) GB of blob cache,
  and the largest blob today is 3.1 GB.
  Recommendation: buy 64 GB or larger. The wizard keeps the current defaults.
EOF

# ---------------------------------------------------------------------------
# CA: generate on a first run, rotate only on request
# ---------------------------------------------------------------------------
sect "certificate authority"
ROTATE="no"
CA_FP_NOW=""
CA_STATE="none"
if [ -f "${CA_DIR}/partyos-ca.crt" ]; then
    # Print the anchor's identity, not just its path. This is the value baked into
    # every stick, and the operator is the only one who can say whether it is the
    # right one. Showing it here and in the summary is the last chance to notice a
    # wrong CA before the build.
    CA_FP_NOW="$(openssl x509 -in "${CA_DIR}/partyos-ca.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
    echo "  A CA already exists: ${CA_DIR}/partyos-ca.crt"
    echo "    subject : $(openssl x509 -in "${CA_DIR}/partyos-ca.crt" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    echo "    SHA-256 : ${CA_FP_NOW:-<unreadable>}"
    if [ -f "${CA_DIR}/EXTERNAL-CA" ]; then
        CA_STATE="external"
        echo "    source  : EXTERNAL (installed by install-certs.sh - a venue CA)"
    elif [ -f "${CA_DIR}/partyos-ca.key" ]; then
        CA_STATE="local"
        echo "    source  : minted here (the private key is present)"
    else
        CA_STATE="no-key"
        echo "    source  : UNKNOWN - the private key is NOT on this box."
        echo "              This box cannot sign with this CA. setup.sh will REFUSE"
        echo "              rather than mint a different CA over it. Copy the key in,"
        echo "              or install it properly with install-certs.sh, or rotate."
    fi
    echo "  Check that fingerprint against the sticks already flashed."
    echo "  Warning: a rotation invalidates EVERY stick already flashed. Every"
    echo "           stick must be re-flashed afterwards."
    ROTATE="$(ask ROTATE_CA "Rotate the CA? (yes/no)" "no")"
    case "${ROTATE}" in yes|y|YES|Y) ROTATE="yes";; *) ROTATE="no";; esac
else
    echo "  No CA yet. This run generates one."
fi

# ---------------------------------------------------------------------------
# summary + ONE confirmation
# ---------------------------------------------------------------------------
sect "summary"
cat <<EOF
  server address   : ${SERVER}
  blob server(s)   : ${BLOB_CSV}
  package mirror   : ${MIRROR}
  chat server      : ${IRC}
  party name       : ${PARTY}
  titles to drop   : ${DROP:-none}
  CA               : $( [ "${ROTATE}" = yes ] && echo "ROTATE (re-flash every stick)" || echo "keep or generate" )
  CA fingerprint   : ${CA_FP_NOW:-none yet (this run mints one)}${CA_FP_NOW:+ (${CA_STATE})}
  deploy.conf      : ${CONF}
  networking       : DHCP for every client
EOF

if [ "${DRY_RUN}" = 1 ]; then
    echo
    say "DRY-RUN: nothing was written."
    exit 0
fi

CONFIRM_V="$(answer_of CONFIRM)"
[ "${YES}" -eq 1 ] && CONFIRM_V="yes"
if [ -z "${CONFIRM_V}" ]; then
    if [ "${INTERACTIVE}" -eq 1 ]; then
        read -r -p "Write all of this? (yes/no) [no]: " CONFIRM_V </dev/tty
    else
        CONFIRM_V="no"
    fi
fi
case "${CONFIRM_V}" in
    yes|y|YES|Y) ;;
    *) say "aborted. Nothing was written."; exit 1;;
esac

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------
sect "writing"

# set_conf_key KEY VAL FILE - replace the KEY= line in place, or append it.
# Every other line stays byte-for-byte the same.
set_conf_key() {
    local key="$1" val="$2" file="$3" tmp
    tmp="$(mktemp)" || return 1
    if grep -q "^${key}=" "${file}"; then
        sed "s|^${key}=.*|${key}=${val}|" "${file}" > "${tmp}"
    else
        cat "${file}" > "${tmp}"
        printf '%s=%s\n' "${key}" "${val}" >> "${tmp}"
    fi
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
}

# 1. back up deploy.conf
if [ -f "${CONF}" ]; then
    BACKUP="${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "${CONF}" "${BACKUP}" || die "cannot back up ${CONF}"
    say "backed up deploy.conf -> ${BACKUP}"
fi

# 2. apply the server address with setup.sh (conf + cert SAN + embed + EFI)
if [ "${SKIP_SERVER_NAME}" -eq 1 ]; then
    say "--skip-server-name: not running setup.sh. The cert and the EFI keep the old name."
    [ -f "${CONF}" ] && set_conf_key PXE_SERVER "${SERVER}" "${CONF}"
else
    SETUP_ARGS="--non-interactive --skip-build --server-name=${SERVER} --party-name=${PARTY}"
    [ "${ROTATE}" = yes ] && SETUP_ARGS="--fresh ${SETUP_ARGS}"
    say "running setup.sh ${SETUP_ARGS}"
    # shellcheck disable=SC2086
    bash "${SETUP_CMD}" ${SETUP_ARGS} || die "setup.sh failed - deploy.conf is at ${BACKUP:-unchanged}"
fi

# 3. the keys setup.sh does not own: the blob list, the mirror, the chat server,
#    the party name. setup.sh points the mirror at the main server, so this write
#    comes AFTER it and keeps an operator split.
[ -f "${CONF}" ] || die "deploy.conf is missing after setup: ${CONF}"
set_conf_key BLOB_SERVERS "${BLOB_CSV}" "${CONF}"
set_conf_key BLOB_SERVER  "${BLOB_CSV%%,*}" "${CONF}"
set_conf_key MIRROR_SERVER "${MIRROR}" "${CONF}"
set_conf_key IRC_SERVER   "${IRC}" "${CONF}"
set_conf_key PARTY_NAME   "${PARTY}" "${CONF}"
say "deploy.conf: PXE_SERVER=${SERVER} BLOB_SERVERS=${BLOB_CSV} MIRROR_SERVER=${MIRROR} IRC_SERVER=${IRC} PARTY_NAME=${PARTY}"

# 4. drop the catalog rows the operator named
if [ -n "${DROP}" ] && [ "${CATALOG_OK}" = 1 ]; then
    cp "${CATALOG}" "${CATALOG}.bak.$(date +%Y%m%d-%H%M%S)" || die "cannot back up ${CATALOG}"
    python3 - "${CATALOG}" "${DROP}" <<'PY' || die "the catalog edit failed"
import json, sys
cat, drop = sys.argv[1], [x.strip() for x in sys.argv[2].split(",") if x.strip()]
d = json.load(open(cat))
before = len(d.get("games", []))
d["games"] = [r for r in d["games"] if r.get("name") not in drop and r.get("id") not in drop]
json.dump(d, open(cat, "w"), indent=2)
open(cat, "a").write("\n")
print("[prepare] catalog: %d rows -> %d rows" % (before, len(d["games"])))
PY
    # The wizard edits catalog.v2.json, but clients fetch the rendered catalog.json.
    # Re-render it here so the served file can never lag the edit. render.sh renders it
    # too, so a later render is a no-op rather than a second chance to forget.
    CAT_DIR="$(cd "$(dirname "${CATALOG}")" && pwd)"
    CATALOG_V2="${CATALOG}" bash "${REPO_ROOT}/scripts/build/build-game-blobs.sh" "${CAT_DIR}" >/dev/null \
        || die "the served catalog.json could not be rendered from ${CATALOG}"
    say "rendered ${CAT_DIR}/catalog.json from the edited catalog"
fi

# ---------------------------------------------------------------------------
# what is left to run
# ---------------------------------------------------------------------------
sect "remaining steps, in order"
cat <<EOF
  1. FORCE=1 make image                       build the squashfs image
  2. make boot-artifacts                      build the served kernel + initramfs
  3. scripts/deploy/render.sh                 render the boot script, portal, torrents
  4. make test-prod                           the hardware-free gate
  5. make verify-ipxe-efi                     the EFI matches the CA and the name
  6. sudo scripts/deploy/flash-usb.sh /dev/sdX --user <name>   one stick per player
  7. pre-seed the popular blobs onto the sticks (after step 3)

  Steps 1, 2 and 6 are heavy builds or need a Linux flashing station, so the
  wizard never runs them. Steps 3 and 4 are safe to run here.
  Docker IS required by the apply step above (setup.sh builds the iPXE EFI in a
  container). The pre-flight at the start checked for it.
EOF

RUNC="$(answer_of RUN_COMMANDS)"
if [ -z "${RUNC}" ] && [ "${INTERACTIVE}" -eq 1 ]; then
    read -r -p "Run the safe steps now? (render,test / Enter = none): " RUNC </dev/tty
fi
case ",${RUNC}," in
    *,render,*) say "running render.sh"; bash "${RENDER}" || die "render.sh failed";;
esac
case ",${RUNC}," in
    *,test,*) say "running make test-prod"; ( cd "${REPO_ROOT}" && make test-prod ) || die "make test-prod failed";;
esac

echo
say "done."
