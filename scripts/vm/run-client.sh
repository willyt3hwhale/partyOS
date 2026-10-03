#!/usr/bin/env bash
# run-client.sh - launch ONE headless client VM (qemu-system-x86_64).
#
# Captures the serial console to a file and exposes a QMP unix socket so the
# harness can read markers and control the VM (hotplug, reset, power off).
# Enforces a hard timeout: if the VM outlives BOOT_TIMEOUT it is killed.
#
# Usage:
#   run-client.sh --name N [options]
# Options:
#   --name NAME            instance name (used for log/socket/pid filenames)
#   --ram MB              guest RAM in MB                  (default CLIENT_RAM_MB)
#   --timeout SEC         hard kill timeout                (default BOOT_TIMEOUT)
#   --disk PATH           a drive image (repeatable)
#   --usb PATH            a removable USB disk image (repeatable; id usbN)
#   --kernel PATH         direct kernel boot
#   --initrd PATH         initrd for direct kernel boot
#   --append "ARGS"       kernel cmdline for direct boot
#   --boot-rom            boot from network ROM (-boot n) for iPXE tests
#   --fda PATH            attach a floppy image and boot from it
#   --netdev SPEC         override the -netdev spec (default user mode SLIRP)
#   --serial PATH         serial log file       (default $RUN_DIR/<name>.serial)
#   --qmp PATH            QMP unix socket path  (default $RUN_DIR/<name>.qmp)
#   --pidfile PATH        pidfile path          (default $RUN_DIR/<name>.pid)
#   --extra "ARGS"        extra raw QEMU args
#   --background          return immediately after launch (default: blocks)
#
# When --background is given, the script prints SERIAL=, QMP=, PID= lines and
# returns 0. Otherwise it waits for the VM to exit (or timeout) and returns the
# VM's exit status (124 on timeout).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

NAME="client"
RAM="${CLIENT_RAM_MB}"
TIMEOUT="${BOOT_TIMEOUT}"
KERNEL="" INITRD="" APPEND="" BOOT_ROM=0 FDA="" NETDEV="" BACKGROUND=0
SERIAL="" QMP="" PIDFILE="" EXTRA="" BOOTFILE="" IPXE_DISK=""
declare -a DISKS=() USBS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --name)     NAME="$2"; shift 2;;
        --ram)      RAM="$2"; shift 2;;
        --timeout)  TIMEOUT="$2"; shift 2;;
        --disk)     DISKS+=("$2"); shift 2;;
        --usb)      USBS+=("$2"); shift 2;;
        --kernel)   KERNEL="$2"; shift 2;;
        --initrd)   INITRD="$2"; shift 2;;
        --append)   APPEND="$2"; shift 2;;
        --boot-rom) BOOT_ROM=1; shift;;
        --bootfile) BOOTFILE="$2"; shift 2;;   # DHCP boot filename (e.g. http URL)
        --ipxe-disk) IPXE_DISK="$2"; shift 2;; # boot iPXE USB image instead of ROM
        --fda)      FDA="$2"; shift 2;;
        --netdev)   NETDEV="$2"; shift 2;;
        --serial)   SERIAL="$2"; shift 2;;
        --qmp)      QMP="$2"; shift 2;;
        --pidfile)  PIDFILE="$2"; shift 2;;
        --extra)    EXTRA="$2"; shift 2;;
        --background) BACKGROUND=1; shift;;
        *) die "run-client: unknown arg '$1'";;
    esac
done

SERIAL="${SERIAL:-${RUN_DIR}/${NAME}.serial}"
QMP="${QMP:-${RUN_DIR}/${NAME}.qmp}"
PIDFILE="${PIDFILE:-${RUN_DIR}/${NAME}.pid}"
: > "${SERIAL}"
rm -f "${QMP}"

# Default user-mode networking: SLIRP, guest sees host/server at 10.0.2.2.
# When --bootfile is given, hand the guest a DHCP boot filename (SLIRP's
# equivalent of dnsmasq dhcp-boot / DHCP option 67). QEMU's iPXE option ROM
# reads it and AUTO-chains it - no typed iPXE command. This is what makes the
# Step 1 boot fully automatic.
if [ -z "${NETDEV}" ]; then
    NETDEV="user,id=net0"
    if [ -n "${BOOTFILE}" ]; then
        NETDEV="${NETDEV},bootfile=${BOOTFILE}"
    fi
fi

# iPXE option ROM for the NIC. QEMU ships an iPXE-based pxe-e1000.rom that talks
# HTTP and prints to the serial console - exactly what the autonomous harness
# needs. Without an explicit romfile QEMU still uses its bundled ROM; we name it
# so the path is deterministic and so --boot-rom is meaningful.
IPXE_ROM=""
for cand in \
    /opt/homebrew/share/qemu/pxe-e1000.rom \
    /usr/local/share/qemu/pxe-e1000.rom \
    /usr/share/qemu/pxe-e1000.rom; do
    [ -f "$cand" ] && { IPXE_ROM="$cand"; break; }
