#!/usr/bin/env bash
# test-render.sh - hardware-FREE unit test for the PROD config renderer
# scripts/deploy/render.sh (renders boot/partyos.ipxe.prod.tmpl -> boot/partyos.ipxe
# from deploy.conf). This path has NO VM coverage - make test-step1..9 exercise the
# VM iPXE templates (a DIFFERENT path). This locks in the rendered kernel cmdline so
# these params cannot silently regress.
#
# It drives render.sh with REPRESENTATIVE temp deploy.conf inputs (never mutates the
# real deploy.conf - copies + edits a temp one; render writes a FIXED output path so
# the real boot/partyos.ipxe + portal/index.html are snapshotted and restored).
#
# Asserts (mapped to the fix each guards):
#   * SINGLE-BOX (BLOB_SERVERS == PXE): NO blob_urls=/blob_url= emitted (clean cmdline);
#     report_url= -> PXE server, archiso_http_srv=, copytoram, the static-ip boot-wedge
#     param ip=${net0/ip}::, the kernel/initrd imgfetch RETRY ladder, step=ipxe report.
#   * TWO BLOB SERVERS: blob_urls=http://a,http://b in EXACT order (failover guard),
#     blob_url= = first base, web-seed torrents list BOTH.
#   * Output is valid-looking iPXE (#!ipxe, a kernel line, a boot).
#
# No VM, no network, no hardware. Pure shell. Exit non-zero on any failed assertion.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

RENDER="${REPO_ROOT}/scripts/deploy/render.sh"
OUT="${REPO_ROOT}/boot/partyos.ipxe"
PORTAL_OUT="${REPO_ROOT}/portal/index.html"
REAL_CONF="${REPO_ROOT}/deploy.conf"
PXE="192.168.0.10:8080"
# HTTPS port mapping: render maps each role's HTTP port to its HTTPS port
# (+363, 8080->8443, matching run-servers.sh). The runtime fetches (blobs/config/
# mirror/portal) are https on the mapped port; the BOOT image + report channel stay
# http on the original port. PXE_HTTPS is the https mapping of the PXE box (:8443).
PXE_HOST="${PXE%%:*}"
PXE_HTTPS="${PXE_HOST}:8443"

[ -x "${RENDER}" ] || { echo "FAIL: render.sh not found/executable at ${RENDER}"; exit 1; }

# --- snapshot the outputs render.sh overwrites, restore them on exit ----------
TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-render-test.XXXXXX")"
SNAP_OUT="${TMPDIR_T}/partyos.ipxe.snap";  HAD_OUT=0
SNAP_POR="${TMPDIR_T}/index.html.snap";    HAD_POR=0
[ -f "${OUT}" ]        && { cp -p "${OUT}" "${SNAP_OUT}"; HAD_OUT=1; }
[ -f "${PORTAL_OUT}" ] && { cp -p "${PORTAL_OUT}" "${SNAP_POR}"; HAD_POR=1; }
restore() {
    if [ "${HAD_OUT}" -eq 1 ]; then cp -p "${SNAP_OUT}" "${OUT}"; else rm -f "${OUT}"; fi
    if [ "${HAD_POR}" -eq 1 ]; then cp -p "${SNAP_POR}" "${PORTAL_OUT}"; else rm -f "${PORTAL_OUT}"; fi
    rm -rf "${TMPDIR_T}"
}
trap restore EXIT

# deploy.conf is not tracked. If the clone has none, build the base config from
# deploy.conf.tmpl the way setup.sh does, with test values for the placeholders.
if [ ! -f "${REAL_CONF}" ]; then
    TMPL_CONF="${REPO_ROOT}/deploy.conf.tmpl"
    [ -f "${TMPL_CONF}" ] || { echo "FAIL: deploy.conf.tmpl not found at ${TMPL_CONF}"; exit 1; }
    REAL_CONF="${TMPDIR_T}/deploy.base.conf"
    sed -e "s|{{PXE_SERVER}}|${PXE}|g" -e "s|{{BLOB_SERVERS}}|${PXE}|g" \
        -e "s|{{BLOB_SERVER}}|${PXE}|g" -e "s|{{MIRROR_SERVER}}|${PXE}|g" \
        -e "s|{{IRC_SERVER}}|${PXE_HOST}:6667|g" -e "s|{{PARTY_NAME}}|partyOS|g" \
        -e "s|{{BOOT_CONFIG_URL}}|${PXE}/server/boot-config.sh|g" \
        "${TMPL_CONF}" > "${REAL_CONF}"
fi

# render CONF -> echoes the rendered boot/partyos.ipxe contents (render writes the
# fixed OUT path; we read it back). Runs from REPO_ROOT so the portal step resolves.
# TORRENTS=skip: these cases render with TEST IPs onto the live fixed boot/portal paths
# (snapshot+restored by the trap), but the LIVE server/games/*.torrent must NEVER be
# rewritten with a test web-seed - so the torrent step is always skipped here. CASE F
# exercises the boot/portal redirect explicitly. stderr (render's chatter) is dropped.
render() {
    ( cd "${REPO_ROOT}" && TORRENTS=skip bash "${RENDER}" "$1" ) >/dev/null 2>&1
    cat "${OUT}"
}

