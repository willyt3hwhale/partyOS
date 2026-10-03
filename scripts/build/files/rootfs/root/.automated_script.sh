#!/usr/bin/env bash
# partyOS robust desktop bring-up (replaces archiso's fetch-or-die runner).
# The bring-up is baked at /usr/local/bin/partyos-desktop-bringup and ALWAYS runs,
# so a network blip during boot can never leave the box at a bare shell. We still
# try the latest served copy first (short, bounded) so an edit to the served
# step3-script.sh is picked up without rebuilding the image; on ANY failure we run
# the baked copy. The desktop itself needs no network (Xorg + XFCE from RAM); the
# report callbacks + app catalog are best-effort at runtime.
BAKED=/usr/local/bin/partyos-desktop-bringup
RUN=/tmp/startup_script

script_url() { local p; for p in $(< /proc/cmdline); do case "$p" in script=*) printf '%s' "${p#*=}"; return;; esac; done; }

run_bringup() {
    local url; url="$(script_url)"
    # bounded wait for the netboot NIC (don't hang boot forever as archiso did);
    # the bring-up does not need the network, so timing out here is harmless.
    local i=0
    while ! systemctl --quiet is-active network-online.target && [ "${i}" -lt 20 ]; do sleep 1; i=$((i+1)); done
    # Pin the partyOS CA only when script= is https (curl ignores --cacert for http, so
    # the dev/VM http boot is unchanged - transition-safe); a still-http URL or a missing
    # ca.pem leaves the fetch unpinned. Without this the prod HTTPS fetch fails TLS and the
    # served hotfix copy is silently never used.
    local ca_args=""
    case "${url}" in https://*) [ -r /etc/partyos/ca.pem ] && ca_args="--cacert /etc/partyos/ca.pem";; esac
    # prefer the latest served copy (tight timeout); fall back to the baked one.
    if [ -n "${url}" ] \
       && curl -fsS ${ca_args} --connect-timeout 3 --max-time 6 --retry 2 --retry-connrefused -o "${RUN}" "${url}" 2>/dev/null \
       && [ -s "${RUN}" ]; then
        chmod +x "${RUN}"
    else
        cp "${BAKED}" "${RUN}"; chmod +x "${RUN}"
    fi
    "${RUN}"
}

if [[ "$(tty)" == "/dev/tty1" ]]; then
    run_bringup
fi
