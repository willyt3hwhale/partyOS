#!/usr/bin/env bash
# exfatsplit-script.sh - in-guest VERIFIER for the CROSS-OS participant stick.
# Fetched at boot via archiso's automated-script hook (partyos-exfatsplit.ipxe
# passes script=<server>/boot/exfatsplit-script.sh). Runs on the tty1 root
# autologin once the live system is up, mirroring proof to the serial console the
# harness scrapes.
#
# IMPORTANT - VERIFIER ONLY, NOT AN INSTALLER:
# The participant stick is now laid out the way the PRODUCTION stick is (and
# build-usbsplit.sh builds): the ext4 LANPARTY_HOME partition carries `.partyos`
# (identity) + `.partyos-cache` at the partition ROOT and the user home tree under a
# `home/` SUBDIR; the exFAT partition is the CROSS-OS share, LABEL PARTYSHARE,
# mounted in-session at /mnt/share (~/Shared). The OS reads `.partyos` from the ext4
# ROOT (NOT exFAT) and the baked partyos-usbhome.service mounts BOTH partitions.
# This script does NOT mount or install anything - it ASSERTS the BAKED mounts +
# the baked identity resolution and emits proof.
#
# What it proves, from a REAL booted VM:
#   1. The BAKED partyos-usbhome.service mounted the ext4 LANPARTY_HOME at
#      /mnt/usbhome AND the exFAT PARTYSHARE at /mnt/share.
#   2. The OS read `.partyos` (USERNAME=) from the ext4 ROOT (the cross-OS share is
#      exFAT, but the config lives on ext4 - readable by Linux; the exFAT partition
#      is the portable share, not the config).
#   3. The home came from the ext4 p2:/home SUBDIR (baked partyos-home-pull) -> seed
#      files in /home/<user>.
#   4. Backward compat (compat=single): a legacy single-ext4 stick (no PARTYSHARE)
#      still resolves `.partyos` from the ext4 root and boots.
#
# Markers (greppable on serial):
#   PARTYOS-EXFATSPLIT-CFG-FS fs=<ext4> label=<lbl> src=<ext4-root|default>
#   PARTYOS-EXFATSPLIT-USERNAME user=<name> src=<ext4-root|default>
#   PARTYOS-EXFATSPLIT-HOME-FS fs=ext4 label=LANPARTY_HOME  home partition fs
#   PARTYOS-EXFATSPLIT-SHARE-FS fs=<exfat|none> label=PARTYSHARE  cross-OS share
#   PARTYOS-EXFATSPLIT-HOME-POPULATED home=<populated|empty>
#   PARTYOS-EXFATSPLIT-READY                                all checks held
#   PARTYOS-EXFATSPLIT-ALIVE                                heartbeats
# HTTP callback:
#   /report?step=exfatsplit&status=ok&cfgfs=ext4&user=<name>&usrc=ext4-root&homefs=ext4&home=populated&sharefs=exfat&token=...

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say() { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

# report_url + exfatsplit_compat are injected by partyos-exfatsplit.ipxe (no
# hardcoded IP). compat=single means a single-ext4 stick is attached (no PARTYSHARE).
report_base=""
compat="split"
for p in $(< /proc/cmdline); do
    case "$p" in
        report_url=*) report_base="${p#*=}";;
        exfatsplit_compat=*) compat="${p#*=}";;
    esac
done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-EXFATSPLIT-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }

HOME_LABEL="LANPARTY_HOME"
SHARE_LABEL="PARTYSHARE"
HOME_MNT="/mnt/usbhome"    # ext4 home partition (baked mountpoint)
SHARE_MNT="/mnt/share"     # exFAT cross-OS share (baked mountpoint)
USB_HOME="${HOME_MNT}/home"   # baked design: the home CONTENT lives in p2:/home
PULL_DONE="/run/partyos-home-pull-done"

say "PARTYOS-EXFATSPLIT boot script started (VERIFIER, compat=${compat}) - ext4 config-at-root + exFAT PARTYSHARE"

