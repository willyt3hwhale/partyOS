#!/usr/bin/env bash
# setup.sh - production setup for a fresh partyOS clone.
#
# The server IP or hostname goes into three places:
#   (a) deploy.conf (PXE_SERVER/BLOB/MIRROR/IRC), rendered from deploy.conf.tmpl;
#   (b) the leaf cert SAN (gen-ca.sh PRIMARY_SAN);
#   (c) the iPXE embed baked into the EFI (boot/embed-https.ipxe.tmpl -> {{PXE_HTTPS}}).
# render.sh puts the other served URLs on the kernel cmdline from deploy.conf.
#
# Operator steps: clone, setup.sh, flash-usb.sh /dev/sdX, make servers, boot a client.
#
# Order of operations:
#   0. (--fresh only) WIPE the CA/certs/generated config + artifacts, then regen
#      everything below from scratch (= "rotate the CA"; nothing else is needed).
#   1. PREREQS (fail fast): Docker daemon, openssl 3.3+, mkfs.exfat (exfatprogs).
#   2. COLLECT + VALIDATE inputs: confirm the server address (default: the DNS name
#      partyos.lan, or take --server-name), party name, blob/mirror/irc default to the
#      same box.
#   3. WRITE deploy.conf. First run (no deploy.conf yet): render it fresh from
#      deploy.conf.tmpl with the operator's values. RE-RUN (deploy.conf exists): back it
#      up (timestamped) and MERGE only the server-derived keys in place - operator edits
#      (BOOT_CONFIG_URL, blob-cache / seed knobs, a hand-pointed IRC/mirror) are preserved.
#   4. RENDER the embed template -> a generated embed (build/embed-https.ipxe).
#   5. GEN CA + leaf with the operator SAN (reuse the CA; --fresh regenerates it).
#      If install-certs.sh installed an external CA, skip gen-ca and reuse it.
#   6. RENDER boot/partyos.ipxe from deploy.conf (scripts/deploy/render.sh).
#   7. BUILD boot artifacts (image + initramfs) unless --skip-build.
#   8. BUILD the iPXE EFI (operator embed + CA baked in) -> build/ipxe-custom-https.efi.
#   9. VERIFY (verify-boot-artifacts unless --skip-build, + verify-ipxe-efi).
#  10. PRINT next steps.
#
# A default run reuses the CA and re-signs only the leaf. --fresh rotates the CA.
# After --fresh, re-flash every USB stick.
#
# The script is re-runnable. It does not flash a USB or start servers.
#
# Flags (all optional; prompts fill the gaps interactively):
#   --server-name=HOST[:PORT]
#                           the server address, a DNS name or an IP. No port -> :8080.
#                           Order: this flag,
#                           then the SERVER_NAME env, then PXE_SERVER in the existing
#                           deploy.conf, then partyos.lan. A DNS name needs a record on
#                           the LAN DNS server (see docs/HOSTING.md).
#   --server-ip=HOST[:PORT] the old name of --server-name (same meaning).
#   --blob-servers=CSV      override the blob failover list (default = server IP).
#   --party-name=NAME       party name. Written as the deploy.conf PARTY_NAME key
#                           (announce.sh reads it) and as the header comment.
#   --non-interactive       no prompts (the server name uses the order above).
#   --fresh | --clean       delete the CA, certs, generated config and artifacts, and
#                           rebuild them (rotates the CA). Re-flash every stick after.
#   --skip-build            skip the boot-artifacts (image+initramfs) build. The EFI
#                           is still built.
#   --skip-prereq           skip the prereq checks (for testing on a partial host).
#   --dry-run               print what WOULD be written/built; touch nothing, no docker.
#   -h | --help             this help.
#
# Output-path override envs (used by the verification harness to keep the dev CA /
# certs / deploy.conf / EFI untouched - it redirects EVERYTHING to temp paths):
#   CONF_OUT        deploy.conf output path        (default: <repo>/deploy.conf)
#   EMBED_OUT       generated embed output path    (default: <repo>/build/embed-https.ipxe)
#   EFI_OUT         built EFI output path          (default: build-ipxe.sh's https default)
#   PARTYOS_CA_DIR  CA output dir (-> gen-ca CA_DIR_OVERRIDE)  (default: <repo>/ca)
#   PARTYOS_TLS_DIR leaf output dir (-> gen-ca TLS_DIR_OVERRIDE) (default: <repo>/server/tls)
#   BOOT_IPXE_OUT   rendered boot script path (-> render.sh)  (default: <repo>/boot/partyos.ipxe)
#   PORTAL_OUT      rendered portal path (-> render.sh)        (default: <repo>/portal/index.html)
# A redirected BOOT_IPXE_OUT also makes render.sh SKIP the live per-blob torrents, so a
# test/dry-run/verification render never touches the live boot/portal/torrent serving state.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"

# --- defaults / output paths (override envs let the verification run hit temp) ----
CONF_OUT="${CONF_OUT:-${REPO_ROOT}/deploy.conf}"
EMBED_OUT="${EMBED_OUT:-${REPO_ROOT}/build/embed-https.ipxe}"
EFI_OUT="${EFI_OUT:-${REPO_ROOT}/build/ipxe-custom-https.efi}"
PARTYOS_CA_DIR="${PARTYOS_CA_DIR:-${REPO_ROOT}/ca}"
PARTYOS_TLS_DIR="${PARTYOS_TLS_DIR:-${REPO_ROOT}/server/tls}"
# render.sh outputs - mirror the CONF_OUT/EMBED_OUT pattern so the verification harness
# redirects the rendered boot script + portal to temp paths and the LIVE served
# boot/partyos.ipxe + portal/index.html (+ the per-blob torrents) are never clobbered.
BOOT_IPXE_OUT="${BOOT_IPXE_OUT:-${REPO_ROOT}/boot/partyos.ipxe}"
PORTAL_OUT="${PORTAL_OUT:-${REPO_ROOT}/portal/index.html}"
# Live default paths, captured so render_boot() can detect when ANY temp override is in
# effect (a verification run points the *_OUT envs at temp) and force render off live.
LIVE_BOOT_IPXE="${REPO_ROOT}/boot/partyos.ipxe"
LIVE_CONF_OUT="${REPO_ROOT}/deploy.conf"

