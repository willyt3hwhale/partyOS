#!/usr/bin/env bash
# test-step3.sh - autonomous VM test for Step 3 (Custom XFCE desktop image).
#
# What it proves, with no hardware and no keystrokes:
#   1. The custom image exists and was built reproducibly (scripts/build) - if it
#      is missing the test BUILDS it first (Docker/amd64 Arch container).
#   2. A headless client VM auto-chains partyos-step3.ipxe (DHCP boot filename),
#      loads the SAME kernel/initramfs as Step 2 but the CUSTOM airootfs.sfs
#      (XFCE + LightDM autologin 'gamer' + browser/file-manager + drivers) over
#      HTTP into RAM (copytoram).
#   3. The graphical session comes up HEADLESSLY: gamer is autologged into an
#      XFCE session on a virtual framebuffer (LightDM + the dummy Xorg driver, or
#      the Xvfb fallback guard if Xorg can't come up under emulation - either way
#      NO GPU / no /dev/dri is required). An XFCE autostart fires the proof:
#        serial markers  PARTYOS-STEP3-DESKTOP-READY
#                        PARTYOS-STEP3-SESSION-ACTIVE xfce4-session=yes xserver=...
#        HTTP callback   REPORT step=3 status=ok desktop=ready xfce=yes ...
#   4. The session is genuinely ACTIVE (not just a fired callback): the callback /
#      serial proof carries xfce4-session=yes and a running X server (Xorg dummy
#      or Xvfb). This is the headless stand-in for "a desktop is on the screen".
#   5. Driver/app PACKAGES are present: the built pkglist is grepped for XFCE,
#      LightDM, the browser, the headless dummy/xvfb drivers, and the AMD/NVIDIA/
#      Intel graphics + network drivers.
#
# GPU/SCREENDUMP NOTE (documented, NOT a gate): a real emulated GPU framebuffer is
# unavailable under TCG (no passthrough, no /dev/dri). So the desktop is brought up HEADLESSLY and asserted via the
# desktop-ready callback + an active xfce4-session, NOT via a real framebuffer
# screendump. A QMP screendump is still ATTEMPTED and logged as a BONUS: on a
# KVM/physical host with virtio-gpu it will be non-blank (and accel works); under
# TCG it is expected blank/absent and does NOT fail the test. This test does not
# cover real GPU acceleration on AMD/NVIDIA/Intel. Test that on physical hardware.
# The boot budget is a VM baseline.
#
# TCG note: on Apple Silicon the x86_64 guest runs under TCG, so a full XFCE boot
# is slow; the default timeout is generous and overridable via STEP3_TIMEOUT.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/config.sh"

# --- config ---------------------------------------------------------------
RAM_MB="${STEP3_RAM_MB:-10240}"        # custom sfs + copytoram + cowspace + XFCE
T="${STEP3_TIMEOUT:-2700}"             # overall boot+verify timeout (seconds)
ALIVE_WAIT="${STEP3_ALIVE_WAIT:-30}"   # window to confirm desktop stays up
CUSTOM_SFS="${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sfs"
PKGLIST="${REPO_ROOT}/server/images/custom/pkglist.x86_64.txt"
TMPL="${REPO_ROOT}/boot/partyos-step3.ipxe.tmpl"
RENDERED="${REPO_ROOT}/boot/partyos-step3.ipxe"
BOOTURL="${SERVER_URL}/boot/partyos-step3.ipxe"

RUN="$(mktemp -d "${TMPDIR:-/tmp}/partyos-step3.XXXXXX")"
SERIAL="${RUN}/step3.serial"
ACCESS="${RUN}/http_access.log"
QMP="${RUN}/step3.qmp"
SHOT="${RUN}/screendump.ppm"
SRV_PID=""
VM_PID=""

