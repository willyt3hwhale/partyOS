#!/usr/bin/env bash
# test-usbsplit.sh - autonomous VM test for the cross-OS USB layout, aligned
# to the PRODUCTION 3-partition stick. The VM test image omits the ESP (it netboots)
# so it carries only the two DATA partitions:
#   p1  ext4   LANPARTY_HOME - identity (`.partyos`) + blob cache at the partition
#              ROOT, and the user home tree under a `home/` SUBDIR (the BAKED
#              partyos-home-pull layout). The OS reads `.partyos` from the ext4 ROOT.
#   p2  exFAT  PARTYSHARE     - the cross-OS (Win/mac/Linux) share, mounted at
#              /mnt/share (~/Shared). (exFAT labels cap at 11 chars; PARTYSHARE = 10.)
#
# Proves, from a REAL booted VM (serial markers + step=exfatsplit HTTP callback)
# plus a HOST-side filesystem-type assertion against the qcow2:
#   CASE split  : the BAKED partyos-usbhome.service mounts the ext4 LANPARTY_HOME at
#                 /mnt/usbhome and the exFAT PARTYSHARE at /mnt/share; the OS reads
#                 `.partyos` (USERNAME=raver7) from the ext4 ROOT, and the home comes
#                 from the ext4 home/ SUBDIR (seed files in /home/raver7). The HOST
#                 confirms ext4 LANPARTY_HOME + exFAT PARTYSHARE via the qcow2.
#   CASE single : a legacy single-ext4 stick (no PARTYSHARE) still boots - `.partyos`
#                 is read from the ext4 root (backward compatible).
#
# This boots the production image with NO installer script= overwriting the baked
# mount/identity/home units - exfatsplit-script.sh is a VERIFIER only.
#
# Heavy under TCG - run on a KVM host via scripts/vm/remote-test.sh test-usbsplit.
# USBSPLIT_RAM_MB / USBSPLIT_TIMEOUT tune each boot; USBSPLIT_SKIP_SINGLE=1 runs
# only the split case.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

RAM_MB="${USBSPLIT_RAM_MB:-10240}"
T="${USBSPLIT_TIMEOUT:-2700}"
ALIVE_WAIT="${USBSPLIT_ALIVE_WAIT:-30}"
HOME_MB="${USBSPLIT_HOME_MB:-256}"      # ext4 LANPARTY_HOME partition size (p1)
SHARE_MB="${USBSPLIT_SHARE_MB:-${USBSPLIT_CFG_MB:-64}}"  # exFAT PARTYSHARE size (p2)
SKIP_SINGLE="${USBSPLIT_SKIP_SINGLE:-0}"

USER_X="${USBSPLIT_USER:-raver7}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
TMPL="${REPO_ROOT}/boot/partyos-exfatsplit.ipxe.tmpl"
RENDERED_SPLIT="${REPO_ROOT}/boot/partyos-exfatsplit.ipxe"
RENDERED_SINGLE="${REPO_ROOT}/boot/partyos-exfatsplit-single.ipxe"
BOOTURL_SPLIT="${SERVER_URL}/boot/partyos-exfatsplit.ipxe"
BOOTURL_SINGLE="${SERVER_URL}/boot/partyos-exfatsplit-single.ipxe"

# Two-partition (split) stick + a single-ext4 (legacy) stick. git-ignored *.qcow2.
USB_SPLIT="${REPO_ROOT}/server/images/usbsplit-split.qcow2"
USB_SINGLE="${REPO_ROOT}/server/images/usbsplit-single.qcow2"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-usbsplit.XXXXXX")"
ACCESS="${RUN}/http_access.log"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ]; then rm -rf "${RUN}"; else
        echo "[usbsplit] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

# --- 0. ensure the custom image exists (it already ships exfat.ko + exfatprogs) -
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[usbsplit] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "USBSPLIT: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "USBSPLIT: FAIL - no custom sfs" >&2; exit 1; }
echo "[usbsplit] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

# --- 1. build the two-partition stick (split) + the single-ext4 stick ---------
SEED_SPLIT="usbsplit-split-$(date +%s)"
SEED_SINGLE="usbsplit-single-$(date +%s)"

