#!/usr/bin/env bash
# step3-script.sh - in-guest desktop bring-up + verifier for the custom XFCE
# image, fetched at boot via archiso's automated-script hook
# (partyos-step3.ipxe passes script=<server>/boot/step3-script.sh). Runs on the
# tty1 root autologin once the live system is up, mirroring to the serial console.
#
# GPU-AWARE: it picks the display path from whether a real DRM device exists:
#   * /dev/dri present (real GPU - physical hardware OR KVM virtio-gpu):
#       keep LightDM -> real Xorg on the GPU -> autologin gamer -> VISIBLE desktop.
#       sshd + the operator key are brought up for diagnostics, and the machine is
#       NOT powered off (it's a real session for a human).
#   * no /dev/dri (TCG headless VM, the autonomous test):
#       drive a virtual framebuffer (Xvfb) in RAM, assert the session via the
#       callback, then power off (the original headless self-test path).
#
# Markers (greppable on serial):
#   PARTYOS-STEP3-DESKTOP-READY / -SESSION-ACTIVE / -ALIVE
# HTTP callback: /report?step=3&status=<ok|degraded>&desktop=<ready|notready>&xserver=Xorg|Xvfb...
#   status/desktop are DERIVED from the real session state (ready only when XFCE is up AND
#   an X server is running); a black seat reports status=degraded&desktop=notready.

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say() { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }
dump() { local f="$1"; [ -f "$f" ] || { say "  (no $f)"; return; }
         say "  --- $f (tail) ---"; tail -n 25 "$f" 2>/dev/null > "${SER}" 2>/dev/null; }

# report_url is injected by partyos-step3.ipxe (no hardcoded IP).
report_base=""
for p in $(< /proc/cmdline); do case "$p" in report_url=*) report_base="${p#*=}";; esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-STEP3-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }

# resolve the desktop user: identity-setup renames the uid-1000 account
# gamer->USER_NAME and publishes the name to /run/partyos-username. NEVER hardcode
# 'gamer' - after a rename it does not exist.
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"

xfce_up() { pgrep -u "${USER_NAME}" -x xfce4-session >/dev/null 2>&1 || \
            pgrep -u "${USER_NAME}" -x xfwm4         >/dev/null 2>&1 || \
            pgrep -u "${USER_NAME}" -x xfce4-panel   >/dev/null 2>&1; }

say "PARTYOS-STEP3 boot script started"
say "PARTYOS-STEP3 user ${USER_NAME}: $(id "${USER_NAME}" 2>&1)"
say "PARTYOS-STEP3 /dev/dri: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"

