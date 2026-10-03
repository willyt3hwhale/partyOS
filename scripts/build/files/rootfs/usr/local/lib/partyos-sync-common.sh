#!/usr/bin/env bash
# partyos-sync-common.sh - shared bits for the home pull/push/hotplug helpers.
# Sourced (not executed). Defines the mountpoints, the resolved user, the rsync
# excludes, and the small guard helpers. The fixed uid 1000 is what makes the
# home portable across partyOS boxes (chown -R after every pull/push).
# The per-player identity parser (internyet.env on the exFAT share). The USERNAME
# MOUNT GATE below reads the stick's identity through it.
# shellcheck source=/dev/null
[ -r /usr/local/lib/partyos-internyet.sh ] && . /usr/local/lib/partyos-internyet.sh
MNT="/mnt/usbhome"
USB_HOME="${MNT}/home"          # p2:/home - backs the RAM /home/<user>
SHARE="/mnt/share"              # p3 exFAT cross-OS share (~/Shared)
STATE_FILE="${MNT}/.partyos-home-state"   # generation counter (at p2 ROOT)
PUSH_INPROGRESS="${MNT}/.partyos-home-pushing"  # dropped BEFORE a push, cleared only on a
                                          # COMPLETED push; if a push is SIGKILLed at
                                          # shutdown it survives to the next boot, where
                                          # the pull logs it (p2 ROOT).
# SHARED mount lock: serializes the check-then-mount of /mnt/usbhome (and /mnt/share)
# across the concurrent boot paths - sysinit partyos-usbhome vs udev-coldplug
# partyos-usb-reinserted both race the same "if not mounted -> mount" and stack two
# mounts. Every mount path flocks THIS file so the loser blocks, re-checks, skips.
# NOTE: partyos-usbhome runs sysinit-early and does NOT source this file - it hardcodes
# the SAME literal path. Keep both copies of "/run/partyos-usbhome-mount.lock" identical.
USBHOME_MOUNT_LOCK="/run/partyos-usbhome-mount.lock"
# MUTUAL HOTPLUG lock: serializes the partyos-usb-removed and partyos-usb-reinserted
# handlers against EACH OTHER. Without it a fast yank-then-replug can interleave their
# steps (removed sets PAUSE + umounts while reinserted remounts + clears PAUSE) and strand
# the session in "device present, mount gone, PAUSE set" - a state the poll reconciler
# refuses to heal, so sync stays silently dead. Both handlers flock THIS file for their
# whole body (bounded wait, then proceed with a WARN rather than hang) so the two run to
# completion one-after-the-other and the LAST event (in udev delivery order) wins coherently.
HOTPLUG_LOCK="/run/partyos-hotplug.lock"
PULL_DONE="/run/partyos-home-pull-done"
# PULL_RAN is written on EVERY normal boot-pull exit (stick pulled, no-stick RAM-only,
# read-only USB, or a bad-mount abort) - all of which equally mean "the home config this
# box will use is now settled on disk". DISTINCT from PULL_DONE (which opens the push gate
# and is written ONLY after a clean --delete pull): a no-stick boot writes RAN but not DONE.
# The desktop launcher waits on RAN so xfce4-panel/xfconfd never read the home mid-pull.
PULL_RAN="/run/partyos-home-pull-ran"
# PULL_INPROGRESS is a RAM-side in-flight marker (distinct from PUSH_INPROGRESS, which is
# on the stick): the boot pull AND the reinsert generation-guard pull drop it around their
# USB->RAM rsync and clear it when the copy is done. The runtime push (partyos-sync-home)
# stands down while it exists, so a 45s push tick can never --delete-mirror a HALF-pulled
# RAM home back over the stick mid-pull - the race the poll-kicked reinsert (timer still
# running, PAUSE_FLAG not set) would otherwise hit. In /run: per-boot, gone on reboot.
PULL_INPROGRESS="/run/partyos-home-pull-inprogress"
PAUSE_FLAG="/run/partyos-sync-paused"
RO_FLAG="/run/partyos-sync-disabled"
GEN_FILE="/run/partyos-home-generation"   # what THIS box last synced
UIDGID=1000