echo "[usbsplit] building TWO-PARTITION stick -> ${USB_SPLIT##*/} (ext4 LANPARTY_HOME .partyos USERNAME=${USER_X} at root + home/ subdir; exFAT PARTYSHARE)" >&2
rm -f "${USB_SPLIT}"
USERNAME="${USER_X}" HOSTNAME="" \
    bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home-split \
    "${USB_SPLIT}" "${HOME_MB}" "${SEED_SPLIT}" "${USER_X}" "" "${SHARE_MB}" >&2 || {
    echo "USBSPLIT: FAIL - split USB build failed" >&2; exit 1; }
[ -f "${USB_SPLIT}" ] || { echo "USBSPLIT: FAIL - no split USB image" >&2; exit 1; }

if [ "${SKIP_SINGLE}" != "1" ]; then
    echo "[usbsplit] building single-ext4 stick -> ${USB_SINGLE##*/} (legacy, .partyos USERNAME=${USER_X} at ext4 root + home/ subdir, no PARTYSHARE)" >&2
    rm -f "${USB_SINGLE}"
    # HOME_SUBDIR=1 so the BAKED partyos-home-pull finds p2:/home; .partyos stays at
    # the ext4 ROOT (the legacy single-stick config path the OS reads).
    USERNAME="${USER_X}" HOSTNAME="" HOME_SUBDIR=1 \
        bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home \
        "${USB_SINGLE}" "${HOME_MB}" "${SEED_SINGLE}" "${USER_X}" "" >&2 || {
        echo "USBSPLIT: FAIL - single USB build failed" >&2; exit 1; }
    [ -f "${USB_SINGLE}" ] || { echo "USBSPLIT: FAIL - no single USB image" >&2; exit 1; }
fi

# --- 2. HOST-side filesystem-type assertion on the split qcow2 ----------------
# Convert qcow2 -> raw and probe each partition offset with blkid (-p -O OFFSET),
# confirming p1 is ext4 (LANPARTY_HOME) @1MiB and p2 is exFAT (PARTYSHARE) @
# (1+HOME_MB)MiB - the build-usbsplit.sh layout. On the KVM host this runs natively;
# if blkid tooling is absent it falls back to Docker.
host_fs_check() {
    local qcow="$1"
    local home_off=$(( 1 * 1024 * 1024 ))             # p1 ext4 LANPARTY_HOME @ 1MiB
    local share_off=$(( (1 + HOME_MB) * 1024 * 1024 ))  # p2 exFAT PARTYSHARE @ (1+HOME_MB)MiB
    local raw="${RUN}/usbsplit-host.raw"
    "${QEMU_IMG}" convert -f qcow2 -O raw "${qcow}" "${raw}" 2>/dev/null || return 1
    local probe
    probe() {
        # $1=offset -> "TYPE LABEL"
        if command -v blkid >/dev/null 2>&1; then
            local t l
            t="$(blkid -p -o value -s TYPE -O "$1" "${raw}" 2>/dev/null)"
            l="$(blkid -p -o value -s LABEL -O "$1" "${raw}" 2>/dev/null)"
            printf '%s %s' "${t}" "${l}"
        else
            docker run --rm --platform linux/amd64 --privileged -v "${raw}:/raw.img:ro" \
                archlinux:latest bash -c "
                    command -v blkid >/dev/null 2>&1 || { pacman -Sy --noconfirm --needed util-linux >/dev/null 2>&1 || { sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf; pacman -Sy --noconfirm --needed util-linux >/dev/null 2>&1; }; }
                    t=\$(blkid -p -o value -s TYPE -O $1 /raw.img 2>/dev/null)
                    l=\$(blkid -p -o value -s LABEL -O $1 /raw.img 2>/dev/null)
                    printf '%s %s' \"\$t\" \"\$l\"
                " 2>/dev/null
        fi
    }
    HOST_HOME="$(probe "${home_off}")"
    HOST_SHARE="$(probe "${share_off}")"
    rm -f "${raw}"
}
echo "[usbsplit] host-side fs-type check on ${USB_SPLIT##*/}..." >&2
HOST_HOME="" HOST_SHARE=""
host_fs_check "${USB_SPLIT}" || echo "[usbsplit] WARN host fs-check could not run" >&2
echo "[usbsplit] HOST p1 (ext4 home) : ${HOST_HOME}" >&2
echo "[usbsplit] HOST p2 (exFAT share): ${HOST_SHARE}" >&2
host_ext4_ok=0;  printf '%s' "${HOST_HOME}"  | grep -qw ext4  && printf '%s' "${HOST_HOME}"  | grep -qw LANPARTY_HOME && host_ext4_ok=1
host_exfat_ok=0; printf '%s' "${HOST_SHARE}" | grep -qw exfat && printf '%s' "${HOST_SHARE}" | grep -qw PARTYSHARE && host_exfat_ok=1

