#!/usr/bin/env bash
# fleet-verify.sh - the cross-host verification matrix for the physical fleet
# (docs/TESTING.md). One row per host x check,
# evidence recorded under scripts/test/results/fleet-<timestamp>/ as per-host
# JSON plus a matrix.md stamped with date + the served sfs sha - so a result can
# always be matched to an image version later.
#
# Modes:
#   --check (default)   READ-ONLY. For each fleet host: ssh probe (up? running
#                       partyOS-from-RAM? detected via /run/archiso + rootfs
#                       type), compare the BOOTED sfs identity (sha512 of the
#                       copytoram sfs in RAM) against the SERVED
#                       server/images/custom/arch/x86_64/airootfs.sha512, and
#                       run the smoke checks: desktop process up, home-sync
#                       timer active, GPU renderer real hardware not llvmpipe
#                       (nvidia-smi on the nvidia host, glxinfo elsewhere),
#                       blob mounted (informational). PLUS the Tier-1 extended
#                       player-visible feature probes (all still single-round-
#                       trip READS, no writes/restarts): app-store icons + Win95
#                       skel tiles present, Chicago95 theme applied, single
#                       Win95 panel, lock wiring (LockCommand/xscreensaver/xss-
#                       lock), session user == stick USERNAME at uid 1000, static
#                       IP applied, seeder unit active, audio default sink not
#                       HDMI, timesync timer + clock drift <=5s, journal snapshot
#                       fresh on the stick, usb-poll alive-not-churning, patched
#                       thunar installed, portal cached, keyboard/timezone
#                       applied. An unreadable value is
#                       "unknown" and never a false FAIL. Never reboots, never
#                       writes on a host.
#   --reboot HOST|all   FULL re-PXE verification: ssh-reboot the host, then
#                       boot-watch the netboot server access log with
#                       lib-bootwatch (hard timeout + STALL detector +
#                       heartbeats - never a silent success-only grep) for
#                       "REPORT step=copytoram" then "step=3 status=ok
#                       desktop=ready", then rerun the smoke checks. REFUSES to
#                       run without an explicit target. A host with the quirk
#                       manual-power-on needs a hand after a poweroff - the tool warns.
#
# Boot markers are matched on log bytes appended AFTER the reboot was triggered
# (bootwatch --from-now), NOT by client IP: a client's boot-time DHCP IP can
# differ from its pinned post-stage3 IP, so hosts are rebooted and
# watched SEQUENTIALLY instead of guessing at IPs.
#
# Exit: 0 = every checked host PASS; 1 = any FAIL or UNREACHABLE (an
# unreachable host is recorded as UNREACHABLE, never guessed at); 64 = usage.
#
# The fleet table comes from FLEET_HOSTS or, if that is unset, from FLEET_CONF.
# Copy scripts/deploy/fleet.conf.example to scripts/deploy/fleet.conf (not in
# git) and list your own hosts there.
#
# Env overrides (the hardware-free test drives these):
#   FLEET_HOSTS         fleet table, lines of  name|ip|gpu|quirks
#   FLEET_CONF          fleet table file (default scripts/deploy/fleet.conf)
#   FLEET_SHA_FILE      served sha file (default server/images/.../airootfs.sha512)
#   FLEET_RESULTS_DIR   results root (default scripts/test/results)
#   FLEET_ACCESS_LOG    netboot server access log for --reboot (or --log PATH);
#                       the file http_server.py stdout is captured into
#   FLEET_BOOT_TIMEOUT / FLEET_BOOT_STALL / FLEET_BOOT_HEARTBEAT  watch tuning (s)
#
# Usage: fleet-verify.sh [--check | --reboot HOST|all] [--log PATH]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=../test/lib-bootwatch.sh
source "${REPO_ROOT}/scripts/test/lib-bootwatch.sh"

# The fleet: one line per physical test box, name|ip|gpu-vendor|quirks. Cover
# each GPU vendor - a pass on one vendor is a pass on one vendor.
FLEET_CONF="${FLEET_CONF:-${SELF_DIR}/fleet.conf}"
if [ -n "${FLEET_HOSTS:-}" ]; then
    FLEET="${FLEET_HOSTS}"
elif [ -f "${FLEET_CONF}" ]; then
    FLEET="$(grep -vE '^[[:space:]]*(#|$)' "${FLEET_CONF}")"
else
    echo "fleet-verify: no fleet table: set FLEET_HOSTS or create ${FLEET_CONF}" >&2
    echo "  (see scripts/deploy/fleet.conf.example)" >&2
    exit 64
fi

SHA_FILE="${FLEET_SHA_FILE:-${REPO_ROOT}/server/images/custom/arch/x86_64/airootfs.sha512}"
RESULTS_ROOT="${FLEET_RESULTS_DIR:-${REPO_ROOT}/scripts/test/results}"
ACCESS_LOG="${FLEET_ACCESS_LOG:-${REPO_ROOT}/server/http_access.log}"
BOOT_TIMEOUT="${FLEET_BOOT_TIMEOUT:-600}"
# Stall must exceed the longest legitimate silent gap in the access log - the
# single-GET sfs transfer logs nothing until the "sent" line lands.
BOOT_STALL="${FLEET_BOOT_STALL:-180}"
BOOT_HEARTBEAT="${FLEET_BOOT_HEARTBEAT:-20}"