# resolve the dynamic desktop account (gamer renamed by identity-setup).
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
HOME_DIR="/home/${USER_NAME}"

# LOGIN_RESOLVED: 1 iff identity-setup has already written /run/partyos-username this boot
# (the logged-in user is known). At pre-identity coldplug it is 0 - the boot path
# (partyos-usbhome + partyos-identity) then DEFINES the login from whatever stick it mounts,
# so there is no "foreign" stick to refuse yet and the USERNAME MOUNT GATE stands down.
LOGIN_RESOLVED=0; [ -r /run/partyos-username ] && LOGIN_RESOLVED=1

# stick_username [CFGFILE] - echo the PROVISIONED username of a stick. This is the SAME
# source + parse identity-setup reads for autologin and hostname, so the gate below can
# never disagree with the account the box logged in as.
#
# The identity moved to `internyet.env` (INTERNYET_USER_NAME) on the stick's shared
# exFAT partition (a share label, /mnt/share). The legacy `.partyos` USERNAME= on the ext4
# home partition is the FALLBACK, so an old stick is still recognised as its owner's.
# Echoes empty for a blank/unprovisioned/absent config (a fresh stick, no identity yet).
# The box's own logged-in identity is ${USER_NAME}.
#
# CFGFILE, when given, overrides the LEGACY path only - the env file is always looked up
# on the share, because the two live on different partitions.
stick_username() {
    local cfg="${1:-${MNT}/.partyos}" envf v
    envf="$(internyet_env_file 2>/dev/null || true)"
    if [ -n "${envf}" ]; then
        v="$(internyet_get INTERNYET_USER_NAME "${envf}" 2>/dev/null || true)"
        v="$(printf '%s' "${v}" | tr -d '[:space:]')"
        [ -n "${v}" ] && { echo "${v}"; return 0; }
    fi
    [ -r "${cfg}" ] || { echo ""; return 0; }
    v="$(grep -E '^[[:space:]]*USERNAME=' "${cfg}" 2>/dev/null \
        | grep -v '^[[:space:]]*#' | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
    echo "${v}"
}

# home_stick_gate STICK_USER LOGIN_USER - the USERNAME MOUNT GATE verdict (one word):
#   mount   - STICK_USER == LOGIN_USER: the box's OWN stick -> mount + sync normally.
#   foreign - STICK_USER is a DIFFERENT named user -> DO NOT mount/sync; refuse + leave alone.
#   blank   - STICK_USER empty (unprovisioned/fresh) -> adoptable as this user's home (the
#             refusal is ONLY for a DIFFERENT named user, never a blank stick).
# A stick's identity is its provisioned USERNAME, not a per-boot box-id: a box always
# recognises its own stick across reboots (same USERNAME), and a foreign player's stick is
# never mounted - so there is no cross-box tie to reconcile (that machinery is gone).
home_stick_gate() {
    local su="$1" lu="$2"
    [ -z "${su}" ] && { echo "blank"; return 0; }
    [ "${su}" = "${lu}" ] && { echo "mount"; return 0; }
    echo "foreign"
}

SKEL="/usr/share/partyos/home-skel"

# rsync excludes: volatile/regenerable data + the ~/Shared mountpoint (p3) so the
# home mirror never recurses into or deletes the exFAT share. ~/games/ is the
# squashfs+tmpfs overlay extraction of cached blobs (regenerable from
# .partyos-cache/games at the p2 root - a DIFFERENT path, untouched here); saves
# live in ~/.config|~/.local/share (synced), never inside ~/games/, so syncing it
# would just copy ~1.2GB of regenerable installs and blow the 60s pull timeout.
RSYNC_EX=(
    --exclude='.cache/'
    --exclude='.local/share/Trash/'
    --exclude='.thumbnails/'
    --exclude='tmp/'
    --exclude='.mozilla/firefox/*/Cache/'
    --exclude='.config/google-chrome/*/Cache/'
    --exclude='.config/chromium/*/Cache/'
    --exclude='*.tmp'
    --exclude='.partyos-sync.lock'
    --exclude='Shared'
    --exclude='games/'
    # app-store launcher tiles: regenerated per-boot from the LAN catalog by gen-launchers
    # (partyos-appstore.service). Exclude from the mirror so the pull's --delete can't wipe
    # freshly-generated tiles before gen-launchers writes them (a race with the home
    # pull); like games/ they are regenerable, never authoritative on the USB.
    --exclude='.local/share/applications/'
    --exclude='Desktop/.apps/'
)