done

E1000_DEV="e1000,netdev=net0"
if [ "${BOOT_ROM}" -eq 1 ] && [ -n "${IPXE_ROM}" ]; then
    E1000_DEV="${E1000_DEV},romfile=${IPXE_ROM}"
fi

# Assemble QEMU args.
declare -a ARGS=(
    -machine q35
    -accel "${ACCEL}"
    -m "${RAM}"
    -smp 2
    -display none
    -nographic
    -no-reboot
    -serial "file:${SERIAL}"
    -qmp "unix:${QMP},server,nowait"
    -netdev "${NETDEV}"
    -device "${E1000_DEV}"
    # Feed guest entropy from the host. Without this the archiso pacman-init
    # GPG key generation starves for randomness under TCG and can take many
    # minutes (or appear to hang); virtio-rng makes that step fast.
    -object "rng-random,filename=/dev/urandom,id=rng0"
    -device "virtio-rng-pci,rng=rng0"
)

for d in "${DISKS[@]:-}"; do
    [ -n "$d" ] && ARGS+=( -drive "file=${d},format=qcow2,if=virtio" )
done

# Attach removable USB drives. The xHCI controller must be declared BEFORE any
# usb-storage device that hangs off it (QEMU resolves the bus at parse time), so
# add the controller first, then bind each drive to bus=xhci.0 explicitly. The
# stable id usb<N> lets QMP hotplug (device_del/device_add) reference each stick
# by name in Step 6.
if [ -n "${USBS[*]:-}" ]; then
    ARGS+=( -device qemu-xhci,id=xhci )
    usb_i=0
    for u in "${USBS[@]:-}"; do
        [ -z "$u" ] && continue
        ARGS+=( -drive "file=${u},format=qcow2,if=none,id=usbdrv${usb_i}"
                -device "usb-storage,bus=xhci.0,drive=usbdrv${usb_i},id=usb${usb_i},removable=on" )
        usb_i=$((usb_i+1))
    done
fi

if [ -n "${KERNEL}" ]; then
    ARGS+=( -kernel "${KERNEL}" )
    [ -n "${INITRD}" ] && ARGS+=( -initrd "${INITRD}" )
    [ -n "${APPEND}" ] && ARGS+=( -append "${APPEND}" )
fi

if [ -n "${FDA}" ]; then
    ARGS+=( -drive "file=${FDA},format=raw,if=floppy" -boot a )
fi

# iPXE USB image path: attach the raw iPXE image as a USB stick and boot from it
# (exercises create_usb.sh's image output). This is the in-VM stand-in for the
# physical iPXE USB; it self-chains over HTTP just like the ROM path.
if [ -n "${IPXE_DISK}" ]; then
    ARGS+=( -drive "file=${IPXE_DISK},format=raw,if=none,id=ipxeusb"
            -device qemu-xhci,id=ipxehci
            -device "usb-storage,drive=ipxeusb,bootindex=0" )
fi

if [ "${BOOT_ROM}" -eq 1 ]; then
    ARGS+=( -boot n )
fi

if [ -n "${EXTRA}" ]; then
    # shellcheck disable=SC2206
    EXTRA_ARR=( ${EXTRA} )
    ARGS+=( "${EXTRA_ARR[@]}" )
fi

log "launching VM '${NAME}' accel=${ACCEL} ram=${RAM}MB timeout=${TIMEOUT}s"
log "  serial -> ${SERIAL}"
log "  qmp    -> ${QMP}"

# Launch in background, record pid, then enforce timeout with a watchdog.
"${QEMU}" "${ARGS[@]}" &
VM_PID=$!
echo "${VM_PID}" > "${PIDFILE}"

# Watchdog: kill the VM if it outlives TIMEOUT.
( sleep "${TIMEOUT}"; if kill -0 "${VM_PID}" 2>/dev/null; then
      log "VM '${NAME}' hit ${TIMEOUT}s timeout - killing"; kill -9 "${VM_PID}" 2>/dev/null; fi ) &
WATCH_PID=$!

if [ "${BACKGROUND}" -eq 1 ]; then
    echo "NAME=${NAME}"
    echo "PID=${VM_PID}"
    echo "SERIAL=${SERIAL}"
    echo "QMP=${QMP}"
    echo "WATCHDOG=${WATCH_PID}"
    exit 0
fi

# Foreground: wait for VM, then reap the watchdog.
RC=0
wait "${VM_PID}" 2>/dev/null || RC=$?
kill "${WATCH_PID}" 2>/dev/null || true
wait "${WATCH_PID}" 2>/dev/null || true
exit "${RC}"
