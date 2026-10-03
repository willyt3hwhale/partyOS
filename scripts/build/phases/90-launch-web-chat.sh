# phase 90-launch-web-chat - sourced by build-custom-image.sh; not standalone
# --- partyos-launch: THE unified app launcher ----------------------------
# Single entry point every desktop icon points at. Resolves <app> from the LAN
# catalog, then:
#   source=blob -> partyos-app install-launch (squashfs+overlay). If the blob is
#                  not served yet (most games - their blobs aren't built)
#                  show a friendly "not available yet" and exit 0, never a crash.
#   source=pkg  -> install via the LAN mirror (partyos-pkg-install) behind a zenity
#                  progress dialog, then exec the app's `exec` (a wrapper like
#                  partyos-browser/partyos-messenger, or the bare binary).
# Runs UNPRIVILEGED as the desktop user; the sub-tools self-`sudo -n` for the bits
# that need root.
bake "usr/local/bin/partyos-launch"

# --- partyos-browser: RUNTIME exec only (env + portal homepage) ---------------
# Pure "run Epiphany the right way" wrapper. Install-on-first-use + the zenity
# progress dialog now live in partyos-launch (the browser catalog row is
# source=pkg -> epiphany + xdg-desktop-portal-gtk). This script assumes the
# browser is already present and only sets up the software-render env, the user
# session bus, the first-run-prompt suppression and the cached-portal homepage.
bake "usr/local/bin/partyos-browser"

# --- partyos-portal-fetch: cache the LAN portal locally at boot --------------
bake "usr/local/bin/partyos-portal-fetch"
bake "etc/systemd/system/partyos-portal.service"
ln -sf /etc/systemd/system/partyos-portal.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-portal.service"

# --- "Internet Explorer" http/mime handler (NoDisplay) ------------------------
# This .desktop exists ONLY to be the default http/https/html handler (so any app
# opening a URL routes through partyos-launch -> install-on-demand + the right
# webkit env). It is NoDisplay=true: the VISIBLE "Internet Explorer" icon is now
# emitted from the catalog row by gen-launchers (Exec=partyos-launch browser), so
# we no longer drop a copy under Desktop/ here (that would double the icon).
bake "usr/share/applications/partyos-browser.desktop"
install -d -o 1000 -g 1000 -m 0755 "${ROOTFS}/home/gamer/Desktop"
install -d -o 1000 -g 1000 "${ROOTFS}/home/gamer/.config"
bake "home/gamer/.config/mimeapps.list"
chown -R 1000:1000 "${ROOTFS}/home/gamer/.config" "${ROOTFS}/home/gamer/Desktop" 2>/dev/null || true
echo "[build] baked LAN mirror + Internet Explorer (on-demand) + local portal"

# --- NYET Messenger: pre-configured LAN IRC chat (HexChat, on-demand) ---------
# Install HexChat on first use from the LAN mirror, generate its config from the
# IRC server (deploy.conf IRC_SERVER, via irc_server= on the cmdline) and the
# player's nick (their USB-supplied identity, /run/partyos-username), and
# auto-connect + join #auditorium.
bake "usr/local/bin/partyos-messenger-config"

bake "usr/local/bin/partyos-messenger"

# NoDisplay handler entry kept for consistency with the IE entry. The VISIBLE
# "NYET Messenger" icon is emitted from the catalog row by gen-launchers
# (Exec=partyos-launch messenger), so no Desktop/ copy is dropped here (that would
# double the icon). Exec routes through partyos-launch so install-on-demand + the
# zenity progress dialog are owned by the one launcher.
bake "usr/share/applications/partyos-messenger.desktop"
echo "[build] baked NYET Messenger (HexChat on-demand, pre-configured for the LAN IRC)"

