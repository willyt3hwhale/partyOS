#!/usr/bin/env bash
# test-desktop-ready-report.sh - hardware-FREE test for the honest step-3 desktop-ready
# report.
#
# Bug: the desktop-ready callback emitted status=ok&desktop=ready UNCONDITIONALLY - even
# for a seat that came up black (Xorg/XFCE never started) - so the server boot log showed
# green for a dead seat. The report already carried the true xfce=/xserver= fields, but
# the load-bearing status/desktop fields were hardcoded.
#
# Fix: DERIVE status/desktop from the already-computed session state in ALL THREE report
# sites - the two boot/step3-script.sh paths (real-GPU + headless) and the baked
# partyos-desktop-ready runner - so status=ok&desktop=ready only when a session component
# is up AND an X server is running, else status=degraded&desktop=notready.
#
# This asserts the wiring statically, EVAL-tests the real carved derive blocks from each
# site, and BEHAVIOURALLY drives the carved partyos-desktop-ready under stubbed pgrep/curl.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

BUILD="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-desktop-ready"
STEP3="${REPO_ROOT}/boot/step3-script.sh"
[ -f "${BUILD}" ] || { echo "FAIL: partyos-desktop-ready baked file not found at ${BUILD}"; exit 1; }
[ -f "${STEP3}" ] || { echo "FAIL: boot/step3-script.sh not found at ${STEP3}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-readyreport.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

echo "================ 1. no report URL still hardcodes status=ok&desktop=ready ="
# the LITERAL bad URL (report?step=3&status=ok&desktop=ready) must be GONE from every site;
# the derive-block comments mention the phrase but never as a report? URL, so this is exact.
for f in "${STEP3}" "${BUILD}"; do
  bad="$(grep -c 'report?step=3&status=ok&desktop=ready' "${f}" || true)"
  assert_eq "${bad}" "0" "$(basename "${f}"): no report URL hardcodes status=ok&desktop=ready"
done
# and the derived form IS present: step3 has both paths (2), build has the RDY runner (1).
assert_eq "$(grep -c 'report?step=3&status=${rstatus}&desktop=${rdesktop}' "${STEP3}" || true)" "2" \
  "step3-script.sh: both report paths use the derived status=\${rstatus}&desktop=\${rdesktop}"
assert_eq "$(grep -c 'report?step=3&status=${rstatus}&desktop=${rdesktop}' "${BUILD}" || true)" "1" \
  "partyos-desktop-ready: the baked runner uses the derived status=\${rstatus}&desktop=\${rdesktop}"

echo
echo "================ 2. EVAL the REAL carved derive blocks from each site ==="
# extract the Nth `# derive-report-status`..`# end-derive-report-status` body from a file.
carve_derive() { awk -v want="$2" '
  /# derive-report-status/{n++; if(n==want){cap=1; next}}
  /# end-derive-report-status/{if(cap){exit}}
  cap' "$1"; }
# source the carved block with a given (xfproc,xsrv) and echo "rstatus rdesktop".
eval_derive() { ( xfproc="$2"; xsrv="$3"; unset rstatus rdesktop; # shellcheck disable=SC1090
                  source "$1"; echo "${rstatus:-UNSET} ${rdesktop:-UNSET}" ); }

declare -a SITES=("step3 real-GPU:${STEP3}:1" "step3 headless:${STEP3}:2" "baked runner:${BUILD}:1")
for spec in "${SITES[@]}"; do
  name="${spec%%:*}"; rest="${spec#*:}"; file="${rest%:*}"; idx="${rest##*:}"
  blk="${TMPDIR_T}/derive-$(echo "${name}" | tr ' ' _).sh"
  carve_derive "${file}" "${idx}" > "${blk}"
  assert_true "$([ -s "${blk}" ]; echo $?)" "${name}: derive block #${idx} carved"
  bash -n "${blk}" && assert_true 0 "${name}: derive block parses" || assert_true 1 "${name}: derive block parses"
  # a real X server + a live session component -> honest READY
  assert_eq "$(eval_derive "${blk}" yes Xorg)" "ok ready"          "${name}: xfce up + Xorg   -> ok ready"
  assert_eq "$(eval_derive "${blk}" yes Xvfb)" "ok ready"          "${name}: xfce up + Xvfb   -> ok ready"
  # black seat: nothing came up -> NOT ready
  assert_eq "$(eval_derive "${blk}" no  none)" "degraded notready" "${name}: nothing up       -> degraded notready"
  # session process exists but the X server died -> NOT ready (the exact false-green case)
  assert_eq "$(eval_derive "${blk}" yes none)" "degraded notready" "${name}: xfce up but no X  -> degraded notready"
  # X up but no session component -> NOT ready
  assert_eq "$(eval_derive "${blk}" no  Xorg)" "degraded notready" "${name}: X up but no xfce  -> degraded notready"
done

echo
echo "================ 3. BEHAVIOUR: drive the carved partyos-desktop-ready ==="
# Run a copy that reads the user name file from the test dir, not from /run.
NAME_FILE="${TMPDIR_T}/partyos-username"
RDY_SH="${TMPDIR_T}/partyos-desktop-ready"
sed "s#/run/partyos-username#${NAME_FILE}#g" "${BUILD}" > "${RDY_SH}"
assert_eq "$(grep -c "< ${NAME_FILE}" "${RDY_SH}" || true)" "1" "partyos-desktop-ready reads the user name from /run/partyos-username"
[ -s "${RDY_SH}" ] || { echo "FAIL: partyos-desktop-ready baked file is empty (${RDY_SH})"; exit 1; }
bash -n "${RDY_SH}" && assert_true 0 "carved partyos-desktop-ready parses (bash -n)" || assert_true 1 "carved partyos-desktop-ready parses (bash -n)"

BIN="${TMPDIR_T}/bin"; install -d "${BIN}"
CURL_LOG="${TMPDIR_T}/curl.log"; export CURL_LOG
cat > "${BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${BIN}/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
echo none            # -> SER=/dev/null, no serial writes
EOF
# curl stub: record the requested URL (RDY sends stdout/stderr to /dev/null, so log to file).
cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *report?step=3*) echo "$a" >> "${CURL_LOG}";; esac; done
exit 0
EOF
# pgrep stub: a process "runs" iff its name (the last arg) is in the colon-list SIM_PROCS.
# With -u USER, the process must also belong to SIM_USER (the session user).
cat > "${BIN}/pgrep" <<'EOF'
#!/usr/bin/env bash
name="${!#}"                                   # last positional = the -x pattern
owner=""
while [ $# -gt 0 ]; do case "$1" in -u) owner="$2"; shift 2;; *) shift;; esac; done
if [ -n "${owner}" ] && [ "${owner}" != "${SIM_USER:-gamer}" ]; then exit 1; fi
case ":${SIM_PROCS:-}:" in *":${name}:"*) exit 0;; *) exit 1;; esac
EOF
# id stub: the script runs as the session user SIM_USER.
cat > "${BIN}/id" <<'EOF'
#!/usr/bin/env bash
case "$*" in -un) echo "${SIM_USER:-gamer}";; *) exec /usr/bin/id "$@";; esac
EOF
chmod +x "${BIN}"/*
# run_rdy PROCS [SESSION_USER [NAME_FILE_CONTENT]]: with no third argument, the name file is absent.
run_rdy() {
  rm -f "${NAME_FILE}"; [ $# -ge 3 ] && printf '%s\n' "$3" > "${NAME_FILE}"
  SIM_PROCS="$1" SIM_USER="${2:-gamer}" PATH="${BIN}:${PATH}" bash "${RDY_SH}" >/dev/null 2>&1 || true
}

echo "  -- black seat (no xfce, no X) -> honest NOT-ready --"
: > "${CURL_LOG}"; run_rdy ""
assert_contains "$(cat "${CURL_LOG}")" "status=degraded&desktop=notready" "black seat reports status=degraded&desktop=notready"
assert_not_contains "$(cat "${CURL_LOG}")" "status=ok&desktop=ready" "black seat NEVER reports a false status=ok&desktop=ready"
assert_contains "$(cat "${CURL_LOG}")" "xfce=no" "black seat still carries the true xfce=no field"
assert_contains "$(cat "${CURL_LOG}")" "xserver=none" "black seat still carries the true xserver=none field"

echo "  -- healthy seat (xfce4-session + Xorg up) -> ready --"
: > "${CURL_LOG}"; run_rdy "xfce4-session:Xorg"
assert_contains "$(cat "${CURL_LOG}")" "status=ok&desktop=ready" "healthy seat reports status=ok&desktop=ready"
assert_contains "$(cat "${CURL_LOG}")" "xserver=Xorg" "healthy seat carries xserver=Xorg"

echo "  -- session up but X server died -> NOT ready (false-green case) --"
: > "${CURL_LOG}"; run_rdy "xfce4-session"
assert_contains "$(cat "${CURL_LOG}")" "status=degraded&desktop=notready" "xfce-up-but-no-X reports status=degraded&desktop=notready"
assert_not_contains "$(cat "${CURL_LOG}")" "status=ok" "xfce-up-but-no-X never reports status=ok"

echo "  -- session user is not gamer --"
assert_eq "$(grep -c -- '-u gamer' "${BUILD}" || true)" "0" "partyos-desktop-ready has no fixed pgrep -u gamer"
: > "${CURL_LOG}"; run_rdy "xfce4-session:xfwm4:xfce4-panel:Xorg" testfake testfake
assert_contains "$(cat "${CURL_LOG}")" "status=ok&desktop=ready" "user testfake (name file) with its xfce session up reports status=ok&desktop=ready"
assert_contains "$(cat "${CURL_LOG}")" "user=testfake" "user testfake (name file) report carries user=testfake"
assert_contains "$(cat "${CURL_LOG}")" "xfce=yes" "user testfake (name file) report carries xfce=yes"
assert_not_contains "$(cat "${CURL_LOG}")" "status=degraded" "user testfake (name file) never reports status=degraded"
echo "  -- no name file: fall back to the user of the process --"
: > "${CURL_LOG}"; run_rdy "xfce4-session:xfwm4:xfce4-panel:Xorg" testfake
assert_contains "$(cat "${CURL_LOG}")" "status=ok&desktop=ready" "user testfake (no name file) reports status=ok&desktop=ready"
assert_contains "$(cat "${CURL_LOG}")" "user=testfake" "user testfake (no name file) report carries user=testfake"

assert_summary "test-desktop-ready-report" || exit 1
echo "test-desktop-ready-report: ALL PASS"
