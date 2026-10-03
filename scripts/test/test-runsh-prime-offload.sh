#!/usr/bin/env bash
# test-runsh-prime-offload.sh - hardware-free test for the nvidia GPU block of every
# blob run.sh.
#
# Bug: run.sh selected the nvidia GLX vendor whenever /dev/nvidia0 existed. On a hybrid
# laptop the X screen runs on the Intel or AMD iGPU, and X loads the nvidia GPU only as
# the GPU screen "NVIDIA-G0". Without PRIME render offload the NV-GLX request fails with
# BadValue, and SDL2 games (Warsow) exit at start.
#
# Fix: run.sh asks X for its providers. With an NVIDIA-G* provider it adds
# __NV_PRIME_RENDER_OFFLOAD=1 and __VK_LAYER_NV_optimus=NVIDIA_only. With no nvidia
# provider it skips the nvidia stack and points DRI_PRIME at the iGPU.
#
# This carves the real nvidia block from each run.sh template (build-app-blob.sh x2,
# build-baseenv-blob.sh, build-proton-blob.sh). It runs the block against a fake /dev,
# /usr/lib, /sys and a stub xrandr, then checks the bwrap arguments.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

B="${REPO_ROOT}/scripts/build"
T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-prime.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

echo "================ 1. every run.sh template is valid bash ==============="
# Carve each template: the single-quoted RUNSH strings and the baseenv heredoc.
awk -v d="${T}" '
    /^RUNSH=\x27#!\/bin\/bash$/ { n++; f=d "/tpl-app-" n ".sh"; print "#!/bin/bash" > f; c=1; next }
    c && /^\x27$/ { c=0; close(f); next }
    c { print > f }' "${B}/build-app-blob.sh"
# The proton template uses '\'' escapes, so print it with the builder's own
# PB_EMIT_RUNSH path (pure bash, no Docker). The game source is an empty dummy dir.
mkdir -p "${T}/gamesrc"
PB_EMIT_RUNSH=1 bash "${B}/build-proton-blob.sh" primetest "${T}/gamesrc" game.exe \
    > "${T}/tpl-proton.sh" 2>/dev/null
assert_true $? "build-proton-blob.sh: PB_EMIT_RUNSH prints the run.sh"
awk -v f="${T}/tpl-baseenv.sh" '
    /<<\x27PARTYOS_RUNSH\x27$/ { c=1; next }
    c && /^PARTYOS_RUNSH$/ { c=0; next }
    c { print > f }' "${B}/build-baseenv-blob.sh"
ntpl=0
for tpl in "${T}"/tpl-*.sh; do
    ntpl=$((ntpl+1))
    bash -n "${tpl}"; assert_true $? "$(basename "${tpl}"): bash -n"
    body="$(cat "${tpl}")"
    assert_contains "${body}" 'NV_MODE="$(nv_prime_mode)"' "$(basename "${tpl}"): probes the PRIME mode"
    assert_contains "${body}" "__NV_PRIME_RENDER_OFFLOAD 1" "$(basename "${tpl}"): sets PRIME render offload"
    assert_contains "${body}" "__VK_LAYER_NV_optimus NVIDIA_only" "$(basename "${tpl}"): sets the Vulkan optimus layer"
    assert_contains "${body}" 'DRI_PRIME "$IGPU"' "$(basename "${tpl}"): Mesa fallback pins DRI_PRIME"
done
# openra and the generic launcher in build-app-blob.sh, plus baseenv and proton.
assert_eq "${ntpl}" "4" "found all 4 run.sh templates with an nvidia block"

echo
echo "================ 2. run the REAL carved nvidia block =================="
# Fake host: nvidia libs, an nvidia ICD, and a hybrid sysfs (nvidia + i915 nodes).
F="${T}/host"
mkdir -p "${F}/dev" "${F}/usr/lib" "${F}/usr/share/vulkan/icd.d" "${F}/bin" \
         "${F}/drivers/nvidia" "${F}/drivers/i915" \
         "${F}/devices/0000:3c:00.0" "${F}/devices/0000:00:02.0" "${F}/sys/class/drm"
touch "${F}/usr/lib/libGLX_nvidia.so.0" "${F}/usr/share/vulkan/icd.d/nvidia_icd.json"
ln -s "${F}/drivers/nvidia" "${F}/devices/0000:3c:00.0/driver"
ln -s "${F}/drivers/i915" "${F}/devices/0000:00:02.0/driver"
mkdir -p "${F}/sys/class/drm/renderD128" "${F}/sys/class/drm/renderD129"
ln -s "${F}/devices/0000:3c:00.0" "${F}/sys/class/drm/renderD128/device"
ln -s "${F}/devices/0000:00:02.0" "${F}/sys/class/drm/renderD129/device"
# Stub xrandr prints $XRANDR_OUT, or fails if XRANDR_FAIL=1. Stub timeout runs its command.
cat > "${F}/bin/xrandr" <<'EOF'
#!/bin/bash
[ "${XRANDR_FAIL:-0}" = 1 ] && exit 1
printf '%b\n' "${XRANDR_OUT}"
EOF
printf '#!/bin/bash\nshift\nexec "$@"\n' > "${F}/bin/timeout"
chmod +x "${F}/bin/xrandr" "${F}/bin/timeout"

