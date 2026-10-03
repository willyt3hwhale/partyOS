#!/usr/bin/env bash
# install-server-service.sh - install the partyOS server systemd unit.
#
# The party servers used to run in an SSH session, so a dropped session stopped
# the whole party. This installs server/systemd/partyos-servers.service.tmpl as
# a systemd unit with Restart=always, so the servers start at boot and come back
# after a crash. The unit has no start limit. If the party address is not on the
# host at boot (no link on eth0), the unit retries until the address is there.
#
# Target: the party server host (Debian). Run it ON that host, as
# root. It never runs a build and never flashes anything.
#
# Usage:
#   sudo scripts/deploy/install-server-service.sh
#   sudo scripts/deploy/install-server-service.sh --user user --repo /home/user/partyos
#   scripts/deploy/install-server-service.sh --dry-run
#
# Flags:
#   --user NAME    the account that runs the servers (default: user).
#   --repo PATH    the repo checkout on the server (default: /home/user/partyos).
#   --no-enable    install the unit file only. Do not enable or start it.
#   --dry-run      print the rendered unit and write nothing.
#   -h | --help    this help.
#
# Environment:
#   UNIT_OUT       the unit path to write (default /etc/systemd/system/
#                  partyos-servers.service). The tests point it at a temp file.
#
# After the install:
#   systemctl status partyos-servers
#   journalctl -u partyos-servers -f
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
TMPL="${REPO_ROOT}/server/systemd/partyos-servers.service.tmpl"

SVC_USER="user"
SVC_REPO="/home/user/partyos"
UNIT_OUT="${UNIT_OUT:-/etc/systemd/system/partyos-servers.service}"
DO_ENABLE=1
DRY_RUN=0

die() { echo "install-server-service: $*" >&2; exit 1; }
say() { echo "[install-server-service] $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --user)      SVC_USER="${2:-}"; shift 2;;
        --user=*)    SVC_USER="${1#*=}"; shift;;
        --repo)      SVC_REPO="${2:-}"; shift 2;;
        --repo=*)    SVC_REPO="${1#*=}"; shift;;
        --no-enable) DO_ENABLE=0; shift;;
        --dry-run)   DRY_RUN=1; shift;;
        -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
        *)           die "unknown argument '$1' (see --help)";;
    esac
done

[ -f "${TMPL}" ] || die "unit template not found: ${TMPL}"
[ -n "${SVC_USER}" ] || die "--user is empty"
case "${SVC_REPO}" in /*) ;; *) die "--repo must be an absolute path";; esac

RENDERED="$(sed -e "s|{{USER}}|${SVC_USER}|g" -e "s|{{REPO}}|${SVC_REPO}|g" "${TMPL}")"

if [ "${DRY_RUN}" = 1 ]; then
    say "DRY-RUN: would write ${UNIT_OUT}"
    printf '%s\n' "${RENDERED}"
    exit 0
fi

# Warn, do not fail, when the checkout is not on this host. The unit is often
# installed before the payload is copied over.
[ -d "${SVC_REPO}" ] || say "WARNING: ${SVC_REPO} does not exist yet on this host"

printf '%s\n' "${RENDERED}" > "${UNIT_OUT}" || die "cannot write ${UNIT_OUT} (run it with sudo)"
say "wrote ${UNIT_OUT}  (User=${SVC_USER}, WorkingDirectory=${SVC_REPO})"

if [ "${DO_ENABLE}" = 1 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || die "systemctl daemon-reload failed"
    systemctl enable partyos-servers.service || die "systemctl enable failed"
    say "enabled partyos-servers.service"
    say "start it with: systemctl start partyos-servers"
    say "watch it with: journalctl -u partyos-servers -f"
else
    say "not enabled. Run: systemctl daemon-reload && systemctl enable --now partyos-servers"
fi