# mkconf DEST SET key=val ...  - start from a COPY of the REAL deploy.conf (so every
# key render.sh reads is PRESENT - render's get() runs grep under set -e/pipefail and
# ABORTS if a key line is absent, so we never delete keys; we override their values).
# Then apply the SET overrides. We vary ONLY the keys under test; the real deploy.conf
# is never mutated. To "remove" a key from the failover resolution, SET it EMPTY
# (key=) - get() returns empty and render's :-/fallback chain then skips it.
mkconf() {
    local dest="$1"; shift
    cp -p "${REAL_CONF}" "${dest}"
    [ "${1:-}" = SET ] && shift
    local arg k
    for arg in "$@"; do
        k="${arg%%=*}"
        if grep -qE "^${k}=" "${dest}"; then
            sed -i.bak -E "s|^${k}=.*|${arg}|" "${dest}" && rm -f "${dest}.bak"
        else
            printf '%s\n' "${arg}" >> "${dest}"
        fi
    done
}

# ============================================================================
# CASE A: SINGLE-BOX (BLOB_SERVERS == PXE == MIRROR). The render's single-box
# optimisation: NO redundant blob_url=/blob_urls=/mirror_url= on the cmdline.
# ============================================================================
echo "================ CASE A: single-box (BLOB == PXE) ============="
CONF_A="${TMPDIR_T}/deploy.single.conf"
mkconf "${CONF_A}" SET "PXE_SERVER=${PXE}" "BLOB_SERVERS=${PXE}" "MIRROR_SERVER=${PXE}" \
                       "IRC_SERVER=192.168.0.10:6667" "PORTAL_PATH=/portal" \
                       "BLOB_CACHE_RESERVE_GB=8" "BLOB_CACHE_MAX_GB=0" \
                       "BOOT_CONFIG_URL=${PXE}/server/boot-config.sh"
A="$(render "${CONF_A}")"

# Pull just the kernel line for the precise cmdline assertions.
KLINE_A="$(printf '%s\n' "${A}" | grep -E '^kernel ' | head -1)"

# valid-looking iPXE
assert_contains "${A}" "#!ipxe"                                   "A: output starts as #!ipxe"
assert_true     "$(printf '%s\n' "${A}" | grep -qE '^kernel '; echo $?)" "A: has a kernel line"
assert_true     "$(printf '%s\n' "${A}" | grep -qE '^boot';     echo $?)" "A: has a boot line"

# single-box optimisation: NO blob params at all (regression if they leak in)
assert_not_contains "${KLINE_A}" "blob_urls=" "A: NO blob_urls= on single-box cmdline"
assert_not_contains "${KLINE_A}" "blob_url="  "A: NO blob_url= on single-box cmdline"
# mirror collapses too (same machine as PXE)
assert_not_contains "${KLINE_A}" "mirror_url=" "A: NO mirror_url= on single-box cmdline"