dir_empty() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }
# USB writable? PRECISE ro test via findmnt's parsed OPTIONS, NOT a `mount | grep`.
# The old `mount | grep -qw ro` FALSE-matched the benign `errors=remount-ro` FS option
# (a normal rw mount setting) and disabled persistence on a perfectly healthy stick.
# findmnt's OPTIONS is a comma-separated list; a genuinely read-only mount carries a
# standalone `ro` field, whereas `errors=remount-ro` is its own distinct field that the
# exact-field match below never trips on. Empty options (MNT not a mountpoint, or
# findmnt absent) -> treat as rw so a transient probe failure can never wedge sync off.
is_rw() {
    local _o
    _o="$(findmnt -rno OPTIONS "${MNT}" 2>/dev/null | head -1)"
    [ -z "${_o}" ] && return 0
    case ",${_o}," in *,ro,*) return 1;; esac
    return 0
}

# is $1 a mountpoint backed by exactly device $2? (guards stacked/double mounts)
is_mounted_dev() { mountpoint -q "$1" 2>/dev/null && [ "$(findmnt -no SOURCE "$1" 2>/dev/null | head -1)" = "$2" ]; }

# mount_majmins MOUNTPOINT -> the MAJ:MIN of each device mounted at MOUNTPOINT, one per
# line, no duplicates. A stacked mount gives one line per layer, so the value is unique.
# The data comes from mountinfo (field 3 is MAJ:MIN, field 5 is the mountpoint). It does
# no device I/O. PARTYOS_MOUNTINFO sets another mountinfo file (the tests use it).
mount_majmins() {
    awk -v mp="$1" '$5 == mp { print $3 }' "${PARTYOS_MOUNTINFO:-/proc/self/mountinfo}" 2>/dev/null | sort -u
}

