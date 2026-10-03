#!/usr/bin/env bash
# test-identity.sh - autonomous VM test for the partyOS dynamic IDENTITY feature
# (the USB `.partyos` config drives the desktop ACCOUNT NAME + the HOSTNAME).
#
# Modelled on test-step4.sh. It boots the SAME custom image three times, each
# with a differently-seeded LANPARTY_HOME stick, and asserts the outcome from a
# REAL booted VM (serial markers + a step=identity HTTP callback). The IDENTITY
# logic under test is BAKED into the image (partyos-identity.service ->
# partyos-identity-setup, see scripts/build/files/rootfs/); the fetched
# identity-script.sh mounts the stick, runs that baked resolver, populates the
# resolved user's home, then emits the proof.
#
# Three cases (each a full boot):
#   (a) USB `.partyos` USERNAME=raver7 (no HOSTNAME)
#         -> session user raver7, uid 1000, `sudo -n true` works,
#            /home/raver7 has the USB seed, hostname matches raver7-[0-9a-f]{4}
#            (DERIVED <username>-<4hex-of-MAC-hash>).
#   (b) USB `.partyos` USERNAME=raver7 + explicit HOSTNAME=lan-rig-01
#         -> hostname is EXACTLY lan-rig-01 (explicit override wins).
#   (c) NO `.partyos` on the stick
#         -> user gamer (fallback), hostname matches partyos-[0-9a-f]{4}.
#
# TCG note: on Apple Silicon the x86_64 guest runs under TCG, so a full RAM boot
# of the custom image is slow; run this on a KVM host via remote-test.sh.
# Timeouts are generous and overridable (IDENTITY_TIMEOUT per boot).

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ----------------------------------------------------------------
RAM_MB="${IDENTITY_RAM_MB:-10240}"        # custom sfs + copytoram + cowspace + DE
T="${IDENTITY_TIMEOUT:-2700}"             # per-boot boot+verify timeout (seconds)
ALIVE_WAIT="${IDENTITY_ALIVE_WAIT:-30}"   # window to confirm system stays up
USB_MB="${IDENTITY_USB_MB:-256}"

# The expected account name for case (a)/(b) and the explicit hostname for (b).
USER_A="${IDENTITY_USER:-raver7}"
HOST_B="${IDENTITY_HOSTNAME:-lan-rig-01}"

CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
TMPL="${REPO_ROOT}/boot/partyos-identity.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-identity.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-identity.ipxe"

# Per-case USB images (git-ignored *.qcow2).
USB_A="${REPO_ROOT}/server/images/usbhome-identity-a.qcow2"
USB_B="${REPO_ROOT}/server/images/usbhome-identity-b.qcow2"
USB_C="${REPO_ROOT}/server/images/usbhome-identity-c.qcow2"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-identity.XXXXXX")"
ACCESS="${RUN}/http_access.log"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ]; then rm -rf "${RUN}"; else
        echo "[identity] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

# --- 0. ensure the custom image exists (it carries the baked identity svc) ---
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[identity] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "IDENTITY: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "IDENTITY: FAIL - no custom sfs" >&2; exit 1; }
echo "[identity] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)" >&2

# --- 1. build the three USB home sticks (rebuilt fresh every run) -----------
# Each case gets a uniquely-tagged seed so the home-population proof ties to the
# exact stick. USERNAME/HOSTNAME on the stick are what the baked resolver reads.
#   A: USERNAME=raver7                 (derived hostname expected)
#   B: USERNAME=raver7 HOSTNAME=...    (explicit hostname expected)
#   C: (no USERNAME -> no .partyos)    (gamer + partyos-<hex> expected)
build_usb() {
    local out="$1" tag="$2" uname="$3" hname="$4"
    echo "[identity] building USB ${out##*/} (tag=${tag} USERNAME='${uname}' HOSTNAME='${hname}')" >&2
    rm -f "${out}"
    USERNAME="${uname}" HOSTNAME="${hname}" \
        bash "${REPO_ROOT}/scripts/create_usb.sh" --image-home "${out}" "${USB_MB}" "${tag}" "${uname}" "${hname}" >&2 || {
        echo "IDENTITY: FAIL - USB build failed for ${out}" >&2; exit 1; }
    [ -f "${out}" ] || { echo "IDENTITY: FAIL - no USB image ${out}" >&2; exit 1; }
}
SEED_A="identity-a-$(date +%s)"
SEED_B="identity-b-$(date +%s)"
SEED_C="identity-c-$(date +%s)"
build_usb "${USB_A}" "${SEED_A}" "${USER_A}" ""
build_usb "${USB_B}" "${SEED_B}" "${USER_A}" "${HOST_B}"
build_usb "${USB_C}" "${SEED_C}" "" ""