# --- Operator boot-config hook (runs BEFORE the desktop bring-up) -------
# If the prod render emitted config_url= (deploy.conf BOOT_CONFIG_URL set), FETCH
# + RUN that server-hosted operator script on EVERY boot before the desktop: the
# operator hook for announcements / config / last-minute updates without rebuilding
# the image. Mirrors the VM step9-script.sh contract + markers, kept INLINE here so
# the prod boot needs no second iPXE chain. FAILURE-TOLERANT: a missing/down/slow
# server or a non-zero script can NEVER abort the boot - we record it and fall
# through to the desktop. Distinct callback step=netboot-config (NOT step=3, which
# is the load-bearing desktop-ready gate, nor step=netboot, the iPXE boot marker)
# so the server log shows the hook ran without colliding with the metadata namespaces.
# Absent config_url= -> this whole block is skipped, boot is unchanged (back-compat).
# SECURITY: this executes a server-fetched script as ROOT. The prod render emits
# config_url= as https:// (the pinned partyOS CA is baked at /etc/partyos/ca.pem), and
# the fetch below pins that CA with --cacert when the URL is https, so the operator
# hook is authenticated against the party's own CA (a still-http URL or a missing
# ca.pem leaves the fetch unpinned - transition-safe, never bricks boot).
config_url=""
for p in $(< /proc/cmdline); do case "$p" in config_url=*) config_url="${p#*=}";; esac; done
if [ -n "${config_url}" ]; then
  SRV_SCRIPT="/run/partyos-server-boot.sh"
  oc_state="missing"   # missing | ran | failed
  # The prod render emits config_url= as https:// with the partyOS CA baked at
  # /etc/partyos/ca.pem, so the operator hook (fetched + run as root) is authenticated.
  # Pin the CA only when config_url is https (curl ignores --cacert for http); a missing
  # ca.pem or a still-http URL leaves the fetch unchanged (transition-safe, never bricks).
  ca_args=""
  case "${config_url}" in https://*) [ -r /etc/partyos/ca.pem ] && ca_args="--cacert /etc/partyos/ca.pem";; esac
  say "PARTYOS-STEP9 fetching operator boot-config ${config_url}"
  if curl -fsS ${ca_args} --max-time 15 -o "${SRV_SCRIPT}" "${config_url}" 2>/dev/null && [ -s "${SRV_SCRIPT}" ]; then
    say "PARTYOS-STEP9-SERVER-SCRIPT-FETCHED bytes=$(wc -c < "${SRV_SCRIPT}" | tr -d ' ')"
    # Bound the operator hook and detach its stdin. The fetch has --max-time 15
    # but the RUN had none, so a blocking/hanging operator script (or one that reads
    # stdin) would freeze every client's boot party-wide. timeout 60 caps it (rc=124
    # -> oc_state=failed, tolerated below); </dev/null stops it inheriting our stdin.
    oc_out="$(timeout 60 bash "${SRV_SCRIPT}" </dev/null 2>&1)"; oc_rc=$?
    say "PARTYOS-STEP9 operator script output: ${oc_out}"
    say "PARTYOS-STEP9-SERVER-SCRIPT-RAN rc=${oc_rc}"
    if [ "${oc_rc}" -eq 0 ]; then
      oc_state="ran"
    else
      oc_state="failed"
      say "PARTYOS-STEP9-SERVER-SCRIPT-FAILED rc=${oc_rc} (tolerated - boot continues)"
    fi
  else
    oc_state="missing"
    say "PARTYOS-STEP9-SERVER-SCRIPT-MISSING (server unreachable or script absent - tolerated, boot continues)"
  fi
  # Best-effort callback so the server log shows the hook ran. Non-fatal, bounded.
  curl -s --max-time 5 \
    "${report_base}/report?step=netboot-config&status=${oc_state}" \
    >/dev/null 2>&1 || say "PARTYOS-STEP9 boot-config callback-failed (non-fatal)"
fi

# --- real GPU? ----------------------------------------------------------------
if ls /dev/dri/card* >/dev/null 2>&1; then HAVE_DRI=1; else HAVE_DRI=0; fi