# The report channel goes HTTPS on the mapped port (:8443), validated by the
# CA baked into the initramfs/rootfs (the iPXE EFI also chained this script over HTTPS).
assert_contains "${KLINE_A}" "report_url=https://${PXE_HTTPS}" "A: report_url= -> PXE server HTTPS :8443"
# The INITRAMFS copytoram sfs fetch (archiso_http_srv=) is HTTPS on
# the mapped port (:8080 -> :8443), pinned to the CA bundled into the initramfs.
assert_contains "${KLINE_A}" "archiso_http_srv=https://${PXE_HTTPS}/server/images/custom/" "A: archiso_http_srv= -> HTTPS PXE :8443 (sfs fetch)"
assert_not_contains "${KLINE_A}" "archiso_http_srv=http://${PXE}/server/images/custom/" "A: archiso_http_srv= NO http (flipped to https)"
# The iPXE-level kernel/initrd fetches go HTTPS:8443 too - the iPXE EFI, the
# initramfs, and the rootfs ALL carry the pinned CA, so every boot-chain fetch is TLS.
assert_contains "${KLINE_A}" "kernel https://${PXE_HTTPS}/server/images/vmlinuz-linux" "A: kernel fetch is HTTPS :8443"
assert_contains "${A}" "initrd https://${PXE_HTTPS}/server/images/initramfs-linux.img" "A: initrd fetch is HTTPS :8443"
# RAM boot
assert_contains "${KLINE_A}" "copytoram"                "A: copytoram present (RAM boot)"
# archiso content-integrity check: the bare `checksum` param verifies airootfs.sfs
# against the served airootfs.sha512 in the initramfs (defense-in-depth on top of TLS).
assert_contains "${KLINE_A}" "checksum" "A: archiso checksum= content-check param present (sfs integrity)"
# The cowspace tmpfs holds the home of the player. Size it relative to the RAM, not fixed.
assert_contains "${KLINE_A}" " cow_spacesize=50% " "A: cow_spacesize=50% (cowspace scales with RAM)"
assert_not_contains "${KLINE_A}" "cow_spacesize=4G" "A: no fixed 4G cowspace"
# Static-ip boot-wedge param: ip= without a device field, plus BOOTIF= (the boot NIC
# MAC). archiso_pxe_common finds the interface by MAC. A fixed eth0 is wrong on a box with
# two NICs, because the kernel gives eth0 to the driver that registers first.
assert_contains "${KLINE_A}" 'ip=${net0/ip}::${net0/gateway}:${net0/netmask} ' "A: static-ip boot-wedge param present (no device field)"
assert_contains "${KLINE_A}" 'BOOTIF=01-${net0/mac:hexhyp} ' "A: BOOTIF= carries the MAC of the boot NIC"
assert_not_contains "${KLINE_A}" '::eth0' "A: ip= does not pin the kernel name eth0"
# DNS server of the iPXE lease goes to the initramfs (so a server hostname resolves)
assert_contains "${KLINE_A}" 'partyos_dns=${net0/dns}' "A: partyos_dns= carries the lease DNS server"
# DHCP option 121 goes to the initramfs raw; the option 3 gateway stays in ip=
assert_contains "${KLINE_A}" 'partyos_routes=${net0/121:hex} ' "A: partyos_routes= carries the raw option 121"
# step3 in-guest script (HTTPS) + GPU modeset params survive the render
assert_contains "${KLINE_A}" "script=https://${PXE_HTTPS}/boot/step3-script.sh" "A: step3 script= -> PXE HTTPS :8443"
assert_contains "${KLINE_A}" "nvidia-drm.modeset=1"     "A: NVIDIA KMS param survives render"

# The WHOLE executed boot chain is TLS - the rendered kernel cmdline carries
# NO plain-http URL at all (kernel/initrd/sfs/script/report + all EXTRA_PARAMS are HTTPS).
assert_not_contains "${KLINE_A}" "http://" "A: kernel cmdline has NO http:// URL (whole chain TLS)"

# the step=ipxe + step=netboot report imgfetch lines (the diagnostic the prod path
# uses). The boot-stage callback is step=netboot status=start (was step=3 status=boot)
# so it no longer collides with the desktop step=3 status=ok desktop=ready gate. Assert the
# new marker IS present AND that the old colliding step=3 boot marker is GONE from the prod
# boot script (the only step=3 a desktop emits is the in-guest status=ok desktop-ready one).
assert_contains "${A}" "report?step=ipxe"             "A: step=ipxe report imgfetch present"
assert_contains "${A}" "report?step=netboot&status=start" "A: step=netboot boot report imgfetch present"
assert_not_contains "${A}" "step=3&status=boot"       "A: old colliding step=3 status=boot marker removed"

# kernel + initrd imgfetch retry ladder (cold-boot tolerance: a :kretry / :iretry
# label + a bounded retry give-up + a :failed handler). These are structural - a
# flattened template that drops the retry loop would regress cold-boot resilience.
# The give-up count is read from the template so this assertion tracks the template's
# own budget (currently 10) instead of hard-coding a stale number.
KMAX="$(printf '%s\n' "${A}" | grep -oE 'iseq \$\{kidx\} [0-9]+' | grep -oE '[0-9]+' | head -1)"
assert_contains "${A}" ":kretry"               "A: kernel fetch retry label present"
assert_contains "${A}" ":iretry"               "A: initrd fetch retry label present"
assert_contains "${A}" "iseq \${kidx} ${KMAX}" "A: kernel retry has a bounded give-up (${KMAX} attempts)"
assert_true     "$( [ -n "${KMAX}" ] && [ "${KMAX}" -ge 1 ] 2>/dev/null; echo $? )" "A: retry budget is a positive count (${KMAX:-unset})"
assert_contains "${A}" "goto failed"           "A: failure path wired (goto failed)"
assert_contains "${A}" ":failed"               "A: :failed handler present (no dead-end fall-through)"

# cmdline knobs from deploy.conf threaded through
assert_contains "${KLINE_A}" "blob_cache_reserve_gb=8" "A: blob_cache_reserve_gb threaded onto cmdline"
assert_contains "${KLINE_A}" "irc_server=192.168.0.10:6667" "A: irc_server= always emitted"
assert_contains "${KLINE_A}" "portal_url=https://${PXE_HTTPS}/portal" "A: portal_url= emitted HTTPS on :8443"

