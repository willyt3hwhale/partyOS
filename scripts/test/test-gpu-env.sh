#!/usr/bin/env bash
# test-gpu-env.sh - hardware-free test for partyos-gpu-env and its launch wiring
#
# The served blobs force the nvidia GLX vendor when /dev/nvidia0 exists. On a hybrid
# laptop that needs PRIME render offload. The image fixes this without a blob rebuild:
# partyos-gpu-env prints the env, and partyos-app / partyos-proton-env pass it to run.sh.
#
# This runs the real partyos-gpu-env against a fake /sys/class/drm and a stub xrandr.
# Then it checks that every launch path passes the env, and that run.sh keeps the env.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

BIN="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin"
GPUENV="${BIN}/partyos-gpu-env"
T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-gpuenv.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

echo "================ 1. partyos-gpu-env on fake hosts ======================"
# mkgpu <drm-dir> <renderD name> <pci addr> <driver>
mkgpu() {
    mkdir -p "${T}/drivers/$4" "${T}/devices/$3" "$1/$2"
    ln -sfn "${T}/drivers/$4" "${T}/devices/$3/driver"
    ln -sfn "${T}/devices/$3" "$1/$2/device"
}
HYB="${T}/drm-hybrid";  mkgpu "${HYB}" renderD128 0000:3c:00.0 nvidia; mkgpu "${HYB}" renderD129 0000:00:02.0 i915
AMD="${T}/drm-amd";     mkgpu "${AMD}" renderD128 0000:01:00.0 nvidia; mkgpu "${AMD}" renderD129 0000:05:00.0 amdgpu
ONE="${T}/drm-nvonly";  mkgpu "${ONE}" renderD128 0000:01:00.0 nvidia
IGP="${T}/drm-intel";   mkgpu "${IGP}" renderD128 0000:00:02.0 i915
touch "${T}/nvidia0"

mkdir -p "${T}/bin"
cat > "${T}/bin/xrandr" <<'EOF'
#!/bin/bash
[ "${XRANDR_FAIL:-0}" = 1 ] && exit 1
printf '%b\n' "${XRANDR_OUT}"
EOF
printf '#!/bin/bash\nshift\nexec "$@"\n' > "${T}/bin/timeout"
chmod +x "${T}/bin/xrandr" "${T}/bin/timeout"

P_HYB='Providers: number : 2\nProvider 0: id: 0x47 cap: 0xb, Source Output, Sink Output, Sink Offload crtcs: 4 outputs: 5 associated providers: 0 name:Intel\nProvider 1: id: 0x253 cap: 0x0 crtcs: 0 outputs: 0 associated providers: 0 name:NVIDIA-G0'
P_AMD='Providers: number : 2\nProvider 0: id: 0x54 cap: 0xf, Source Output, Sink Output, Source Offload, Sink Offload crtcs: 4 outputs: 4 associated providers: 0 name:AMD Radeon Graphics @ pci:0000:05:00.0\nProvider 1: id: 0x253 cap: 0x0 crtcs: 0 outputs: 0 associated providers: 0 name:NVIDIA-G0'
P_NV='Providers: number : 2\nProvider 0: id: 0x1b8 cap: 0x1, Source Output crtcs: 4 outputs: 6 associated providers: 0 name:NVIDIA-0\nProvider 1: id: 0x47 cap: 0xf, Source Output, Sink Output, Source Offload, Sink Offload crtcs: 3 outputs: 3 associated providers: 0 name:modesetting'
P_INTEL='Providers: number : 1\nProvider 0: id: 0x47 cap: 0xb, Source Output, Sink Output, Sink Offload crtcs: 4 outputs: 5 associated providers: 0 name:Intel'

# run <drm> <nvdev> <xrandr output | FAIL>
run() {
    local fail=0 out="$3"; [ "$3" = FAIL ] && { fail=1; out=""; }
    PATH="${T}/bin:${PATH}" PARTYOS_GPU_DRM="$1" PARTYOS_GPU_NVDEV="$2" \
        XRANDR_OUT="${out}" XRANDR_FAIL="${fail}" bash "${GPUENV}"
}
NL=$'\n'

out="$(run "${HYB}" "${T}/nvidia0" "${P_HYB}")"; rc=$?
assert_true "${rc}" "hybrid Intel+nvidia: exit 0"
assert_eq "${out}" "__NV_PRIME_RENDER_OFFLOAD=1${NL}__VK_LAYER_NV_optimus=NVIDIA_only" \
    "hybrid Intel+nvidia laptop: PRIME render offload env"