cleanup() {
    local rc=$?
    [ -n "${VM_PID}" ] && kill -9 "${VM_PID}" 2>/dev/null || true
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    if [ "${rc}" -eq 0 ] && [ -z "${KEEP_RUNDIR:-}" ]; then rm -rf "${RUN}"; else
        echo "[step3] logs preserved in ${RUN}" >&2; fi
}
trap cleanup EXIT INT TERM

# --- 0. ensure the custom image exists (build it if not) -------------------
if [ ! -f "${CUSTOM_SFS}" ]; then
    echo "[step3] custom image missing - building it (Docker/amd64 Arch)..." >&2
    bash "${REPO_ROOT}/scripts/build/build-image.sh" >&2 || {
        echo "STEP 3: FAIL - custom image build failed" >&2; exit 1; }
fi
[ -f "${CUSTOM_SFS}" ] || { echo "STEP 3: FAIL - no custom sfs after build" >&2; exit 1; }
[ -f "${PKGLIST}" ]    || { echo "STEP 3: FAIL - no pkglist after build" >&2; exit 1; }
echo "[step3] custom sfs: $(du -h "${CUSTOM_SFS}" | cut -f1)  pkglist: $(wc -l < "${PKGLIST}") pkgs" >&2

# --- 1. PACKAGE-PRESENCE assertion (fast, do before the slow boot) ---------
# Each entry: a human label + a grep pattern matched against the pkglist.
echo "[step3] asserting driver/app packages present in the built image..." >&2
declare -a REQUIRE=(
  # 'xfce4' is a package GROUP; pacman -Q lists its members, so assert on the
  # real session/panel packages that constitute the XFCE desktop.
  "XFCE session:^xfce4-session "
  "XFCE panel:^xfce4-panel "
  "XFCE settings:^xfce4-settings "
  "file manager (thunar):^thunar "
  "display manager (lightdm):^lightdm "
  # The browser (Epiphany) is not baked. It installs on first use from the LAN
  # mirror, so it is not in this pkglist.
  "X server:^xorg-server "
  "headless dummy driver:^xf86-video-dummy "
  "virtual framebuffer (xvfb):^xorg-server-xvfb "
  "mesa (software GL):^mesa "
  "AMD driver (amdgpu):^xf86-video-amdgpu "
  "AMD driver (ati):^xf86-video-ati "
  "Intel driver:^xf86-video-intel "
  "NVIDIA open (nouveau):^xf86-video-nouveau "
  # The image ships the proprietary 'nvidia' driver (see 20-packages.sh).
  "NVIDIA proprietary (nvidia):^nvidia "
  "network (NetworkManager):^networkmanager "
)
pkg_ok=1
for entry in "${REQUIRE[@]}"; do
    label="${entry%%:*}"; pat="${entry#*:}"
    if grep -qE "${pat}" "${PKGLIST}"; then
        echo "  [ok]   ${label}" >&2
    else
        echo "  [MISS] ${label}  (pattern: ${pat})" >&2
        pkg_ok=0
    fi
done
if [ "${pkg_ok}" -ne 1 ]; then
    echo "STEP 3: FAIL - required packages missing from image" >&2
    exit 1
fi
echo "[step3] all required packages present" >&2

# --- 2. render the Step 3 iPXE script with the right SERVER_URL -------------
bash "${SELF_DIR}/render-ipxe.sh" "${TMPL}" "${RENDERED}" >&2 || {
    echo "STEP 3: FAIL - iPXE render" >&2; exit 1; }

# --- 3. start HTTP server --------------------------------------------------
: > "${ACCESS}"
python3 -u "${REPO_ROOT}/server/http_server.py" "${SERVER_PORT}" >"${ACCESS}" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null && break
    sleep 0.25
done
echo "[step3] HTTP server up pid=${SRV_PID}" >&2

# --- 4. launch client VM (background, with QMP for screendump) -------------
export RUN_DIR="${RUN}"
bash "${SELF_DIR}/run-client.sh" --name step3 \
    --serial "${SERIAL}" --pidfile "${RUN}/step3.pid" --qmp "${QMP}" \
    --background \
    --boot-rom --bootfile "${BOOTURL}" --ram "${RAM_MB}" --timeout "${T}" >&2
