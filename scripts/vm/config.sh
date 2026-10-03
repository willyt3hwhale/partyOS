#!/usr/bin/env bash
# config.sh - single source of truth for VM test harness configuration.
# Sourced by all other scripts under scripts/vm/. No hardcoded server IPs
# anywhere else: everything derives from SERVER_IP/SERVER_PORT defined here.

# --- Network model ---------------------------------------------------------
# Default networking is QEMU user-mode (SLIRP). In SLIRP the guest reaches the
# host (where our HTTP server runs) at the fixed gateway address 10.0.2.2.
# That is why SERVER_IP defaults to 10.0.2.2: from inside the client VM, that
# is "the server". Other networks can override SERVER_IP through the environment.
: "${SERVER_IP:=10.0.2.2}"        # address of the HTTP server *as seen by the guest*
: "${SERVER_PORT:=8080}"          # HTTP server port
: "${SERVER_BIND:=0.0.0.0}"       # address the HTTP server binds on the host

export SERVER_IP SERVER_PORT SERVER_BIND
export SERVER_URL="http://${SERVER_IP}:${SERVER_PORT}"

# --- Server split -----------------------------------------------------------
# The single hub is split into TWO roles, addressed by INDEPENDENT base-URLs so
# in production they live on different machines (on the test host they share one
# host but use distinct ports/listeners):
#   * NETBOOT server  - serves ONLY the boot image (kernel/initramfs/squashfs).
#     Clients fetch boot from here. Defaults to the existing SERVER_PORT so the
#     foundation's boot path is unchanged.
#   * BLOB server(s)  - serve game/tool blobs + the catalog. A client is handed a
#     LIST of blob base-URLs and FAILS OVER across them (first that answers wins),
#     so a dead blob server does not stop the party. Scales horizontally.
# Every URL here is independent: the blob base-URL is NOT derived from the netboot
# base-URL. A real deployment overrides these via the environment.
: "${NETBOOT_PORT:=${SERVER_PORT}}"      # boot-image server port
: "${BLOB_PORT1:=8091}"                   # first blob server port
: "${BLOB_PORT2:=8092}"                   # second blob server port (failover)
export NETBOOT_PORT BLOB_PORT1 BLOB_PORT2
export NETBOOT_URL="http://${SERVER_IP}:${NETBOOT_PORT}"
export BLOB_URL1="http://${SERVER_IP}:${BLOB_PORT1}"
export BLOB_URL2="http://${SERVER_IP}:${BLOB_PORT2}"
# Ordered, comma-separated failover list the client tries in order. Independent
# of NETBOOT_URL by construction.
: "${BLOB_URLS:=${BLOB_URL1},${BLOB_URL2}}"
export BLOB_URLS

# --- Paths -----------------------------------------------------------------
# Resolve repo root from this file's location so scripts work from any cwd.
VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${VM_DIR}/../.." && pwd)"
export VM_DIR REPO_ROOT

# --- VM boot artifact (isolation from the LIVE prod boot script) ------------
# The VM renderer (render-ipxe.sh) writes a SEPARATE served boot script so a VM
# test run can NEVER clobber the LIVE prod boot/partyos.ipxe (which
# scripts/deploy/render.sh writes with the pinned-CA production cmdline; the build
# host can be the server, so a shared path silently breaks real clients).
# Both live under boot/ and are served by the same http_server, but at DISTINCT
# names. VM_BOOT_URL is the URL clients auto-chain to (option 67). Overridable.
: "${VM_IPXE_NAME:=partyos.ipxe.vm}"
export VM_IPXE_NAME
export VM_IPXE_OUT="${REPO_ROOT}/boot/${VM_IPXE_NAME}"
export VM_BOOT_URL="${SERVER_URL}/boot/${VM_IPXE_NAME}"

# Scratch/run dir for ephemeral artifacts (serial logs, QMP sockets, pidfiles).
# Kept OUT of the repo tree. Override with RUN_DIR=.
: "${RUN_DIR:=$(mktemp -d "${TMPDIR:-/tmp}/partyos-vm.XXXXXX")}"
export RUN_DIR

# --- QEMU ------------------------------------------------------------------
# Locate binaries on PATH so the harness is portable across hosts (mac/brew at
# /opt/homebrew, Linux at /usr/bin). Allow override via env.
_find() { command -v "$1" 2>/dev/null; }
: "${QEMU:=$(_find qemu-system-x86_64)}"
: "${QEMU_IMG:=$(_find qemu-img)}"
: "${QEMU:=/opt/homebrew/bin/qemu-system-x86_64}"   # last-resort fallback
: "${QEMU_IMG:=/opt/homebrew/bin/qemu-img}"
export QEMU QEMU_IMG

# Acceleration: try the best available accelerator by actually launching a paused
# VM with it. Order: KVM (x86 Linux host) -> HVF (x86 mac) -> TCG (emulation).
# On Apple Silicon the x86_64 QEMU has no HVF, so it lands on TCG.
_accel_works() {
    "${QEMU}" -machine q35 -accel "$1" -display none -nographic \
        -no-reboot -m 16 -S -monitor none -serial none </dev/null \
        >/dev/null 2>&1 &
    local pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0
    fi
    wait "$pid" 2>/dev/null; return 1
}
pick_accel() {
    local a
    for a in kvm hvf; do
        if _accel_works "$a"; then echo "$a"; return; fi
    done
    echo "tcg"
}
: "${ACCEL:=$(pick_accel)}"
export ACCEL

# --- Defaults --------------------------------------------------------------
: "${CLIENT_RAM_MB:=512}"         # default guest RAM for trivial tests
: "${BOOT_TIMEOUT:=60}"           # hard per-VM timeout (seconds)
export CLIENT_RAM_MB BOOT_TIMEOUT

# --- Helpers ---------------------------------------------------------------
log()  { printf '[harness] %s\n' "$*" >&2; }
die()  { printf '[harness] ERROR: %s\n' "$*" >&2; exit 1; }
