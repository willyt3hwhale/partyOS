#!/usr/bin/env bash
# partyos-usb-labels.sh - find the partitions of the player stick by label.
#
# The player stick has two data partitions:
#   home   ext4. It holds the home (home/), the blob cache and the sync state.
#          It is mounted at /mnt/usbhome.
#   share  exFAT. It holds internyet.env and the certificates. It is mounted at
#          /mnt/share (~/Shared).
#
# Each partition has an ORDERED list of accepted labels. The first label that is
# on a partition wins. The venue label is first, the legacy label is second, so
# venue sticks and legacy sticks both work. If both labels are present, the
# venue label wins.
#
# The kernel command line sets the lists (render.sh writes them from deploy.conf):
#   usb_home_labels=PARTYOSHOME,LANPARTY_HOME
#   usb_share_labels=PARTYDATA,PARTYSHARE
# If a parameter is absent or has no valid label, the baked defaults below apply.
# A valid label has 1 to 16 characters from A-Z a-z 0-9 _ -. The script ignores
# other items.
#
# Source this file, or run it:
#   partyos-usb-labels.sh labels home|share      print the list, one per line
#   partyos-usb-labels.sh resolve home|share     print the device, exit 1 if none
#   partyos-usb-labels.sh is home|share LABEL    exit 0 if LABEL is in the list
# The udev rule 99-partyos-usbhome.rules uses "is home".
#
# Environment (the tests use these):
#   PARTYOS_CMDLINE   the kernel command line file (default /proc/cmdline).
#   PARTYOS_BY_LABEL  the by-label directory (default /dev/disk/by-label).

PARTYOS_HOME_LABELS_DEFAULT="PARTYOSHOME,LANPARTY_HOME"
PARTYOS_SHARE_LABELS_DEFAULT="PARTYDATA,PARTYSHARE"

# _partyos_label_list LIST -> the valid labels of the comma list, one per line.
_partyos_label_list() {
    local item
    local IFS=,
    for item in $1; do
        [[ "${item}" =~ ^[A-Za-z0-9_-]{1,16}$ ]] && printf '%s\n' "${item}"
    done
    return 0
}

# partyos_usb_labels home|share -> the ordered label list, one per line.
partyos_usb_labels() {
    local key def p val="" out
    case "$1" in
        home)  key="usb_home_labels";  def="${PARTYOS_HOME_LABELS_DEFAULT}";;
        share) key="usb_share_labels"; def="${PARTYOS_SHARE_LABELS_DEFAULT}";;
        *) return 2;;
    esac
    # Use `cat`, not $(< file 2>/dev/null): the redirect breaks the bash fast path.
    for p in $(cat "${PARTYOS_CMDLINE:-/proc/cmdline}" 2>/dev/null); do
        case "${p}" in "${key}="*) val="${p#*=}";; esac
    done
    out="$(_partyos_label_list "${val}")"
    [ -n "${out}" ] || out="$(_partyos_label_list "${def}")"
    printf '%s\n' "${out}"
}

# partyos_label_is home|share LABEL -> exit 0 if LABEL is in the list.
partyos_label_is() {
    local l
    [ -n "${2:-}" ] || return 1
    while IFS= read -r l; do
        [ "${l}" = "$2" ] && return 0
    done <<EOF
$(partyos_usb_labels "$1")
EOF
    return 1
}

# partyos_label_devs LABEL -> every partition with LABEL, sorted, one per line.
partyos_label_devs() {
    local lbl="$1" devs byl="${PARTYOS_BY_LABEL:-/dev/disk/by-label}"
    devs="$(timeout 15 blkid -o device -t "LABEL=${lbl}" 2>/dev/null | sort || true)"
    # Fallback for a blkid without -t (or a cold cache): the single-label lookup.
    [ -n "${devs}" ] || devs="$(timeout 15 blkid -L "${lbl}" 2>/dev/null || true)"
    if [ -z "${devs}" ] && [ -e "${byl}/${lbl}" ]; then
        devs="$(readlink -f "${byl}/${lbl}" 2>/dev/null || true)"
    fi
    [ -n "${devs}" ] && printf '%s\n' "${devs}"
    return 0
}

# partyos_resolve_label_dev home|share -> the device to mount, or nothing.
# The first label of the list that is on a partition wins. If more than one
# partition has that label (two sticks), the lowest partition UUID wins. The
# UUID is fixed per stick, so the same stick wins on every boot, whatever the
# kernel enumeration order is. The choice goes to stderr as a WARN.
#
# Pass 1 looks at the udev by-label links. They cost no device I/O. Pass 2 asks
# blkid, for a udev database that is not ready yet. A blkid search for a label
# that is not there probes every block device. partyos-usb-poll calls this every
# few seconds, so a missing first label must not cause a probe when a later
# label has a link.
partyos_resolve_label_dev() {
    local kind="$1" lbl="" devs="" count d uuid picked="" picked_uuid="" ignored=""
    local labels byl="${PARTYOS_BY_LABEL:-/dev/disk/by-label}"
    labels="$(partyos_usb_labels "${kind}")"
    while IFS= read -r lbl; do
        [ -n "${lbl}" ] && [ -e "${byl}/${lbl}" ] || continue
        devs="$(partyos_label_devs "${lbl}")"
        [ -n "${devs}" ] && break
    done <<EOF
${labels}
EOF
    if [ -z "${devs}" ]; then
        while IFS= read -r lbl; do
            [ -n "${lbl}" ] || continue
            devs="$(partyos_label_devs "${lbl}")"
            [ -n "${devs}" ] && break
        done <<EOF
${labels}
EOF
    fi
    [ -n "${devs}" ] || return 0
    count="$(printf '%s\n' "${devs}" | grep -c .)"
    if [ "${count}" -le 1 ]; then
        printf '%s\n' "${devs}" | head -1
        return 0
    fi
    while IFS= read -r d; do
        [ -n "${d}" ] || continue
        uuid="$(timeout 5 blkid -o value -s UUID "${d}" 2>/dev/null || true)"
        [ -n "${uuid}" ] || uuid="zzzzzzzz-nouuid-${d##*/}"
        if [ -z "${picked}" ] || [[ "${uuid}" < "${picked_uuid}" ]]; then
            [ -z "${picked}" ] || ignored="${ignored}${picked} "
            picked="${d}"; picked_uuid="${uuid}"
        else
            ignored="${ignored}${d} "
        fi
    done <<EOF
${devs}
EOF
    echo "partyos-usb-labels: WARN ${count} ${kind} partitions with label ${lbl}; using ${picked} (UUID=${picked_uuid}, the lowest), ignoring: ${ignored}" >&2
    printf '%s\n' "${picked}"
}

# partyos_dev_is home|share DEV -> exit 0 if the label of DEV is in the list.
partyos_dev_is() {
    local lbl
    lbl="$(timeout 5 blkid -o value -s LABEL "$2" 2>/dev/null || true)"
    partyos_label_is "$1" "${lbl}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        labels)  partyos_usb_labels "${2:-}";;
        resolve) d="$(partyos_resolve_label_dev "${2:-}")"; [ -n "${d}" ] && printf '%s\n' "${d}";;
        is)      partyos_label_is "${2:-}" "${3:-}";;
        *) echo "usage: $0 labels|resolve home|share | is home|share LABEL" >&2; exit 2;;
    esac
fi
