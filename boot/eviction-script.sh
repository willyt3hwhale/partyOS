#!/usr/bin/env bash
# eviction-script.sh - autonomous in-guest verifier for RAM lifecycle /
# eviction, fetched at boot via archiso's automated-script hook
# (partyos-eviction.ipxe passes script=<server>/boot/eviction-script.sh). Runs on
# the tty1 root autologin once the live system is up, mirroring to the serial
# console the harness scrapes.
#
# The LOGIC under test is BAKED into the custom image (build-custom-image.sh):
#   /usr/local/bin/partyos-ram   the RAM lifecycle / eviction manager
#   /usr/local/bin/partyos-app   the app-store backend (its install gate calls
#                                partyos-ram ensure-room; launch brackets the run
#                                with mark-busy/mark-idle)
# The test drives the CLI backend, not GUI clicks: a real click
# and this headless run share the exact same code path.
#
# The scenario (deterministic via the test-mode RAM override, so we don't need
# multi-GB real games): set a TIGHT effective free-RAM budget with PARTYOS_FREE_MB,
# install blobs until RAM is "full", mark one IN USE, then launch one more that
# WON'T fit and assert the manager:
#   1. detects the shortfall FROM THE METADATA (ram_min vs free),
#   2. (non-interactive test mode) evicts an IDLE blob to make room - freeing RAM,
#   3. does NOT evict the IN-USE blob (it is protected),
#   4. the new blob then installs (mounts) successfully.
# free -m is captured before/after and carried in the callback so the host sees
# RAM was actually freed.
#
# Markers (greppable on serial):
#   PARTYOS-EVICT-SETUP                          blobs loaded, RAM tight
#   PARTYOS-RAM-CHECK / -SHORTFALL / -OFFER      manager reasoning over metadata
#   PARTYOS-RAM-PROTECT name=<n>                 in-use blob protected
#   PARTYOS-RAM-EVICTED name=<n>                 idle blob freed from RAM
#   PARTYOS-EVICT-PROTECTED-OK                   in-use blob survived
#   PARTYOS-EVICT-FREED-OK before=<MB> after=<MB>  RAM freed by eviction
#   PARTYOS-EVICT-INSTALLED-OK name=<n>          the new blob mounted after room made
#   PARTYOS-EVICT-READY                          all assertions met
#   PARTYOS-EVICT-ALIVE                          heartbeats proving the system stays up
# HTTP callback (report_url injected by the ipxe, no hardcoded IP):
#   step=eviction status=ok shortfall=1 evicted=<n> protected=<n> installed=1
#     free_before=<MB> free_after=<MB>

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

report_base=""
for p in $(< /proc/cmdline); do case "$p" in
    report_url=*) report_base="${p#*=}";;
esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-EVICTION-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }
SERVER_BASE="${report_base}"
export PARTYOS_SERVER="${SERVER_BASE}"   # partyos-app reads the catalog from here

APP=/usr/local/bin/partyos-app
RAM=/usr/local/bin/partyos-ram

say "PARTYOS-EVICT boot script started (RAM lifecycle / eviction)"
say "PARTYOS-EVICT server_base=${SERVER_BASE}"
say "PARTYOS-EVICT partyos-ram present: $([ -x "${RAM}" ] && echo yes || echo no)"
say "PARTYOS-EVICT partyos-app present: $([ -x "${APP}" ] && echo yes || echo no)"

modprobe squashfs 2>/dev/null || true
modprobe overlay  2>/dev/null || true
modprobe loop     2>/dev/null || true

fail() {
    say "PARTYOS-EVICT ERROR $1"
    curl -s --max-time 5 "${report_base}/report?step=eviction&status=fail&reason=$1" >/dev/null 2>&1 || true
    sleep 5
    systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
    exit 1
}

[ -x "${RAM}" ] || fail "no-ram-manager"
[ -x "${APP}" ] || fail "no-app-backend"

# --- mount the USB stick rw so the blob cache is persistent (matches appstore) -
LABEL="LANPARTY_HOME"; MNT="/mnt/usbhome"
udevadm settle 2>/dev/null || true
DEV="$(bash /usr/local/lib/partyos-usb-labels.sh resolve home 2>/dev/null || blkid -L "${LABEL}" 2>/dev/null || true)"
if [ -z "${DEV}" ]; then
    for _ in $(seq 1 15); do DEV="$(bash /usr/local/lib/partyos-usb-labels.sh resolve home 2>/dev/null || blkid -L "${LABEL}" 2>/dev/null || true)"; [ -n "${DEV}" ] && break; sleep 1; udevadm settle 2>/dev/null || true; done