HYBRID='Providers: number : 2\nProvider 0: id: 0x47 cap: 0xb, Source Output, Sink Output, Sink Offload crtcs: 4 outputs: 5 associated providers: 0 name:Intel\nProvider 1: id: 0x253 cap: 0x0 crtcs: 0 outputs: 0 associated providers: 0 name:NVIDIA-G0'
NVONLY='Providers: number : 1\nProvider 0: id: 0x1b8 cap: 0x1, Source Output crtcs: 4 outputs: 6 associated providers: 0 name:NVIDIA-0'
INTELONLY='Providers: number : 1\nProvider 0: id: 0x47 cap: 0xb, Source Output, Sink Output, Sink Offload crtcs: 4 outputs: 5 associated providers: 0 name:Intel'

# carve <builder> <n>: the n-th region from "nv_prime_mode() {" to the closing fi of
# the nvidia if-block, with host paths moved into the fake root.
carve() {
    awk -v want="$2" '
        /^nv_prime_mode\(\) \{$/ { n++; if (n == want) c=1 }
        c { print }
        c && /^if \[ -e \/dev\/nvidia0 \]/ { g=1 }
        c && g && /^fi$/ { exit }' "$1" \
    | sed -e "s#/dev/nvidia0#${F}/dev/nvidia0#g" \
          -e "s#/usr/share/vulkan/icd.d#${F}/usr/share/vulkan/icd.d#g" \
          -e "s#/etc/vulkan/icd.d#${F}/etc/vulkan/icd.d#g" \
          -e "s#for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu#for d in ${F}/usr/lib#" \
          -e "s#/sys/class/drm#${F}/sys/class/drm#g"
}

# run_block <file>: source the carved block and print one bwrap argument per line.
run_block() {
    ( PATH="${F}/bin:${PATH}"; SCRATCH="${T}"; RUNHOME="${T}"; args=()
      # shellcheck disable=SC1090
      source "$1"; printf '%s\n' "${args[@]}" )
}

for spec in "build-app-blob.sh 1" "build-app-blob.sh 2" "build-baseenv-blob.sh 1" "build-proton-blob.sh 1"; do
    set -- ${spec}
    lbl="$1#$2"; blk="${T}/blk-${1%.sh}-$2.sh"
    carve "${B}/$1" "$2" > "${blk}"
    assert_contains "$(cat "${blk}")" "__GLX_VENDOR_LIBRARY_NAME nvidia" "${lbl}: carved the nvidia block"
    touch "${F}/dev/nvidia0"

    out="$(XRANDR_OUT="${HYBRID}" run_block "${blk}")"
    assert_contains "${out}" "__GLX_VENDOR_LIBRARY_NAME" "${lbl} hybrid: nvidia GLX vendor"
    assert_contains "${out}" "__NV_PRIME_RENDER_OFFLOAD" "${lbl} hybrid: PRIME render offload"
    assert_contains "${out}" "__VK_LAYER_NV_optimus" "${lbl} hybrid: Vulkan optimus layer"
    assert_not_contains "${out}" "DRI_PRIME" "${lbl} hybrid: no DRI_PRIME"

    out="$(XRANDR_OUT="${NVONLY}" run_block "${blk}")"
    assert_contains "${out}" "__GLX_VENDOR_LIBRARY_NAME" "${lbl} nvidia X screen: nvidia GLX vendor"
    assert_not_contains "${out}" "__NV_PRIME_RENDER_OFFLOAD" "${lbl} nvidia X screen: no offload"

    out="$(XRANDR_FAIL=1 run_block "${blk}")"
    assert_contains "${out}" "__GLX_VENDOR_LIBRARY_NAME" "${lbl} xrandr fails: nvidia GLX vendor (old path)"
    assert_not_contains "${out}" "__NV_PRIME_RENDER_OFFLOAD" "${lbl} xrandr fails: no offload"

    out="$(XRANDR_OUT="${INTELONLY}" run_block "${blk}")"
    assert_not_contains "${out}" "__GLX_VENDOR_LIBRARY_NAME" "${lbl} no nvidia provider: no nvidia vendor"
    assert_not_contains "${out}" "/nvidia/" "${lbl} no nvidia provider: no nvidia libs bound"
    assert_contains "${out}" "pci-0000_00_02_0" "${lbl} no nvidia provider: DRI_PRIME is the i915 node"

    rm -f "${F}/dev/nvidia0"
    out="$(XRANDR_OUT="${HYBRID}" run_block "${blk}")"
    assert_eq "${out}" "" "${lbl} no /dev/nvidia0: block adds nothing"
done

assert_summary
