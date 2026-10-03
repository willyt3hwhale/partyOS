#!/usr/bin/env bash
# test-fleet-verify.sh - hardware-FREE test for scripts/deploy/fleet-verify.sh,
# the cross-host verification matrix tool. NO real network calls: ssh is mocked
# via a PATH shim that answers per-IP with canned probe output (the remote
# nvidia-smi/glxinfo answers are part of that canned ssh output, since they run
# ON the remote side). The served-sha file and results dir are redirected to a
# temp dir, so the real repo state and the real test machines are never touched.
#
# Covers: --check against a mocked fleet (one healthy host, one llvmpipe
# failure, one unreachable), matrix.md content (date + served sha header, one
# row per host, correct verdicts), per-host JSON fields, exit codes (non-zero
# on any FAIL/UNREACHABLE, zero on an all-healthy fleet), that --check never
# issues a reboot (a precise detector with a positive control, which skips
# comment prose), the Tier-1 grading both ways (healthy answers PASS, bad
# answers FAIL the host), that --reboot REFUSES to run without an explicit target,
# and the --reboot happy/unhappy paths end to end against a synthetic access
# log: trigger issued, copytoram + desktop markers boot-watched (boot=ok), and
# a boot that never reports STALLING - with the boot-watch failure overriding
# an otherwise green probe (FAIL, never a false PASS).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

FLEET_SH="${REPO_ROOT}/scripts/deploy/fleet-verify.sh"
[ -f "${FLEET_SH}" ] || { echo "FAIL: fleet-verify.sh not found at ${FLEET_SH}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-fleettest.XXXXXX")"
cleanup() { rm -rf "${TMPDIR_T}"; }
trap cleanup EXIT

SHIM="${TMPDIR_T}/shim"
RESULTS="${TMPDIR_T}/results"
MOCK_LOG="${TMPDIR_T}/ssh-calls.log"
SHA_FILE="${TMPDIR_T}/airootfs.sha512"
mkdir -p "${SHIM}" "${RESULTS}"

# The "served" sfs sha the healthy host's booted sha must match.
GOOD_SHA="aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff000011112222333344445555666677778888"
echo "${GOOD_SHA}  airootfs.sfs" > "${SHA_FILE}"

# --- the ssh PATH shim ------------------------------------------------------
# Answers per target IP: .1 healthy intel, .2 nvidia wedged on llvmpipe,
# .3 unreachable (exit 255, like a timed-out ConnectTimeout). Records BOTH
# the argv AND the piped stdin (the remote probe script) into MOCK_LOG, so the
# read-only assert can inspect everything that would reach a real host. The
# OUTER heredoc is UNquoted on purpose: ${GOOD_SHA} expands at write time (the
# shim carries the literal sha), while the \$-escaped vars stay runtime.
cat > "${SHIM}/ssh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "${MOCK_LOG}"
cat >> "${MOCK_LOG}"   # tee the piped remote script into the log too
target=""
for a in "\$@"; do case "\$a" in root@*) target="\${a#root@}";; esac; done
# tier1_healthy - the extended (Tier-1) probe answers of a healthy client.
# CLOCK_EPOCH is the real "now", so the drift check sees 0s. If MOCK_TIER1_BAD
# is set, some answers are positively wrong (Adwaita theme, 0 launchers, HDMI
# audio, seeder failed), so the grading is tested in both directions.
tier1_healthy() {
    cat <<'T1'
USER1000=gamer
STICK_USER=gamer
DESK_TILES=26
SKEL_TILES=6
PANEL_COUNT=1
PANEL_POS=p=8;x=0;y=0
LOCK_CMD=/usr/local/bin/partyos-lock
XSS_LOCK_FALSE=yes
PW_SET=no
XSS_LOCK_RUN=no
SESS_USER=gamer
SESS_UID=1000
STATIC_WANT=
STATIC_ON_NIC=n/a
STATICIP_ACTIVE=inactive
ARIA2_LISTEN=1
TIMESYNC_ACTIVE=active
JOURNAL_NEWEST_AGE=40
JOURNAL_HAS_JOURNAL=yes
FAILED_UNITS=0
FAILED_UNIT_NAMES=
USBPOLL_ACTIVE=active
USBPOLL_CHURN=3
THUNAR_PKG=thunar 4.18.10-1
PORTAL_CACHED=yes
HEXCHAT_SERVLIST=yes
KBD_LAYOUT=se
TZ_SET=Europe/Stockholm
T1
    echo "CLOCK_EPOCH=\$(date +%s)"
    if [ -n "\${MOCK_TIER1_BAD:-}" ]; then
        printf '%s\n' THEME_NAME=Adwaita ICON_THEME=Chicago95 APP_LAUNCHERS=0 \
            "AUDIO_SINK=HDA Intel HDMI" AUDIO_IS_HDMI=yes SEEDER_ACTIVE=failed
    else
        printf '%s\n' THEME_NAME=Chicago95 ICON_THEME=Chicago95 APP_LAUNCHERS=26 \
            "AUDIO_SINK=Built-in Audio Analog Stereo" AUDIO_IS_HDMI=no SEEDER_ACTIVE=active
    fi
}
case "\${target}" in
    10.0.0.1)
        cat <<'PROBE'