MODE="check"
TARGET=""
usage() { echo "Usage: fleet-verify.sh [--check | --reboot HOST|all] [--log PATH]" >&2; exit 64; }
while [ $# -gt 0 ]; do
    case "$1" in
        --check)  MODE="check"; shift;;
        --reboot)
            MODE="reboot"
            # REFUSE without an explicit target - rebooting the fleet must
            # never happen by default or via a missing argument.
            if [ $# -lt 2 ] || [ -z "${2:-}" ] || [ "${2#--}" != "${2:-}" ]; then
                echo "fleet-verify: --reboot refused: an explicit HOST (name|ip) or 'all' is required" >&2
                exit 64
            fi
            TARGET="$2"; shift 2;;
        --log)    ACCESS_LOG="${2:?--log needs a path}"; shift 2;;
        *) echo "fleet-verify: unknown arg '$1'" >&2; usage;;
    esac
done

# The served image identity every result is stamped with.
SERVED_SHA="absent"
if [ -f "${SHA_FILE}" ]; then
    SERVED_SHA="$(awk '{print $1; exit}' "${SHA_FILE}")"
fi

if [ "${MODE}" = "reboot" ]; then
    # Validate the target against the fleet table before touching anything.
    if [ "${TARGET}" != "all" ]; then
        found=0
        while IFS='|' read -r n i _gpu _quirks; do
            if [ "${TARGET}" = "${n}" ] || [ "${TARGET}" = "${i}" ]; then found=1; fi
        done <<< "${FLEET}"
        if [ "${found}" -ne 1 ]; then
            echo "fleet-verify: --reboot refused: '${TARGET}' is not a fleet host. Known hosts:" >&2
            printf '%s\n' "${FLEET}" | awk -F'|' '{printf "  %s %s\n", $1, $2}' >&2
            exit 64
        fi
    fi
    if [ ! -f "${ACCESS_LOG}" ]; then
        echo "fleet-verify: --reboot needs the netboot server access log to boot-watch." >&2
        echo "fleet-verify: ${ACCESS_LOG} not found - capture http_server.py/run-servers.sh stdout" >&2
        echo "fleet-verify: to a file and point --log PATH (or FLEET_ACCESS_LOG) at it." >&2
        exit 64
    fi
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
RES_DIR="${RESULTS_ROOT}/fleet-${STAMP}"
mkdir -p "${RES_DIR}"
DATE_ISO="$(date '+%Y-%m-%d %H:%M:%S')"

# --- remote probe -----------------------------------------------------------
# ONE ssh round-trip per host: run a small sh script remotely that prints
# KEY=VALUE lines. Read-only by construction - it only reads /run, /proc,
# process/unit state and hashes a file already sitting in RAM.
PROBE_OUT=""
probe_host() {
    local ip="$1" gpu="$2" rc=0
    # ServerAlive*: a post-connect deadline (~60s). ConnectTimeout only bounds
    # the connect; a wedged remote (glxinfo against dead X, sha512sum on wedged
    # storage) would otherwise hang this probe forever - the exact silent-watcher
    # failure this tooling exists to kill. Portable (macOS has no timeout(1)).
    PROBE_OUT="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=5 -o ServerAliveCountMax=12 \
        "root@${ip}" "GPU_VENDOR=${gpu} sh -s" 2>/dev/null <<'EOSH'
echo "PROBE_OK=1"
if [ -d /run/archiso ]; then echo "OS=partyos-ram"; else echo "OS=other"; fi
echo "ROOTFS=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)"
echo "CMDLINE_SRV=$(tr ' ' '\n' </proc/cmdline 2>/dev/null | grep '^archiso_http_srv=' | head -1)"
echo "UPSINCE=$(uptime -s 2>/dev/null || echo unknown)"
SFS=""
for f in /run/archiso/copytoram/airootfs.sfs \
         /run/archiso/httpspace/arch/x86_64/airootfs.sfs \
         /run/archiso/copytoram/arch/x86_64/airootfs.sfs \
         /run/archiso/bootmnt/arch/x86_64/airootfs.sfs; do
    [ -f "$f" ] && { SFS="$f"; break; }
done
if [ -n "$SFS" ]; then
    echo "SFS_SHA=$(sha512sum "$SFS" 2>/dev/null | cut -d' ' -f1)"
else
    echo "SFS_SHA="
fi
if pgrep -x xfce4-session >/dev/null 2>&1; then echo "DESKTOP=up"; else echo "DESKTOP=down"; fi
echo "HOMESYNC=$(systemctl is-active partyos-home-sync.timer 2>/dev/null || echo unknown)"
if mount 2>/dev/null | grep -q "/games/"; then echo "BLOB=mounted"; else echo "BLOB=none"; fi
case "${GPU_VENDOR}" in
    nvidia)
        out="$(nvidia-smi -L 2>/dev/null | head -1)"
        if [ -n "$out" ]; then
            echo "GPU_RENDERER=$out"
        else
            ren="$(DISPLAY=:0 glxinfo -B 2>/dev/null | grep 'OpenGL renderer' | head -1)"
            echo "GPU_RENDERER=${ren:-nvidia-smi-failed}"
        fi;;
    *)
        ren="$(DISPLAY=:0 glxinfo -B 2>/dev/null | grep 'OpenGL renderer' | head -1)"
        if [ -n "$ren" ]; then
            echo "GPU_RENDERER=$ren"
        else
            echo "GPU_RENDERER=$(ls /dev/dri/renderD* 2>/dev/null | head -1)"
        fi;;
