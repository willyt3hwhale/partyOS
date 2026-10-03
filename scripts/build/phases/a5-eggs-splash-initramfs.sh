# phase a5-eggs-splash-initramfs - sourced by build-custom-image.sh; not standalone
# --- Easter eggs (made by LilWil) ---------------------------------------------
# `lilwil` / `party` - hidden credits command.
bake "usr/local/bin/lilwil"
ln -sf lilwil "${ROOTFS}/usr/local/bin/party"
# cmd.exe (xfce4-terminal) opens with a Win95 parody banner, once per shell.
cat >> "${ROOTFS}/etc/bash.bashrc" <<'MOTD'

# --- partyOS cmd.exe easter egg (made by LilWil) ---
if [[ $- == *i* ]] && [[ -z "${PARTYOS_MOTD_SHOWN}" ]]; then
  export PARTYOS_MOTD_SHOWN=1
  echo "Microsoft(R) Windows 95   [Version 4.00.950, allegedly]"
  echo "    (C) Cackleright LilWil 1995-2026. All wrongs reserved."
  echo
  echo "Type 'lilwil' for credits. There is no internet. You knew this."
  echo
fi
MOTD
echo "[build] baked easter eggs (lilwil/party command + cmd.exe banner)"

# --- Plymouth boot splash (partyOS logo + live status + "by LilWil") ----------
# plymouth is installed as a package above. Ship the partyOS theme, set it default,
# and add the plymouth mkinitcpio HOOK so the splash covers the WHOLE boot incl. the
# copytoram sfs fetch. No 'kms' hook (slim initramfs) - plymouth renders on simpledrm
# (efifb), which is built into the kernel. The render adds 'splash' to the cmdline.
PLYDIR="$(dirname "${BASH_SOURCE[0]}")/plymouth"; [ -d "${PLYDIR}" ] || PLYDIR=/scripts/plymouth
if [ -d "${PLYDIR}/partyos" ] && [ -d "${ROOTFS}/usr/share/plymouth/themes" ]; then
  cp -rf "${PLYDIR}/partyos" "${ROOTFS}/usr/share/plymouth/themes/"
  install -d "${ROOTFS}/etc/plymouth"
  printf '[Daemon]\nTheme=partyos\nShowDelay=0\nDeviceTimeout=8\n' > "${ROOTFS}/etc/plymouth/plymouthd.conf"
  # default.plymouth = what plymouth resolves first. The plymouth package ships it
  # as a symlink to the distro default theme; rm it first (cp -f over a symlink
  # follows it / fails on a dangling one), then ship a COPY of ours (a symlink can
  # get mangled in the initramfs cpio -> plymouth falls back to a default theme).
  rm -f "${ROOTFS}/usr/share/plymouth/themes/default.plymouth"
  cp -f "${ROOTFS}/usr/share/plymouth/themes/partyos/partyos.plymouth" \
    "${ROOTFS}/usr/share/plymouth/themes/default.plymouth"
  # add the plymouth HOOK right after 'udev' in the archiso initramfs config so it
  # is in the early CPIO (the slim-initramfs rebuild then drops only 'kms').
  for _h in "${ROOTFS}"/etc/mkinitcpio.conf.d/*.conf "${ROOTFS}/etc/mkinitcpio.conf"; do
    [ -f "${_h}" ] || continue
    grep -q '^HOOKS' "${_h}" || continue
    grep -q 'plymouth' "${_h}" || sed -i 's/\(^HOOKS=([^)]*\budev\b\)/\1 plymouth/' "${_h}"
  done
  echo "[build] Plymouth partyOS splash installed (theme + plymouthd.conf + HOOK)"
else
  echo "[build] WARN plymouth theme dir missing - no splash"
fi

# --- copytoram sfs-fetch retry + stall watchdog --------------------------------
# archiso's stock initramfs hook archiso_pxe_http fetches the ~1.2GB airootfs.sfs
# over HTTP with a SINGLE bare `curl -L -f` - no --retry, no timeout. A stalled or
# slow fetch (NIC hiccup, switch STP, server blip) then sits FOREVER on a
# still-open-but-idle socket and the boot hangs at the "Starting partyOS" splash.
# Every sfs/checksum/sig
# fetch funnels through the hook's _curl_get() function, so we override that one
# curl invocation to retry + abort-and-retry on a throughput stall:
#   --retry 5 --retry-connrefused --retry-delay 2  : up to 5 retries, 2s apart,
#       also retry a refused connection (server not yet ready).
#   --connect-timeout 20                           : cap the TCP connect wait.
#   --speed-limit 1024 --speed-time 120            : THE WATCHDOG - softened
#       (was 100KB/s/30s). On a contended LAN (other clients pulling
#       the same 1.2GB sfs + seeders) a slow-but-PROGRESSING fetch can legitimately
#       dip under 100KB/s for >30s -> the old watchdog spuriously aborted and
#       re-fetched from byte 0 (no resume) -> retry storm that feeds the disease.
#       Now it only trips on a TRULY DEAD socket (under 1KB/s for 120s), which
#       --retry then re-attempts - keeping the anti-hang guard without the
#       false-positive on a slow link.
#   --cacert /etc/partyos/ca.pem                   : the sfs fetch goes
#       HTTPS (render sets archiso_http_srv=https://...:8443) so _curl_get must
#       validate the pinned partyOS CA. The CA is bundled INTO the initramfs at this
#       exact path by the FILES drop-in below (the rootfs /etc/partyos/ca.pem is NOT
#       automatically in the initramfs - archiso_pxe_http runs pre-rootfs). curl
#       IGNORES --cacert for an http:// URL, so this is transition-safe: a deploy that
#       (re)renders archiso_http_srv=http still boots, the flag is simply inert.
# This is baked into the rootfs hook; slim-initramfs.sh's `mkinitcpio -g` reads
# this exact file, so the override lands in the regenerated initramfs-linux.img
# (the artifact actually booted), not just the rootfs. Idempotent: re-running
# skips if the flags are already present.
_PXE_HTTP="${ROOTFS}/usr/lib/initcpio/hooks/archiso_pxe_http"
_RETRY_FLAGS='--retry 5 --retry-connrefused --retry-delay 2 --connect-timeout 20 --speed-limit 1024 --speed-time 120 --cacert /etc/partyos/ca.pem'
if [ -f "${_PXE_HTTP}" ]; then
  if grep -q -- '--speed-time' "${_PXE_HTTP}"; then
    echo "[build] copytoram curl-retry already present in archiso_pxe_http (idempotent skip)"
  elif grep -q 'curl -L -f -o "/run/archiso/httpspace' "${_PXE_HTTP}"; then
    # Insert the retry/watchdog flags right after the `curl -L -f` of _curl_get
    # (the single fetch path for sfs + checksum + sigs). Anchored on the literal
    # httpspace destination so we only touch _curl_get, not the -r 0-0 probe curls.
    sed -i "s|curl -L -f -o \"/run/archiso/httpspace|curl -L -f ${_RETRY_FLAGS} -o \"/run/archiso/httpspace|" "${_PXE_HTTP}"
    grep -q -- '--speed-time' "${_PXE_HTTP}" \
      && echo "[build] copytoram sfs fetch hardened: curl-retry + stall watchdog baked into archiso_pxe_http" \
      || { echo "[build] ERROR: archiso_pxe_http curl-retry override did NOT apply" >&2; exit 1; }
  else
    # The sed is anchored to archiso's exact `curl -L -f -o "/run/archiso/httpspace`
    # string. If a future archiso bump changes that line the anchor no longer matches and
    # the retry/watchdog flags CANNOT be injected -> the original copytoram boot-wedge
    # silently returns. A WARN here would ship that broken initramfs unnoticed. FAIL HARD so
    # the archiso change is caught at build time instead of regressing the boot in the field.
    echo "[build] ERROR: archiso_pxe_http _curl_get anchor not found - copytoram curl-retry/watchdog NOT applied; archiso likely changed the fetch line. Refusing to ship an initramfs without copytoram resilience." >&2
    exit 1
  fi
else
  # No hook to harden at all -> same risk (no copytoram retry/watchdog). Fatal.
  echo "[build] ERROR: ${_PXE_HTTP} missing - cannot inject copytoram curl-retry/watchdog. Refusing to ship an initramfs without copytoram resilience." >&2
  exit 1
fi

# --- bundle the pinned CA INTO the initramfs (HTTPS sfs fetch) ---------
# The copytoram retry _curl_get override above adds `--cacert /etc/partyos/ca.pem` so the copytoram
# sfs fetch validates the pinned partyOS CA once render flips archiso_http_srv= to
# https://...:8443. BUT archiso's archiso_pxe_http hook runs IN THE INITRAMFS, before
# the rootfs is mounted - so the rootfs /etc/partyos/ca.pem (baked earlier) is NOT
# automatically present there. mkinitcpio's FILES= array copies an absolute path from
# the build root straight into the initramfs at the SAME path, so we drop a dedicated
# conf.d snippet that adds the CA at exactly /etc/partyos/ca.pem - matching the --cacert
# path in _curl_get. A separate drop-in (not the archiso-owned config) keeps this
# orthogonal to the plymouth/netwait HOOKS edits and is trivially revertible.
# FATAL if the CA is missing (it was installed in the early bake above): without it in
# the initramfs the https sfs fetch fails closed = no boot. Catch it at build time.
_CA_IN_RFS="${ROOTFS}/etc/partyos/ca.pem"
if [ -f "${_CA_IN_RFS}" ]; then
  install -d -m0755 "${ROOTFS}/etc/mkinitcpio.conf.d"
  # FILES+=() appends, so this never clobbers a FILES set by archiso or another drop-in.
  bake "etc/mkinitcpio.conf.d/partyos-ca.conf"
  echo "[build] bundled pinned CA into the initramfs (FILES+=(/etc/partyos/ca.pem) drop-in) for the HTTPS copytoram sfs fetch"
else
  echo "[build] ERROR: ${_CA_IN_RFS} missing - cannot bundle the pinned CA into the initramfs. The HTTPS copytoram sfs fetch would fail closed = no boot. The CA bake earlier must have been skipped." >&2
  exit 1
fi

# --- initramfs NIC link-wait + DHCP retry + copytoram diagnostic --------------
# Reported wedge: after kernel+initramfs load (plymouth
# "Starting partyOS" splash shows) the boot stalls BEFORE any airootfs.sfs GET -
# the server log shows step=ipxe -> vmlinuz -> initramfs.img then NOTHING. So it
# hangs INSIDE the initramfs, after load, before the copytoram sfs fetch.
#
# Root cause (diagnosed from the extracted hooks):
#   archiso_pxe_common run_hook calls `ipconfig -t 60 "ip=dhcp"` to bring up the
#   network. klibc's ipconfig sends DHCP DISCOVER IMMEDIATELY - it does NOT wait
#   for NIC carrier/link first. On a COLD boot an Intel NIC (e1000e/igb) plus the
#   switch port take several seconds to negotiate link (autoneg + switch STP). If
#   DHCP fires before link is up the lease attempt is lost; with a flapping/slow
#   link the 60s budget can expire -> ipconfig fails -> archiso drops to an
#   interactive shell that NEVER posts a report and NEVER fetches the sfs. That is
#   exactly the observed "splash then nothing" wedge. The NIC kernel modules ARE
#   present (e1000e/igb/igc/e1000/r8169 all bundled by archiso_pxe_common's
#   add_checked_modules "/drivers/net/"), so this is a link-TIMING problem, not a
#   missing-driver problem. The copytoram curl-retry cannot help: _curl_get only
#   runs AFTER ipconfig succeeds and the mount_handler is reached.
#
# Fix, baked into the rootfs so slim-initramfs.sh's `mkinitcpio -g` lands it in the
# booted initramfs-linux.img:
#   1. A custom run_hook `partyos_netwait`, inserted into HOOKS right BEFORE
#      archiso_pxe_common: bring every wired NIC up and BLOCK until one reports
#      carrier (link), up to a generous timeout, BEFORE ipconfig runs DHCP. Cold
#      NICs link late; this removes the race. Best-effort: on timeout it proceeds
#      anyway (ipconfig's own retry below still gets a shot) so it can never brick
#      a boot.
#   2. Patch archiso_pxe_common's single `ipconfig -t 60` into a RETRY LOOP (a few
#      attempts, longer per-try timeout) so one missed lease is retried instead of
#      falling straight into the dead interactive shell.
#   3. A copytoram DIAGNOSTIC: archiso_pxe_http's mount_handler posts
#      `report?step=copytoram&status=start&ip=...` to report_url RIGHT BEFORE the
#      sfs fetch. This disambiguates the NEXT wedge: if the server log shows
#      step=copytoram the initramfs network came up and the wedge is the sfs fetch
#      itself; if it does NOT, the network (ipconfig/link) is still the problem.
#      Best-effort (curl --max-time 5 ... || true), never blocks boot.
_HOOKS_DIR="${ROOTFS}/usr/lib/initcpio/hooks"
_INST_DIR="${ROOTFS}/usr/lib/initcpio/install"
_PXE_COMMON="${ROOTFS}/usr/lib/initcpio/hooks/archiso_pxe_common"

# 1a. runtime hook: NIC link-wait (klibc ash / busybox userspace) -------------
bake "usr/lib/initcpio/hooks/partyos_netwait"

# 1b. install hook: bundle the runscript (ip/busybox already pulled by archiso) -
bake "usr/lib/initcpio/install/partyos_netwait"

# 1c. insert partyos_netwait into HOOKS right before archiso_pxe_common --------
_NETWAIT_HOOKED=0
for _h in "${ROOTFS}"/etc/mkinitcpio.conf.d/*.conf "${ROOTFS}/etc/mkinitcpio.conf"; do
  [ -f "${_h}" ] || continue
  grep -q '^HOOKS' "${_h}" || continue
  grep -q 'archiso_pxe_common' "${_h}" || continue
  if grep -q 'partyos_netwait' "${_h}"; then
    _NETWAIT_HOOKED=1
  else
    sed -i 's/\barchiso_pxe_common\b/partyos_netwait archiso_pxe_common/' "${_h}"
    grep -q 'partyos_netwait archiso_pxe_common' "${_h}" && _NETWAIT_HOOKED=1
  fi
done
if [ "${_NETWAIT_HOOKED}" = "1" ]; then
  echo "[build] partyos_netwait NIC link-wait hook added before archiso_pxe_common"
else
  echo "[build] WARN could not insert partyos_netwait into HOOKS" >&2
fi

# 1d. DHCP option 121: add the classless static routes of the iPXE lease. The hook
# must run AFTER archiso_pxe_common, because a router is only reachable after
# ipconfig has set the address.
bake "usr/lib/initcpio/hooks/partyos_routes"
bake "usr/lib/initcpio/install/partyos_routes"
_ROUTES_HOOKED=0
for _h in "${ROOTFS}"/etc/mkinitcpio.conf.d/*.conf "${ROOTFS}/etc/mkinitcpio.conf"; do
  [ -f "${_h}" ] || continue
  grep -q '^HOOKS' "${_h}" || continue
  grep -q 'archiso_pxe_common' "${_h}" || continue
  if grep -q 'partyos_routes' "${_h}"; then
    _ROUTES_HOOKED=1
  else
    sed -i 's/\barchiso_pxe_common\b/archiso_pxe_common partyos_routes/' "${_h}"
    grep -q 'archiso_pxe_common partyos_routes' "${_h}" && _ROUTES_HOOKED=1
  fi
done
if [ "${_ROUTES_HOOKED}" = "1" ]; then
  echo "[build] partyos_routes option-121 hook added after archiso_pxe_common"
else
  echo "[build] ERROR: could not insert partyos_routes into HOOKS" >&2
  exit 1
fi

# 2. archiso_pxe_common: turn the single ipconfig call into a DHCP retry loop ---
if [ -f "${_PXE_COMMON}" ]; then
  if grep -q 'partyOS DHCP retry' "${_PXE_COMMON}"; then
    echo "[build] ipconfig DHCP-retry already present in archiso_pxe_common (idempotent skip)"
  elif grep -q 'if ! ipconfig -t 60 "ip=\${ip}"; then' "${_PXE_COMMON}"; then
    # Replace the single 6-line attempt-then-shell block with a 3-try loop. No
    # python/perl in the arch build container, so use awk: on the unique anchor
    # line emit the new block and skip the 5 lines through the closing `fi`.
    awk '
      /^        if ! ipconfig -t 60 "ip=\$\{ip\}"; then$/ {
        print "        # partyOS DHCP retry: a cold NIC can miss the first lease even after"
        print "        # the link-wait hook; retry a few times before the dead interactive shell."
        print "        _pdhcp=0"
        print "        while :; do"
        print "            if ipconfig -t 60 \"ip=${ip}\"; then"
        print "                break"
        print "            fi"
        print "            _pdhcp=$((_pdhcp + 1))"
        print "            if [ \"${_pdhcp}\" -ge 3 ]; then"
        print "                echo \"ERROR; Failed to configure network (after ${_pdhcp} DHCP tries)\""
        print "                echo \"   Falling back to interactive prompt\""
        print "                echo \"   You can try to fix the problem manually, log out when you are finished\""
        print "                launch_interactive_shell"
        print "                break"
        print "            fi"
        print "            echo \":: partyOS: DHCP attempt ${_pdhcp} failed - retrying...\""
        print "            sleep 2"
        print "        done"
        skip = 5            # drop the original block: the 4 echo/shell lines + closing fi
        next
      }
      skip > 0 { skip--; next }
      { print }
    ' "${_PXE_COMMON}" > "${_PXE_COMMON}.new" && mv "${_PXE_COMMON}.new" "${_PXE_COMMON}"
    grep -q 'partyOS DHCP retry' "${_PXE_COMMON}" \
      && echo "[build] ipconfig DHCP-retry loop baked into archiso_pxe_common" \
      || { echo "[build] ERROR ipconfig DHCP-retry override did NOT apply" >&2; exit 1; }
  else
    echo "[build] WARN ipconfig anchor not found in archiso_pxe_common - DHCP-retry NOT applied" >&2
  fi
else
  echo "[build] WARN ${_PXE_COMMON} missing - DHCP-retry NOT applied" >&2
fi

# 3. archiso_pxe_http: post step=copytoram diagnostic before the sfs fetch -----
if [ -f "${_PXE_HTTP}" ]; then
  if grep -q 'step=copytoram' "${_PXE_HTTP}"; then
    echo "[build] copytoram diagnostic already present in archiso_pxe_http (idempotent skip)"
  elif grep -q '_curl_get "\${archiso_http_srv}\${archisobasedir}/\${arch}/airootfs.\${img_type}"' "${_PXE_HTTP}"; then
    # Insert the step=copytoram diagnostic right BEFORE the sfs _curl_get. awk
    # (no python/perl in the container) emits the diag block on the anchor line,
    # then prints the anchor. The single-quoted sed inside is escaped \\1 for awk.
    awk '
      /^    _curl_get "\$\{archiso_http_srv\}\$\{archisobasedir\}\/\$\{arch\}\/airootfs\.\$\{img_type\}" "\/\$\{arch\}"$/ {
        print "    # partyOS copytoram diagnostic: prove the initramfs network is up and we reached the"
        print "    # sfs fetch. If the server log shows step=copytoram, the wedge (if any) is the"
        print "    # sfs transfer itself; if it never shows, the wedge is the network/ipconfig."
        print "    # Best-effort, never blocks boot. report_url= is exported as a shell var"
        print "    # by mkinitcpio parse_cmdline (the idiom archiso uses for archiso_http_srv);"
        print "    # there is no getarg under mkinitcpio, so read the var directly."
        print "    _preport=\"${report_url:-}\""
        print "    if [ -n \"${_preport}\" ]; then"
        print "        _pip=\"$(ip route get 1.1.1.1 2>/dev/null | sed -n '"'"'s/.*src \\([0-9.]*\\).*/\\1/p'"'"' | head -1)\""
        print "        curl -fsS --max-time 5 \"${_preport}/report?step=copytoram&status=start&ip=${_pip}\" >/dev/null 2>&1 || true"
        print "    fi"
      }
      { print }
    ' "${_PXE_HTTP}" > "${_PXE_HTTP}.new" && mv "${_PXE_HTTP}.new" "${_PXE_HTTP}"
    grep -q 'step=copytoram' "${_PXE_HTTP}" \
      && echo "[build] copytoram step=copytoram diagnostic baked into archiso_pxe_http" \
      || { echo "[build] ERROR copytoram diagnostic did NOT apply" >&2; exit 1; }
  else
    echo "[build] WARN sfs _curl_get anchor not found in archiso_pxe_http - diagnostic NOT applied" >&2
  fi