CONF_TMPL="${REPO_ROOT}/deploy.conf.tmpl"
EMBED_TMPL="${REPO_ROOT}/boot/embed-https.ipxe.tmpl"
GENCA="${SELF_DIR}/gen-ca.sh"
RENDER="${SELF_DIR}/render.sh"
CHECK_EFI="${SELF_DIR}/check-ipxe-efi.sh"
BUILD_IPXE="${BUILD_IPXE:-${REPO_ROOT}/scripts/build/build-ipxe.sh}"

# Default server address if no flag, no SERVER_NAME env and no deploy.conf give one.
DEFAULT_SERVER_NAME="${PARTYOS_SERVER_NAME:-partyos.lan}"
# The party name a fresh deploy.conf gets when the operator gives none. It must match
# the name the tests and the wizard default to.
DEFAULT_PARTY_NAME="Internyet"
# Path of the stock operator boot-config hook on the main server. setup.sh points
# BOOT_CONFIG_URL at it so the hook is live by default.
BOOT_CONFIG_PATH="/server/boot-config.sh"

# HTTPS port offset (8080 -> 8443), same mapping render.sh + run-servers.sh use.
HTTPS_PORT_OFFSET="${HTTPS_PORT_OFFSET:-363}"

# --- flag parse ---------------------------------------------------------------
SERVER_IP=""
BLOB_SERVERS=""
BLOB_SERVERS_SET=0   # 1 once the operator explicitly supplies --blob-servers
PARTY_NAME=""
BOOT_CONFIG_URL=""
PARTY_NAME_SET=0     # 1 once the operator explicitly supplies a party name (flag or prompt)
INTERACTIVE=1
FRESH=0
SKIP_BUILD=0
SKIP_PREREQ=0
DRY_RUN=0

for arg in "$@"; do
    case "${arg}" in
        --server-name=*|--server-ip=*) SERVER_IP="${arg#*=}" ;;
        --blob-servers=*) BLOB_SERVERS="${arg#*=}"; BLOB_SERVERS_SET=1 ;;
        --party-name=*)   PARTY_NAME="${arg#*=}"; PARTY_NAME_SET=1 ;;
        --non-interactive) INTERACTIVE=0 ;;
        --fresh|--clean)  FRESH=1 ;;
        --skip-build)     SKIP_BUILD=1 ;;
        --skip-prereq)    SKIP_PREREQ=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "setup: unknown argument '${arg}' (see --help)" >&2
            exit 1 ;;
    esac
done

# A dry-run is non-destructive by definition: it must touch nothing and run no docker.
[ "${DRY_RUN}" = 1 ] && SKIP_BUILD=1

say()  { echo "[setup] $*"; }
sect() { echo; echo "==== $* ===="; }

# elapsed_since START - human "Ns" since the epoch-seconds in $1 (heartbeat helper).
elapsed_since() { echo "$(( $(date +%s) - $1 ))s"; }

# ============================================================================
# 0. --fresh: WIPE the CA/certs/generated config + artifacts (= rotate the CA)
# ============================================================================
# A fresh run rotates the CA. Sticks flashed with the old EFI fail the TLS boot chain.
fresh_banner() {
    cat >&2 <<'EOF'

################################################################################
#                                                                              #
#   !!  --fresh : WIPE + REGENERATE FROM SCRATCH (this ROTATES the CA)  !!      #
#                                                                              #
#   This deletes the existing CA, leaf certs, generated deploy.conf/embed, and #
#   the built EFI, then mints a BRAND-NEW root CA and rebuilds everything.      #
#                                                                              #
#   A new root CA invalidates EVERY USB stick already flashed: the old EFI     #
#   trusts the OLD CA and will FAIL the TLS boot chain. After this you MUST     #
#   RE-FLASH EVERY STICK with the freshly-built EFI (flash-usb.sh).            #
#                                                                              #
################################################################################

EOF
}

# wipe_state - remove the CA/certs/generated config + artifacts so the regen below
# starts from a clean slate. Honours the *_OUT / *_DIR override envs so the
# verification harness (which points everything at temp paths) wipes ONLY its temp
# copies and never the live dev trust material.
wipe_state() {
    sect "0. --fresh: wiping CA/certs/generated config + artifacts"

    # Name the anchor that is about to be destroyed. An operator who sees a
    # fingerprint here can still stop and check it against the sticks already
    # flashed. A bare "removed <path>" list said nothing about what was lost.
    local ca_crt="${PARTYOS_CA_DIR}/partyos-ca.crt"
    if [ -f "${ca_crt}" ]; then
        local old_fp
        old_fp="$(openssl x509 -in "${ca_crt}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
        echo >&2
        echo "  !! DESTROYING the current trust anchor:" >&2
        echo "     subject     : $(openssl x509 -in "${ca_crt}" -noout -subject 2>/dev/null | sed 's/^subject=//')" >&2
        echo "     SHA-256     : ${old_fp:-<unreadable>}" >&2
        echo "     EVERY USB stick flashed against this CA is invalidated by this wipe." >&2
        echo "     They pin the CA above and will FAIL the TLS boot chain afterwards." >&2
        echo "     You MUST reflash every stick with the newly built EFI." >&2
        echo >&2
    fi

    # An external (venue) CA installed by install-certs.sh leaves a marker that
    # makes gen-ca.sh refuse to sign. The wipe deletes the cert the marker
    # describes, so a surviving marker describes nothing and blocks the rebuild.
    # Remove it here, and say so - a --fresh over a venue CA discards the venue CA.
    local marker="${PARTYOS_CA_DIR}/EXTERNAL-CA"
    if [ -f "${marker}" ]; then
        echo "  !! an EXTERNAL (venue) CA is installed - this wipe DISCARDS it." >&2
        echo "     to keep it, abort now and re-run without --fresh." >&2
        echo "     to put the self-minted CA back instead: scripts/deploy/install-certs.sh --restore-lab" >&2
    fi

    local f
    for f in \
        "${ca_crt}" \
        "${PARTYOS_CA_DIR}/partyos-ca.key" \
        "${PARTYOS_CA_DIR}/partyos-ca.srl" \
        "${marker}" \
        "${PARTYOS_CA_DIR}/partyos-ca.crt.lab-backup" \
        "${PARTYOS_CA_DIR}/partyos-ca.key.lab-backup" \
        "${PARTYOS_TLS_DIR}/partyos.crt" \
        "${PARTYOS_TLS_DIR}/partyos.key" \
        "${PARTYOS_TLS_DIR}/partyos.crt.lab-backup" \
        "${PARTYOS_TLS_DIR}/partyos.key.lab-backup" \
        "${CONF_OUT}" \
        "${EMBED_OUT}" \
        "${EFI_OUT}"; do
        if [ -e "${f}" ]; then
            rm -f "${f}"
            say "removed ${f}"
        fi
    done
    say "wipe complete - regenerating from scratch below"
    say "the new CA fingerprint is printed in step 5; reflash every stick with it"
}

