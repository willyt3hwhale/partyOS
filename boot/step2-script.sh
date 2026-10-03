#!/usr/bin/env bash
# step2-script.sh - autonomous in-guest verifier for Step 2 (RAM boot).
#
# This is fetched by archiso's automated-script mechanism: partyos.ipxe passes
# script=http://<server>/boot/step2-script.sh on the kernel cmdline; archiso's
# /root/.automated_script.sh downloads and runs it on the tty1 autologin once
# network-online.target is up. By then the airootfs.sfs has already been pulled
# over HTTP into RAM (HTTP boot forces copytoram), so the system is RAM-only.
#
# The autologin/automated script runs on tty1, not the serial console, so we
# explicitly echo to /dev/ttyS0 to make progress observable by the harness over
# serial, and we curl /report so it lands in the HTTP server access log. Both
# channels are how the harness "watches the screen" with no human.
#
# Markers (greppable):
#   PARTYOS-STEP2-LOGIN    reached an automated shell after RAM boot
#   PARTYOS-STEP2-RAMONLY  confirmed running from RAM, no root block device
#   PARTYOS-STEP2-ALIVE    still alive AFTER the harness killed the HTTP server
#                          (the VM-equivalent of "USB removed")

SER=/dev/ttyS0; case "$(systemd-detect-virt 2>/dev/null)" in none|"") SER=/dev/null;; esac
say() { echo "$*" > "${SER}" 2>/dev/null; echo "$*"; }

# Server URL is injected by partyos.ipxe via the report_url= cmdline param so we
# never hardcode an IP. Fall back to the SLIRP gateway if unset.
report_base=""
for p in $(< /proc/cmdline); do
    case "$p" in
        report_url=*) report_base="${p#*=}";;
    esac
done
# No report_url=: fail loudly. The stage still runs; only the reports are lost.
[ -n "${report_base}" ] || { m="PARTYOS-STEP2-NO-SERVER: no report_url= on /proc/cmdline"; echo "${m}" >&2; logger -t partyos -p user.err "${m}" 2>/dev/null || true; }

say "PARTYOS-STEP2-LOGIN reached automated shell"

# --- RAM-only assertion ---------------------------------------------------
# After copytoram the live root is an overlay backed by tmpfs/ram; there must be
# no real backing block device mounted as / . Capture the evidence.
root_src="$(findmnt -no SOURCE / 2>/dev/null || echo unknown)"
mem_line="$(free -m | awk '/^Mem:/{print}')"
# Are there any non-loop, non-ram block-backed mounts of a physical disk for / ?
# On archiso copytoram, / is 'airootfs' (overlay) over tmpfs; cowspace is tmpfs.
ram_ok=1
if findmnt -no SOURCE / 2>/dev/null | grep -qiE '/dev/(sd|vd|nvme|hd)'; then
    ram_ok=0
fi

say "PARTYOS-STEP2 root_src=${root_src}"
say "PARTYOS-STEP2 ${mem_line}"
free -m > "${SER}" 2>/dev/null

if [ "${ram_ok}" -eq 1 ]; then
    say "PARTYOS-STEP2-RAMONLY no physical root device (root=${root_src})"
else
    say "PARTYOS-STEP2-DISKROOT unexpected physical root: ${root_src}"
fi

# --- report via HTTP callback (server still alive at this point) -----------
mem_total="$(free -m | awk '/^Mem:/{print $2}')"
mem_used="$(free -m | awk '/^Mem:/{print $3}')"
curl -s --max-time 5 \
  "${report_base}/report?step=2&status=ok&ramonly=${ram_ok}&root=${root_src}&memtotal=${mem_total}&memused=${mem_used}" \
  > /dev/null 2>&1 || say "callback-failed (non-fatal)"

# --- detach / survive-server-kill proof ------------------------------------
# The harness kills the HTTP server shortly after the step=2 callback lands.
# We then keep printing an ALIVE heartbeat to serial WITHOUT touching the
# network. If the guest were depending on the server (e.g. NFS root), it would
# hang or die here. Surviving + still scheduling proves RAM-only operation.
say "PARTYOS-STEP2 entering detach heartbeat (server may be killed now)"
i=0
while [ "$i" -lt 30 ]; do
    sleep 2
    i=$((i+1))
    say "PARTYOS-STEP2-ALIVE heartbeat ${i} root=${root_src}"
done

say "PARTYOS-STEP2 detach window complete, powering off"
# Clean shutdown so the VM exits and the harness reaps it promptly.
systemctl poweroff --no-block 2>/dev/null || poweroff -f 2>/dev/null || true
