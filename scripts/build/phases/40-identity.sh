# phase 40-identity - sourced by build-custom-image.sh; not standalone
# --- 4b. partyOS config parser + per-boot identity service -------------------
# The USB stick carries a single config file `.partyos` at the root of the
# ext4 home partition (plain KEY=value lines, '#' comments). The
# desktop ACCOUNT NAME is read from it (USERNAME=) instead of the hardcoded
# 'gamer'. We bake TWO things into the image:
#   1. partyos-cfg  - a tiny reusable PARSER (partyos_cfg KEY FILE). It PARSES
#      the file (never sources it - a stray line must not execute).
#   2. partyos-identity-setup + partyos-identity.service - a generic per-boot
#      service ordered After the USB-home mount and Before display-manager. It
#      resolves the username from .partyos (fallback 'gamer'), ensures the
#      account exists at FIXED uid/gid 1000, gives it passwordless sudo, points
#      its home at the USB-synced /home/<name>, rewrites LightDM autologin BEFORE
#      lightdm starts, AND resolves+sets the HOSTNAME (explicit HOSTNAME= from
#      .partyos, else <username>-<machine-suffix>, else partyos-<machine-suffix>).
#      No security boundary (user owns the machine); validation is for
#      robustness only.
echo "[build] baking partyos-cfg parser + partyos-identity service..."
install -d "${ROOTFS}/usr/local/bin"

# --- the reusable parser (partyos_cfg KEY FILE -> value or empty) ------------
bake "usr/local/bin/partyos-cfg"

# --- the venue identity parser (internyet.env on the exFAT share) ------------
# The per-player identity moved OFF the home partition. The venue writes
# `internyet.env` on the shared exFAT partition (a share label, /mnt/share).
# partyos-internyet.sh parses it - again by grep, never by sourcing - and maps:
#   USERNAME <- INTERNYET_USER_NAME
#   nick     <- INTERNYET_ALIAS
#   HOSTNAME <- INTERNYET_DEFAULT_FQDN (the full FQDN; first label is the alias)
#   email    <- INTERNYET_EMAIL
# The legacy `.partyos` / `user.conf` files stay as the fallback, so an old stick
# still boots.
install -d "${ROOTFS}/usr/local/lib"
bake "usr/local/lib/partyos-internyet.sh"

# --- the per-boot identity resolver (the service ExecStart) ------------------
bake "usr/local/bin/partyos-identity-setup"

# --- the systemd unit: After usbhome mount, Before display-manager -----------
bake "etc/systemd/system/partyos-identity.service"
# Enable it (symlink, like the other baked services - no systemctl under emu).
install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/partyos-identity.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-identity.service"
echo "[build] baked partyos-identity.service (enabled)"

# --- venue trust stores: the CA anchor + the client certificate --------------
# partyos-trust-setup imports from the SAME share dir the env file lives in:
#   ca.crt     -> the OS anchor (update-ca-trust). Epiphany/WebKitGTK reads the
#                 OS store through glib-networking, so this covers the browser
#                 this image ships. It also covers curl, git and python.
#   client.p12 -> the NSS databases (Firefox profiles, Chromium ~/.pki/nssdb),
#                 unlocked with INTERNYET_P12_PASSWORD. The password never
#                 reaches a command line or a log line.
# Two entry points: a boot service for the system anchor (root), and a session
# autostart for the per-user browser stores. Both are idempotent and non-fatal.
bake "usr/local/bin/partyos-trust-setup"
bake "etc/systemd/system/partyos-trust.service"
ln -sf /etc/systemd/system/partyos-trust.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-trust.service"
install -d "${ROOTFS}/etc/xdg/autostart"
bake "etc/xdg/autostart/partyos-trust.desktop"
echo "[build] baked partyos-trust.service + session autostart (venue CA + client cert)"