# The portal page itself. run-servers.sh disables the plaintext :8080 listener by
# default, so every link the portal shows a player must be HTTPS. A rendered
# http://host:8080 link is a dead link.
POR_A="$(cat "${PORTAL_OUT}")"
assert_contains "${POR_A}" "https://${PXE_HTTPS}" "A: portal renders the HTTPS base"
assert_not_contains "${POR_A}" "http://${PXE}" "A: portal has no plaintext PXE URL"
assert_not_contains "${POR_A}" "{{PXE_URL}}" "A: portal leaves no unsubstituted PXE placeholder"

# ============================================================================
# CASE B: TWO BLOB SERVERS (a different machine than PXE). The render MUST emit
# the ordered failover list blob_urls=A,B, blob_url= = first base, and the
# torrents must list BOTH as web-seeds.
# ============================================================================
echo
echo "================ CASE B: two blob servers (failover) =========="
B1H="192.168.0.50:8080"
B2H="192.168.0.51:8080"
# Blob URLs are emitted HTTPS on the mapped port (:8080 -> :8443).
B1S="192.168.0.50:8443"
B2S="192.168.0.51:8443"
CONF_B="${TMPDIR_T}/deploy.split.conf"
# BLOB_SERVERS wins over the singular BLOB_SERVER (precedence), so leave BLOB_SERVER
# as-is in the copied conf - render must not abort on a missing key.
mkconf "${CONF_B}" SET "PXE_SERVER=${PXE}" "BLOB_SERVERS=${B1H},${B2H}" "MIRROR_SERVER=${PXE}"
B="$(render "${CONF_B}")"
KLINE_B="$(printf '%s\n' "${B}" | grep -E '^kernel ' | head -1)"

# EXACT ordered failover list (failover guard) - order must be A then B, now HTTPS
assert_contains "${KLINE_B}" "blob_urls=https://${B1S},https://${B2S}" "B: blob_urls= lists BOTH bases HTTPS in EXACT order"
# back-compat singular = FIRST base, HTTPS
assert_contains "${KLINE_B}" "blob_url=https://${B1S}" "B: blob_url= = first base HTTPS (back-compat)"
# The blob params carry NO http:// scheme (they flipped to https)
assert_not_contains "${KLINE_B}" "blob_urls=http://" "B: blob_urls= is NOT http"
# report still pinned to the PXE box (HTTPS :8443), NOT a blob server
assert_contains "${KLINE_B}" "report_url=https://${PXE_HTTPS}" "B: report_url= still -> PXE box HTTPS (not a blob server)"
# the static-ip wedge + copytoram still there in the split case
assert_contains "${KLINE_B}" 'ip=${net0/ip}::${net0/gateway}:${net0/netmask} BOOTIF=01-${net0/mac:hexhyp} ' "B: static-ip wedge + BOOTIF still present in split deploy"
assert_contains "${KLINE_B}" "copytoram" "B: copytoram still present in split deploy"

# the order matters: A must appear before B in blob_urls= (proves the failover order)
URLS_B="$(printf '%s\n' "${KLINE_B}" | grep -oE 'blob_urls=[^ ]+' | head -1)"
case "${URLS_B}" in
    "blob_urls=https://${B1S},https://${B2S}") _assert_ok "B: failover order is A-then-B exactly (HTTPS)";;
    *) _assert_bad "B: failover order wrong (got [${URLS_B}])";;
esac

# the per-blob torrent web-seed list (render.sh WEBSEEDS) must include BOTH blob
# servers. There may be no *.squashfs to actually build torrents from in a clean
# checkout, so assert on the WEBSEEDS computation by re-deriving it the same way:
# both bases, /server/games suffix. We assert the render's own log line carries both
# (render echoes the blob list); to keep this hardware-free we assert the blob bases
# the torrent step would seed from are both present in the kernel cmdline list above,
# which is the same ordered set WEBSEEDS is built from.
assert_contains "${KLINE_B}" "https://${B1S}" "B: web-seed/blob base A present (HTTPS)"
assert_contains "${KLINE_B}" "https://${B2S}" "B: web-seed/blob base B present (HTTPS)"

# ============================================================================
# CASE C: legacy singular BLOB_SERVER, different machine -> still emits params.
# ============================================================================
echo
echo "================ CASE C: legacy BLOB_SERVER (singular) ========"
BSL="192.168.0.60:8080"
BSLS="192.168.0.60:8443"   # legacy blob server flips to HTTPS on the mapped port
CONF_C="${TMPDIR_T}/deploy.legacy.conf"
# legacy path: BLOB_SERVERS set EMPTY (not deleted - render aborts on a missing key)
# so the singular BLOB_SERVER fallback engages via render's :-/ chain.
mkconf "${CONF_C}" SET "PXE_SERVER=${PXE}" "BLOB_SERVERS=" "BLOB_SERVER=${BSL}"
C="$(render "${CONF_C}")"
KLINE_C="$(printf '%s\n' "${C}" | grep -E '^kernel ' | head -1)"
assert_contains "${KLINE_C}" "blob_urls=https://${BSLS}" "C: legacy BLOB_SERVER -> 1-element blob_urls= (HTTPS)"
assert_contains "${KLINE_C}" "blob_url=https://${BSLS}"  "C: legacy BLOB_SERVER -> blob_url= (HTTPS)"

