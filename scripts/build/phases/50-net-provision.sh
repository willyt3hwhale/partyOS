# phase 50-net-provision - sourced by build-custom-image.sh; not standalone
# --- partyos-userconf-setup + service (identity plumbing) ------------------
# Reads the USB `user.conf` (NICK, FULLNAME, IRC_SERVER, MUMBLE_SERVER, EMAIL)
# with the same grep-based `partyos_cfg` parser used for `.partyos` (NEVER
# sourced - a hostile line must not execute), VALIDATES + SANITIZES every value,
# and publishes them to root-owned tmpfs (/run): a single /run/partyos-user.conf
# (clean KEY=value pairs the seeder consumes) plus convenience files
# /run/partyos-nick and /run/partyos-fullname. Sanitization strips quotes,
# newlines and shell metacharacters so the downstream literal-`sed` seeder is
# injection-safe. NICK falls back to /run/partyos-username then
# 'partygoer'. Ordered After identity (needs /run/partyos-username) and Before
# display-manager so the values exist before any app launches.
echo "[build] baking partyos-userconf service..."
bake "usr/local/bin/partyos-userconf-setup"

bake "etc/systemd/system/partyos-userconf.service"
ln -sf /etc/systemd/system/partyos-userconf.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-userconf.service"
echo "[build] baked partyos-userconf.service (enabled)"

# --- partyos-staticip-setup + service: per-player static network --------
# iPXE DHCPs once to fetch the OS (unavoidable). After that the network is binary,
# driven by the USB user.conf:
#   STATIC_IP=A.B.C.D[/p]  -> FULLY-explicit static. The stick carries the whole config:
#                    Address (+ optional GATEWAY / DNS keys). NO DHCP is run on the link
#                    - the drop-in is laid down via network-pre.target BEFORE networkd
#                    configures the NIC, so we never grab+abandon a pool lease on a DHCP
#                    server we don't control. Applied to whichever wired NIC has link.
#   (unset)        -> plain DHCP (any stale static profile is removed first).
# The party LAN's DHCP server isn't ours (no reservations), which is the whole reason a
# fixed address must be specified end-to-end rather than derived from a lease. The
# drop-in sorts BEFORE the archiso 20-ethernet.network (first matching .network wins).
bake "usr/local/bin/partyos-staticip-setup"
bake "etc/systemd/system/partyos-staticip.service"
ln -sf /etc/systemd/system/partyos-staticip.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-staticip.service"
echo "[build] baked partyos-staticip.service (full-explicit static net or DHCP, enabled)"

# --- partyos-lpd-route + service: multicast route for aria2 LPD -
# aria2's BitTorrent Local Peer Discovery (LPD) sends/receives its discovery beacon on
# the link-local multicast group 239.192.152.143:6771. To do that the kernel needs a
# route covering 239.0.0.0/8 out the LAN interface; on a fresh partyOS boot that route
# is ABSENT (an offline LAN party has no default route, and neither the static drop-in
# nor the archiso DHCP profile installs a multicast route). Without it aria2 logs
#   "Failed to initialize LPD message receiver. cause: ... No such device"
# and silently finds no peers - so a magnet / load-url pull never discovers the seeding
# peer (aria2 1.37 also ignores the magnet's x.pe explicit-peer, leaving LPD as the ONLY
# working discovery mechanism on a flat LAN). Fix: add 239.0.0.0/8 dev <lan-iface> once
# the network is up. The iface name isn't known at build time, so derive it at runtime
# from the interface that actually holds the LAN (global-scope IPv4) address - which is
# exactly the interface aria2 binds LPD to (it sources from the routable address). This
# works for BOTH the static-IP and the plain-DHCP paths. Idempotent: a pre-existing
# route is treated as success.
# The same script adds 255.255.255.255/32 on that interface. With no default route,
# a sendto() to the limited broadcast fails with ENETUNREACH, so LAN game discovery
# (Warcraft III, UDP 6112) finds no games.
bake "usr/local/bin/partyos-lpd-route"
bake "etc/systemd/system/partyos-lpd-route.service"
ln -sf /etc/systemd/system/partyos-lpd-route.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-lpd-route.service"
echo "[build] baked partyos-lpd-route.service (multicast route for aria2 LPD, enabled)"