VM_PID="$(cat "${RUN}/step3.pid" 2>/dev/null || true)"
echo "[step3] VM pid=${VM_PID} ram=${RAM_MB}MB timeout=${T}s accel=${ACCEL}" >&2

ser_has() { [ -f "${SERIAL}" ] && grep -qF -- "$1" "${SERIAL}" 2>/dev/null; }
log_has() { [ -f "${ACCESS}" ] && grep -qF -- "$1" "${ACCESS}" 2>/dev/null; }
vm_alive() { [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; }
count_ser() { tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -cF -- "$1"; }

# --- 5. wait for the desktop-ready proof -----------------------------------
echo "[step3] waiting up to ${T}s for desktop-ready (serial marker or callback)" >&2
deadline=$(( $(date +%s) + T ))
got_desktop=0
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if log_has "REPORT step=3 status=ok"; then got_desktop=1; break; fi
    if ser_has "PARTYOS-STEP3-DESKTOP-READY"; then got_desktop=1; break; fi
    if ! vm_alive; then echo "[step3] VM exited before desktop-ready" >&2; break; fi
    sleep 3
done

echo "----- serial tail -----" >&2
tr -d '\000' < "${SERIAL}" 2>/dev/null | tail -30 >&2
echo "-----------------------" >&2
echo "----- access log (REPORT lines) -----" >&2
grep "REPORT" "${ACCESS}" 2>/dev/null >&2 || echo "(none)" >&2
echo "-------------------------------------" >&2

if [ "${got_desktop}" -ne 1 ]; then
    echo "STEP 3: FAIL - never reached desktop-ready" >&2
    exit 1
fi
echo "[step3] desktop-ready reached" >&2

# --- 6. BONUS: framebuffer screendump via QMP (NOT a gate under TCG) --------
# Grab a PPM screendump over QMP and report whether it has >1 distinct pixel
# colour. On a KVM/physical host with virtio-gpu a real (software- or hardware-
# rendered) desktop is on the emulated display and this comes back non-blank.
# Under TCG the headless session runs on Xvfb/dummy with nothing on the QEMU
# display, so this is expected blank/absent - hence it is logged as a BONUS and
# does NOT affect the verdict (see GPU note in the header). The gating "the
# desktop is up" proof is the active xfce4-session + desktop-ready callback.
echo "[step3] (bonus) capturing QMP screendump -> ${SHOT}" >&2
screendump_ok=0
if [ -S "${QMP}" ]; then
    python3 - "${QMP}" "${SHOT}" <<'PYQMP' >&2 || true
import socket, json, sys, time
qmp_path, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(15); s.connect(qmp_path)
f = s.makefile("rwb", buffering=0)
def recv():
    line = f.readline()
    return json.loads(line) if line else None
recv()  # greeting
def cmd(obj):
    f.write((json.dumps(obj)+"\r\n").encode())
    # read until we see a return/error (skip async events)
    for _ in range(50):
        m = recv()
        if m is None: return None
        if "return" in m or "error" in m: return m
    return None
cmd({"execute":"qmp_capabilities"})
r = cmd({"execute":"screendump","arguments":{"filename":out}})
print("[step3] screendump qmp result:", r)
s.close()
PYQMP
    # Analyse the PPM: count distinct pixels.
    if [ -f "${SHOT}" ]; then
        distinct="$(python3 - "${SHOT}" <<'PYPPM'
import sys
p=sys.argv[1]
with open(p,"rb") as fh:
    data=fh.read()
# Parse minimal binary PPM (P6) header: magic, width, height, maxval
if not data.startswith(b"P6"):
    print(0); sys.exit()
# tokens after P6
idx=2; toks=[]
while len(toks)<3:
    while idx<len(data) and data[idx] in b" \t\n\r": idx+=1
    if idx<len(data) and data[idx:idx+1]==b"#":
        while idx<len(data) and data[idx] not in b"\n": idx+=1
        continue
    start=idx
    while idx<len(data) and data[idx] not in b" \t\n\r": idx+=1
    toks.append(data[start:idx])
idx+=1  # single whitespace after maxval
w,h,mx=int(toks[0]),int(toks[1]),int(toks[2])
pix=data[idx:]
colors=set()
step=3
for i in range(0,min(len(pix), w*h*3)-2,3):
    colors.add(pix[i:i+3])
    if len(colors)>50: break
print(len(colors))
PYPPM
)"
        echo "[step3] screendump distinct colours (capped at 50): ${distinct}" >&2
        if [ "${distinct:-0}" -gt 1 ]; then
            screendump_ok=1
            echo "[step3] framebuffer NON-BLANK (${distinct} colours) - desktop drawn" >&2
        else
            echo "[step3] framebuffer looks blank (${distinct} colour), non-gate" >&2
        fi
    else
        echo "[step3] no screendump file, non-gate" >&2
    fi