# ============================================================================
# CASE D: Step 9 operator boot-config hook (BOOT_CONFIG_URL). Back-compat: when
# UNSET (the real deploy.conf default) NO config_url= is emitted; when SET the
# render emits config_url=http://<value> so step3-script.sh runs the operator hook.
# Also re-confirms the single-box CASE-A render stays clean of config_url=.
# ============================================================================
echo
echo "================ CASE D: operator boot-config hook (Step 9) ==="
# D-off: BOOT_CONFIG_URL empty -> NO config_url= on the cmdline. The hook is ON by
#        default now (setup.sh points it at the server's own /server/boot-config.sh),
#        so emptying the key is the documented way to switch it off. CASE A renders
#        with the real deploy.conf, which carries the default-on value.
CONF_D0="${TMPDIR_T}/deploy.bootcfg-off.conf"
mkconf "${CONF_D0}" SET "PXE_SERVER=${PXE}" "BLOB_SERVERS=${PXE}" "MIRROR_SERVER=${PXE}" "BOOT_CONFIG_URL="
D0="$(render "${CONF_D0}")"
KLINE_D0="$(printf '%s\n' "${D0}" | grep -E '^kernel ' | head -1)"
assert_not_contains "${KLINE_D0}" "config_url=" "D: an emptied BOOT_CONFIG_URL -> NO config_url= (the off switch)"
assert_contains "${KLINE_A}" "config_url=https://${PXE_HTTPS}/server/boot-config.sh" "D: the default-on hook value reaches CASE A as an HTTPS config_url="

# D-on: BOOT_CONFIG_URL set -> config_url=https://<host:8443>/<path> emitted.
BCFG="192.168.0.10:8080/server/boot-config.sh"
BCFG_HTTPS="https://192.168.0.10:8443/server/boot-config.sh"   # host port mapped, /path kept
CONF_D1="${TMPDIR_T}/deploy.bootcfg-on.conf"
mkconf "${CONF_D1}" SET "PXE_SERVER=${PXE}" "BLOB_SERVERS=${PXE}" "MIRROR_SERVER=${PXE}" "BOOT_CONFIG_URL=${BCFG}"
D1="$(render "${CONF_D1}")"
KLINE_D1="$(printf '%s\n' "${D1}" | grep -E '^kernel ' | head -1)"
assert_contains "${KLINE_D1}" "config_url=${BCFG_HTTPS}" "D: BOOT_CONFIG_URL set -> config_url=https://<host:8443>/<path>"
# the operator-hook fetch is the most security-sensitive: it MUST NOT be http
assert_not_contains "${KLINE_D1}" "config_url=http://" "D: config_url= is NOT http (operator hook is HTTPS)"
# no double scheme on the host:port/path value
assert_not_contains "${KLINE_D1}" "config_url=https://https://" "D: no double https:// scheme on config_url="

# ============================================================================
# CASE E: WHOLE BOOT CHAIN IS TLS. EVERY fetch is HTTPS: the post-boot runtime
# fetches (blobs / config / mirror / portal),
# the INITRAMFS copytoram sfs fetch (archiso_http_srv=), AND the iPXE-level
# kernel/initrd fetches + the step3 in-guest script fetch + report_url=. The
# iPXE EFI, the initramfs, and the rootfs ALL carry the pinned CA, so every fetch on the
# executed chain is validated against the party CA. NOTHING is left on plain HTTP. A
# regression (any URL left on / reverted to http) breaks the TLS contract: assert every
# boot-chain URL is HTTPS and the rendered cmdline contains NO http:// at all. From ONE
# split render (blobs + mirror + portal + config_url all populated).
# ============================================================================
echo
echo "================ CASE E: WHOLE boot chain HTTPS, nothing on http ===="
EB="192.168.0.50:8080"; EBS="192.168.0.50:8443"
EM="192.168.0.70:8080"; EMS="192.168.0.70:8443"
ECFG="192.168.0.10:8080/server/boot-config.sh"
CONF_E="${TMPDIR_T}/deploy.tls.conf"
mkconf "${CONF_E}" SET "PXE_SERVER=${PXE}" "BLOB_SERVERS=${EB}" "MIRROR_SERVER=${EM}" \
                       "PORTAL_PATH=/portal" "BOOT_CONFIG_URL=${ECFG}"
E="$(render "${CONF_E}")"
KLINE_E="$(printf '%s\n' "${E}" | grep -E '^kernel ' | head -1)"