# --- 4b-bis. boot-speed + reachability fixes -
# 1. archiso's /root/.automated_script.sh (the script= runner) loops on
#    `until systemctl is-active network-online.target`, but NOTHING pulls that
#    target, so it hangs forever ("waiting for network-online.target"). Make
#    multi-user.target Want it so it actually activates.
ln -sf /usr/lib/systemd/system/network-online.target \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/network-online.target"
# 2. wait-online --any: complete as soon as the netboot NIC is routable, not when
#    EVERY interface is up (a dead 2nd NIC would otherwise stall boot ~120s).
install -d "${ROOTFS}/etc/systemd/system/systemd-networkd-wait-online.service.d"
bake "etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf"
# 2b. systemd-resolved: clear the compiled-in public FallbackDNS. The LAN is offline,
#     so only the DHCP lease DNS (or the static DNS=) may resolve.
install -d "${ROOTFS}/etc/systemd/resolved.conf.d"
bake "etc/systemd/resolved.conf.d/10-partyos-no-fallback.conf"
# 3. mask pacman-init + reflector: pointless on a live RAM OS that never installs
#    packages at runtime (pacman-init ~9-38s of gnupg keyring init; reflector ~54s
#    of mirror refresh over an internet a LAN-party box does not have).
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/pacman-init.service"
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/reflector.service"
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/reflector.timer"
# 3b. mask etc-pacman.d-gnupg.mount: the archiso releng profile ships a unit that
#     mounts an EMPTY tmpfs over /etc/pacman.d/gnupg at boot, SHADOWING the keyring
#     we populate at BUILD time (above) so pacman sees 0 keys. That tmpfs (not
#     keyboxd) is the real "keybox shadow"; archiso's normal flow then re-runs
#     pacman-key --init/--populate to fill it - the ~90s entropy-bound master-key
#     generation we are eliminating. Mask the mount so the BUILD-populated keyring
#     under it stays visible at runtime with ZERO init. pacman-init.service (which
#     would otherwise pull this mount via Requires=/BindsTo=) is already masked above.
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/etc-pacman.d-gnupg.mount"
# 3c. mask systemd-network-generator: it cannot parse the ip= of the BOOTIF handoff.
#     ip= has no device field, because archiso_pxe_common adds the device from BOOTIF=.
#     The generator then fails on every boot. Its only output was a unit for the
#     kernel name eth0, and the real root uses predictable names (enp1s0), so that
#     unit never matched.
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/systemd-network-generator.service"
# 4. early sshd + operator key so the box is reachable DURING boot (not only after
#    step3) - lets us debug a slow/stuck boot. Every image enables sshd and allows
#    root login with a public key. The build bakes root ssh login with the builder
#    key, if one is present. The key file is operator-supplied and not in git. Put your public keys in
#    files/rootfs/root/.ssh/authorized_keys. If the file is absent, no key is baked.
install -d -m700 "${ROOTFS}/root/.ssh"
if [ -f "${FILES}/rootfs/root/.ssh/authorized_keys" ]; then
  bake "root/.ssh/authorized_keys"
else
  echo "[build] no files/rootfs/root/.ssh/authorized_keys - root has no ssh key" >&2
fi
install -d "${ROOTFS}/etc/ssh/sshd_config.d"
printf 'PermitRootLogin yes\nPubkeyAuthentication yes\n' > "${ROOTFS}/etc/ssh/sshd_config.d/99-partyos-debug.conf"
ln -sf /usr/lib/systemd/system/sshd.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/sshd.service"
echo "[build] baked boot-speed fixes (network-online puller, wait-online --any, mask pacman-init/reflector + gnupg tmpfs mount, early sshd+key)"

# 5. ROBUST desktop bring-up. archiso's /root/.automated_script.sh fetches the
#    script= URL ONCE (curl --retry 10) and, on failure, silently drops to a tty
#    shell - so a single network blip during the boot fetch window leaves a box
#    with NO desktop until it is manually rebooted (a box can download the sfs,
#    then fail to fetch step3 and land at a bare shell).
#    Fix: BAKE the bring-up into the image so it ALWAYS runs (the desktop needs no
#    network), and override the runner to prefer a freshly-fetched copy (so a dev
#    edit to the served step3 is still picked up) but fall back to the baked one on
#    any fetch failure. Single source of truth: boot/step3-script.sh (also served).
install -m755 /boot-src/step3-script.sh "${ROOTFS}/usr/local/bin/partyos-desktop-bringup"
bake "root/.automated_script.sh"
echo "[build] baked robust desktop bring-up (baked /usr/local/bin/partyos-desktop-bringup + fetch-or-baked runner)"