# ============================================================================
# 1. PREREQS (fail fast)
# ============================================================================
# openssl_ok BIN -> 0 if BIN is openssl 3.3+ (probed by -not_before support, which is
# exactly what gen-ca needs for the backdated clock-tolerant certs).
openssl_has_not_before() { "$1" x509 -help 2>&1 | grep -q -- '-not_before'; }

# find_openssl33 -> echo a path to an openssl that supports -not_before, or empty.
# Mirrors gen-ca's detection so "the openssl gen-ca would pick" is the one we check.
find_openssl33() {
    local cand
    if command -v openssl >/dev/null 2>&1 && openssl_has_not_before openssl; then
        command -v openssl; return 0
    fi
    for cand in \
        /opt/homebrew/opt/openssl@3/bin/openssl \
        /opt/homebrew/opt/openssl/bin/openssl \
        /opt/homebrew/opt/openssl@3.6/bin/openssl \
        /opt/homebrew/opt/openssl@3.5/bin/openssl \
        /opt/homebrew/opt/openssl@3.4/bin/openssl \
        /opt/homebrew/opt/openssl@3.3/bin/openssl \
        /usr/local/opt/openssl@3/bin/openssl; do
        if [ -x "${cand}" ] && openssl_has_not_before "${cand}"; then echo "${cand}"; return 0; fi
    done
    return 1
}

check_prereqs() {
    sect "1. prerequisites"
    local fail=0

    # Docker daemon (build-ipxe + boot-artifacts run in linux/amd64 containers).
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        say "OK  docker daemon is running"
    else
        echo "[setup] MISSING: docker daemon not running." >&2
        echo "        partyOS builds the iPXE EFI + boot image in linux/amd64 containers." >&2
        echo "        Install Docker and start it, then re-run. See docs/HOSTING.md (Prerequisites)." >&2
        echo "          Debian/Ubuntu: apt install docker.io && systemctl start docker" >&2
        echo "          Arch:          pacman -S docker && systemctl start docker" >&2
        echo "          macOS:         brew install --cask docker  (then launch Docker Desktop)" >&2
        fail=1
    fi

    # openssl 3.3+ (gen-ca needs -not_before for the clock-tolerant backdated certs).
    local ossl
    if ossl="$(find_openssl33)"; then
        say "OK  openssl 3.3+ found: ${ossl} ($("${ossl}" version 2>/dev/null))"
    else
        echo "[setup] MISSING: openssl 3.3+ (need 'openssl x509 -not_before' for clock-tolerant certs)." >&2
        echo "        Install a newer openssl, then re-run. See docs/HOSTING.md (Prerequisites)." >&2
        echo "          Debian/Ubuntu: apt install openssl   (bookworm+ ships 3.x; trixie ships 3.3+)" >&2
        echo "          Arch:          pacman -S openssl      (rolling, already 3.3+)" >&2
        echo "          macOS:         brew install openssl@3" >&2
        fail=1
    fi

    # mkfs.exfat (exfatprogs) - create_usb.sh formats the PARTYSHARE partition with it.
    if command -v mkfs.exfat >/dev/null 2>&1; then
        say "OK  mkfs.exfat present (exfatprogs)"
    else
        echo "[setup] MISSING: mkfs.exfat (exfatprogs) - create_usb.sh formats PARTYSHARE with it." >&2
        echo "        Install exfatprogs, then re-run. See docs/HOSTING.md (Prerequisites)." >&2
        echo "          Debian/Ubuntu: apt install exfatprogs" >&2
        echo "          Arch:          pacman -S exfatprogs" >&2
        echo "          macOS:         brew install exfatprogs   (exFAT formatting is done at flash time)" >&2
        # A name change (--skip-build) does not flash, so it does not need mkfs.exfat.
        if [ "${SKIP_BUILD}" = 1 ]; then echo "[setup] (--skip-build: not required now, only at flash time)" >&2; else fail=1; fi
    fi

    [ "${fail}" -eq 0 ] || { echo "[setup] prerequisites not met - see the messages above." >&2; exit 1; }
}

# ============================================================================
# 2. host primary-LAN-IP auto-detection (portable: mac + linux)
# ============================================================================
# detect_primary_ip -> echo this host's primary non-loopback IPv4, or empty. Cribbed
# from run-servers.sh's portable style: route-based first (the IP that would reach the
# internet, i.e. the primary LAN iface), then a per-OS interface fallback.
detect_primary_ip() {
    local ip=""
    # Linux: the source address the kernel picks to reach a public IP = primary LAN IP.
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    fi
    # macOS: the default-route interface, then its inet address.
    if [ -z "${ip}" ] && command -v route >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
        local dev
        dev="$(route -n get 1.1.1.1 2>/dev/null | sed -n 's/.*interface: \(.*\)/\1/p' | head -1)"
        [ -n "${dev}" ] && ip="$(ipconfig getifaddr "${dev}" 2>/dev/null || true)"
    fi
    # macOS fallback: common wired/wifi interfaces.
    if [ -z "${ip}" ] && command -v ipconfig >/dev/null 2>&1; then
        local en
        for en in en0 en1 en2; do
            ip="$(ipconfig getifaddr "${en}" 2>/dev/null || true)"
            [ -n "${ip}" ] && break
        done
    fi
    # Last resort: first non-loopback inet from ifconfig.
    if [ -z "${ip}" ] && command -v ifconfig >/dev/null 2>&1; then
        ip="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)"
    fi
    printf '%s' "${ip}"
}