PROBE_OK=1
OS=partyos-ram
ROOTFS=overlay
CMDLINE_SRV=archiso_http_srv=https://10.0.0.100:8443/server/images/custom/
UPSINCE=2026-07-17 10:00:00
SFS_SHA=${GOOD_SHA}
DESKTOP=up
HOMESYNC=active
BLOB=mounted
GPU_RENDERER=OpenGL renderer string: Mesa Intel(R) UHD Graphics 620 (KBL GT2)
PROBE
        tier1_healthy
        exit 0;;
    10.0.0.2)
        cat <<'PROBE'
PROBE_OK=1
OS=partyos-ram
ROOTFS=overlay
CMDLINE_SRV=archiso_http_srv=https://10.0.0.100:8443/server/images/custom/
UPSINCE=2026-07-17 10:05:00
SFS_SHA=${GOOD_SHA}
DESKTOP=up
HOMESYNC=active
BLOB=none
GPU_RENDERER=OpenGL renderer string: llvmpipe (LLVM 17.0.6, 256 bits)
PROBE
        tier1_healthy
        exit 0;;
    *)
        exit 255;;
esac
EOF
chmod +x "${SHIM}/ssh"
# Sanity: the write-time expansion really put the sha into the shim.
grep -q "${GOOD_SHA}" "${SHIM}/ssh" || { echo "FAIL: GOOD_SHA not expanded into the ssh shim"; exit 1; }

# fleet_verify ARGS... - run the real script with the shim first in PATH and
# every override pointed at the temp dir. Callers may pre-set FLEET_* vars
# (fleet table, access log, a per-case results dir) - those win.
# The mocked fleet. fleet_verify passes it unless a case sets FLEET_HOSTS.
TEST_FLEET="host-c|10.0.0.3|amd|manual-power-on
host-b|10.0.0.2|nvidia|-
host-a|10.0.0.1|intel|-"
fleet_verify() {
    PATH="${SHIM}:${PATH}" \
    FLEET_HOSTS="${FLEET_HOSTS:-${TEST_FLEET}}" \
    FLEET_SHA_FILE="${SHA_FILE}" \
    FLEET_RESULTS_DIR="${FLEET_RESULTS_DIR:-${RESULTS}}" \
    bash "${FLEET_SH}" "$@"
}

echo "================ fleet-verify cross-host matrix test ================"

# ----------------------------------------------------------------------------
echo
echo "---- 1. --check on the mocked fleet: healthy + llvmpipe + unreachable ----"
: > "${MOCK_LOG}"
out="$(fleet_verify --check 2>&1)"
rc=$?
assert_false "${rc}" "--check exits non-zero (one FAIL + one UNREACHABLE in the fleet)"
assert_contains "${out}" "host-a (10.0.0.1): PASS"          "healthy host reported PASS"
assert_contains "${out}" "host-b (10.0.0.2): FAIL"        "llvmpipe host reported FAIL"
assert_contains "${out}" "host-c (10.0.0.3): UNREACHABLE" "down host reported UNREACHABLE (never guessed)"