# --- 3. render the iPXE scripts (split + single compat variants) --------------
EXFATSPLIT_COMPAT=split  bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED_SPLIT}"  >&2 || { echo "USBSPLIT: FAIL render split" >&2; exit 1; }
EXFATSPLIT_COMPAT=single bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED_SINGLE}" >&2 || { echo "USBSPLIT: FAIL render single" >&2; exit 1; }

# --- 4. start HTTP server -----------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[usbsplit] HTTP server up pid=${SRV_PID}" >&2

# --- helpers ------------------------------------------------------------------
SERIAL=""
ser_has()   { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
vm_alive()  { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
count_ser() { tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -cF -- "$1"; }
report_line() { tail -c +"${LOG_OFFSET:-1}" "${ACCESS}" 2>/dev/null | grep -F "REPORT step=exfatsplit status=ok" | tail -1; }

# Boot ONE case; sets GOT_READY, STAYED, and the resolved R_* fields.
run_case() {
    local name="$1" usb="$2" booturl="$3"
    SERIAL="${RUN}/${name}.serial"
    local qmp="${RUN}/${name}.qmp" pidf="${RUN}/${name}.pid"
    LOG_OFFSET=$(( $(wc -c < "${ACCESS}" 2>/dev/null || echo 0) + 1 ))

    echo "[usbsplit] === case ${name}: booting with USB ${usb##*/} ===" >&2
    export RUN_DIR="${RUN}"
    bash "${SELF_DIR}/run-client.sh" --name "${name}" \
        --serial "${SERIAL}" --pidfile "${pidf}" --qmp "${qmp}" \
        --background \
        --boot-rom --bootfile "${booturl}" \
        --usb "${usb}" \
        --ram "${RAM_MB}" --timeout "${T}" >&2
    VM_PID="$(cat "${pidf}" 2>/dev/null || true)"
    echo "[usbsplit] case ${name} VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

    echo "[usbsplit] case ${name}: waiting up to ${T}s for exfatsplit-ready" >&2
    local deadline; deadline=$(( $(date +%s) + T ))
    GOT_READY=0
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if tail -c +"${LOG_OFFSET}" "${ACCESS}" 2>/dev/null | grep -qF "REPORT step=exfatsplit status=ok"; then GOT_READY=1; break; fi
        if ser_has "PARTYOS-EXFATSPLIT-READY"; then GOT_READY=1; break; fi
        if ! vm_alive; then echo "[usbsplit] case ${name} VM exited before ready" >&2; break; fi
        sleep 3
    done

    echo "----- case ${name} serial tail -----" >&2
    tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -40 >&2
    echo "----- case ${name} REPORT lines -----" >&2
    tail -c +"${LOG_OFFSET}" "${ACCESS}" 2>/dev/null | grep "REPORT step=exfatsplit" >&2 || echo "(none)" >&2
    echo "-------------------------------------" >&2

    # Confirm the system stays up.
    local alive_before; alive_before="$(count_ser 'PARTYOS-EXFATSPLIT-ALIVE')"
    STAYED=0
    local ddl; ddl=$(( $(date +%s) + ALIVE_WAIT ))
    while [ "$(date +%s)" -lt "${ddl}" ]; do
        local now; now="$(count_ser 'PARTYOS-EXFATSPLIT-ALIVE')"
        if [ "${now:-0}" -gt "${alive_before:-0}" ] && vm_alive; then STAYED=1; break; fi
        if ! vm_alive; then break; fi
        sleep 3
    done

    local rl; rl="$(report_line)"
    R_CFGFS="$(printf '%s' "${rl}" | grep -oE 'cfgfs=[^ ]+' | head -1 | cut -d= -f2)"
    R_USER="$(printf '%s' "${rl}" | grep -oE 'user=[^ ]+' | head -1 | cut -d= -f2)"
    R_USRC="$(printf '%s' "${rl}" | grep -oE 'usrc=[^ ]+' | head -1 | cut -d= -f2)"
    R_HOMEFS="$(printf '%s' "${rl}" | grep -oE 'homefs=[^ ]+' | head -1 | cut -d= -f2)"
    R_HOME="$(printf '%s' "${rl}" | grep -oE 'home=[^ ]+' | head -1 | cut -d= -f2)"
    R_SHAREFS="$(printf '%s' "${rl}" | grep -oE 'sharefs=[^ ]+' | head -1 | cut -d= -f2)"

    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    wait "${VM_PID}" 2>/dev/null || true
    VM_PID=""
}

# --- 5. CASE split ------------------------------------------------------------
run_case "split" "${USB_SPLIT}" "${BOOTURL_SPLIT}"
s_ready=$(( GOT_READY )); s_stayed=$(( STAYED ))
# config is read from the ext4 ROOT now (NOT exFAT); the exFAT partition is the share.
s_cfg_ok=0;  [ "${R_CFGFS}" = "ext4" ] && [ "${R_USRC}" = "ext4-root" ] && s_cfg_ok=1
s_user_ok=0; [ "${R_USER}" = "${USER_X}" ] && s_user_ok=1
s_home_ok=0; [ "${R_HOMEFS}" = "ext4" ] && [ "${R_HOME}" = "populated" ] && s_home_ok=1
s_share_ok=0; [ "${R_SHAREFS}" = "exfat" ] && s_share_ok=1
S_CFGFS="${R_CFGFS}"; S_USRC="${R_USRC}"; S_HOMEFS="${R_HOMEFS}"; S_USER="${R_USER}"; S_SHAREFS="${R_SHAREFS}"

# --- 6. CASE single (backward compat) -----------------------------------------
if [ "${SKIP_SINGLE}" != "1" ]; then
    run_case "single" "${USB_SINGLE}" "${BOOTURL_SINGLE}"
    c_ready=$(( GOT_READY )); c_stayed=$(( STAYED ))
    # single stick still reads .partyos from the ext4 ROOT (no PARTYSHARE present).
    c_cfg_ok=0;  [ "${R_USRC}" = "ext4-root" ] && c_cfg_ok=1
    c_user_ok=0; [ "${R_USER}" = "${USER_X}" ] && c_user_ok=1
    C_USRC="${R_USRC}"; C_USER="${R_USER}"
else
    c_ready=1 c_stayed=1 c_cfg_ok=1 c_user_ok=1 C_USRC="(skipped)" C_USER="(skipped)"
fi

# --- 7. verdict ---------------------------------------------------------------
echo "================ USBSPLIT VERDICT ===========================" >&2
echo "HOST: p1 ext4 LANPARTY_HOME present (${HOST_HOME})  : ${host_ext4_ok}" >&2
echo "HOST: p2 exFAT PARTYSHARE present (${HOST_SHARE})   : ${host_exfat_ok}" >&2
echo "(split)  ready=${s_ready} stayed=${s_stayed}" >&2
echo "    .partyos read from ext4 ROOT (cfgfs=${S_CFGFS} usrc=${S_USRC}) : ${s_cfg_ok}" >&2
echo "    USERNAME=${USER_X} resolved (got '${S_USER}')                  : ${s_user_ok}" >&2
echo "    home on ext4 LANPARTY_HOME home/ subdir, populated (homefs=${S_HOMEFS}) : ${s_home_ok}" >&2
echo "    exFAT PARTYSHARE share mounted (sharefs=${S_SHAREFS})          : ${s_share_ok}" >&2
echo "(single) ready=${c_ready} stayed=${c_stayed}" >&2
echo "    .partyos read from ext4 ROOT (usrc=${C_USRC})                  : ${c_cfg_ok}" >&2
echo "    USERNAME=${USER_X} resolved (got '${C_USER}')                  : ${c_user_ok}" >&2
echo "=============================================================" >&2

PASS=1
for v in "${host_exfat_ok}" "${host_ext4_ok}" \
         "${s_ready}" "${s_stayed}" "${s_cfg_ok}" "${s_user_ok}" "${s_home_ok}" "${s_share_ok}" \
         "${c_ready}" "${c_stayed}" "${c_cfg_ok}" "${c_user_ok}"; do
    [ "${v}" = "1" ] || PASS=0
done

# Tidy the per-case USB images (git-ignored, but keep the tree clean).
rm -f "${USB_SPLIT}" "${USB_SINGLE}" 2>/dev/null || true

if [ "${PASS}" -eq 1 ]; then
    echo "USBSPLIT: PASS" >&2
    exit 0
fi
echo "USBSPLIT: FAIL" >&2
exit 1