# looks_like_hostport HP -> 0 if HP is a plausible IPv4/hostname with an optional
# :PORT suffix, 1 otherwise. Deliberately permissive (LAN names + IPs), just a sanity
# gate against empty / obviously-malformed input.
looks_like_hostport() {
    local hp="$1" host port
    [ -n "${hp}" ] || return 1
    case "${hp}" in
        *:*) host="${hp%:*}"; port="${hp##*:}";;
        *)   host="${hp}";    port="";;
    esac
    [ -n "${host}" ] || return 1
    # A port, if present, must be all digits.
    [ -z "${port}" ] || case "${port}" in ''|*[!0-9]*) return 1;; esac
    # The host must be a dotted IPv4 OR a hostname (letters/digits/dots/hyphens).
    case "${host}" in
        *[!0-9.]*) case "${host}" in *[!A-Za-z0-9.-]*) return 1;; *) return 0;; esac;;
        *.*.*.*)   return 0;;
        *)         case "${host}" in *[!A-Za-z0-9-]*) return 1;; *) return 0;; esac;;
    esac
}

# with_port HOSTPORT DEFAULTPORT -> echo HOSTPORT, appending :DEFAULTPORT if it has none.
with_port() {
    case "$1" in *:*) printf '%s' "$1";; *) printf '%s:%s' "$1" "$2";; esac
}

# host_of HOSTPORT -> just the host (strip any :PORT). port_of -> the port or 8080.
host_of() { printf '%s' "${1%%:*}"; }
port_of() { case "$1" in *:*) printf '%s' "${1##*:}";; *) printf '%s' "8080";; esac; }

# https_base HOST[:PORT] -> https://HOST:(PORT+OFFSET); bare host assumes 8080->8443.
# Identical mapping to render.sh's https_base so the embed's chain URL matches.
https_base() {
    local hp="$1" host port
    case "${hp}" in
        *:*) host="${hp%%:*}"; port="${hp##*:}";;
        *)   host="${hp}";     port="8080";;
    esac
    case "${port}" in ''|*[!0-9]*) port="8080";; esac
    printf 'https://%s:%s' "${host}" "$(( port + HTTPS_PORT_OFFSET ))"
}

collect_inputs() {
    sect "2. inputs"

    # SERVER_IP: the flag wins, then the SERVER_NAME env, then PXE_SERVER in the
    # existing deploy.conf, then DEFAULT_SERVER_NAME. Clients reach the server by this
    # name, so the LAN DNS server must resolve it.
    if [ -z "${SERVER_IP}" ] && [ -n "${SERVER_NAME:-}" ]; then
        SERVER_IP="${SERVER_NAME}"
    fi
    if [ -z "${SERVER_IP}" ]; then
        local suggest="${DEFAULT_SERVER_NAME}"
        if [ -f "${CONF_OUT}" ]; then
            suggest="$(conf_get PXE_SERVER "${CONF_OUT}")"
            suggest="${suggest:-${DEFAULT_SERVER_NAME}}"
        fi
        if [ "${INTERACTIVE}" -eq 0 ]; then
            SERVER_IP="${suggest}"
        else
            say "this host's primary LAN IP: $(detect_primary_ip)  (the DNS name must resolve to it)"
            read -r -p "Server hostname/IP [${suggest}]: " SERVER_IP
            SERVER_IP="${SERVER_IP:-${suggest}}"
        fi
    fi
    looks_like_hostport "${SERVER_IP}" || {
        echo "[setup] invalid server address: '${SERVER_IP}' (expected IP or hostname, optional :PORT)" >&2
        exit 1
    }
    # Default the PXE port to 8080 if the operator gave none.
    SERVER_IP="$(with_port "${SERVER_IP}" 8080)"

    # PARTY_NAME: flag wins; else prompt with a default. A non-empty interactive answer
    # counts as operator-supplied (PARTY_NAME_SET), so a re-run only rewrites the header
    # party name when the operator actually gave one - an empty enter preserves it.
    if [ -z "${PARTY_NAME}" ]; then
        if [ "${INTERACTIVE}" -eq 1 ]; then
            read -r -p "Party name [${DEFAULT_PARTY_NAME}]: " PARTY_NAME
            [ -n "${PARTY_NAME}" ] && PARTY_NAME_SET=1
        fi
        PARTY_NAME="${PARTY_NAME:-${DEFAULT_PARTY_NAME}}"
    fi
    # The name goes through a | delimited sed and into a KEY=value line, so reject the
    # two characters that would corrupt either one.
    case "${PARTY_NAME}" in
        *'|'*|*$'\n'*) echo "[setup] invalid party name: '|' and newlines are not allowed" >&2; exit 1 ;;
    esac

    # Blob/mirror/irc default to the same box (single-box deploy). Blob/mirror inherit
    # the PXE host:port; IRC gets the IRC default port 6667 (no port -> :6667).
    local host
    host="$(host_of "${SERVER_IP}")"
    if [ -z "${BLOB_SERVERS}" ]; then
        BLOB_SERVERS="${SERVER_IP}"
    else
        # Validate each entry of the operator-supplied CSV, applying the :8080 default.
        local _csv="" _bs
        local _oldifs="${IFS}"; IFS=','
        for _bs in ${BLOB_SERVERS}; do
            _bs="$(printf '%s' "${_bs}" | tr -d '[:space:]')"
            [ -n "${_bs}" ] || continue
            looks_like_hostport "${_bs}" || { IFS="${_oldifs}"; echo "[setup] invalid blob server: '${_bs}'" >&2; exit 1; }
            _bs="$(with_port "${_bs}" 8080)"
            _csv="${_csv:+${_csv},}${_bs}"
        done
        IFS="${_oldifs}"
        BLOB_SERVERS="${_csv}"
    fi
    # BLOB_SERVER (singular legacy) = first of the failover list.
    BLOB_SERVER="${BLOB_SERVERS%%,*}"
    MIRROR_SERVER="${SERVER_IP}"
    IRC_SERVER="${host}:6667"
    # The operator boot-config hook is ON by default and points at this server's own
    # stock server/boot-config.sh. The render maps host:port to the HTTPS port, and the
    # client tolerates a missing or failing script, so a default-on hook cannot brick a
    # boot. An operator who does not want it empties the key - the merge preserves that.
    BOOT_CONFIG_URL="${SERVER_IP}${BOOT_CONFIG_PATH}"

    # PXE_HTTPS is the operator's https chain base, baked into the embed/EFI.
    PXE_HTTPS="$(https_base "${SERVER_IP}")"

    say "server (PXE)  : ${SERVER_IP}"
    say "blob servers  : ${BLOB_SERVERS}"
    say "mirror server : ${MIRROR_SERVER}"
    say "irc server    : ${IRC_SERVER}"
    say "boot-config   : ${BOOT_CONFIG_URL}  (operator hook, on by default)"
    say "party name    : ${PARTY_NAME}"
    say "https chain   : ${PXE_HTTPS}/boot/partyos.ipxe  (baked into the EFI)"
}

