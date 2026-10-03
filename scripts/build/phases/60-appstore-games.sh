# phase 60-appstore-games - sourced by build-custom-image.sh; not standalone
# --- 4d. app-store / launcher -------------------------------------------
# The UX over the blob catalog: every available blob shows as a shortcut / in an
# "app store" window, and selecting one INSTALLS (download-if-absent -> mount via
# overlay) + LAUNCHES it. The backend is a CLI, and a thin GUI calls the CLI - so
# a GUI click and a headless test exercise the SAME code path. We bake:
#   1. partyos-app   - the CLI backend. Subcommands:
#        list                  print the catalog (from the LAN), one row per blob
#        install <id>          download-if-absent -> mount via squashfs+overlay
#        launch  <id>          run the blob's entry (must be installed first)
#        install-launch <id>   install (if needed) then launch - the one-click path
#        installed             list currently-installed (mounted) blobs
#        remove  <id>          unmount the overlay + free it (keeps any USB cache)
#        gen-launchers         (re)generate per-blob .desktop shortcuts from catalog
#      It REUSES the step7/8 flow: catalog fetch, USB cache (.partyos-cache/games,
#      survives reboot) with a RAM fallback, sha256-verify, squashfs ro lower +
#      tmpfs overlay upper at ~/games/<name>. <id> resolves by catalog id OR name.
#   2. The icons ARE the store (no window): gen-launchers writes one install-on-
#      click .desktop per catalog blob (Exec=partyos-app install-launch <id>) into
#      BOTH the app menu (grouped by category) and the desktop (under a per-category
#      subdir). A per-boot oneshot refreshes them from the live LAN catalog. Click =
#      download + launch; privileged ops (mount/overlay) self-elevate via sudo -n.
echo "[build] baking partyos-app (app-store backend) + launcher..."

bake "usr/local/bin/partyos-app"

# NO app-store WINDOW: the auto-generated per-app icons ARE the store. Every
# catalog blob gets a menu + desktop launcher (cmd_gen_launchers) that installs +
# launches on click. A separate chooser window would just duplicate that, so it
# was removed - the player browses icons, not a list dialog.
install -d "${ROOTFS}/usr/share/applications"
install -d -o 1000 -g 1000 "${ROOTFS}/home/gamer/Desktop"
install -d -o 1000 -g 1000 "${ROOTFS}/home/gamer/.config/xfce4/xfconf/xfce-perchannel-xml"
bake "home/gamer/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
chown -R 1000:1000 "${ROOTFS}/home/gamer/.config" "${ROOTFS}/home/gamer/Desktop" 2>/dev/null || true
echo "[build] baked partyos-app (app-store backend; per-app icons are the store)"

# --- partyos-share-game: produce a share code for a cached blob ---------------
# Resolve the cached blob, ensure a .torrent exists (mktorrent if missing), ensure a
# bounded seeder is live (partyos-app seed-cached dedups per blob), then build a SHORT
# magnet code (~200 bytes: info-hash + name + seeder peer + web-seed + sha + size),
# copy it to the clipboard and show it. The magnet REPLACED an inline-base64-torrent
# partyos:// URI that hit ~334KB for a 3GB blob and busted Linux's 128KB argv limit so
# `partyos-app load-url` could not even be invoked. With no arg it pops a zenity picker
# of the currently-installed (mounted) games.
bake "usr/local/bin/partyos-share-game"
echo "[build] baked partyos-share-game (Load-from-URL share-code generator)"

# --- partyos-loadurl: paste a share code, confirm, then load it ---------------
# zenity entry to paste the code, scheme/version validation, a trust confirmation
# naming the source IP, then hand off to the engine (partyos-app load-url) behind a
# pulsing zenity progress. All real work (download/verify/mount/launch) is in the
# engine; this is purely the GUI front door.
bake "usr/local/bin/partyos-loadurl"
echo "[build] baked partyos-loadurl (Load-from-URL GUI front door)"

# --- partyos-unlock: enter a code to reveal hidden games ------------------
# The store's "Enter a Code" front door - it REPLACED the old Load-from-URL magnet-paste
# tile. A zenity entry takes a short code and hands it to `partyos-app unlock-code`, which
# does ALL the real work (match hidden rows by unlock_code, persist to the USB home, regen
# the launchers) - so a headless test and a real click exercise the SAME backend path. A
# matching code reveals + persists the hidden blob(s) and this toasts success; a wrong code
# reveals nothing and this toasts "invalid code". Single-quoted heredoc: $ vars resolve on
# the client, not at build time.
bake "usr/local/bin/partyos-unlock"
echo "[build] baked partyos-unlock (Enter-a-Code GUI front door for hidden games)"

# --- partyos-proton-env: the on-client wine-env ENGINE ------------------------
# Manages per-user wine "game envs" on the USB home so a player can install + play a
# Windows game with zero terminal. Each env is a writable wine prefix cloned from the
# base proton-env blob's pristine prefix-template; the blob's PARAMETERIZED launcher
# (bin/run.sh, driven by PARTYOS_ENV_PREFIX / PARTYOS_RUN_EXE / PARTYOS_RUN_ARGS) does
# the actual sandboxed wine run. This engine is the backend; partyos-newgame (the zenity
# wizard) is the GUI. It is ALSO fully CLI-drivable headless (the hardware test drives it
# over ssh), so it NEVER blocks on a GUI - the zenity error popups are best-effort only.
# Single-quoted heredoc: $ vars below are LITERAL, resolved at runtime on the client.
bake "usr/local/bin/partyos-proton-env"
echo "[build] baked partyos-proton-env (on-client wine-env engine)"

# --- partyos-gpu-env: the GPU env of a game launch -----------------------------
# On a hybrid laptop (iGPU drives X, nvidia is the GPU screen NVIDIA-G0) it prints the
# PRIME render offload env, or DRI_PRIME for the display iGPU. partyos-app and
# partyos-proton-env pass it to the blob run.sh, so old blobs get it too.
bake "usr/local/bin/partyos-gpu-env"
echo "[build] baked partyos-gpu-env (PRIME offload env for game launches)"

# --- partyos-newgame: the "New Windows Game" zenity WIZARD --------------------
# Pure-GUI front door over the engine (partyos-proton-env): create a wine env, run a
# windows installer in it, pick the installed game's .exe, play. ZERO terminal - the user
# never types a path; the only typing is the env's name. Every engine error surfaces as a
# zenity --error. Single-quoted heredoc so $ vars are literal (resolved on the client).
bake "usr/local/bin/partyos-newgame"
echo "[build] baked partyos-newgame (New Windows Game zenity wizard)"

# Start-menu (whisker) entry for the wizard - the menu reads /usr/share/applications;
# the desktop tile (added by gen-launchers) does not appear there on its own.
install -d "${ROOTFS}/usr/share/applications"
bake "usr/share/applications/partyos-newgame.desktop"
echo "[build] baked New Windows Game whisker entry"