fi

# --- NVIDIA proprietary driver wiring -----------------------------------
# The `nvidia` modules live in the rootfs SFS (not the stock initramfs); udev
# auto-loads them (via the package modalias) for an NVIDIA GPU once the rootfs is
# up - well before step3 starts Xorg. Blacklist nouveau so it never races for the
# card (nouveau hangs Ampere). nvidia-drm.modeset=1 (kernel cmdline) gives KMS ->
# native resolution; Xorg then auto-selects the nvidia driver for accel. Intel/AMD
# rigs simply have no NVIDIA GPU, so nvidia never binds - harmless.
install -d "${ROOTFS}/etc/modprobe.d"
printf 'blacklist nouveau\nblacklist nouveaufb\n' > "${ROOTFS}/etc/modprobe.d/partyos-nvidia.conf"
echo "[build] NVIDIA: proprietary driver baked + nouveau blacklisted"

# Writeback tuning for the slow USB stick. partyOS runs from RAM, so the default
# vm.dirty_ratio=20 let the kernel keep GIGABYTES of dirty pages. A multi-GB blob
# download then hit one giant writeback that blocked aria2/curl past their time-outs.
# That fix set a cap of 32 MB. It was measured on a fast stick:
# a 3 GB blob in about 280 s.
# Measured 2026-09-23 on a "General UDisk" stick (USB 2.0, ~0.4 random 16K writes/s),
# 800 MB blob, 12 min per run:
#   * 32 MB:  the stick writes 0.12 MB/s. BitTorrent pieces arrive in random order,
#     and a small window gives the stick random writes.
#   * 256 MB: the stick writes 0.45-0.51 MB/s (4x). Writeback sorts a larger window
#     by file offset, so more writes are sequential.
#   * 1 GB: no gain for a blob larger than the window (0.45 MB/s on a 3.3 GB blob),
#     and the aria2 RPC stays silent for 890 s or more.
# Cost: up to 256 MB is not on the stick when a download completes. The sync in
# partyos-app get_blob and a safe eject can take minutes on a slow stick.
# The stall rule of partyos-app p2p_download and this value are
# coupled. If you change one, measure the other again.
# Byte counts, not ratios: a ratio of a large RAM is still too much.
install -d "${ROOTFS}/etc/sysctl.d"
printf 'vm.dirty_bytes = 268435456\nvm.dirty_background_bytes = 67108864\n' \
    > "${ROOTFS}/etc/sysctl.d/90-partyos-usb-writeback.conf"
echo "[build] USB writeback tuned (dirty_bytes 256M: sorted writeback to the slow stick)"