# --- runtime fetches: HTTPS on the mapped port ---
assert_contains "${KLINE_E}" "blob_urls=https://${EBS}"   "E: blob_urls= is HTTPS (runtime fetch flipped)"
assert_contains "${KLINE_E}" "blob_url=https://${EBS}"    "E: blob_url= is HTTPS (runtime fetch flipped)"
assert_contains "${KLINE_E}" "mirror_url=https://${EMS}"  "E: mirror_url= is HTTPS (pacman mirror flipped)"
assert_contains "${KLINE_E}" "portal_url=https://${PXE_HTTPS}/portal" "E: portal_url= is HTTPS on :8443"
assert_contains "${KLINE_E}" "config_url=https://192.168.0.10:8443/server/boot-config.sh" "E: config_url= is HTTPS (operator hook flipped)"

# --- the INITRAMFS copytoram sfs fetch goes HTTPS (pinned bundled CA) ---
assert_contains "${KLINE_E}" "archiso_http_srv=https://${PXE_HTTPS}/server/images/custom/" "E: archiso_http_srv= is HTTPS (sfs/copytoram fetch flipped)"
assert_not_contains "${KLINE_E}" "archiso_http_srv=http://${PXE}/server/images/custom/" "E: archiso_http_srv= NO http"
# archiso content-integrity check: the bare `checksum` param verifies the sfs against
# the served airootfs.sha512 in the initramfs (defense-in-depth on top of pinned-CA TLS).
assert_contains "${KLINE_E}" "checksum" "E: archiso checksum content-check param present (sfs integrity)"

# --- the iPXE-level kernel/initrd + step3 script= + report channel go HTTPS ---
# The iPXE EFI / initramfs / rootfs all carry the pinned CA, so these are TLS-validated.
assert_contains "${KLINE_E}" "report_url=https://${PXE_HTTPS}" "E: report_url= is HTTPS :8443 (report channel)"
assert_contains "${KLINE_E}" "kernel https://${PXE_HTTPS}/server/images/vmlinuz-linux" "E: kernel fetch is HTTPS :8443 (iPXE chain)"
assert_contains "${E}" "initrd https://${PXE_HTTPS}/server/images/initramfs-linux.img" "E: initrd fetch is HTTPS :8443 (iPXE chain)"
assert_contains "${KLINE_E}" "script=https://${PXE_HTTPS}/boot/step3-script.sh" "E: step3 script= is HTTPS :8443"
# nothing on the iPXE-level fetches stayed http (no http kernel/initrd/script/report)
assert_not_contains "${E}" "kernel http://" "E: kernel line is NOT http (whole chain TLS)"
assert_not_contains "${E}" "initrd http://" "E: initrd line is NOT http (whole chain TLS)"
assert_not_contains "${E}" "report_url=http://" "E: report_url= is NOT http (whole chain TLS)"
assert_not_contains "${E}" "script=http://" "E: step3 script= is NOT http (whole chain TLS)"
# --- WHOLE CHAIN: the rendered kernel cmdline carries NO plain-http URL at all ---
# (kernel/initrd/sfs/script/report + every EXTRA_PARAM are HTTPS - the chain is TLS
# end to end). EXTRA_PARAMS irc_server= is host:port (no scheme), portal/mirror/blob/
# config are https, so there is genuinely zero http:// in the cmdline.
assert_not_contains "${KLINE_E}" "http://" "E: kernel cmdline has NO http:// URL (whole chain TLS)"
# sanity: the chain IS https (the flip really happened)
assert_contains "${E}" "https://" "E: rendered script carries https boot-chain URLs (flip happened)"

# ============================================================================
# CASE F: OUTPUT-PATH ISOLATION (regression guard for the setup-render-clobbers
# bug). render.sh now honours BOOT_IPXE_OUT / PORTAL_OUT / TORRENTS=skip so a
# test/dry-run render lands in TEMP and NEVER touches the LIVE served outputs.
# A `--server-ip 10.9.9.9` style test render must NOT clobber boot/partyos.ipxe,
# portal/index.html, or the per-blob server/games/*.torrent. This is the EXACT
# bug this guard pins: a redirected render with a TEST IP lands in temp; live is
# byte-for-byte untouched and the test IP never leaks into a live file.
# ============================================================================
echo
echo "================ CASE F: output-path isolation (no live clobber) ===="
# Capture the live sha of the outputs BEFORE the redirected render. (The trap
# already snapshot/restores boot/partyos.ipxe + portal/index.html for the
# default-path cases; here we additionally PROVE the redirect leaves them byte-
# identical so a redirected test render cannot clobber live.)
sha_of() { [ -f "$1" ] && shasum -a 256 "$1" | cut -d' ' -f1 || echo "MISSING"; }
LIVE_OUT_SHA_BEFORE="$(sha_of "${OUT}")"
LIVE_POR_SHA_BEFORE="$(sha_of "${PORTAL_OUT}")"
# one live torrent (if any) - assert the redirected render does NOT touch it
LIVE_TOR="$(ls "${REPO_ROOT}/server/games"/*.squashfs.torrent 2>/dev/null | head -1 || true)"
LIVE_TOR_SHA_BEFORE="$( [ -n "${LIVE_TOR}" ] && sha_of "${LIVE_TOR}" || echo "NOTORRENT")"