# ============================================================================
# 3. write deploy.conf (fresh from the template; MERGE-in-place on re-run)
# ============================================================================
# conf_get KEY FILE -> echo the value of KEY=... (first match), empty if absent.
conf_get() { sed -n "s|^$1=||p" "$2" | head -1; }

# set_conf_key KEY VAL FILE - replace the KEY=... line in FILE in place (append if the
# key is absent), leaving every OTHER line - operator edits, comments, blank lines -
# byte-for-byte untouched. | sed delimiter (deploy.conf values are host:port[,...],
# never containing |). Portable in-place edit (no GNU/BSD `sed -i` split).
set_conf_key() {
    local key="$1" val="$2" file="$3" tmp
    tmp="$(mktemp)"
    if grep -q "^${key}=" "${file}"; then
        sed "s|^${key}=.*|${key}=${val}|" "${file}" > "${tmp}"
    else
        cat "${file}" > "${tmp}"
        printf '%s=%s\n' "${key}" "${val}" >> "${tmp}"
    fi
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
}

# set_party_header NAME FILE - rewrite the `# Party:` header comment in place (no-op if
# the file has no such header - we never inject one on a merge).
set_party_header() {
    local name="$1" file="$2" tmp
    grep -q '^# Party:' "${file}" || return 0
    tmp="$(mktemp)"
    sed "s|^# Party:.*|# Party: ${name}|" "${file}" > "${tmp}"
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
}

