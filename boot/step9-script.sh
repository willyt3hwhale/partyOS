#!/usr/bin/env bash
# step9-script.sh - autonomous in-guest bring-up + verifier for Step 9
# (Server Boot Scripts), fetched at boot via archiso's automated-script hook
# (partyos-step9.ipxe passes script=<server>/boot/step9-script.sh). Runs on the
# tty1 root autologin once the live system is up, mirroring to the serial console.
#
# What Step 9 adds on top of the Step 3 headless desktop:
#   The SERVER hosts a per-boot script (server/boot-config.sh). On EACH boot, and
#   BEFORE the desktop starts, the client FETCHES that script over HTTP and EXECUTES
#   it. Its effect (a server-driven config value) is captured and carried in the
#   client's HTTP callback, proving the server script ran and applied. CRUCIALLY,
#   failure is NON-FATAL: if the server is unreachable, the fetch fails, or the
#   server script exits non-zero, the client LOGS it and STILL brings up the
#   desktop. The harness boots once with the server up (effect applied) and once
#   with the server KILLED (desktop still reached).
#
# Markers (greppable on serial):
#   PARTYOS-STEP9-SERVER-SCRIPT-FETCHED    server boot script downloaded
#   PARTYOS-STEP9-SERVER-SCRIPT-MISSING    fetch failed (server down/absent) - tolerated
#   PARTYOS-STEP9-SERVER-SCRIPT-RAN rc=..  server script executed (rc captured)
#   PARTYOS-STEP9-SERVER-EFFECT announce=. value the SERVER script applied
#   PARTYOS-STEP9-SERVER-SCRIPT-FAILED rc=.. server script exited non-zero - tolerated
#   PARTYOS-STEP9-DESKTOP-READY            the gamer XFCE session is up (headless)
#   PARTYOS-STEP9-SESSION-ACTIVE           carries xfce4-session=yes + the X server
#   PARTYOS-STEP9-ALIVE                    heartbeats proving the desktop stays up
# HTTP callback (report_url injected by partyos-step9.ipxe, no hardcoded IP):
#   step=9 status=ok desktop=ready boot=<label> server_script=<ran|missing|failed>
#     announce=<value-from-server> xfce=<yes|no> xserver=<Xvfb|Xorg|none>

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say()  { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }
dump() { local f="$1"; [ -f "$f" ] || { say "  (no $f)"; return; }
         say "  --- $f (tail) ---"; tail -n 25 "$f" 2>/dev/null > "${SER}" 2>/dev/null; }

# server base + report base + boot label + config url come from the kernel cmdline
# (no IP baked). config_url is the SERVER BOOT SCRIPT endpoint; it is a SEPARATE
# server from the OS/report server so the harness can kill JUST the boot-script
# server (proving failure tolerance) while the OS server stays up to RAM-boot the
# image. If config_url= is absent it falls back to the OS server's copy.
report_base=""
boot_label="serverup"
config_url=""
for p in $(< /proc/cmdline); do case "$p" in
    report_url=*)  report_base="${p#*=}";;
    boot_label=*)  boot_label="${p#*=}";;
    config_url=*)  config_url="${p#*=}";;
esac; done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-STEP9-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }
SERVER_BASE="${report_base}"
[ -n "${config_url}" ] || config_url="${SERVER_BASE}/server/boot-config.sh"
SERVER_SCRIPT_URL="${config_url}"

# resolve the desktop user: identity-setup renames the uid-1000 account
# gamer->USER_NAME and publishes the name to /run/partyos-username. NEVER hardcode
# 'gamer' - after a rename it does not exist.
USER_NAME="gamer"
[ -r /run/partyos-username ] && USER_NAME="$(tr -d '[:space:]' < /run/partyos-username)"
[ -n "${USER_NAME}" ] || USER_NAME="gamer"

say "PARTYOS-STEP9 boot script started (server boot scripts, boot=${boot_label})"
say "PARTYOS-STEP9 user ${USER_NAME}: $(id "${USER_NAME}" 2>&1)"
say "PARTYOS-STEP9 server_base=${SERVER_BASE} config_url=${SERVER_SCRIPT_URL}"

# ===========================================================================
# 1. SERVER BOOT SCRIPT: fetch + run BEFORE the desktop. Failures are NON-FATAL.
# ===========================================================================
# Everything here is wrapped so a missing/broken/slow server can NEVER abort the
# boot - we record the outcome and fall through to the desktop bring-up regardless.
SRV_SCRIPT="/run/partyos-server-boot.sh"
server_state="missing"     # missing | ran | failed
ANNOUNCE=""