# ----------------------------------------------------------------------------
echo
echo "---- 2. results dir: matrix.md content ----"
RES_DIR="$(ls -d "${RESULTS}"/fleet-* 2>/dev/null | tail -1)"
assert_true "$([ -n "${RES_DIR}" ] && [ -d "${RES_DIR}" ]; echo $?)" "results dir fleet-<timestamp> created"
MATRIX="$(cat "${RES_DIR}/matrix.md" 2>/dev/null)"
assert_contains "${MATRIX}" "- date: "                    "matrix header carries the date"
assert_contains "${MATRIX}" "- served sfs sha: ${GOOD_SHA}" "matrix header carries the served sfs sha"
assert_contains "${MATRIX}" "- mode: check"               "matrix header carries the mode"
assert_contains "${MATRIX}" "| host-a | 10.0.0.1 | intel |" "matrix has the host-a row"
assert_contains "${MATRIX}" "| PASS |"                    "matrix carries a PASS verdict"
assert_contains "${MATRIX}" "| llvmpipe |"                "matrix flags the llvmpipe renderer"
assert_contains "${MATRIX}" "| UNREACHABLE |"             "matrix carries the UNREACHABLE verdict"
assert_contains "${MATRIX}" "| match |"                   "matrix shows the booted-sha match"
# the matrix is also printed to stdout, not only written to disk.
assert_contains "${out}" "| host | ip | gpu |"            "matrix printed to stdout too"

# ----------------------------------------------------------------------------
echo
echo "---- 3. per-host JSON: fields and verdicts ----"
json_field() { # json_field FILE PYEXPR - eval PYEXPR with the parsed dict as d
    F="$1" python3 - "$2" <<'PY'
import json, os, sys
with open(os.environ["F"]) as f:
    d = json.load(f)
print(eval(sys.argv[1]))
PY
}
J="${RES_DIR}/host-a.json"
assert_true "$([ -f "${J}" ]; echo $?)" "host-a.json written"
assert_eq "$(json_field "${J}" 'd["result"]')" "PASS"            "host-a json result PASS"
assert_eq "$(json_field "${J}" 'd["checks"]["os"]')" "partyos-ram" "host-a json os partyos-ram"
assert_eq "$(json_field "${J}" 'd["checks"]["sha"]')" "match"    "host-a json booted sha matches served"
assert_eq "$(json_field "${J}" 'd["served_sha"]')" "${GOOD_SHA}" "host-a json carries the served sha"
assert_eq "$(json_field "${J}" 'd["checks"]["homesync"]')" "active" "host-a json home-sync active"
J="${RES_DIR}/host-b.json"
assert_eq "$(json_field "${J}" 'd["result"]')" "FAIL"            "host-b json result FAIL"
assert_eq "$(json_field "${J}" 'd["checks"]["gpu"]')" "llvmpipe" "host-b json gpu verdict llvmpipe"
assert_contains "$(json_field "${J}" 'd["checks"]["gpu_renderer"]')" "llvmpipe" "host-b json keeps the raw renderer string"
assert_contains "$(json_field "${J}" 'd["reason"]')" "gpu"       "host-b json reason names the gpu"
J="${RES_DIR}/host-c.json"
assert_eq "$(json_field "${J}" 'd["result"]')" "UNREACHABLE"     "host-c json result UNREACHABLE"
assert_eq "$(json_field "${J}" 'd["checks"]["reachable"]')" "no" "host-c json reachable=no"

# ----------------------------------------------------------------------------
echo
echo "---- 4. --check is READ-ONLY: no state-modifying command reaches a host ----"
# The shim logged argv AND the piped probe script, so this covers the payload
# too, not just the command line.
assert_true "$([ -s "${MOCK_LOG}" ]; echo $?)" "the mock log captured the probe payload (non-empty)"
assert_contains "$(cat "${MOCK_LOG}")" "PROBE_OK" "probe payload really was teed into the log"
# modcmds FILE - print each line of FILE that runs a state-modifying command.
# Shell comment lines are skipped: prose such as "no restarts, no reboots" is
# not a command. The rest must match a command word at a command position.
modcmds() {
    grep -vE '^[[:space:]]*#' "$1" | grep -E \
        '(^|[;&|(`[:space:]])(reboot|poweroff|shutdown|halt|mkfs(\.[a-z0-9]+)?|wipefs|rm|dd|tee|truncate)([[:space:]]|;|$)|systemctl[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(restart|stop|start|reload|kill|enable|disable|mask|reboot|poweroff|halt)([[:space:]]|$)|(^|[^0-9&>])>>?[[:space:]]*/(etc|mnt|home|var|usr|boot|dev/sd)' \
        2>/dev/null || true
}
# Positive control: the detector really catches a modifying payload.
CTRL="${TMPDIR_T}/ctrl.sh"
printf '%s\n' '# no restarts, no reboots here' 'echo ok' > "${CTRL}"
assert_eq "$(modcmds "${CTRL}" | wc -l | tr -d ' ')" "0" "detector ignores comment prose (no false positive)"
for bad in 'systemctl reboot' 'systemctl restart partyos-seeder.service' 'x=1; reboot' \
           'echo x > /etc/timezone' 'dd if=/dev/zero of=/dev/sda' 'rm -f /mnt/usbhome/.partyos'; do
    printf '%s\n' "${bad}" > "${CTRL}"
    assert_eq "$(modcmds "${CTRL}" | wc -l | tr -d ' ')" "1" "detector catches: ${bad}"