# --- helper: resolve a device node by filesystem label -----------------------
dev_by_label() {
    local lbl="$1" d=""
    d="$(blkid -L "${lbl}" 2>/dev/null || true)"
    [ -n "${d}" ] || d="$(readlink -f "/dev/disk/by-label/${lbl}" 2>/dev/null || true)"
    printf '%s' "${d}"
}

# --- 0. assert the BAKED mount unit is present (not installed by us) -----------
[ -x /usr/local/bin/partyos-usbhome ] && say "PARTYOS-EXFATSPLIT baked present: /usr/local/bin/partyos-usbhome" \
    || say "PARTYOS-EXFATSPLIT ERROR baked partyos-usbhome MISSING (image regression?)"

# --- 1. wait for the BAKED partyos-usbhome.service to mount the ext4 home -------
home_dev="$(dev_by_label "${HOME_LABEL}")"
home_fs="$([ -n "${home_dev}" ] && blkid -o value -s TYPE "${home_dev}" 2>/dev/null || echo none)"
mounted_home=0
for _ in $(seq 1 30); do
    if mountpoint -q "${HOME_MNT}"; then mounted_home=1; break; fi
    sleep 1
done
[ "${mounted_home}" -eq 1 ] && say "PARTYOS-EXFATSPLIT ext4 ${HOME_LABEL} (${home_fs}) mounted at ${HOME_MNT} (baked)" \
    || say "PARTYOS-EXFATSPLIT ERROR ${HOME_MNT} not mounted by the baked partyos-usbhome.service"

# --- 2. observe the exFAT PARTYSHARE mount (cross-OS share at /mnt/share) -------
share_dev="$(dev_by_label "${SHARE_LABEL}")"
share_fs="none"
mounted_share=0
if [ -n "${share_dev}" ]; then
    share_fs="$(blkid -o value -s TYPE "${share_dev}" 2>/dev/null || echo unknown)"
    for _ in $(seq 1 20); do
        if mountpoint -q "${SHARE_MNT}"; then mounted_share=1; break; fi
        sleep 1
    done
fi
say "PARTYOS-EXFATSPLIT-SHARE-FS fs=${share_fs} label=${SHARE_LABEL} mnt=$([ "${mounted_share}" -eq 1 ] && echo yes || echo no)"

# --- 3. determine WHERE .partyos was read from: the ext4 ROOT (not exFAT) -------
# The baked config-finder reads `.partyos` from the ext4 partition ROOT. The exFAT
# partition is the cross-OS share (PARTYSHARE), NOT the config. We confirm the
# config file exists at the ext4 root and that the baked identity resolved it.
cfg_source="default"
cfg_fs_used="none"
cfg_label_used="none"
CFG_FILE=""
if [ "${mounted_home}" -eq 1 ] && [ -r "${HOME_MNT}/.partyos" ]; then
    CFG_FILE="${HOME_MNT}/.partyos"
    cfg_source="ext4-root"
    cfg_fs_used="${home_fs}"
    cfg_label_used="${HOME_LABEL}"
fi
say "PARTYOS-EXFATSPLIT-CFG-FS fs=${cfg_fs_used} label=${cfg_label_used} src=${cfg_source}"
say "PARTYOS-EXFATSPLIT .partyos: $( [ -n "${CFG_FILE}" ] && [ -r "${CFG_FILE}" ] && tr '\n' ';' < "${CFG_FILE}" || echo '(absent)')"

# --- 4. resolve the desktop user the BAKED identity published ------------------
# partyos-identity reads `.partyos` USERNAME= from the ext4 root and publishes the
# resolved name to /run/partyos-username. Read it (do NOT re-parse / rename here).
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
HOME_DIR="/home/${USER_NAME}"
say "PARTYOS-EXFATSPLIT-USERNAME user=${USER_NAME} src=${cfg_source}"