# mounted_dev_present MOUNTPOINT -> exit 0 if the kernel still has a device that is
# mounted at MOUNTPOINT. exit 1 if MOUNTPOINT has mounts and all of their devices are
# gone. exit 2 if nothing is mounted at MOUNTPOINT.
# The test is /sys/dev/block/MAJ:MIN. The kernel removes that entry when the device goes
# away, so the test is exact and it reads no data from the stick. It does not use the
# label, because a second stick can have the same label. PARTYOS_SYSFS sets another
# sysfs root (the tests use it).
mounted_dev_present() {
    local mm majmins
    majmins="$(mount_majmins "$1")"
    [ -n "${majmins}" ] || return 2
    while IFS= read -r mm; do
        [ -e "${PARTYOS_SYSFS:-/sys}/dev/block/${mm}" ] && return 0
    done <<EOF
${majmins}
EOF
    return 1
}
# mount_writers MOUNTPOINT [SELF_PID]  - echo the space-separated PIDs of processes holding
# any file open UNDER MOUNTPOINT (an open fd OR their cwd), EXCLUDING SELF_PID. Pure /proc
# (neither psmisc/fuser nor lsof is in the image), PROCROOT overridable for hardware-free
# unit tests. safe-eject uses this to refuse "safe to remove" while a player's file manager
# or editor is still writing to the lazily-unmountable home/share - esp. the journal-less
# exFAT ~/Shared, where a yank mid-write truncates their file and dirties the FAT for their
# other OS. Best-effort: an fd we cannot readlink (permission) just does not match.
mount_writers() {
    local mp="${1%/}" self="${2:-0}" procroot="${PROCROOT:-/proc}" d pid tgt f found out=""
    [ -n "${mp}" ] || { echo ""; return 0; }
    for d in "${procroot}"/[0-9]*; do
        [ -d "${d}" ] || continue
        pid="${d##*/}"
        [ "${pid}" = "${self}" ] && continue
        tgt="$(readlink "${d}/cwd" 2>/dev/null || true)"
        case "${tgt%/}" in "${mp}"|"${mp}"/*) out="${out} ${pid}"; continue;; esac
        found=0
        for f in "${d}"/fd/*; do
            [ -L "${f}" ] || continue
            tgt="$(readlink "${f}" 2>/dev/null || true)"
            case "${tgt%/}" in "${mp}"|"${mp}"/*) found=1; break;; esac
        done
        [ "${found}" -eq 1 ] && out="${out} ${pid}"
    done
    echo "${out# }"
}
# unmount EVERY stacked layer at $1 until it is no longer a mountpoint (bounded).
# A single umount only drops the top layer; coldplug + boot-mount can stack two.
umount_all() {
    local d="$1" i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        mountpoint -q "${d}" 2>/dev/null || break
        umount -l "${d}" 2>/dev/null || umount -f "${d}" 2>/dev/null || break
    done
}

# Cleanly release the exFAT share ($1 = mountpoint, default ${SHARE}). exFAT
# has no journal, so a yanked stick can leave a dirty/corrupt FAT that confuses the
# player's other OS. We (1) flush pending writes (sync), (2) drain every stacked layer,
# then (3) - only if the backing device still exists (graceful eject, not a surprise
# pull) - run fsck.exfat/exfatfsck best-effort, bounded with `timeout` so a wedged fsck
# can never block eject/removal. All steps are best-effort: a missing exfatprogs, an
# already-gone device, or a non-zero fsck just logs and returns - it NEVER blocks.
share_unmount_clean() {
    local d="${1:-${SHARE}}" dev fsck
    # capture the backing device BEFORE unmount (findmnt is empty once it is gone).
    dev="$(findmnt -no SOURCE "${d}" 2>/dev/null | head -1)"
    sync 2>/dev/null || true        # flush the exFAT share's dirty pages first
    umount_all "${d}"               # drop all stacked layers (bounded, lazy fallback)
    # fsck only makes sense on a still-present device (the safe-eject path). On a
    # surprise removal the node is gone -> skip silently. exfatprogs may be absent.
    [ -n "${dev}" ] && [ -b "${dev}" ] || return 0
    fsck="$(command -v fsck.exfat || command -v exfatfsck || true)"
    [ -n "${fsck}" ] || { echo "partyos: no fsck.exfat/exfatfsck - skipping the share check"; return 0; }
    echo "partyos: fsck the share ${dev} (${fsck})"
    timeout 60 "${fsck}" "${dev}" >/dev/null 2>&1 \
        && echo "partyos: the share ${dev} is clean" \
        || echo "partyos: the share ${dev}: fsck reported issues/aborted (best-effort)"
    return 0
}

# read/advance the generation counter stored at the p2 ROOT.
# gen_read keeps its legacy contract (echo a number, missing/corrupt -> 0) for the
# few read-only callers; the DECISION path below uses gen_read_status instead so it
# can tell "absent" (fresh stick) from "corrupt" (present-but-unparseable) - the two
# must NOT both collapse to 0, or a corrupted counter mis-decides and clobbers data.
gen_read()    { local g; g="$(cat "${STATE_FILE}" 2>/dev/null | tr -cd '0-9')"; echo "${g:-0}"; }
# gen_write N - write the stick counter atomically: a temp file, an fsync of that file,
# a rename, then an fsync of the p2 root directory. A kill at any point leaves the old
# or the new value, never a truncated (corrupt) file. It flushes only these two items.
# A global `sync` here flushes every dirty page of the box (game downloads on the same
# stick included) and blocked for minutes, until systemd killed the push between the
# two counter writes.
gen_write() {
    local tmp="${STATE_FILE}.new"
    echo "${1:-0}" > "${tmp}" 2>/dev/null || return 0
    sync "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${STATE_FILE}" 2>/dev/null || true
    sync "${STATE_FILE%/*}" 2>/dev/null || true
}
gen_baseline(){ echo "${1:-0}" > "${GEN_FILE}" 2>/dev/null || true; }
gen_mine()    { local g; g="$(cat "${GEN_FILE}" 2>/dev/null | tr -cd '0-9')"; echo "${g:-0}"; }

# THE PENDING PUSH (the push-in-progress marker with an owner). A push writes
# "<boot_id> <new_gen>" into PUSH_INPROGRESS before its rsync. The commit order is:
#   1. rsync the home, 2. gen_write new_gen (stick), 3. gen_baseline new_gen (RAM),
#   4. remove the marker.
# If the push is killed between steps 2 and 3, the stick is one generation ahead of
# this box. The marker then still names THIS boot and exactly that generation, so the
# next push knows that the newer stick generation is its own completed mirror, not a
# newer home from another machine. The boot id changes at every boot and only this
# boot writes it, so another machine can never match it. A marker from another box,
# a legacy empty marker, or a different generation does not match.
# PARTYOS_BOOT_ID_FILE sets another boot id file (the tests use it).
boot_id() { tr -d '[:space:]' < "${PARTYOS_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null; }

# push_mark_pending N - write the marker for a push that will commit generation N,
# and fsync only the marker.
push_mark_pending() {
    echo "$(boot_id) ${1:-0}" > "${PUSH_INPROGRESS}" 2>/dev/null || true
    sync "${PUSH_INPROGRESS}" 2>/dev/null || true
}

# gen_own_pending STICK_GEN - exit 0 if the marker says that THIS boot started the
# push that wrote STICK_GEN to the stick (the interrupted commit of this box).
gen_own_pending() {
    local me owner pgen
    me="$(boot_id)"
    [ -n "${me}" ] || return 1
    [ -s "${PUSH_INPROGRESS}" ] || return 1
    read -r owner pgen _ < "${PUSH_INPROGRESS}" 2>/dev/null || return 1
    [ "${owner}" = "${me}" ] && [ "${pgen}" = "${1:-x}" ]
}

# gen_read_status FILE  - echo "STATUS VALUE":
#   absent  0    -> file missing or empty   (genuinely first-ever use: SAFE/fresh)
#   ok      <n>  -> file present, parses to a plain integer
#   corrupt 0    -> file present but holds NO usable digits (e.g. exFAT stick yanked
#                   mid-write left garbage) -> DANGER: do not trust, do not clobber.
# The absent-vs-corrupt split is the whole point: legacy gen_read folded both to 0.
gen_read_status() {
    local f="$1" raw g
    if [ ! -s "${f}" ]; then echo "absent 0"; return 0; fi
    raw="$(cat "${f}" 2>/dev/null)"
    g="$(printf '%s' "${raw}" | tr -cd '0-9')"
    if [ -n "${g}" ]; then echo "ok ${g}"; else echo "corrupt 0"; fi
}

# gen_decide MY_GEN STICK_STATUS STICK_VAL  - echo the sync verdict (one word):
#   push        - stick older/fresh/EQUAL, ours is authoritative: normal --delete-delay push.
#   standdown   - stick strictly newer: do not push (reinsert handler pulls).
#   pull        - stick strictly newer (reinsert context): pull it in.
#   corrupt     - stick gen unreadable: do NOT clobber the stick; skip the push (preserve it).
# The USERNAME MOUNT GATE (partyos-usb-reinserted) guarantees a stick is only ever mounted
# when its provisioned USERNAME matches the logged-in user, so a mounted stick is ALWAYS this
# box's own. That eliminates the old "same gen, DIFFERENT box" cross-box tie: an EQUAL gen is
# now just our OWN steady-state re-mirror (our last push bumped both counters), so it folds
# into the normal push. The per-boot box-id + the separate `tie` verdict that used to split
# those apart are gone. A STRICTLY-newer stick can still legitimately occur for the SAME user
# (they booted their own stick on another of their rigs and brought it back), so standdown/pull
# is KEPT. corrupt still stands down (never clobber an unreadable counter). --delete-delay +
# the rc-gates remain the safety, not a backup.
gen_decide() {
    local mine="$1" status="$2" val="$3"
    case "${status}" in
        corrupt) echo "corrupt"; return 0;;
        absent)  echo "push";    return 0;;   # fresh stick, ours is the truth
    esac
    # status == ok: a real integer to compare.
    if [ "${val}" -gt "${mine}" ] 2>/dev/null; then echo "standdown"; return 0; fi
    echo "push"   # val <= mine: ours is authoritative (older, OR our own equal-gen steady state)
}