out="$(run "${AMD}" "${T}/nvidia0" "${P_AMD}")"
assert_eq "${out}" "__NV_PRIME_RENDER_OFFLOAD=1${NL}__VK_LAYER_NV_optimus=NVIDIA_only" \
    "hybrid AMD+nvidia: PRIME render offload env"

out="$(run "${HYB}" "${T}/missing-nvidia0" "${P_HYB}")"
assert_eq "${out}" "DRI_PRIME=pci-0000_00_02_0" "hybrid, no /dev/nvidia0: Mesa on the Intel iGPU"

out="$(run "${HYB}" "${T}/nvidia0" "${P_INTEL}")"
assert_eq "${out}" "DRI_PRIME=pci-0000_00_02_0" "hybrid, X has no nvidia provider: Mesa on the Intel iGPU"

out="$(run "${AMD}" "${T}/nvidia0" "${P_INTEL/name:Intel/name:AMD Radeon Graphics}")"
assert_eq "${out}" "DRI_PRIME=pci-0000_05_00_0" "hybrid AMD, X has no nvidia provider: Mesa on the AMD iGPU"

out="$(run "${HYB}" "${T}/nvidia0" "${P_NV}")"
assert_eq "${out}" "" "nvidia drives the X screen: no env (old path)"

out="$(run "${HYB}" "${T}/nvidia0" FAIL)"
assert_eq "${out}" "" "xrandr gives no answer: no env (old path)"

out="$(run "${ONE}" "${T}/nvidia0" "${P_NV}")"
assert_eq "${out}" "" "nvidia-only desktop: no env"

out="$(run "${IGP}" "${T}/missing-nvidia0" "${P_INTEL}")"
assert_eq "${out}" "" "Intel-only box: no env"

out="$(run "${T}/no-such-drm" "${T}/missing-nvidia0" "${P_INTEL}")"
assert_eq "${out}" "" "no DRM nodes (VM): no env"

echo
echo "================ 2. every launch path passes the GPU env ==============="
APP="$(cat "${BIN}/partyos-app")"
n="$(grep -c '"${GPU_ENV\[@\]}" \\$' "${BIN}/partyos-app")"
assert_eq "${n}" "2" "partyos-app: cmd_launch and launch_from_meta pass GPU_ENV to run.sh"
n="$(grep -c '^        gpu_env "' "${BIN}/partyos-app")"
assert_eq "${n}" "2" "partyos-app: both launch paths call gpu_env first"
assert_contains "${APP}" "/usr/local/bin/partyos-gpu-env" "partyos-app: gpu_env runs partyos-gpu-env"
PENV="$(cat "${BIN}/partyos-proton-env")"
assert_contains "${PENV}" '/usr/local/bin/partyos-gpu-env' "partyos-proton-env: reads partyos-gpu-env"
assert_contains "${PENV}" 'env "${gpu[@]}" bash "${BASE_RUN}"' "partyos-proton-env: passes the GPU env to run.sh"

# Carve gpu_env from partyos-app and run it with a stub helper on PATH-free absolute path.
fn="$(awk '/^gpu_env\(\) \{$/{c=1} c{print} c&&/^\}$/{exit}' "${BIN}/partyos-app")"
assert_contains "${fn}" "mapfile -t GPU_ENV" "partyos-app: carved gpu_env"
stub="${T}/partyos-gpu-env"
printf '#!/bin/bash\necho "__NV_PRIME_RENDER_OFFLOAD=1"\necho "SEEN_DISPLAY=$DISPLAY"\n' > "${stub}"; chmod +x "${stub}"
got="$( eval "${fn//\/usr\/local\/bin\/partyos-gpu-env/${stub}}"; gpu_env ":7" "/x/auth"; printf '%s|' "${GPU_ENV[@]}" )"
assert_eq "${got}" "__NV_PRIME_RENDER_OFFLOAD=1|SEEN_DISPLAY=:7|" "gpu_env: fills GPU_ENV with the helper output and forwards DISPLAY"

echo
echo "================ 3. image bakes the helper, run.sh keeps the env ======="
MAN="$(cat "${REPO_ROOT}/scripts/build/files/rootfs.manifest")"
assert_contains "${MAN}" "usr/local/bin/partyos-gpu-env	755	0:0" "manifest: partyos-gpu-env 755 root"
assert_contains "$(cat "${REPO_ROOT}/scripts/build/phases/60-appstore-games.sh")" \
    'bake "usr/local/bin/partyos-gpu-env"' "phase 60 bakes partyos-gpu-env"
for b in build-app-blob.sh build-baseenv-blob.sh build-proton-blob.sh; do
    assert_not_contains "$(cat "${REPO_ROOT}/scripts/build/${b}")" "--clearenv" \
        "${b}: run.sh bwrap keeps the env (no --clearenv)"
done

assert_summary