esac

# --- extended read-only feature probes (Tier-1) --
# Everything below is a READ: no writes, no restarts, no reboots - it only reads
# files, unit state, process/socket state and the desktop user's xfconf/wpctl.
# player-visible features that ship but were never verified on a booted client
# (icons, theme, panel, lock wiring, identity, static IP, seeder, audio, clock,
# journal, usb-poll, thunar, portal, kbd/tz). Each emits KEY=VALUE
# lines the host evaluator turns into PASS/FAIL; an unreadable value stays empty
# and is treated as "unknown" (never a false FAIL), matching the sha/gpu cells.
U1000="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
UHOME1000="$(getent passwd 1000 2>/dev/null | cut -d: -f6)"
RUN1000="/run/user/1000"
echo "USER1000=${U1000}"
# urun CMD... - run inside the uid-1000 desktop session (xfconf/wpctl live there,
# not in root's env). Empty output if the user/session can't be reached.
urun() {
    [ -n "${U1000}" ] || return 0
    command -v runuser >/dev/null 2>&1 || return 0
    runuser -u "${U1000}" -- env DISPLAY=:0 XDG_RUNTIME_DIR="${RUN1000}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=${RUN1000}/bus" "$@" 2>/dev/null
}
# stick identity: run the on-image parser CLI (never source a stick-controlled file).
STICK_USER="$(/usr/local/bin/partyos-cfg USERNAME /mnt/usbhome/.partyos 2>/dev/null)"
[ -n "${STICK_USER}" ] || STICK_USER=gamer
echo "STICK_USER=${STICK_USER}"

# 1/21. App-store icons + Win95 skel tiles: the icons ARE the store, 0 = no games.
APPDIR="${UHOME1000}/.local/share/applications"
DESKDIR="${UHOME1000}/Desktop"
echo "APP_LAUNCHERS=$(ls "${APPDIR}"/partyos-app-*.desktop 2>/dev/null | wc -l | tr -d ' ')"
echo "DESK_TILES=$(find "${DESKDIR}" -maxdepth 3 -name 'partyos-app-*.desktop' 2>/dev/null | wc -l | tr -d ' ')"
_skel=0
for _t in cmd.exe.desktop control-panel.desktop my-computer.desktop faq.desktop \
          report-an-issue.desktop "Recycle Bin.desktop"; do
    [ -e "${DESKDIR}/${_t}" ] && _skel=$((_skel + 1))
done
echo "SKEL_TILES=${_skel}"

# 3. Chicago95 theme applied at RUNTIME (xfsettingsd reverts to Adwaita otherwise).
echo "THEME_NAME=$(urun xfconf-query -c xsettings -p /Net/ThemeName)"
echo "ICON_THEME=$(urun xfconf-query -c xsettings -p /Net/IconThemeName)"

# 4. Panel layout: the Win95 bottom bar must be up. Count the xfce4-panel PROCESS by
# owner uid 1000 - reliable from root (no session bus needed), unlike the old xfconf
# `-p /panels -l` list which only emits per-leaf paths (/panels/panel-1/position, ...)
# and never a bare /panels/panel-N, so `grep -cE '^/panels/panel-[0-9]+$'` mis-counted
# a LIVE panel as 0 and false-failed the host. 0 = panel dead, 2+ = a stray/duplicate
# panel process. PANEL_POS (read via the session) corroborates a live, configured panel.
echo "PANEL_COUNT=$(pgrep -u 1000 xfce4-panel 2>/dev/null | wc -l | tr -d ' ')"
echo "PANEL_POS=$(urun xfconf-query -c xfce4-panel -p /panels/panel-1/position | tr -d '\n')"

# 2. Screensaver/lock wiring: LockCommand routed to our gated wrapper, xscreensaver
# saver-only (lock:False), and IF a password is set the xss-lock idle bridge running.
echo "LOCK_CMD=$(urun xfconf-query -c xfce4-session -p /general/LockCommand)"
if [ -f "${UHOME1000}/.xscreensaver" ]; then
    if grep -qE '^lock:[[:space:]]*False' "${UHOME1000}/.xscreensaver" 2>/dev/null; then
        echo "XSS_LOCK_FALSE=yes"; else echo "XSS_LOCK_FALSE=no"; fi
else
    echo "XSS_LOCK_FALSE=absent"
fi
if [ -s /mnt/usbhome/.partyos-passwd ]; then echo "PW_SET=yes"; else echo "PW_SET=no"; fi
if pgrep -u 1000 -x xss-lock >/dev/null 2>&1; then echo "XSS_LOCK_RUN=yes"; else echo "XSS_LOCK_RUN=no"; fi

# 5. Autologin identity: WHOSE session is up, not just that one is. uid must be 1000.
_sp="$(pgrep -x xfce4-session 2>/dev/null | head -1)"
if [ -n "${_sp}" ]; then
    _su="$(ps -o user:32= -p "${_sp}" 2>/dev/null | tr -d ' ')"
    echo "SESS_USER=${_su}"
    echo "SESS_UID=$(id -u "${_su}" 2>/dev/null)"
else
    echo "SESS_USER="; echo "SESS_UID="
fi