# redirected render: TEST IP into TEMP outputs, torrents skipped.
FTMP="${TMPDIR_T}/iso"
mkdir -p "${FTMP}"
CONF_F="${TMPDIR_T}/deploy.iso.conf"
mkconf "${CONF_F}" SET "PXE_SERVER=10.9.9.9:8080" "BLOB_SERVERS=10.9.9.9:8080" "MIRROR_SERVER=10.9.9.9:8080"
( cd "${REPO_ROOT}" && BOOT_IPXE_OUT="${FTMP}/partyos.ipxe" PORTAL_OUT="${FTMP}/index.html" \
    bash "${RENDER}" "${CONF_F}" ) >/dev/null 2>&1

# (a) the TEMP output exists and carries the TEST IP / test values
assert_true "$( [ -f "${FTMP}/partyos.ipxe" ]; echo $? )" "F: redirected render WROTE the temp boot script"
assert_true "$( [ -f "${FTMP}/index.html" ]; echo $? )"   "F: redirected render WROTE the temp portal"
assert_contains "$(cat "${FTMP}/partyos.ipxe")" "10.9.9.9" "F: TEST IP 10.9.9.9 landed in the TEMP boot script"

# (b) the LIVE boot/partyos.ipxe is UNCHANGED and contains NO test IP
LIVE_OUT_SHA_AFTER="$(sha_of "${OUT}")"
assert_eq "${LIVE_OUT_SHA_BEFORE}" "${LIVE_OUT_SHA_AFTER}" "F: LIVE boot/partyos.ipxe sha UNCHANGED by the redirected render"
if [ -f "${OUT}" ]; then
    assert_not_contains "$(cat "${OUT}")" "10.9.9.9" "F: LIVE boot/partyos.ipxe did NOT get the test IP (no clobber)"
fi
# (b2) the LIVE portal is unchanged too (the redirect carried it off live)
LIVE_POR_SHA_AFTER="$(sha_of "${PORTAL_OUT}")"
assert_eq "${LIVE_POR_SHA_BEFORE}" "${LIVE_POR_SHA_AFTER}" "F: LIVE portal/index.html sha UNCHANGED by the redirected render"

# (c) the torrents step did NOT write/modify a live server/games/*.torrent (skipped)
if [ -n "${LIVE_TOR}" ]; then
    assert_eq "${LIVE_TOR_SHA_BEFORE}" "$(sha_of "${LIVE_TOR}")" "F: LIVE server/games/*.torrent UNCHANGED (torrent step skipped on redirect)"
else
    _assert_ok "F: no live torrents present to clobber (torrent step is a no-op here)"
fi

# ============================================================================
# CASE H: the server is a DNS NAME. Every client-facing URL carries the name.
# ============================================================================
echo
echo "================ CASE H: server by DNS name ============="
CONF_H="${TMPDIR_T}/deploy.hostname.conf"
mkconf "${CONF_H}" SET "PXE_SERVER=partyos.lan:8080" "BLOB_SERVERS=partyos.lan:8080" \
                       "BLOB_SERVER=" "MIRROR_SERVER=partyos.lan:8080" \
                       "IRC_SERVER=partyos.lan:6667" "PORTAL_PATH=/portal" "BOOT_CONFIG_URL="
H="$(render "${CONF_H}")"
KLINE_H="$(printf '%s\n' "${H}" | grep -E '^kernel ' | head -1)"
assert_contains "${KLINE_H}" "kernel https://partyos.lan:8443/server/images/vmlinuz-linux" "H: kernel fetch uses the name"
assert_contains "${KLINE_H}" "archiso_http_srv=https://partyos.lan:8443/server/images/custom/" "H: archiso_http_srv= uses the name"
assert_contains "${KLINE_H}" "report_url=https://partyos.lan:8443" "H: report_url= uses the name"
assert_contains "${KLINE_H}" 'partyos_dns=${net0/dns}' "H: partyos_dns= present so the initramfs can resolve the name"
assert_contains "${KLINE_H}" 'partyos_routes=${net0/121:hex} ' "H: partyos_routes= present so the initramfs gets the option 121 routes"
assert_not_contains "${H}" "192.168.0.10" "H: no old server IP left in the render"
assert_not_contains "${H}" "10.99.99.99" "H: no live server IP left in the render"

# ============================================================================
# CASE I: a VENUE deploy - the PXE/blob/mirror name and the IRC name are on
# DIFFERENT hosts, the way an event on someone else's DNS is configured. The
# boot script must carry the PXE name everywhere and pass the IRC name through
# untouched, and no lab name may survive the render.
# ============================================================================
echo
echo "================ CASE I: venue names, split IRC host ===="
CONF_I="${TMPDIR_T}/deploy.venue.conf"
mkconf "${CONF_I}" SET "PXE_SERVER=partyos.c.example:8080" \
                       "BLOB_SERVERS=partyos.c.example:8080" "BLOB_SERVER=" \
                       "MIRROR_SERVER=partyos.c.example:8080" \
                       "IRC_SERVER=chat.c.example:6667" "PORTAL_PATH=/portal" \
                       "BOOT_CONFIG_URL=partyos.c.example:8080/server/boot-config.sh"