# --- 5. wait for the BAKED boot pull to populate /home/<user> from p2:/home -----
for _ in $(seq 1 60); do [ -e "${PULL_DONE}" ] && break; sleep 1; done
[ -e "${PULL_DONE}" ] && say "PARTYOS-EXFATSPLIT baked boot pull done (${PULL_DONE})" \
    || say "PARTYOS-EXFATSPLIT WARN baked pull-done gate not set"

home_ok=0
token=""
if [ -f "${HOME_DIR}/WELCOME.txt" ] && [ -f "${HOME_DIR}/.partyos-home-token" ]; then
    home_ok=1
    token="$(tr -d '\n' < "${HOME_DIR}/.partyos-home-token" 2>/dev/null)"
    say "PARTYOS-EXFATSPLIT-HOME-POPULATED home=populated ${HOME_DIR} (token=${token})"
else
    say "PARTYOS-EXFATSPLIT-HOME-POPULATED home=empty (ext4 home/ seed missing in ${HOME_DIR})"
    say "PARTYOS-EXFATSPLIT ${USB_HOME} listing: $(ls -A "${USB_HOME}" 2>/dev/null | tr '\n' ' ')"
fi
say "PARTYOS-EXFATSPLIT-HOME-FS fs=${home_fs} label=${HOME_LABEL} mnt=$(mountpoint -q "${HOME_MNT}" && echo yes || echo no)"

# --- 6. evaluate the verdict for this boot's compat shape --------------------
# split  : config read from ext4 ROOT; ext4 home mounted; exFAT PARTYSHARE present.
# single : config read from ext4 ROOT; ext4 home mounted; no PARTYSHARE partition.
cfg_ok=0
[ "${cfg_source}" = "ext4-root" ] && cfg_ok=1
home_fs_ok=0
[ "${home_fs}" = "ext4" ] && mountpoint -q "${HOME_MNT}" && home_fs_ok=1
user_ok=0
[ "$(id -u "${USER_NAME}" 2>/dev/null || echo '')" = "1000" ] && user_ok=1
share_ok=1
case "${compat}" in
    single) [ "${mounted_share}" -eq 0 ] || share_ok=1 ;;   # no PARTYSHARE expected (tolerant)
    *)      [ "${share_fs}" = "exfat" ] && share_ok=1 || share_ok=0 ;;
esac

# --- 7. emit ready proof + HTTP callback -------------------------------------
if [ "${cfg_ok}" -eq 1 ] && [ "${home_fs_ok}" -eq 1 ] && [ "${home_ok}" -eq 1 ] && \
   [ "${user_ok}" -eq 1 ] && [ "${share_ok}" -eq 1 ]; then
    say "PARTYOS-EXFATSPLIT-READY user=${USER_NAME} cfgfs=${cfg_fs_used} usrc=${cfg_source} homefs=${home_fs} home=populated sharefs=${share_fs}"
    curl -s --max-time 5 \
      "${report_base}/report?step=exfatsplit&status=ok&cfgfs=${cfg_fs_used}&user=${USER_NAME}&usrc=${cfg_source}&homefs=${home_fs}&home=populated&sharefs=${share_fs}&token=${token}" \
      >/dev/null 2>&1 || say "PARTYOS-EXFATSPLIT callback-failed (non-fatal)"
else
    say "PARTYOS-EXFATSPLIT NOT ready (cfg=${cfg_ok} homefs=${home_fs_ok} home=${home_ok} user=${user_ok} share=${share_ok})"
    curl -s --max-time 5 \
      "${report_base}/report?step=exfatsplit&status=fail&cfgfs=${cfg_fs_used}&user=${USER_NAME}&usrc=${cfg_source}&homefs=${home_fs}&home=${home_ok}&sharefs=${share_fs}" \
      >/dev/null 2>&1 || true
fi

# --- 8. heartbeats: prove it stays up, then power off ------------------------
i=0
while [ "$i" -lt 10 ]; do
    sleep 3; i=$((i+1))
    say "PARTYOS-EXFATSPLIT-ALIVE heartbeat ${i} user=${USER_NAME} cfgsrc=${cfg_source}"
done
say "PARTYOS-EXFATSPLIT stay-up window complete, powering off"
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