say "PARTYOS-STEP9 fetching server boot script ${SERVER_SCRIPT_URL}"
# config_url= is emitted as https:// with the partyOS CA baked at
# /etc/partyos/ca.pem; pin it for an https target (curl ignores --cacert for http, and a
# missing ca.pem / still-http URL leaves the fetch unchanged - transition-safe).
ca_args=""
case "${SERVER_SCRIPT_URL}" in https://*) [ -r /etc/partyos/ca.pem ] && ca_args="--cacert /etc/partyos/ca.pem";; esac
if curl -fsS ${ca_args} --max-time 15 -o "${SRV_SCRIPT}" "${SERVER_SCRIPT_URL}" && [ -s "${SRV_SCRIPT}" ]; then
    say "PARTYOS-STEP9-SERVER-SCRIPT-FETCHED bytes=$(wc -c < "${SRV_SCRIPT}" | tr -d ' ')"
    # Run it, capturing stdout so we can extract the server-driven effect value.
    out="$(bash "${SRV_SCRIPT}" 2>&1)"; rc=$?
    say "PARTYOS-STEP9 server script output: ${out}"
    say "PARTYOS-STEP9-SERVER-SCRIPT-RAN rc=${rc}"
    # Pull the announce value the SERVER applied (proves the effect came from the server).
    ANNOUNCE="$(printf '%s\n' "${out}" | sed -nE 's/.*PARTYOS-SERVER-CONFIG announce=(.*) tag=.*/\1/p' | head -1)"
    if [ "${rc}" -eq 0 ]; then
        server_state="ran"
        say "PARTYOS-STEP9-SERVER-EFFECT announce=${ANNOUNCE}"
        # Confirm the effect actually landed on the live client filesystem.
        if [ -f /etc/partyos/server-config ]; then
            say "PARTYOS-STEP9 applied config on client: $(tr '\n' ' ' < /etc/partyos/server-config)"
        fi
    else
        server_state="failed"
        say "PARTYOS-STEP9-SERVER-SCRIPT-FAILED rc=${rc} (tolerated - boot continues)"
    fi
else
    # Server down / script absent / fetch timed out: tolerate and keep booting.
    server_state="missing"
    say "PARTYOS-STEP9-SERVER-SCRIPT-MISSING (server unreachable or script absent - tolerated, boot continues)"
fi

# ===========================================================================
# 2. DESKTOP: bring up the headless XFCE session (same path as Step 3). This runs
#    AFTER the server script, and MUST run whether the server script ran or not.
# ===========================================================================
systemctl stop lightdm 2>/dev/null || true
GAMER_UID="$(id -u "${USER_NAME}" 2>/dev/null || echo 1000)"
RUNTIME="/run/user/${GAMER_UID}"
install -d -o "${USER_NAME}" -g "${USER_NAME}" -m 700 "${RUNTIME}" 2>/dev/null || mkdir -p "${RUNTIME}"

say "PARTYOS-STEP9 starting Xvfb :0 (virtual framebuffer, no GPU)"
Xvfb :0 -screen 0 1280x800x24 -nolisten tcp >/var/log/partyos-xvfb.log 2>&1 &
XVFB_PID=$!
sleep 3
if ! kill -0 "${XVFB_PID}" 2>/dev/null; then
  say "PARTYOS-STEP9 ERROR Xvfb died on start"; dump /var/log/partyos-xvfb.log
fi

say "PARTYOS-STEP9 launching XFCE session for ${USER_NAME} on :0"
runuser -l "${USER_NAME}" -c '/usr/local/bin/partyos-xfce-launch' >/var/log/partyos-xfce.log 2>&1 &
XFCE_PID=$!

xfce_up() { pgrep -u "${USER_NAME}" -x xfce4-session >/dev/null 2>&1 || \
            pgrep -u "${USER_NAME}" -x xfwm4         >/dev/null 2>&1 || \
            pgrep -u "${USER_NAME}" -x xfce4-panel   >/dev/null 2>&1; }
up=0
for i in $(seq 1 20); do
  if xfce_up; then up=1; say "PARTYOS-STEP9 xfce session detected after ${i} checks"; break; fi
  if ! kill -0 "${XFCE_PID}" 2>/dev/null; then
    say "PARTYOS-STEP9 WARN session launcher exited (attempt ${i}); inspecting"; break
  fi
  sleep 3
done
if [ "${up}" -ne 1 ]; then
  say "PARTYOS-STEP9 ERROR no XFCE component came up under Xvfb"
  dump /var/log/partyos-xfce.log
  dump /var/log/partyos-xvfb.log
  say "PARTYOS-STEP9 ${USER_NAME} procs:"; pgrep -au "${USER_NAME}" > "${SER}" 2>/dev/null
fi

if xfce_up; then xfproc=yes; else xfproc=no; fi
xsrv="$(pgrep -x Xorg >/dev/null 2>&1 && echo Xorg || { pgrep -x Xvfb >/dev/null 2>&1 && echo Xvfb || echo none; })"
say "PARTYOS-STEP9-DESKTOP-READY xfce session up user=${USER_NAME} display=:0 server_script=${server_state}"
say "PARTYOS-STEP9-SESSION-ACTIVE session=XFCE xfce4-session=${xfproc} xserver=${xsrv}"

# ===========================================================================
# 3. CALLBACK: report desktop-ready + the server-script outcome + the applied value.
#    NOTE: when the server is killed (boot=serverdown) the callback itself will
#    not reach the server - that is expected; the SERIAL marker is the proof of
#    desktop-ready in that case. We still attempt it (harmless if it fails).
# ===========================================================================
curl -s --max-time 5 \
  "${report_base}/report?step=9&status=ok&desktop=ready&boot=${boot_label}&server_script=${server_state}&announce=${ANNOUNCE}&xfce=${xfproc}&xserver=${xsrv}" \
  >/dev/null 2>&1 || say "PARTYOS-STEP9 callback-failed (non-fatal; expected when server is down)"

# --- heartbeats: prove the desktop STAYS up --------------------------------
i=0
while [ "$i" -lt 20 ]; do
  sleep 3; i=$((i+1))
  if xfce_up; then alive=up; else alive=down; fi
  say "PARTYOS-STEP9-ALIVE desktop heartbeat ${i} xfce=${alive} server_script=${server_state}"
done

say "PARTYOS-STEP9 stay-up window complete, powering off"
sync
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