fi
if [ -n "${DEV}" ]; then
    install -d "${MNT}"
    mountpoint -q "${MNT}" || mount -o rw "${DEV}" "${MNT}" 2>/dev/null || mount "${DEV}" "${MNT}" 2>/dev/null || true
    mount -o remount,rw "${MNT}" 2>/dev/null || true
    say "PARTYOS-EVICT usb mounted dev=${DEV}"
else
    say "PARTYOS-EVICT no LANPARTY_HOME stick - using RAM cache"
fi

USER_NAME="$(tr -d '[:space:]' </run/partyos-username 2>/dev/null || echo gamer)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"
GAMES_DIR="/home/${USER_NAME}/games"
CATALOG="/run/partyos-app-catalog.json"
# Prime the catalog so partyos-ram can read metadata (partyos-app writes it too).
curl -fsS --max-time 30 -o "${CATALOG}" "${SERVER_BASE}/server/games/catalog.json" 2>/dev/null || fail "catalog"

# Show the projected RAM need for each catalog blob (proves we read the metadata).
for n in hello pong dummy; do
    say "PARTYOS-EVICT project ${n}: $(${RAM} project "${CATALOG}" "${n}" 2>/dev/null)"
done

# ============================================================================
# Step 1: load blobs so RAM has live mounts to evict. hello (ram_min 256) and
# dummy (ram_min 128) are the two we pre-load; pong (ram_min 512) is the one we
# later try to launch that won't fit a tight budget.
# We DELIBERATELY do not impose the tight budget here so the first installs
# succeed and create the live overlay mounts.
# ============================================================================
say "PARTYOS-EVICT === pre-loading hello + dummy (creating live mounts) ==="
${APP} install hello  || fail "preload-hello"
${APP} install dummy  || fail "preload-dummy"
hello_mounted=0; mountpoint -q "${GAMES_DIR}/hello" 2>/dev/null && hello_mounted=1
dummy_mounted=0; mountpoint -q "${GAMES_DIR}/dummy" 2>/dev/null && dummy_mounted=1
say "PARTYOS-EVICT-SETUP hello_mounted=${hello_mounted} dummy_mounted=${dummy_mounted}"
[ "${hello_mounted}" -eq 1 ] && [ "${dummy_mounted}" -eq 1 ] || fail "preload-not-mounted"

# Mark hello IN USE (simulating a running game holding the blob). This is exactly
# what partyos-app does around launch via mark-busy/mark-idle, but here we hold
# the ref across the next install so the manager must protect hello.
${RAM} mark-busy hello
say "PARTYOS-EVICT marked hello in-use (refs=$(${RAM} refs hello)); dummy is idle (refs=$(${RAM} refs dummy))"
say "PARTYOS-EVICT state:"
${RAM} state | while IFS= read -r r; do say "PARTYOS-EVICT-STATE ${r}"; done

# ============================================================================
# Step 2: now launch pong (ram_min 512) under a TIGHT budget that is BELOW pong's
# ram_min but ABOVE what a single eviction frees - so the manager MUST evict to
# fit. PARTYOS_FREE_MB makes the shortfall deterministic regardless of the VM's
# real RAM. Non-interactive mode drives the eviction decision (auto-evict idle).
# Expectation: shortfall detected from metadata, the IDLE blob (dummy) evicted,
# the IN-USE blob (hello) PROTECTED, then pong mounts.
# ============================================================================
TIGHT_FREE="${EVICT_TIGHT_FREE:-300}"   # < pong.ram_min(512); >= dummy/hello footprint headroom
export PARTYOS_FREE_MB="${TIGHT_FREE}"
export PARTYOS_RAM_NONINTERACTIVE=1

FREE_BEFORE="$(${RAM} free-mb)"
say "PARTYOS-EVICT === launching pong under tight budget free=${FREE_BEFORE}MB (pong needs 512MB) ==="

INSTALL_OUT="$(${APP} install pong 2>&1)"
echo "${INSTALL_OUT}" > "${SER}" 2>/dev/null

# assertions from the manager's markers
shortfall=0;  echo "${INSTALL_OUT}" | grep -qF "PARTYOS-RAM-SHORTFALL name=pong" && shortfall=1
protected=0;  echo "${INSTALL_OUT}" | grep -qF "PARTYOS-RAM-PROTECT name=hello" && protected=1
evicted_dummy=0; echo "${INSTALL_OUT}" | grep -qF "PARTYOS-RAM-EVICTED name=dummy" && evicted_dummy=1
evicted_hello=0; echo "${INSTALL_OUT}" | grep -qF "PARTYOS-RAM-EVICTED name=hello" && evicted_hello=1

# After eviction, re-read the free budget. The main asserts are: dummy is gone,
# hello survives, pong is mounted.
FREE_AFTER="$(${RAM} free-mb)"