# 7. Static IP actually applied (not a lucky DHCP lease at the pinned address).
STATIC_RAW="$(/usr/local/bin/partyos-cfg STATIC_IP /mnt/usbhome/user.conf 2>/dev/null)"
STATIC_ADDR="${STATIC_RAW%%/*}"
echo "STATIC_WANT=${STATIC_ADDR}"
if [ -n "${STATIC_ADDR}" ]; then
    if ip -4 -o addr show 2>/dev/null | grep -qF " ${STATIC_ADDR}/"; then
        echo "STATIC_ON_NIC=yes"; else echo "STATIC_ON_NIC=no"; fi
else
    echo "STATIC_ON_NIC=n/a"
fi
echo "STATICIP_ACTIVE=$(systemctl is-active partyos-staticip.service 2>/dev/null || echo unknown)"

# 6. Client boot-seeding (the "clients seed forever" P2P design rests on this unit).
echo "SEEDER_ACTIVE=$(systemctl is-active partyos-seeder.service 2>/dev/null || echo unknown)"
echo "ARIA2_LISTEN=$(ss -ltnp 2>/dev/null | grep -c aria2)"

# 14. Clock sync: timer live + client epoch (drift vs this host is judged remotely).
echo "TIMESYNC_ACTIVE=$(systemctl is-active partyos-timesync.timer 2>/dev/null || echo unknown)"
echo "CLOCK_EPOCH=$(date +%s 2>/dev/null)"

# 11. Audio: the default sink must be onboard analog, not HDMI (silent-HDMI bug).
if command -v wpctl >/dev/null 2>&1 && [ -n "${U1000}" ]; then
    _ds="$(urun wpctl status | awk '/Sinks:/{f=1;next} /Sources:/{f=0} f' \
            | grep '\*' | sed 's/.*\*[[:space:]]*[0-9]*\.[[:space:]]*//; s/\[vol.*//' \
            | sed 's/[[:space:]]*$//' | head -1)"
    echo "AUDIO_SINK=${_ds}"
    case "$(printf '%s' "${_ds}" | tr 'A-Z' 'a-z')" in
        "")                       echo "AUDIO_IS_HDMI=unknown";;
        *hdmi*|*displayport*|*dp*) echo "AUDIO_IS_HDMI=yes";;
        *)                        echo "AUDIO_IS_HDMI=no";;
    esac
else
    echo "AUDIO_SINK="; echo "AUDIO_IS_HDMI=unknown"
fi

