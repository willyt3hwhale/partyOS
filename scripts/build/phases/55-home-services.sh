# phase 55-home-services - sourced by build-custom-image.sh; not standalone
# --- 4c. per-user start-services-from-home ------------------------------
# A participant can host their OWN services (game servers, file shares, web
# things) that auto-start on boot from their USB-backed HOME, surviving reboot.
# The convention lives entirely in the home (so it travels with the stick):
#
#   ~/.partyos-services/                 service declaration dir
#     <name>.sh        (executable)      a launcher script - run AS THE USER,
#                                        cwd=$HOME, HOME set, backgrounded.
#     <name>.service   (systemd unit)    a systemd USER unit - installed into
#                                        the user's systemd dir and started via
#                                        `systemctl --user` (best-effort; the
#                                        graphical/logind path). The script form
#                                        is the always-reliable headless path.
#     disabled/                          anything here is IGNORED (opt-out).
#
# State lives in the home: each service's stdout/stderr -> ~/.partyos-services/
# .run/<name>.log, its pid -> .run/<name>.pid. Because the home is USB-synced
# (Steps 4-6), the declarations + state persist across reboots.
#
# Discovery/DNS for the resulting services is provided by the EVENT LAN, not us.
#
# Baked artifacts:
#   1. partyos-home-services  - the per-user launcher (the service ExecStart).
#   2. partyos-home-services.service - runs it once per boot, After the USB-home
#      mount + identity, as a generic per-user boot hook.
echo "[build] baking partyos-home-services (start-services-from-home)..."
bake "usr/local/bin/partyos-home-services"

bake "etc/systemd/system/partyos-home-services.service"
ln -sf /etc/systemd/system/partyos-home-services.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-home-services.service"
echo "[build] baked partyos-home-services.service (enabled)"