done
mods="$(modcmds "${MOCK_LOG}")"
[ -n "${mods}" ] && printf '  offending lines:\n%s\n' "${mods}"
assert_eq "$(printf '%s' "${mods}" | grep -c . || true)" "0" "no reboot/restart/write command in anything --check sent"

# ----------------------------------------------------------------------------
echo
echo "---- 5. exit 0 when every checked host is healthy ----"
rc=0
out="$(FLEET_HOSTS="host-a|10.0.0.1|intel|-" fleet_verify --check 2>&1)" || rc=$?
assert_true "${rc}" "healthy-only fleet exits 0"
assert_contains "${out}" "all checked hosts PASS" "healthy-only fleet prints the PASS summary"

# ----------------------------------------------------------------------------
echo
echo "---- 5b. an unhealthy Tier-1 probe fails an otherwise healthy host ----"
rc=0
out="$(MOCK_TIER1_BAD=1 FLEET_HOSTS="host-a|10.0.0.1|intel|-" \
      FLEET_RESULTS_DIR="${RESULTS}/tier1-bad" fleet_verify --check 2>&1)" || rc=$?
assert_false "${rc}" "a Tier-1 failure makes --check exit non-zero"
assert_contains "${out}" "host-a (10.0.0.1): FAIL" "Tier-1 failure grades the host FAIL"
R_T1="$(ls -d "${RESULTS}/tier1-bad"/fleet-* | tail -1)"
T1F="$(json_field "${R_T1}/host-a.json" 'd["extended"]["fails"]')"
for tag in icons theme audio seeder; do
    assert_contains "${T1F}" "${tag}" "Tier-1 fails list names ${tag}"
done
assert_eq "$(json_field "${R_T1}/host-a.json" 'd["checks"]["desktop"]')" "up" "base probe was green (the Tier-1 probes alone flipped it)"
H_T1F="$(json_field "${RES_DIR}/host-a.json" 'd["extended"]["fails"]')"
assert_eq "${H_T1F}" "" "healthy Tier-1 answers produce no extended fails"

# ----------------------------------------------------------------------------
echo
echo "---- 6. --reboot refuses without an explicit target ----"
rc=0
out="$(fleet_verify --reboot 2>&1)" || rc=$?
assert_false "${rc}" "--reboot with no target exits non-zero"
assert_contains "${out}" "refused" "--reboot with no target says it refused"
rc=0
out="$(fleet_verify --reboot --log /dev/null 2>&1)" || rc=$?
assert_false "${rc}" "--reboot followed by another flag (no target) exits non-zero"
rc=0
out="$(fleet_verify --reboot no-such-box 2>&1)" || rc=$?
assert_false "${rc}" "--reboot with an unknown host exits non-zero"
assert_contains "${out}" "refused" "--reboot with an unknown host says it refused"
# and no refusal path ever reached ssh at all.
: > "${MOCK_LOG}"
fleet_verify --reboot 2>/dev/null || true
fleet_verify --reboot no-such-box 2>/dev/null || true
assert_true "$([ ! -s "${MOCK_LOG}" ]; echo $?)" "refused --reboot runs never invoked ssh"