# 8. Journal persistence: a fresh *.journal snapshot landed on the stick this boot.
_jd=/mnt/usbhome/.partyos-journal
_newest="$(ls -1dt "${_jd}"/boot-* 2>/dev/null | head -1)"
if [ -n "${_newest}" ]; then
    echo "JOURNAL_NEWEST_AGE=$(( $(date +%s) - $(stat -c %Y "${_newest}" 2>/dev/null || echo 0) ))"
    if ls "${_newest}"/*.journal >/dev/null 2>&1; then
        echo "JOURNAL_HAS_JOURNAL=yes"; else echo "JOURNAL_HAS_JOURNAL=no"; fi
else
    echo "JOURNAL_NEWEST_AGE="; echo "JOURNAL_HAS_JOURNAL=no"
fi
# 8b. System health: a FLOOD of failed units = something regressed broadly.
echo "FAILED_UNITS=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l | tr -d ' ')"
echo "FAILED_UNIT_NAMES=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{printf "%s%s", sep, $1; sep=","} END{print ""}')"

# 10. usb-poll reconciler: alive and NOT churning (journal churn).
echo "USBPOLL_ACTIVE=$(systemctl is-active partyos-usb-poll.service 2>/dev/null || echo unknown)"
echo "USBPOLL_CHURN=$(journalctl -u partyos-usb-poll.service --since '-2 min' -q --no-pager 2>/dev/null | wc -l | tr -d ' ')"

# 23. Patched Thunar (.desktop trust) installed - stock silently ships raw names.
echo "THUNAR_PKG=$(pacman -Q thunar 2>/dev/null)"

# 20. Portal cached at boot + NYET Messenger (HexChat) seeded config present.
if [ -s /var/lib/partyos/portal/index.html ]; then echo "PORTAL_CACHED=yes"; else echo "PORTAL_CACHED=no"; fi
if [ -f "${UHOME1000}/.config/hexchat/servlist.conf" ]; then echo "HEXCHAT_SERVLIST=yes"; else echo "HEXCHAT_SERVLIST=no"; fi

# 25. Keyboard layout + timezone actually applied from user.conf (or defaults).
echo "KBD_LAYOUT=$(grep -i 'XkbLayout' /etc/X11/xorg.conf.d/00-keyboard.conf 2>/dev/null | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)"
echo "TZ_SET=$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]')"
EOSH
)" || rc=$?
    return "${rc}"
}

# pval KEY - extract a value from the last probe output (empty if absent).
pval() { printf '%s\n' "${PROBE_OUT}" | sed -n "s/^${1}=//p" | head -1; }

# ef TAG REASON - record an extended-probe FAILURE for the host under evaluation.
# Relies on bash dynamic scope: EXT_FAILS/result/reason are locals of check_host,
# so appending here flips that host's verdict without threading return values.
ef() { EXT_FAILS="${EXT_FAILS}${EXT_FAILS:+,}$1"; result="FAIL"; reason="${reason}$2; "; }

# --- per-host evaluation ----------------------------------------------------
# check_host NAME IP GPU QUIRKS BOOTCELL - probe, evaluate, write JSON, append
# a matrix row. Sets HOST_RESULT to PASS|FAIL|UNREACHABLE.
MATRIX_ROWS=""
FAILED=0
check_host() {
    local name="$1" ip="$2" gpu="$3" quirks="$4" bootcell="$5"
    local reach os sha_cell desktop homesync gpucell blob result
    local rootfs cmdline_srv sfs_sha renderer upsince reason=""
    # extended-probe cells (Tier-1). Default "-" / empty so set -u is satisfied on
    # the not-partyOS / unreachable paths where the extended block never runs.
    local ext_cell="-" EXT_FAILS="" drift="" user1000=""
    local app_l="" desk_t="" skel_t="" theme="" icon_theme="" panel_c="" panel_pos=""
    local lock_cmd="" xss_false="" pw_set="" xss_run="" sess_u="" sess_uid="" stick_u=""
    local static_w="" static_nic="" staticip="" seeder="" aria2="" audio_sink="" audio_hdmi=""
    local ts_active="" clk="" journ_age="" journ_has="" usbpoll="" usbchurn=""
    local failed_units="" failed_names=""
    local thunar="" portal="" hexchat="" kbd="" tz=""

    if probe_host "${ip}" "${gpu}" && [ "$(pval PROBE_OK)" = "1" ]; then
        reach="yes"
        os="$(pval OS)"; rootfs="$(pval ROOTFS)"; cmdline_srv="$(pval CMDLINE_SRV)"
        sfs_sha="$(pval SFS_SHA)"; desktop="$(pval DESKTOP)"
        homesync="$(pval HOMESYNC)"; blob="$(pval BLOB)"
        renderer="$(pval GPU_RENDERER)"; upsince="$(pval UPSINCE)"

        if [ "${os}" != "partyos-ram" ]; then
            # Not our OS (e.g. the host booted its internal disk OS): the
            # smoke checks would be meaningless noise - record and fail.
            sha_cell="-"; desktop="-"; homesync="-"; gpucell="-"; blob="-"
            result="FAIL"; reason="not partyOS-from-RAM (no /run/archiso)"
        else
            # Booted-image identity: sha512 of the sfs sitting in RAM vs the
            # served sha512 file. A mismatch means the host booted a stale
            # image = FAIL; unhashable (no copytoram sfs found) is recorded as
            # unknown, not guessed at.
            if [ -z "${sfs_sha}" ]; then sha_cell="unknown"
            elif [ "${SERVED_SHA}" = "absent" ]; then sha_cell="no-served-sha"
            elif [ "${sfs_sha}" = "${SERVED_SHA}" ]; then sha_cell="match"
            else sha_cell="MISMATCH"; fi

            case "${renderer}" in
                *llvmpipe*)           gpucell="llvmpipe";;
                ""|nvidia-smi-failed) gpucell="fail";;
                *)                    gpucell="ok";;
            esac

            result="PASS"
            if [ "${sha_cell}" = "MISMATCH" ]; then result="FAIL"; reason="${reason}booted sfs != served sfs; "; fi
            if [ "${desktop}" != "up" ]; then result="FAIL"; reason="${reason}desktop down; "; fi
            if [ "${homesync}" != "active" ]; then result="FAIL"; reason="${reason}home-sync ${homesync}; "; fi
            if [ "${gpucell}" != "ok" ]; then result="FAIL"; reason="${reason}gpu ${gpucell} (${renderer}); "; fi
            # blob is informational only: "none" is a valid state on a fresh
            # boot, so it never fails the host on its own.

            # --- extended player-visible feature checks (Tier-1) --------------
            # Read the probe values, then FAIL only on a POSITIVELY-wrong or
            # definitively-absent read (an empty/unknown value = "couldn't
            # observe" = no FAIL), so a headless/session-less host never fails
            # here spuriously. Legitimate variation (no STATIC_IP -> DHCP, no
            # password -> no auto-lock) is skipped, not failed.
            user1000="$(pval USER1000)"; stick_u="$(pval STICK_USER)"
            app_l="$(pval APP_LAUNCHERS)"; desk_t="$(pval DESK_TILES)"; skel_t="$(pval SKEL_TILES)"
            theme="$(pval THEME_NAME)"; icon_theme="$(pval ICON_THEME)"
            panel_c="$(pval PANEL_COUNT)"; panel_pos="$(pval PANEL_POS)"
            lock_cmd="$(pval LOCK_CMD)"; xss_false="$(pval XSS_LOCK_FALSE)"
            pw_set="$(pval PW_SET)"; xss_run="$(pval XSS_LOCK_RUN)"
            sess_u="$(pval SESS_USER)"; sess_uid="$(pval SESS_UID)"
            static_w="$(pval STATIC_WANT)"; static_nic="$(pval STATIC_ON_NIC)"; staticip="$(pval STATICIP_ACTIVE)"
            seeder="$(pval SEEDER_ACTIVE)"; aria2="$(pval ARIA2_LISTEN)"
            audio_sink="$(pval AUDIO_SINK)"; audio_hdmi="$(pval AUDIO_IS_HDMI)"
            ts_active="$(pval TIMESYNC_ACTIVE)"; clk="$(pval CLOCK_EPOCH)"
            journ_age="$(pval JOURNAL_NEWEST_AGE)"; journ_has="$(pval JOURNAL_HAS_JOURNAL)"
            usbpoll="$(pval USBPOLL_ACTIVE)"; usbchurn="$(pval USBPOLL_CHURN)"
            failed_units="$(pval FAILED_UNITS)"; failed_names="$(pval FAILED_UNIT_NAMES)"
            thunar="$(pval THUNAR_PKG)"; portal="$(pval PORTAL_CACHED)"; hexchat="$(pval HEXCHAT_SERVLIST)"
            kbd="$(pval KBD_LAYOUT)"; tz="$(pval TZ_SET)"

            # 1/21 icons: the store is the icons - 0 launchers = no games.
            [ "${app_l:-0}" = "0" ] && ef icons "app-store icons empty (0 launchers)"
            # 3 theme: a positively-wrong theme name (grey Adwaita revert) fails.
            [ -n "${theme}" ] && [ "${theme}" != "Chicago95" ] && ef theme "ThemeName ${theme} != Chicago95"
            [ -n "${icon_theme}" ] && [ "${icon_theme}" != "Chicago95" ] && ef theme "IconThemeName ${icon_theme} != Chicago95"
            # 4 panel: the uid-1000 xfce4-panel process must be up. 0 procs AND an
            # unreadable panel_pos = panel dead (FAIL); 2+ = a stray/duplicate panel
            # process (FAIL). A readable panel_pos corroborates a live, configured
            # panel, so it rescues a transient 0 - never a false-fail on a live box.
            if [ -n "${panel_c}" ]; then
                if [ "${panel_c}" -gt 1 ]; then
                    ef panel "xfce4-panel process count ${panel_c} > 1 (duplicate panel)"
                elif [ "${panel_c}" = "0" ] && [ -z "${panel_pos}" ]; then
                    ef panel "no xfce4-panel process and panel position unreadable"
                fi
            fi
            # 2 lock wiring: gated LockCommand, saver-only, auto-lock armed iff passworded.
            [ -n "${lock_cmd}" ] && [ "${lock_cmd}" != "/usr/local/bin/partyos-lock" ] && ef lock "LockCommand=${lock_cmd}"
            [ "${xss_false}" = "no" ] && ef lock ".xscreensaver lock not False"
            [ "${pw_set}" = "yes" ] && [ "${xss_run}" = "no" ] && ef lock "passworded but xss-lock not armed"
            # 5 identity: the live session user is the stick user, at uid 1000.
            [ -n "${sess_u}" ] && [ "${sess_u}" != "${stick_u}" ] && ef session "session user ${sess_u} != stick ${stick_u}"
            [ -n "${sess_uid}" ] && [ "${sess_uid}" != "1000" ] && ef session "session uid ${sess_uid} != 1000"
            # 7 static IP: only judged when the stick asks for one (else DHCP is valid).
            if [ -n "${static_w}" ]; then
                [ "${static_nic}" != "yes" ] && ef staticip "static ${static_w} not on any NIC"
                [ "${staticip}" != "active" ] && ef staticip "partyos-staticip ${staticip}"
            fi
            # 6 seeder: the boot-seeder unit (oneshot RemainAfterExit) must be active.
            [ "${seeder}" != "active" ] && ef seeder "partyos-seeder ${seeder}"
            # 11 audio: the default sink must not be HDMI.
            [ "${audio_hdmi}" = "yes" ] && ef audio "default sink is HDMI (${audio_sink})"
            # 14 timesync: timer live + client clock within 5s of this host's clock.
            [ "${ts_active}" != "active" ] && ef timesync "partyos-timesync.timer ${ts_active}"
            if [ -n "${clk}" ]; then
                drift=$(( $(date +%s) - clk )); [ "${drift}" -lt 0 ] && drift=$(( -drift ))
                [ "${drift}" -gt 5 ] && ef timesync "clock drift ${drift}s > 5s"
            fi
            # 8 journal: the snapshot MECHANISM must work - a *.journal snapshot for this
            # boot must exist on the stick. Age is NOT a fail signal: the per-boot dir's
            # mtime only bumps when journald rotates a NEW *.journal file, so an idle-but-
            # healthy box legitimately keeps one snapshot dir for many minutes. Age stays
            # informational (H_JOURNAL_AGE); PASS/FAIL keys on the snapshot existing +
            # system health (the failed-unit flood guard below).
            [ "${journ_has}" != "yes" ] && ef journal "no *.journal snapshot on stick"
            # 8b journal health: a flood of failed units means a broad regression.
            [ -n "${failed_units}" ] && [ "${failed_units}" -gt 5 ] && ef failedunits "flood of failed units (${failed_units}: ${failed_names})"
            # 10 usb-poll: alive and not churning (journal churn).
            [ "${usbpoll}" != "active" ] && ef usbpoll "partyos-usb-poll ${usbpoll}"
            [ -n "${usbchurn}" ] && [ "${usbchurn}" -gt 200 ] && ef usbpoll "usb-poll churning (${usbchurn} msgs/2m)"
            # 23 thunar / 20 portal / 25 kbd+tz presence.
            [ -z "${thunar}" ] && ef thunar "thunar not installed"
            [ "${portal}" != "yes" ] && ef portal "portal not cached"
            [ -z "${tz}" ] && ef tz "timezone not set"
            [ -z "${kbd}" ] && ef kbd "keyboard layout not applied"
            ext_cell="${EXT_FAILS:-ok}"
        fi
    else
        reach="no"
        os="-"; rootfs=""; cmdline_srv=""; sfs_sha=""; upsince=""
        sha_cell="-"; desktop="-"; homesync="-"; gpucell="-"; blob="-"; renderer=""
        result="UNREACHABLE"; reason="ssh probe failed (down, or not on the LAN)"
    fi

    # A boot-watch failure (reboot mode) trumps a green probe: the point was a
    # FRESH boot, and we could not prove one.
    case "${bootcell}" in
        ok|-) : ;;
        *) result="FAIL"; reason="${reason}boot-watch ${bootcell}; ";;
    esac

    if [ "${result}" != "PASS" ]; then FAILED=1; fi
    HOST_RESULT="${result}"

    # Per-host JSON evidence (python3 for guaranteed valid JSON).
    H_NAME="${name}" H_IP="${ip}" H_GPU="${gpu}" H_QUIRKS="${quirks}" \
    H_MODE="${MODE}" H_DATE="${DATE_ISO}" H_SERVED_SHA="${SERVED_SHA}" \
    H_BOOT="${bootcell}" H_REACH="${reach}" H_OS="${os}" H_ROOTFS="${rootfs}" \
    H_CMDLINE="${cmdline_srv}" H_SFS_SHA="${sfs_sha}" H_SHA="${sha_cell}" \
    H_DESKTOP="${desktop}" H_HOMESYNC="${homesync}" H_GPUCELL="${gpucell}" \
    H_RENDERER="${renderer}" H_BLOB="${blob}" H_UPSINCE="${upsince}" \
    H_RESULT="${result}" H_REASON="${reason}" \
    H_EXT_RESULT="${ext_cell}" H_EXT_FAILS="${EXT_FAILS}" H_USER1000="${user1000}" \
    H_STICK_USER="${stick_u}" H_APP_LAUNCHERS="${app_l}" H_DESK_TILES="${desk_t}" \
    H_SKEL_TILES="${skel_t}" H_THEME="${theme}" H_ICON_THEME="${icon_theme}" \
    H_PANEL_COUNT="${panel_c}" H_PANEL_POS="${panel_pos}" H_LOCK_CMD="${lock_cmd}" \
    H_XSS_LOCK_FALSE="${xss_false}" H_PW_SET="${pw_set}" H_XSS_LOCK_RUN="${xss_run}" \
    H_SESS_USER="${sess_u}" H_SESS_UID="${sess_uid}" H_STATIC_WANT="${static_w}" \
    H_STATIC_ON_NIC="${static_nic}" H_STATICIP="${staticip}" H_SEEDER="${seeder}" \
    H_ARIA2="${aria2}" H_AUDIO_SINK="${audio_sink}" H_AUDIO_HDMI="${audio_hdmi}" \
    H_TIMESYNC="${ts_active}" H_CLOCK_DRIFT="${drift}" H_JOURNAL_AGE="${journ_age}" \
    H_JOURNAL_HAS="${journ_has}" H_USBPOLL="${usbpoll}" H_USBPOLL_CHURN="${usbchurn}" \
    H_FAILED_UNITS="${failed_units}" H_FAILED_NAMES="${failed_names}" \
    H_THUNAR="${thunar}" H_PORTAL="${portal}" H_HEXCHAT="${hexchat}" \
    H_KBD="${kbd}" H_TZ="${tz}" \
    python3 - > "${RES_DIR}/${name}.json" <<'PY'
import json, os
e = os.environ.get
print(json.dumps({
    "host": e("H_NAME"), "ip": e("H_IP"), "gpu_vendor": e("H_GPU"),
    "quirks": e("H_QUIRKS"), "mode": e("H_MODE"), "date": e("H_DATE"),
    "served_sha": e("H_SERVED_SHA"), "boot": e("H_BOOT"),
    "checks": {
        "reachable": e("H_REACH"), "os": e("H_OS"), "rootfs": e("H_ROOTFS"),
        "cmdline_srv": e("H_CMDLINE"), "sfs_sha": e("H_SFS_SHA"),
        "sha": e("H_SHA"), "desktop": e("H_DESKTOP"),
        "homesync": e("H_HOMESYNC"), "gpu": e("H_GPUCELL"),
        "gpu_renderer": e("H_RENDERER"), "blob": e("H_BLOB"),
        "up_since": e("H_UPSINCE"),
    },
    "extended": {
        "result": e("H_EXT_RESULT"), "fails": e("H_EXT_FAILS"),
        "user1000": e("H_USER1000"), "stick_user": e("H_STICK_USER"),
        "app_launchers": e("H_APP_LAUNCHERS"), "desk_tiles": e("H_DESK_TILES"),
        "skel_tiles": e("H_SKEL_TILES"), "theme": e("H_THEME"),
        "icon_theme": e("H_ICON_THEME"), "panel_count": e("H_PANEL_COUNT"),
        "panel_pos": e("H_PANEL_POS"), "lock_command": e("H_LOCK_CMD"),
        "xscreensaver_lock_false": e("H_XSS_LOCK_FALSE"), "password_set": e("H_PW_SET"),
        "xss_lock_running": e("H_XSS_LOCK_RUN"), "session_user": e("H_SESS_USER"),
        "session_uid": e("H_SESS_UID"), "static_want": e("H_STATIC_WANT"),
        "static_on_nic": e("H_STATIC_ON_NIC"), "staticip_service": e("H_STATICIP"),
        "seeder_service": e("H_SEEDER"), "aria2_listeners": e("H_ARIA2"),
        "audio_sink": e("H_AUDIO_SINK"), "audio_is_hdmi": e("H_AUDIO_HDMI"),
        "timesync_timer": e("H_TIMESYNC"), "clock_drift_s": e("H_CLOCK_DRIFT"),
        "journal_newest_age_s": e("H_JOURNAL_AGE"), "journal_has_journal": e("H_JOURNAL_HAS"),
        "usbpoll_service": e("H_USBPOLL"), "usbpoll_churn_2m": e("H_USBPOLL_CHURN"),
        "failed_units": e("H_FAILED_UNITS"), "failed_unit_names": e("H_FAILED_NAMES"),
        "thunar_pkg": e("H_THUNAR"), "portal_cached": e("H_PORTAL"),
        "hexchat_servlist": e("H_HEXCHAT"), "keyboard_layout": e("H_KBD"),
        "timezone": e("H_TZ"),
    },
    "result": e("H_RESULT"), "reason": e("H_REASON"),
}, indent=2))
PY

    MATRIX_ROWS="${MATRIX_ROWS}| ${name} | ${ip} | ${gpu} | ${bootcell} | ${reach} | ${os} | ${sha_cell} | ${desktop} | ${homesync} | ${gpucell} | ${blob} | ${ext_cell} | ${result} |
"
}

# --- reboot + boot-watch (only in --reboot mode, never by default) ----------
# reboot_and_watch NAME IP QUIRKS - trigger an ssh reboot and watch the netboot
# access log for a fresh PXE boot. Sets BOOTCELL to ok|timeout|stall|fail-marker.
reboot_and_watch() {
    local name="$1" ip="$2" quirks="$3" rc=0
    case "${quirks}" in *manual-power-on*)
        echo "[fleet-verify] NOTE: ${name} needs MANUAL power-on if it powers off instead of rebooting - someone must power it on." >&2
    esac
    echo "[fleet-verify] rebooting ${name} (${ip}) via ssh..." >&2
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=5 -o ServerAliveCountMax=12 \
        "root@${ip}" "systemctl reboot" 2>/dev/null; then
        # The connection dropping mid-reboot is normal; a refused connection is
        # not. Either way the boot-watch below is the real verdict - but note it.
        echo "[fleet-verify] reboot trigger returned non-zero for ${name} (connection drop is normal) - watching anyway" >&2
    fi
    # Stage 1: initramfs network up + sfs fetch starting.
    bootwatch_wait --log "${ACCESS_LOG}" --from-now \
        --marker "REPORT step=copytoram" \
        --timeout "${BOOT_TIMEOUT}" --stall "${BOOT_STALL}" \
        --heartbeat "${BOOT_HEARTBEAT}" --label "${name}-copytoram" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        case "${rc}" in
            "${BOOTWATCH_TIMEOUT}") BOOTCELL="timeout";;
            "${BOOTWATCH_STALL}")   BOOTCELL="stall";;
            *)                      BOOTCELL="fail-marker";;
        esac
        return 0
    fi
    # Stage 2: desktop up. Matched from-now again (step=3 always follows
    # copytoram), still no IP guessing.
    rc=0
    bootwatch_wait --log "${ACCESS_LOG}" --from-now \
        --marker "step=3 status=ok desktop=ready" \
        --timeout "${BOOT_TIMEOUT}" --stall "${BOOT_STALL}" \
        --heartbeat "${BOOT_HEARTBEAT}" --label "${name}-desktop" || rc=$?
    case "${rc}" in
        0)                      BOOTCELL="ok";;
        "${BOOTWATCH_TIMEOUT}") BOOTCELL="timeout";;
        "${BOOTWATCH_STALL}")   BOOTCELL="stall";;
        *)                      BOOTCELL="fail-marker";;
    esac
}

# --- main loop --------------------------------------------------------------
echo "[fleet-verify] mode=${MODE} served-sha=${SERVED_SHA}"
echo "[fleet-verify] results -> ${RES_DIR}"

while IFS='|' read -r name ip gpu quirks; do
    [ -n "${name}" ] || continue
    if [ "${MODE}" = "reboot" ]; then
        if [ "${TARGET}" != "all" ] && [ "${TARGET}" != "${name}" ] && [ "${TARGET}" != "${ip}" ]; then
            continue
        fi
        BOOTCELL="-"
        reboot_and_watch "${name}" "${ip}" "${quirks}"
        check_host "${name}" "${ip}" "${gpu}" "${quirks}" "${BOOTCELL}"
    else
        check_host "${name}" "${ip}" "${gpu}" "${quirks}" "-"
    fi
    echo "[fleet-verify] ${name} (${ip}): ${HOST_RESULT}"
done <<< "${FLEET}"

# --- matrix -----------------------------------------------------------------
MATRIX="${RES_DIR}/matrix.md"
{
    echo "# Fleet verification matrix"
    echo
    echo "- date: ${DATE_ISO}"
    echo "- mode: ${MODE}"
    echo "- served sfs sha: ${SERVED_SHA}"
    echo "- sha file: ${SHA_FILE}"
    echo
    echo "| host | ip | gpu | boot | reachable | os | sha | desktop | homesync | gpu-render | blob | ext | result |"
    echo "|------|----|-----|------|-----------|----|-----|---------|----------|------------|------|-----|--------|"
    printf '%s' "${MATRIX_ROWS}"
} > "${MATRIX}"

echo
cat "${MATRIX}"
echo

if [ "${FAILED}" -ne 0 ]; then
    echo "[fleet-verify] RESULT: FAIL (see ${RES_DIR})"
    exit 1
fi
echo "[fleet-verify] RESULT: all checked hosts PASS (${RES_DIR})"
exit 0