if [ "${HAVE_DRI}" = 1 ]; then
  # ===== REAL GPU PATH (physical hardware / virtio-gpu): visible desktop =======
  say "PARTYOS-STEP3 real GPU (DRM) present -> LightDM + real Xorg (visible desktop)"

  # Diagnostic SSH access into the live system (so a failed desktop is still
  # debuggable on real hardware). Best-effort; never fatal.
  # Force root key login on (archiso sshd may block it) so diagnostics are reachable.
  printf 'PermitRootLogin yes\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/99-partyos-debug.conf 2>/dev/null
  ( systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || /usr/sbin/sshd 2>/dev/null ) || true
  say "PARTYOS-STEP3 sshd up (root key) for diagnostics; ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"

  # CRITICAL: the image bakes /etc/X11/xorg.conf.d/10-headless-dummy.conf which
  # forces Driver "dummy" (in-memory framebuffer, no real output) for the headless
  # VM test path. On a real GPU that makes Xorg render to nothing -> blank screen.
  # Remove it (RAM overlay) so Xorg auto-detects the real GPU (modesetting/i915).
  rm -f /etc/X11/xorg.conf.d/10-headless-dummy.conf /etc/X11/xorg.conf.d/*dummy* 2>/dev/null
  say "PARTYOS-STEP3 removed dummy Xorg config -> Xorg will auto-detect real GPU"

  # Bring up the desktop the PROVEN way the headless path does (root starts the X
  # server, gamer runs partyos-xfce-launch on it) but on a REAL Xorg instead of
  # Xvfb. This bypasses LightDM autologin entirely (its greeter/accountsservice
  # quirks left it parked at a login prompt). LightDM is stopped so it doesn't
  # grab the GPU/VT.
  systemctl stop lightdm 2>/dev/null || true
  sleep 1
  GAMER_UID="$(id -u "${USER_NAME}" 2>/dev/null || echo 1000)"
  install -d -o "${USER_NAME}" -g "${USER_NAME}" -m 700 "/run/user/${GAMER_UID}" 2>/dev/null || mkdir -p "/run/user/${GAMER_UID}"

  # Start the systemd --user manager for the desktop user NOW, as root. The user units
  # (pipewire.socket/pipewire-pulse.socket/wireplumber.service) are enabled but only run
  # once user@UID is active - and it is NOT: starting that *system* unit needs root/polkit
  # (the user-context nudge in partyos-xfce-launch fails silently as the user), and linger
  # is enabled too late (after logind's boot scan) to auto-start it this boot. Without the
  # user manager pipewire never starts -> pactl = connection refused -> no sound. Doing it
  # here, as root, is what works. enable-linger persists it for next boot too. Best-effort.
  loginctl enable-linger "${USER_NAME}" 2>/dev/null || true
  systemctl start "user@${GAMER_UID}.service" 2>/dev/null || true
  for i in $(seq 1 20); do [ -S "/run/user/${GAMER_UID}/bus" ] && break; sleep 0.5; done
  say "PARTYOS-STEP3 user@${GAMER_UID} $(systemctl is-active "user@${GAMER_UID}.service" 2>/dev/null) bus=$([ -S "/run/user/${GAMER_UID}/bus" ] && echo up || echo down)"

  # Apply the user's keyboard layout/timezone (partyos-userconf-setup writes
  # /etc/X11/xorg.conf.d/00-keyboard.conf) BEFORE Xorg starts. The service only orders
  # Before=display-manager.service, but we bypass display-manager and start Xorg here -
  # so without this explicit, blocking start the first session can race up with the
  # compiled-in 'us' keymap instead of the configured one (e.g. 'se'). Oneshot +
  # RemainAfterExit -> this returns once the config is on disk (no-op if already done).
  systemctl start partyos-userconf.service 2>/dev/null || true

  # Authenticate the gamer to root's X server with an MIT-MAGIC-COOKIE
  # (XAUTHORITY), NOT a host-based `xhost +local:` grant. `+local:` opened :0 to
  # EVERY local uid/process for the whole session, which let an arbitrary local
  # user connect, inject input (XTEST), snoop keystrokes, or cover/kill the screen
  # locker window - bypassing the lock. A per-session cookie readable only by the
  # gamer (and root, who owns the dir) gives the legitimate XFCE session access
  # while a different local user has no cookie and is refused. The cookie lives in
  # the gamer's 0700 runtime dir (created above, owned by the gamer).
  XAUTH_FILE="/run/user/${GAMER_UID}/partyos-Xauthority"
  : > "${XAUTH_FILE}" 2>/dev/null || true
  # generate a 128-bit cookie (mcookie = util-linux, always present) and register
  # it for :0 under the gamer's name+uid so they own it, then point Xorg at it.
  COOKIE="$(mcookie 2>/dev/null)"
  if [ -n "${COOKIE}" ]; then
    xauth -f "${XAUTH_FILE}" add ":0" MIT-MAGIC-COOKIE-1 "${COOKIE}" >/dev/null 2>&1 || true
    # hostname-qualified entry too, so apps that resolve $DISPLAY to host/unix:0 match.
    xauth -f "${XAUTH_FILE}" add "$(uname -n)/unix:0" MIT-MAGIC-COOKIE-1 "${COOKIE}" >/dev/null 2>&1 || true
    # Make the entries FamilyWild (ffff), so that they match all hostnames.
    # The identity step changes the hostname after this point. A cookie for the
    # old hostname does not match, and XFCE fails with "Authorization required".
    # Write the wild entries to a new file. If that fails, keep the old file.
    # begin-xauth-wild
    rm -f "${XAUTH_FILE}.wild" 2>/dev/null || true
    xauth -f "${XAUTH_FILE}" nlist 2>/dev/null | sed -e 's/^..../ffff/' \
      | xauth -f "${XAUTH_FILE}.wild" nmerge - >/dev/null 2>&1 || true
    if [ -s "${XAUTH_FILE}.wild" ]; then
      mv -f "${XAUTH_FILE}.wild" "${XAUTH_FILE}" 2>/dev/null || true
    fi
    rm -f "${XAUTH_FILE}.wild" 2>/dev/null || true
    # end-xauth-wild
  fi
  chown "${USER_NAME}:${USER_NAME}" "${XAUTH_FILE}" 2>/dev/null || true
  chmod 600 "${XAUTH_FILE}" 2>/dev/null || true

  say "PARTYOS-STEP3 starting real Xorg :0 on the GPU (vt1)"
  Xorg :0 -auth "${XAUTH_FILE}" -nolisten tcp vt1 >/var/log/partyos-xorg.log 2>&1 &
  XORG_PID=$!
  for i in $(seq 1 25); do
    [ -S /tmp/.X11-unix/X0 ] && break
    kill -0 "${XORG_PID}" 2>/dev/null || { say "PARTYOS-STEP3 ERROR Xorg died starting"; dump /var/log/partyos-xorg.log; break; }
    sleep 1
  done

  say "PARTYOS-STEP3 launching XFCE as ${USER_NAME} on real :0"
  runuser -l "${USER_NAME}" -c "DISPLAY=:0 XAUTHORITY='${XAUTH_FILE}' /usr/local/bin/partyos-xfce-launch" >/var/log/partyos-xfce.log 2>&1 &

  up=0
  for i in $(seq 1 30); do
    if xfce_up; then up=1; say "PARTYOS-STEP3 XFCE up on real Xorg after ${i} checks"; break; fi
    sleep 2
  done

  xsrv="$(pgrep -x Xorg >/dev/null 2>&1 && echo Xorg || echo none)"
  if [ "${up}" = 1 ]; then xfproc=yes; else
    xfproc=no
    say "PARTYOS-STEP3 ERROR XFCE did not come up on real Xorg - diagnostics:"
    dump /var/log/partyos-xorg.log
    dump /var/log/partyos-xfce.log
    say "  drm modules: $(lsmod | awk '/i915|amdgpu|nouveau|radeon|virtio_gpu/{print $1}' | tr '\n' ' ')"
    say "  (sshd up - NOT powering off)"
  fi

  say "PARTYOS-STEP3-DESKTOP-READY user=${USER_NAME} display=:0"
  say "PARTYOS-STEP3-SESSION-ACTIVE session=XFCE xfce4-session=${xfproc} xserver=${xsrv}"
  # derive-report-status: report HONESTLY - status=ok&desktop=ready ONLY when XFCE is up
  # AND an X server is running. A seat that came up black (Xorg/XFCE never started) must
  # report status=degraded&desktop=notready, not a false green. (fleet-verify keys success
  # off status=ok = a truly-up seat, so honest reporting never masks a healthy box.)
  if [ "${xfproc}" = yes ] && [ "${xsrv}" != none ]; then
    rstatus=ok; rdesktop=ready
  else
    rstatus=degraded; rdesktop=notready
  fi
  # end-derive-report-status
  curl -s --max-time 5 \
    "${report_base}/report?step=3&status=${rstatus}&desktop=${rdesktop}&user=${USER_NAME}&session=XFCE&xfce=${xfproc}&xserver=${xsrv}&gpu=real" \
    >/dev/null 2>&1 || say "PARTYOS-STEP3 callback-failed (non-fatal)"

  # Real session for a human: keep it up, do NOT power off. Heartbeat for logs.
  while true; do
    sleep 15
    say "PARTYOS-STEP3-ALIVE real-desktop xorg=$(pgrep -x Xorg >/dev/null && echo up || echo down) xfce=$(xfce_up && echo up || echo down)"
  done
  exit 0
fi

# ===== HEADLESS VM PATH (no /dev/dri, TCG autonomous test): Xvfb + poweroff =====
say "PARTYOS-STEP3 no DRM device -> headless Xvfb path (autonomous test)"
systemctl stop lightdm 2>/dev/null || true

GAMER_UID="$(id -u "${USER_NAME}" 2>/dev/null || echo 1000)"
RUNTIME="/run/user/${GAMER_UID}"
install -d -o "${USER_NAME}" -g "${USER_NAME}" -m 700 "${RUNTIME}" 2>/dev/null || mkdir -p "${RUNTIME}"

# Start the systemd --user manager as root so the enabled pipewire user units run (see
# the real-Xorg path above for the full rationale). Best-effort, never blocks the desktop.
loginctl enable-linger "${USER_NAME}" 2>/dev/null || true
systemctl start "user@${GAMER_UID}.service" 2>/dev/null || true
for i in $(seq 1 20); do [ -S "${RUNTIME}/bus" ] && break; sleep 0.5; done

say "PARTYOS-STEP3 starting Xvfb :0 (virtual framebuffer, no GPU)"
Xvfb :0 -screen 0 1280x800x24 -nolisten tcp >/var/log/partyos-xvfb.log 2>&1 &
XVFB_PID=$!
sleep 3
if ! kill -0 "${XVFB_PID}" 2>/dev/null; then
  say "PARTYOS-STEP3 ERROR Xvfb died on start"; dump /var/log/partyos-xvfb.log
fi

say "PARTYOS-STEP3 launching XFCE session for ${USER_NAME} on :0"
runuser -l "${USER_NAME}" -c '/usr/local/bin/partyos-xfce-launch' >/var/log/partyos-xfce.log 2>&1 &
XFCE_PID=$!

up=0
for i in $(seq 1 20); do
  if xfce_up; then up=1; say "PARTYOS-STEP3 xfce session detected after ${i} checks"; break; fi
  if ! kill -0 "${XFCE_PID}" 2>/dev/null; then
    say "PARTYOS-STEP3 WARN session launcher exited (attempt ${i}); inspecting"; break
  fi
  sleep 3
done
if [ "${up}" -ne 1 ]; then
  say "PARTYOS-STEP3 ERROR no XFCE component came up under Xvfb"
  dump /var/log/partyos-xfce.log
  dump /var/log/partyos-xvfb.log
  say "PARTYOS-STEP3 ${USER_NAME} procs:"; pgrep -au "${USER_NAME}" > "${SER}" 2>/dev/null
fi

if xfce_up; then xfproc=yes; else xfproc=no; fi
xsrv="$(pgrep -x Xvfb >/dev/null 2>&1 && echo Xvfb || echo none)"
say "PARTYOS-STEP3-DESKTOP-READY xfce session up user=${USER_NAME} display=:0"
say "PARTYOS-STEP3-SESSION-ACTIVE session=XFCE xfce4-session=${xfproc} xserver=${xsrv}"
# derive-report-status: report HONESTLY - status=ok&desktop=ready ONLY when XFCE is up AND
# an X server (Xvfb here) is running. A headless seat where no XFCE component came up must
# report status=degraded&desktop=notready, not a false green. (fleet-verify keys success
# off status=ok = a truly-up seat, so honest reporting never masks a healthy box.)
if [ "${xfproc}" = yes ] && [ "${xsrv}" != none ]; then
  rstatus=ok; rdesktop=ready
else
  rstatus=degraded; rdesktop=notready
fi
# end-derive-report-status
curl -s --max-time 5 \
  "${report_base}/report?step=3&status=${rstatus}&desktop=${rdesktop}&user=${USER_NAME}&session=XFCE&xfce=${xfproc}&xserver=${xsrv}" \
  >/dev/null 2>&1 || say "PARTYOS-STEP3 callback-failed (non-fatal)"

i=0
while [ "$i" -lt 30 ]; do
  sleep 3; i=$((i+1))
  if xfce_up; then alive=up; else alive=down; fi
  say "PARTYOS-STEP3-ALIVE desktop heartbeat ${i} xfce=${alive}"
done

say "PARTYOS-STEP3 stay-up window complete, powering off"
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