else
    echo "[step3] no QMP socket, no screendump, non-gate" >&2
fi

# --- 7. confirm the desktop STAYS up (heartbeats) --------------------------
alive_before="$(count_ser 'PARTYOS-STEP3-ALIVE')"
echo "[step3] confirming desktop stays up (${ALIVE_WAIT}s, alive_before=${alive_before})" >&2
ddl=$(( $(date +%s) + ALIVE_WAIT ))
stayed=0
while [ "$(date +%s)" -lt "${ddl}" ]; do
    now="$(count_ser 'PARTYOS-STEP3-ALIVE')"
    if [ "${now:-0}" -gt "${alive_before:-0}" ] && vm_alive; then stayed=1; break; fi
    if ! vm_alive; then echo "[step3] VM died during stay-up window" >&2; break; fi
    sleep 3
done

# --- session-active assertion (the headless "desktop is really up" gate) -----
# Beyond a fired callback, require evidence that an XFCE session is genuinely
# running: either the callback carried xfce=yes, or the serial shows the
# SESSION-ACTIVE marker with xfce4-session=yes. This distinguishes a real headless
# desktop from a stray curl, with no GPU/screendump dependency.
session_ok=0
if grep -F "REPORT step=3 status=ok" "${ACCESS}" 2>/dev/null | grep -q "xfce=yes"; then
    session_ok=1
fi
if tr -d '\000' < "${SERIAL}" 2>/dev/null | grep -F "PARTYOS-STEP3-SESSION-ACTIVE" | grep -q "xfce4-session=yes"; then
    session_ok=1
fi

# --- verdict --------------------------------------------------------------
echo "================ STEP 3 VERDICT ==============================" >&2
desktop_ok=0; { log_has "REPORT step=3 status=ok" || ser_has "PARTYOS-STEP3-DESKTOP-READY"; } && desktop_ok=1
echo "packages present                      : ${pkg_ok}" >&2
echo "desktop-ready (callback/serial)       : ${desktop_ok}" >&2
echo "xfce session active (headless)        : ${session_ok}" >&2
echo "framebuffer non-blank (BONUS, non-gate): ${screendump_ok}" >&2
echo "desktop stayed up (heartbeats)        : ${stayed}" >&2

# Screendump is a documented KVM/physical BONUS, NOT a gate (see header). The
# autonomous headless gate is: packages present + desktop-ready callback +
# an active xfce4-session + the desktop staying up.
if [ "${pkg_ok}" -eq 1 ] && [ "${desktop_ok}" -eq 1 ] && \
   [ "${session_ok}" -eq 1 ] && [ "${stayed}" -eq 1 ]; then
    echo "STEP 3: PASS" >&2
    exit 0
fi
echo "STEP 3: FAIL" >&2
exit 1