# ----------------------------------------------------------------------------
echo
echo "---- 7. --reboot with a valid target still refuses without an access log ----"
rc=0
out="$(FLEET_ACCESS_LOG="${TMPDIR_T}/no-such-access.log" fleet_verify --reboot host-a 2>&1)" || rc=$?
assert_false "${rc}" "--reboot without the netboot access log exits non-zero"
assert_contains "${out}" "access log" "the error explains the missing access log"

# ----------------------------------------------------------------------------
echo
echo "---- 8. --reboot happy path: trigger + boot-watch both markers -> boot=ok ----"
# Synthetic access log pre-seeded with a STALE copytoram marker from a
# "previous boot" (from-now must skip it); a background appender then plays a
# fresh boot: copytoram first, desktop-ready after. Single-host fleet + short
# watch tuning so the whole run takes a few seconds.
ACCESS="${TMPDIR_T}/http_access.log"
printf '[HTTP] 100.000 REPORT step=copytoram status=stale-previous-boot\n' > "${ACCESS}"
: > "${MOCK_LOG}"
( sleep 1; echo "[HTTP] 200.000 REPORT step=copytoram status=start" >> "${ACCESS}"
  sleep 2; echo "[HTTP] 201.000 REPORT step=3 status=ok desktop=ready user=gamer" >> "${ACCESS}" ) &
rc=0
out="$(FLEET_HOSTS="host-a|10.0.0.1|intel|-" \
      FLEET_RESULTS_DIR="${RESULTS}/reboot-ok" FLEET_ACCESS_LOG="${ACCESS}" \
      FLEET_BOOT_TIMEOUT=20 FLEET_BOOT_STALL=10 FLEET_BOOT_HEARTBEAT=1 \
      fleet_verify --reboot host-a 2>&1)" || rc=$?
wait
assert_true "${rc}" "--reboot happy path exits 0"
assert_contains "$(cat "${MOCK_LOG}")" "systemctl reboot" "the reboot trigger was actually issued over ssh"
assert_contains "${out}" "host-a (10.0.0.1): PASS" "rebooted host reported PASS"
R_OK="$(ls -d "${RESULTS}/reboot-ok"/fleet-* | tail -1)"
assert_contains "$(cat "${R_OK}/matrix.md")" "- mode: reboot" "matrix header says mode reboot"
assert_eq "$(json_field "${R_OK}/host-a.json" 'd["boot"]')" "ok"     "json boot verdict ok"
assert_eq "$(json_field "${R_OK}/host-a.json" 'd["result"]')" "PASS" "json result PASS after a fresh verified boot"

# ----------------------------------------------------------------------------
echo
echo "---- 9. --reboot unhappy path: no report -> STALL trumps the green probe ----"
# The host reboots but never reports (wedged before stage3): the access log
# stays silent, bootwatch STALLs, and even though the ssh probe afterwards
# looks perfectly healthy (the mock still answers green), the host must be
# FAIL - a green probe can never paper over an unproven boot.
printf '[HTTP] 300.000 old line\n' > "${ACCESS}"
rc=0
out="$(FLEET_HOSTS="host-a|10.0.0.1|intel|-" \
      FLEET_RESULTS_DIR="${RESULTS}/reboot-stall" FLEET_ACCESS_LOG="${ACCESS}" \
      FLEET_BOOT_TIMEOUT=30 FLEET_BOOT_STALL=2 FLEET_BOOT_HEARTBEAT=1 \
      fleet_verify --reboot host-a 2>&1)" || rc=$?
assert_false "${rc}" "--reboot with a silent access log exits non-zero"
R_ST="$(ls -d "${RESULTS}/reboot-stall"/fleet-* | tail -1)"
assert_eq "$(json_field "${R_ST}/host-a.json" 'd["boot"]')" "stall"  "json boot verdict stall (wedged, not slow)"
assert_eq "$(json_field "${R_ST}/host-a.json" 'd["result"]')" "FAIL" "green probe does NOT rescue an unproven boot"
assert_contains "$(json_field "${R_ST}/host-a.json" 'd["reason"]')" "boot-watch" "json reason names the boot-watch failure"
assert_contains "$(json_field "${R_ST}/host-a.json" 'd["checks"]["desktop"]')" "up" "probe itself WAS green (desktop up) - proving the override"

assert_summary "test-fleet-verify" || exit 1
echo "test-fleet-verify: ALL PASS"