write_deploy_conf() {
    sect "3. deploy.conf"
    [ -f "${CONF_TMPL}" ] || { echo "[setup] template not found: ${CONF_TMPL}" >&2; exit 1; }

    # --- FRESH WRITE: no existing deploy.conf (first run, or --fresh wiped it) --------
    # This is the ONLY path that renders template DEFAULTS - a full template substitution.
    if [ ! -f "${CONF_OUT}" ]; then
        if [ "${DRY_RUN}" = 1 ]; then
            say "DRY-RUN would CREATE ${CONF_OUT} (fresh, from template) with:"
            echo "    # Party: ${PARTY_NAME}"
            echo "    PARTY_NAME=${PARTY_NAME}"
            echo "    PXE_SERVER=${SERVER_IP}"
            echo "    BLOB_SERVERS=${BLOB_SERVERS}"
            echo "    BLOB_SERVER=${BLOB_SERVER}"
            echo "    MIRROR_SERVER=${MIRROR_SERVER}"
            echo "    IRC_SERVER=${IRC_SERVER}"
            echo "    BOOT_CONFIG_URL=${BOOT_CONFIG_URL}"
            return 0
        fi
        mkdir -p "$(dirname "${CONF_OUT}")"
        # Prepend a party-name header comment (a human label), then substitute the six
        # operator placeholders. PARTY_NAME is a real consumed key - announce.sh reads it
        # - so it is substituted like the addresses. | delimiter (values have no |).
        {
            echo "# Party: ${PARTY_NAME}"
            echo "# Generated by scripts/deploy/setup.sh - re-run it to change the server IP."
            sed -e "s|{{PXE_SERVER}}|${SERVER_IP}|g" \
                -e "s|{{BLOB_SERVERS}}|${BLOB_SERVERS}|g" \
                -e "s|{{BLOB_SERVER}}|${BLOB_SERVER}|g" \
                -e "s|{{MIRROR_SERVER}}|${MIRROR_SERVER}|g" \
                -e "s|{{IRC_SERVER}}|${IRC_SERVER}|g" \
                -e "s|{{PARTY_NAME}}|${PARTY_NAME}|g" \
                -e "s|{{BOOT_CONFIG_URL}}|${BOOT_CONFIG_URL}|g" \
                "${CONF_TMPL}"
        } > "${CONF_OUT}"
        say "wrote ${CONF_OUT} (fresh)"
        return 0
    fi

    # --- RE-RUN MERGE: deploy.conf already exists - PRESERVE operator edits -----------
    # A re-run's job is to change the server IP, NOT to blow away hand-tuned keys
    # (BOOT_CONFIG_URL, the blob-cache / seed knobs, a hand-pointed IRC/mirror, comments).
    # So we back up the file and update ONLY the server-derived keys, and among those only
    # where they were TRACKING the server IP (single-box default) or the operator EXPLICITLY
    # supplied them this run. Everything else is left byte-for-byte untouched.
    local old_pxe old_host old_blobs old_mirror old_irc old_bcu
    old_pxe="$(conf_get PXE_SERVER "${CONF_OUT}")"
    old_host="${old_pxe%%:*}"
    old_blobs="$(conf_get BLOB_SERVERS "${CONF_OUT}")"
    old_mirror="$(conf_get MIRROR_SERVER "${CONF_OUT}")"
    old_irc="$(conf_get IRC_SERVER "${CONF_OUT}")"
    old_bcu="$(conf_get BOOT_CONFIG_URL "${CONF_OUT}")"

    local new_pxe new_blobs new_blob1 new_mirror new_irc
    new_pxe="${SERVER_IP}"
    # BLOB: explicit --blob-servers wins; else follow the IP only if it was tracking the
    # old PXE box (single-box default); else keep the operator's hand-pointed blob list.
    if [ "${BLOB_SERVERS_SET}" = 1 ]; then
        new_blobs="${BLOB_SERVERS}"
    elif [ "${old_blobs}" = "${old_pxe}" ]; then
        new_blobs="${SERVER_IP}"
    else
        new_blobs="${old_blobs}"
    fi
    new_blob1="${new_blobs%%,*}"
    # MIRROR / IRC: follow the IP only if they were tracking the old PXE box; a hand-pointed
    # mirror/IRC (different host) is an operator edit and is preserved verbatim.
    if [ "${old_mirror}" = "${old_pxe}" ]; then new_mirror="${SERVER_IP}"; else new_mirror="${old_mirror}"; fi
    if [ "${old_irc}" = "${old_host}:6667" ]; then new_irc="$(host_of "${SERVER_IP}"):6667"; else new_irc="${old_irc}"; fi
    # BOOT_CONFIG_URL: follow the IP only when it was tracking the old PXE box with the
    # stock path. An empty value means the operator switched the hook off, and a
    # hand-pointed URL is an operator edit - both are preserved verbatim.
    local new_bcu
    if [ "${old_bcu}" = "${old_pxe}${BOOT_CONFIG_PATH}" ]; then
        new_bcu="${SERVER_IP}${BOOT_CONFIG_PATH}"
    else
        new_bcu="${old_bcu}"
    fi

    if [ "${DRY_RUN}" = 1 ]; then
        say "DRY-RUN ${CONF_OUT} EXISTS - would PRESERVE operator edits (back up + merge keys):"
        say "  would back up to ${CONF_OUT}.bak.<timestamp>"
        echo "    PXE_SERVER   : ${old_pxe} -> ${new_pxe}"
        echo "    BLOB_SERVERS : ${old_blobs} -> ${new_blobs}"
        echo "    MIRROR_SERVER: ${old_mirror} -> ${new_mirror}"
        echo "    IRC_SERVER   : ${old_irc} -> ${new_irc}"
        echo "    BOOT_CONFIG_URL: ${old_bcu:-<empty, hook off>} -> ${new_bcu:-<empty, hook off>}"
        [ "${PARTY_NAME_SET}" = 1 ] && echo "    PARTY_NAME    : ${PARTY_NAME} (key + header)"
        say "  (the blob-cache / seed knobs and every other line: UNTOUCHED)"
        return 0
    fi

    local bak; bak="${CONF_OUT}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "${CONF_OUT}" "${bak}"
    say "backed up existing deploy.conf -> ${bak}"

    set_conf_key PXE_SERVER    "${new_pxe}"    "${CONF_OUT}"
    set_conf_key BLOB_SERVERS  "${new_blobs}"  "${CONF_OUT}"
    set_conf_key BLOB_SERVER   "${new_blob1}"  "${CONF_OUT}"
    set_conf_key MIRROR_SERVER "${new_mirror}" "${CONF_OUT}"
    set_conf_key IRC_SERVER    "${new_irc}"    "${CONF_OUT}"
    set_conf_key BOOT_CONFIG_URL "${new_bcu}"   "${CONF_OUT}"
    # Only rewrite the party name when the operator actually supplied one. It is a real
    # key (announce.sh reads PARTY_NAME=), so write the key as well as the header comment.
    if [ "${PARTY_NAME_SET}" = 1 ]; then
        set_conf_key PARTY_NAME "${PARTY_NAME}" "${CONF_OUT}"
        set_party_header "${PARTY_NAME}" "${CONF_OUT}"
    fi

    say "merged server-derived keys into ${CONF_OUT} (operator edits preserved)"
}

# ============================================================================
# 4. render the iPXE embed template (operator https base -> {{PXE_HTTPS}})
# ============================================================================
render_embed() {
    sect "4. iPXE embed"
    [ -f "${EMBED_TMPL}" ] || { echo "[setup] embed template not found: ${EMBED_TMPL}" >&2; exit 1; }
    if [ "${DRY_RUN}" = 1 ]; then
        say "DRY-RUN would render ${EMBED_OUT} with chain ${PXE_HTTPS}/boot/partyos.ipxe"
        return 0
    fi
    mkdir -p "$(dirname "${EMBED_OUT}")"
    sed -e "s|{{PXE_HTTPS}}|${PXE_HTTPS}|g" "${EMBED_TMPL}" > "${EMBED_OUT}"
    say "wrote ${EMBED_OUT} (chain ${PXE_HTTPS}/boot/partyos.ipxe)"
}