# --- 2. render the identity iPXE script ------------------------------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || {
    echo "IDENTITY: FAIL - iPXE render" >&2; exit 1; }

# --- 3. start the HTTP server (shared across the three boots) ---------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[identity] HTTP server up pid=${SRV_PID}" >&2

# --- helpers ---------------------------------------------------------------
SERIAL=""
ser_has()   { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
ser_re()    { [ -f "${SERIAL}" ] && tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -qE -- "$1"; }
vm_alive()  { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
count_ser() { tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -cF -- "$1"; }
# Pull the report query string for the most recent ok callback in THIS boot's
# access-log slice (set by run_case to the byte offset before the boot).
report_line() { tail -c +"${LOG_OFFSET:-1}" "${ACCESS}" 2>/dev/null | grep -F "REPORT step=identity status=ok" | tail -1; }

# Run ONE case: boot the image with the given USB, wait for the identity-ready
# proof, confirm it stays up, then return the resolved user/hostname for the
# caller to assert. Sets globals: GOT_READY, STAYED, R_USER, R_UID, R_SUDO,
# R_HOME, R_HOST, R_HSRC, SERIAL (for the caller's own grepping).
run_case() {
    local name="$1" usb="$2"
    SERIAL="${RUN}/${name}.serial"
    local qmp="${RUN}/${name}.qmp" pidf="${RUN}/${name}.pid"
    LOG_OFFSET=$(( $(wc -c < "${ACCESS}" 2>/dev/null || echo 0) + 1 ))

    echo "[identity] === case ${name}: booting with USB ${usb##*/} ===" >&2
    export RUN_DIR="${RUN}"
    bash "${SELF_DIR}/run-client.sh" --name "${name}" \
        --serial "${SERIAL}" --pidfile "${pidf}" --qmp "${qmp}" \
        --background \
        --boot-rom --bootfile "${BOOTURL}" \
        --usb "${usb}" \
        --ram "${RAM_MB}" --timeout "${T}" >&2
    VM_PID="$(cat "${pidf}" 2>/dev/null || true)"
    echo "[identity] case ${name} VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

    echo "[identity] case ${name}: waiting up to ${T}s for identity-ready" >&2
    local deadline; deadline=$(( $(date +%s) + T ))
    GOT_READY=0
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if tail -c +"${LOG_OFFSET}" "${ACCESS}" 2>/dev/null | grep -qF "REPORT step=identity status=ok"; then GOT_READY=1; break; fi
        if ser_has "PARTYOS-IDENTITY-READY"; then GOT_READY=1; break; fi
        if ! vm_alive; then echo "[identity] case ${name} VM exited before ready" >&2; break; fi
        sleep 3
    done

    echo "----- case ${name} serial tail -----" >&2
    tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -40 >&2
    echo "----- case ${name} REPORT lines -----" >&2
    tail -c +"${LOG_OFFSET}" "${ACCESS}" 2>/dev/null | grep "REPORT step=identity" >&2 || echo "(none)" >&2
    echo "-------------------------------------" >&2

    # Confirm the system stays up (heartbeats).
    local alive_before; alive_before="$(count_ser 'PARTYOS-IDENTITY-ALIVE')"
    STAYED=0
    local ddl; ddl=$(( $(date +%s) + ALIVE_WAIT ))
    while [ "$(date +%s)" -lt "${ddl}" ]; do
        local now; now="$(count_ser 'PARTYOS-IDENTITY-ALIVE')"
        if [ "${now:-0}" -gt "${alive_before:-0}" ] && vm_alive; then STAYED=1; break; fi
        if ! vm_alive; then break; fi
        sleep 3
    done

    # Extract the resolved values from the ok callback (authoritative), falling
    # back to the serial marker if the callback query is unavailable.
    local rl; rl="$(report_line)"
    R_USER="$(printf '%s' "${rl}" | grep -oE 'user=[^ ]+' | head -1 | cut -d= -f2)"
    R_UID="$(printf '%s' "${rl}" | grep -oE 'uid=[^ ]+' | head -1 | cut -d= -f2)"
    R_SUDO="$(printf '%s' "${rl}" | grep -oE 'sudo=[^ ]+' | head -1 | cut -d= -f2)"
    R_HOME="$(printf '%s' "${rl}" | grep -oE 'home=[^ ]+' | head -1 | cut -d= -f2)"
    R_HOST="$(printf '%s' "${rl}" | grep -oE 'hostname=[^ ]+' | head -1 | cut -d= -f2)"
    R_HSRC="$(printf '%s' "${rl}" | grep -oE 'hsrc=[^ ]+' | head -1 | cut -d= -f2)"

    # Free the VM for the next case.
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    wait "${VM_PID}" 2>/dev/null || true
    VM_PID=""
}

# --- 4. case (a): USERNAME=raver7 -> derived hostname -----------------------
run_case "identity-a" "${USB_A}"
a_user_ok=0;  [ "${R_USER}" = "${USER_A}" ] && [ "${R_UID}" = "1000" ] && a_user_ok=1
a_sudo_ok=0;  [ "${R_SUDO}" = "1" ] && a_sudo_ok=1
a_home_ok=0;  [ "${R_HOME}" = "populated" ] && a_home_ok=1
# hostname must be the DERIVED <username>-<4hex>.
a_host_ok=0;  printf '%s' "${R_HOST}" | grep -qE "^${USER_A}-[0-9a-f]{4}$" && a_host_ok=1
a_ready=$(( GOT_READY )); a_stayed=$(( STAYED ))
A_HOST="${R_HOST}"; A_HSRC="${R_HSRC}"

# --- 5. case (b): explicit HOSTNAME= overrides ------------------------------
run_case "identity-b" "${USB_B}"
b_user_ok=0;  [ "${R_USER}" = "${USER_A}" ] && [ "${R_UID}" = "1000" ] && b_user_ok=1
# hostname must be EXACTLY the explicit override.
b_host_ok=0;  [ "${R_HOST}" = "${HOST_B}" ] && b_host_ok=1
b_src_ok=0;   [ "${R_HSRC}" = "explicit" ] && b_src_ok=1
b_ready=$(( GOT_READY )); b_stayed=$(( STAYED ))
B_HOST="${R_HOST}"; B_HSRC="${R_HSRC}"

# --- 6. case (c): no .partyos -> gamer + partyos-<hex> ----------------------
run_case "identity-c" "${USB_C}"
c_user_ok=0;  [ "${R_USER}" = "gamer" ] && [ "${R_UID}" = "1000" ] && c_user_ok=1
c_host_ok=0;  printf '%s' "${R_HOST}" | grep -qE "^partyos-[0-9a-f]{4}$" && c_host_ok=1
c_ready=$(( GOT_READY )); c_stayed=$(( STAYED ))
C_USER="${R_USER}"; C_HOST="${R_HOST}"

# --- 7. verdict ------------------------------------------------------------
echo "================ IDENTITY VERDICT ===========================" >&2
echo "(a) USERNAME=${USER_A}: ready=${a_ready} stayed=${a_stayed}" >&2
echo "    user=${USER_A} uid=1000                : ${a_user_ok}" >&2
echo "    passwordless sudo (sudo -n true)       : ${a_sudo_ok}" >&2
echo "    /home/${USER_A} has USB seed           : ${a_home_ok}" >&2
echo "    hostname '${A_HOST}' = ${USER_A}-[0-9a-f]{4} (src=${A_HSRC}): ${a_host_ok}" >&2
echo "(b) explicit HOSTNAME=${HOST_B}: ready=${b_ready} stayed=${b_stayed}" >&2
echo "    user=${USER_A} uid=1000                : ${b_user_ok}" >&2
echo "    hostname '${B_HOST}' = '${HOST_B}' exactly (src=${B_HSRC}): ${b_host_ok}" >&2
echo "    hostname source reported explicit      : ${b_src_ok}" >&2
echo "(c) no .partyos: ready=${c_ready} stayed=${c_stayed}" >&2
echo "    user '${C_USER}' = gamer, uid=1000     : ${c_user_ok}" >&2
echo "    hostname '${C_HOST}' = partyos-[0-9a-f]{4}: ${c_host_ok}" >&2
echo "=============================================================" >&2

PASS=1
for v in "${a_ready}" "${a_stayed}" "${a_user_ok}" "${a_sudo_ok}" "${a_home_ok}" "${a_host_ok}" \
         "${b_ready}" "${b_stayed}" "${b_user_ok}" "${b_host_ok}" "${b_src_ok}" \
         "${c_ready}" "${c_stayed}" "${c_user_ok}" "${c_host_ok}"; do
    [ "${v}" = "1" ] || PASS=0
done

# Tidy the per-case USB images (git-ignored, but keep the tree clean).
rm -f "${USB_A}" "${USB_B}" "${USB_C}" 2>/dev/null || true

if [ "${PASS}" -eq 1 ]; then
    echo "IDENTITY: PASS" >&2
    exit 0
fi
echo "IDENTITY: FAIL" >&2
exit 1