I="$(render "${CONF_I}")"
KLINE_I="$(printf '%s\n' "${I}" | grep -E '^kernel ' | head -1)"
assert_contains "${KLINE_I}" "archiso_http_srv=https://partyos.c.example:8443/server/images/custom/" \
    "I: the sfs fetch uses the venue PXE name"
assert_contains "${KLINE_I}" "report_url=https://partyos.c.example:8443" "I: report_url= uses the venue PXE name"
assert_contains "${KLINE_I}" "irc_server=chat.c.example:6667" "I: the IRC host passes through on its own name"
assert_contains "${KLINE_I}" "portal_url=https://partyos.c.example:8443/portal" "I: portal_url= uses the venue PXE name"
assert_contains "${KLINE_I}" "config_url=https://partyos.c.example:8443/server/boot-config.sh" \
    "I: the boot-config hook uses the venue PXE name"
assert_not_contains "${I}" "partyos.lan" "I: no lab name left in the render"
assert_not_contains "${I}" "chat.c.example:8443" "I: the IRC host is never turned into an HTTPS base"

# ============================================================================
# CASE J: the partition labels of the player stick. deploy.conf holds an ORDERED
# comma list per partition; the render passes it on the kernel cmdline. Empty = no
# param (the image has the same defaults baked in). A bad value fails the render.
# ============================================================================
echo
echo "================ CASE J: stick partition labels ========="
assert_contains "$(cat "${REAL_CONF}")" "USB_HOME_LABELS=PARTYOSHOME,LANPARTY_HOME" \
    "J: deploy.conf lists the venue home label first, the legacy label second"
assert_contains "$(cat "${REAL_CONF}")" "USB_SHARE_LABELS=PARTYDATA,PARTYSHARE" \
    "J: deploy.conf lists the venue share label first, the legacy label second"
assert_contains "$(cat "${REPO_ROOT}/deploy.conf.tmpl")" "USB_HOME_LABELS=PARTYOSHOME,LANPARTY_HOME" \
    "J: deploy.conf.tmpl has the same home label default"
CONF_J="${TMPDIR_T}/deploy.labels.conf"
mkconf "${CONF_J}" SET "USB_HOME_LABELS=PARTYOSHOME,LANPARTY_HOME" "USB_SHARE_LABELS=PARTYDATA,PARTYSHARE"
KLINE_J="$(render "${CONF_J}" | grep -E '^kernel ' | head -1)"
assert_contains "${KLINE_J}" "usb_home_labels=PARTYOSHOME,LANPARTY_HOME" "J: usb_home_labels= is on the cmdline, in order"
assert_contains "${KLINE_J}" "usb_share_labels=PARTYDATA,PARTYSHARE" "J: usb_share_labels= is on the cmdline, in order"
mkconf "${CONF_J}" SET "USB_HOME_LABELS=MYHOME" "USB_SHARE_LABELS=MYSHARE,PARTYSHARE"
KLINE_J="$(render "${CONF_J}" | grep -E '^kernel ' | head -1)"
assert_contains "${KLINE_J}" "usb_home_labels=MYHOME " "J: an operator label list reaches the cmdline"
assert_contains "${KLINE_J}" "usb_share_labels=MYSHARE,PARTYSHARE" "J: an operator share list reaches the cmdline"
mkconf "${CONF_J}" SET "USB_HOME_LABELS=" "USB_SHARE_LABELS="
KLINE_J="$(render "${CONF_J}" | grep -E '^kernel ' | head -1)"
assert_not_contains "${KLINE_J}" "usb_home_labels=" "J: an empty USB_HOME_LABELS emits no param (baked default)"
assert_not_contains "${KLINE_J}" "usb_share_labels=" "J: an empty USB_SHARE_LABELS emits no param (baked default)"
mkconf "${CONF_J}" SET "USB_HOME_LABELS=GOOD,bad&label"
( cd "${REPO_ROOT}" && BOOT_IPXE_OUT="${TMPDIR_T}/j.ipxe" PORTAL_OUT="${TMPDIR_T}/j.html" TORRENTS=skip \
    bash "${RENDER}" "${CONF_J}" ) >"${TMPDIR_T}/j.out" 2>&1
assert_false $? "J: a label with a bad character fails the render"
assert_contains "$(cat "${TMPDIR_T}/j.out")" "USB_HOME_LABELS must be a comma list of labels" "J: the render names the bad key"

assert_summary "test-render" || exit 1
echo "test-render: ALL PASS"