# ============================================================================
# 5. generate the CA + leaf with the operator SAN
# ============================================================================
gen_ca() {
    sect "5. CA + leaf cert"
    [ -x "${GENCA}" ] || { echo "[setup] gen-ca.sh not executable: ${GENCA}" >&2; exit 1; }
    local host force_arg="" extra_san=""
    host="$(host_of "${SERVER_IP}")"
    # If the server is a DNS name, also put this host's IP in the SAN. Then a client
    # that dials the IP (an old stick) still validates the leaf.
    case "${host}" in *[!0-9.]*) extra_san="$(detect_primary_ip)";; esac
    # --fresh wiped the CA above, so a plain gen-ca mints a new one; pass --force too
    # so a fresh rotation is unambiguous even if a stray CA survived the wipe.
    [ "${FRESH}" -eq 1 ] && force_arg="--force"
    # An external (venue) CA is installed by install-certs.sh. We do not hold its
    # key, so gen-ca.sh refuses. Use the installed CA and leaf as they are. The EFI
    # step below then builds against that CA. The leaf must cover the server name,
    # or every client fails the TLS host check.
    if [ -f "${PARTYOS_CA_DIR}/EXTERNAL-CA" ] && [ "${FRESH}" -eq 0 ]; then
        local ca="${PARTYOS_CA_DIR}/partyos-ca.crt" leaf="${PARTYOS_TLS_DIR}/partyos.crt"
        [ -f "${ca}" ] || { echo "[setup] external CA marker present but ${ca} is missing" >&2; exit 1; }
        [ -f "${leaf}" ] || { echo "[setup] external CA installed but the leaf ${leaf} is missing (run install-certs.sh)" >&2; exit 1; }
        if ! openssl x509 -in "${leaf}" -noout -checkhost "${host}" 2>/dev/null | grep -q 'does match'; then
            echo "[setup] the installed leaf does NOT cover ${host}. Get a leaf with that SAN (install-certs.sh)." >&2
            exit 1
        fi
        say "external CA installed (${PARTYOS_CA_DIR}/EXTERNAL-CA): gen-ca skipped, CA + leaf reused"
        say "leaf covers ${host}"
        say "CA SHA-256: $(openssl x509 -in "${ca}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
        return 0
    fi
    if [ "${DRY_RUN}" = 1 ]; then
        say "DRY-RUN would run: gen-ca.sh ${force_arg} ${host} ${extra_san}  (CA_DIR=${PARTYOS_CA_DIR}, TLS_DIR=${PARTYOS_TLS_DIR})"
        say "DRY-RUN the leaf SAN would carry ${host} as its primary entry"
        return 0
    fi
    # Thread the override dirs into gen-ca via its CA_DIR_OVERRIDE / TLS_DIR_OVERRIDE
    # so the verification run mints into temp dirs and the live dev CA is untouched.
    # CA_FP_CONF points gen-ca at the config it records CA_FINGERPRINT in. Thread
    # CONF_OUT explicitly so a verification run records into its own temp config and
    # the live deploy.conf is untouched, while an apply run records into the real one.
    CA_DIR_OVERRIDE="${PARTYOS_CA_DIR}" TLS_DIR_OVERRIDE="${PARTYOS_TLS_DIR}" \
    CA_FP_CONF="${CONF_OUT}" \
        bash "${GENCA}" ${force_arg} "${host}" ${extra_san:+"${extra_san}"} \
        || { echo "[setup] gen-ca.sh FAILED - see its message above. Nothing was built." >&2; exit 1; }
    say "CA + leaf ready (SAN primary=${host}, dir=${PARTYOS_CA_DIR}/${PARTYOS_TLS_DIR##*/})"
    say "CA SHA-256: $(openssl x509 -in "${PARTYOS_CA_DIR}/partyos-ca.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
}

# ============================================================================
# 6. render boot/partyos.ipxe from deploy.conf
# ============================================================================
render_boot() {
    sect "6. render boot/partyos.ipxe"
    [ -x "${RENDER}" ] || { echo "[setup] render.sh not executable: ${RENDER}" >&2; exit 1; }
    if [ "${DRY_RUN}" = 1 ]; then
        # A dry-run writes NOTHING live: don't invoke render.sh at all (it would write the
        # fixed boot/partyos.ipxe + portal + torrents). Report the LIVE path it WOULD render.
        say "DRY-RUN would run: render.sh ${CONF_OUT}  (would write ${LIVE_BOOT_IPXE} + portal + torrents)"
        say "DRY-RUN nothing written (boot/partyos.ipxe, portal/, server/games/*.torrent untouched)"
        return 0
    fi
    # Verification / non-apply temp mode: if the harness redirected EITHER the boot output
    # OR deploy.conf to a temp path, derive a temp dir and point render.sh's boot+portal at
    # it and SKIP the live torrents - so a test render never touches the live serving state.
    # The DEFAULT (no overrides) leaves render.sh at exactly its live paths (apply unchanged).
    if [ "${BOOT_IPXE_OUT}" != "${LIVE_BOOT_IPXE}" ] || [ "${CONF_OUT}" != "${LIVE_CONF_OUT}" ]; then
        local rdir
        rdir="$(dirname "${BOOT_IPXE_OUT}")"
        [ "${BOOT_IPXE_OUT}" = "${LIVE_BOOT_IPXE}" ] && { rdir="$(dirname "${CONF_OUT}")"; BOOT_IPXE_OUT="${rdir}/partyos.ipxe"; }
        [ "${PORTAL_OUT}" != "${REPO_ROOT}/portal/index.html" ] || PORTAL_OUT="${rdir}/index.html"
        say "verify-mode: render -> ${BOOT_IPXE_OUT} (live boot/partyos.ipxe + portal + torrents untouched)"
        BOOT_IPXE_OUT="${BOOT_IPXE_OUT}" PORTAL_OUT="${PORTAL_OUT}" TORRENTS=skip \
            bash "${RENDER}" "${CONF_OUT}"
        return 0
    fi
    bash "${RENDER}" "${CONF_OUT}"
}

# ============================================================================
# 7. boot artifacts (image + initramfs) - heavy, skippable
# ============================================================================
build_boot_artifacts() {
    sect "7. boot artifacts (image + initramfs)"
    if [ "${SKIP_BUILD}" = 1 ]; then
        say "SKIP (--skip-build / --dry-run) - NOT building image+initramfs"
        say "      operators MUST run 'make boot-artifacts' before serving (or omit --skip-build)"
        return 0
    fi
    local t0; t0="$(date +%s)"
    say "running 'make boot-artifacts' (Docker linux/amd64; image+initramfs, several minutes)..."
    ( cd "${REPO_ROOT}" && make boot-artifacts ) &
    local mk=$!
    # Heartbeat so a hang is visible (the docker build is silent for long stretches).
    while kill -0 "${mk}" 2>/dev/null; do
        sleep 20
        kill -0 "${mk}" 2>/dev/null && say "  ... still building boot artifacts ($(elapsed_since "${t0}") elapsed)"
    done
    wait "${mk}" || { echo "[setup] boot-artifacts build FAILED" >&2; exit 1; }
    say "boot artifacts built ($(elapsed_since "${t0}"))"
}