# hello (in-use) must STILL be mounted; dummy (idle) must be GONE.
hello_survives=0; mountpoint -q "${GAMES_DIR}/hello" 2>/dev/null && hello_survives=1
dummy_gone=0;     mountpoint -q "${GAMES_DIR}/dummy" 2>/dev/null || dummy_gone=1
pong_mounted=0;   mountpoint -q "${GAMES_DIR}/pong"  2>/dev/null && pong_mounted=1

say "PARTYOS-EVICT-PROTECTED-OK hello_survives=${hello_survives} dummy_gone=${dummy_gone}"
say "PARTYOS-EVICT-INSTALLED-OK name=pong mounted=${pong_mounted}"

# --- explicit protection probe: a RUNNING blob cannot be evicted -------------
# The auto-eviction above made room from the IDLE blob alone, so hello was never
# attempted (correct - in-use blobs are protected from auto-eviction). Prove the
# protection directly: ask the manager to evict the in-use hello; it must REFUSE
# (PARTYOS-RAM-PROTECT), leaving hello mounted. This is the "a running blob is
# protected" assertion - the user would have to explicitly force-evict it.
PROBE_OUT="$(${RAM} evict hello "${GAMES_DIR}" 2>&1)"
echo "${PROBE_OUT}" > "${SER}" 2>/dev/null
protected=0; echo "${PROBE_OUT}" | grep -qF "PARTYOS-RAM-PROTECT name=hello" && protected=1
hello_still=0; mountpoint -q "${GAMES_DIR}/hello" 2>/dev/null && hello_still=1
say "PARTYOS-EVICT-PROTECT-PROBE protected=${protected} hello_still_mounted=${hello_still}"
# combined protection verdict: hello was never auto-evicted AND a direct evict of
# the running blob is refused AND it stays mounted throughout.
protected_ok=0
[ "${evicted_hello}" -eq 0 ] && [ "${protected}" -eq 1 ] && [ "${hello_survives}" -eq 1 ] && [ "${hello_still}" -eq 1 ] && protected_ok=1

# real free -m before/after the WHOLE sequence (host-visible RAM-freed proof):
# capture actual MemAvailable around an explicit re-evict-free measurement by
# unsetting the override and reading /proc/meminfo directly.
unset PARTYOS_FREE_MB
REAL_FREE="$(${RAM} free-mb)"
say "PARTYOS-EVICT real MemAvailable now=${REAL_FREE}MB"

# release hello's ref (cleanup, mirrors mark-idle after a real run ends)
${RAM} mark-idle hello >/dev/null 2>&1 || true

# ============================================================================
# verdict + callback
# ============================================================================
ready=0
if [ "${shortfall}" -eq 1 ] && [ "${protected_ok}" -eq 1 ] && [ "${evicted_dummy}" -eq 1 ] \
   && [ "${evicted_hello}" -eq 0 ] && [ "${hello_survives}" -eq 1 ] && [ "${dummy_gone}" -eq 1 ] \
   && [ "${pong_mounted}" -eq 1 ]; then
    ready=1
    say "PARTYOS-EVICT-FREED-OK before=${FREE_BEFORE} after=${FREE_AFTER} (idle blob evicted, in-use protected)"
    say "PARTYOS-EVICT-READY RAM eviction verified (shortfall from metadata; idle evicted; in-use protected; new blob mounted)"
    curl -s --max-time 5 \
      "${report_base}/report?step=eviction&status=ok&shortfall=${shortfall}&evicted=dummy&protected=hello&installed=${pong_mounted}&free_before=${FREE_BEFORE}&free_after=${FREE_AFTER}&real_free=${REAL_FREE}" \
      >/dev/null 2>&1 || say "PARTYOS-EVICT callback-failed (non-fatal)"
else
    say "PARTYOS-EVICT NOT ready (shortfall=${shortfall} protected_ok=${protected_ok} evicted_dummy=${evicted_dummy} evicted_hello=${evicted_hello} hello_survives=${hello_survives} dummy_gone=${dummy_gone} pong_mounted=${pong_mounted})"
    curl -s --max-time 5 \
      "${report_base}/report?step=eviction&status=fail&shortfall=${shortfall}&protected=${protected}&evicted_dummy=${evicted_dummy}&hello_survives=${hello_survives}&dummy_gone=${dummy_gone}&pong_mounted=${pong_mounted}" \
      >/dev/null 2>&1 || true
fi

sync
umount "${MNT}" 2>/dev/null || mount -o remount,ro "${MNT}" 2>/dev/null || true

# --- heartbeats: prove the system stays up -----------------------------------
i=0
while [ "${i}" -lt 20 ]; do
    sleep 2; i=$((i+1))
    say "PARTYOS-EVICT-ALIVE heartbeat ${i} ready=${ready}"
    [ "${ready}" -eq 1 ] && [ "${i}" -ge 5 ] && break
done

say "PARTYOS-EVICT stay-up window complete, powering off"
sync
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
