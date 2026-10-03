#!/usr/bin/env bash
# qmp.sh - send a single QMP command to a running VM's QMP unix socket and print
# the JSON reply. Used by the hot-plug test (Step 6) to remove/reinsert the
# virtual USB stick programmatically - the autonomous stand-in for physically
# yanking and reinserting a stick.
#
# QMP requires a handshake: read the greeting, send qmp_capabilities, THEN the
# real command. We do that in one short-lived connection so the command lands on
# a negotiated channel. The reply JSON lines are printed to stdout; callers grep
# for "return" (success) or "error".
#
# Usage:
#   qmp.sh SOCKET 'JSON-COMMAND'
# Example (remove the usb stick with qdev id 'usb0'):
#   qmp.sh /path/step6.qmp '{"execute":"device_del","arguments":{"id":"usb0"}}'
#
# Re-adding a usb-storage device needs its backing drive too; the drive is added
# first (drive_add via human-monitor-command), then the device. See the step6
# test for the exact sequence.
#
# Implementation: python3 (always present on the host) speaks the socket
# directly - no socat dependency.
set -euo pipefail

SOCK="${1:?usage: qmp.sh SOCKET JSON-COMMAND}"
CMD="${2:?usage: qmp.sh SOCKET JSON-COMMAND}"

[ -S "${SOCK}" ] || { echo "qmp: no such socket: ${SOCK}" >&2; exit 2; }

QMP_SOCK="${SOCK}" QMP_CMD="${CMD}" python3 - <<'PY'
import json, os, socket, sys, time

sock_path = os.environ["QMP_SOCK"]
cmd = os.environ["QMP_CMD"]

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sock_path)
buf = b""

def recv_line(timeout=5):
    global buf
    s.settimeout(timeout)
    while b"\n" not in buf:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            return None
        if not chunk:
            return None
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return line.decode(errors="replace")

# 1. Greeting (banner).
recv_line()
# 2. Negotiate capabilities.
s.sendall(b'{"execute":"qmp_capabilities"}\n')
recv_line()  # the {"return":{}} for capabilities
# 3. The real command.
s.sendall((cmd + "\n").encode())

# Print all reply lines for ~1s so async events (DEVICE_DELETED, etc.) are seen
# too; the caller greps for "return"/"error".
deadline = time.time() + 1.5
got_reply = False
while time.time() < deadline:
    line = recv_line(timeout=0.5)
    if line is None:
        if got_reply:
            break
        continue
    print(line)
    if '"return"' in line or '"error"' in line:
        got_reply = True

s.close()
PY