# ============================================================================
# 8. build the iPXE EFI (operator embed + operator CA baked in)
# ============================================================================
build_efi() {
    sect "8. iPXE EFI"
    [ -f "${BUILD_IPXE}" ] || { echo "[setup] build-ipxe.sh not found: ${BUILD_IPXE}" >&2; exit 1; }
    local ca_crt="${PARTYOS_CA_DIR}/partyos-ca.crt"
    if [ "${DRY_RUN}" = 1 ]; then
        say "DRY-RUN would run: build-ipxe.sh EMBED=${EMBED_OUT} CA=${ca_crt} OUT=${EFI_OUT}"
        say "DRY-RUN the EFI would bake the operator embed (chain ${PXE_HTTPS}) + the operator CA"
        return 0
    fi
    [ -f "${ca_crt}" ] || { echo "[setup] CA cert missing: ${ca_crt} (step 5 should have minted it)" >&2; exit 1; }
    local t0; t0="$(date +%s)"
    say "building the iPXE EFI (Docker linux/amd64; clones iPXE, ~1-3 min)..."
    say "  EMBED=${EMBED_OUT}"
    say "  CA=${ca_crt}"
    say "  OUT=${EFI_OUT}"
    EMBED="${EMBED_OUT}" CA="${ca_crt}" OUT="${EFI_OUT}" VARIANT=https bash "${BUILD_IPXE}" &
    local bp=$!
    while kill -0 "${bp}" 2>/dev/null; do
        sleep 15
        kill -0 "${bp}" 2>/dev/null && say "  ... still building the EFI ($(elapsed_since "${t0}") elapsed)"
    done
    wait "${bp}" || { echo "[setup] iPXE EFI build FAILED" >&2; exit 1; }
    say "EFI built -> ${EFI_OUT} ($(elapsed_since "${t0}"))"
}

# ============================================================================
# 9. verify
# ============================================================================
verify() {
    sect "9. verify"
    if [ "${DRY_RUN}" = 1 ]; then
        say "DRY-RUN skips verification (nothing was built)"
        return 0
    fi
    if [ "${SKIP_BUILD}" = 1 ]; then
        say "SKIP verify-boot-artifacts (--skip-build: image+initramfs not built this run)"
    else
        say "verify-boot-artifacts (served initramfs has the pinned CA + --cacert + is fresh)..."
        ( cd "${REPO_ROOT}" && make verify-boot-artifacts )
    fi
    # The EFI guard: assert the produced EFI embeds the operator CA we just minted.
    say "verify-ipxe-efi (the built EFI embeds the current CA + the server name)..."
    bash "${CHECK_EFI}" "${EFI_OUT}" "${PARTYOS_CA_DIR}/partyos-ca.crt" "${CONF_OUT}"
    say "verification PASSED"
}

# ============================================================================
# 10. next steps
# ============================================================================
next_steps() {
    sect "next steps"
    cat <<EOF
The server IP (${SERVER_IP}) is now baked into:
  - ${CONF_OUT}                    (PXE/blob/mirror/irc)
  - ${PARTYOS_TLS_DIR}/partyos.crt SAN  (TLS host-vs-cert)
  - ${EFI_OUT}                     (the iPXE EFI chains to ${PXE_HTTPS})

To go live:
  1. Flash a USB stick (ERASES it):
       sudo ./scripts/deploy/flash-usb.sh /dev/sdX
  2. Start serving (from the repo root):
       make servers
  3. Boot a client from the stick - it auto-chains over HTTPS to ${SERVER_IP}.

Re-run this script any time to change the server IP (it REUSES the CA). To rotate
the CA / start over, re-run with --fresh - that re-pins every client and you must
re-flash every stick. See docs/HOSTING.md for the full guide.
EOF

    # On a fresh run (= CA rotation), end with the LOUD re-flash reminder.
    if [ "${FRESH}" -eq 1 ]; then
        cat >&2 <<EOF

################################################################################
#   !!  CA WAS ROTATED (--fresh) - RE-FLASH EVERY USB STICK NOW  !!            #
#                                                                              #
#   The new CA is baked into the freshly-built EFI (${EFI_OUT##*/}).      #
#   Every stick still carrying the OLD EFI trusts the OLD CA and will FAIL     #
#   the TLS boot chain. Re-flash them all:                                     #
#       sudo ./scripts/deploy/flash-usb.sh /dev/sdX   (once per stick)         #
################################################################################
EOF
    fi
}

# ============================================================================
# main
# ============================================================================
sect "partyOS turnkey setup"
[ "${DRY_RUN}" = 1 ] && say "DRY-RUN: nothing will be written or built."

# --fresh = CA rotation: warn + confirm LOUDLY before wiping anything (skipped on a
# dry-run and on a non-interactive run, where the operator has already opted in).
if [ "${FRESH}" -eq 1 ]; then
    fresh_banner
    if [ "${DRY_RUN}" = 1 ]; then
        say "DRY-RUN (--fresh): would WIPE the CA/certs/generated config + artifacts, then rotate the CA"
    elif [ "${INTERACTIVE}" -eq 1 ]; then
        # Show the anchor that is about to go, BEFORE the prompt. The operator needs
        # to recognise it (or fail to) while they can still abort.
        if [ -f "${PARTYOS_CA_DIR}/partyos-ca.crt" ]; then
            echo "  CA about to be DESTROYED: $(openssl x509 -in "${PARTYOS_CA_DIR}/partyos-ca.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')" >&2
            [ -f "${PARTYOS_CA_DIR}/EXTERNAL-CA" ] && echo "  (that is an EXTERNAL/venue CA - this discards it)" >&2
            echo >&2
        fi
        printf 'Type ROTATE to confirm the wipe + CA rotation: ' >&2
        read -r _confirm
        [ "${_confirm}" = "ROTATE" ] || { echo "[setup] aborted (did not type ROTATE)" >&2; exit 0; }
    else
        say "--non-interactive --fresh: proceeding with the wipe + CA rotation without a prompt"
    fi
fi

[ "${SKIP_PREREQ}" = 1 ] || check_prereqs
[ "${SKIP_PREREQ}" = 1 ] && say "skipping prereq checks (--skip-prereq)"
collect_inputs
# Wipe AFTER collecting inputs (so a bad/empty IP fails before anything is deleted)
# but BEFORE writing the regenerated config/CA. Skipped on a dry-run (touch nothing).
if [ "${FRESH}" -eq 1 ] && [ "${DRY_RUN}" != 1 ]; then
    wipe_state
fi
write_deploy_conf
render_embed
gen_ca
render_boot
build_boot_artifacts
build_efi
verify
next_steps
sect "done"
