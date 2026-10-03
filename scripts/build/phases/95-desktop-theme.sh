# phase 95-desktop-theme - sourced by build-custom-image.sh; not standalone
# ============================================================================
# Chicago95 (Win95 look): theme + icons + cursors + Start menu + bottom taskbar
# ============================================================================
# Vendor the Chicago95 theme/icons/cursors system-wide, seed xfconf as SYSTEM
# defaults (so the look survives the gamer->username rename), add the teal Win95
# wallpaper, and lay down the single bottom taskbar + Start menu (whiskermenu,
# installed as a package above). git is in the container tooling; the build has
# network.
#
# REPRODUCIBILITY + FAIL-LOUD: the theme is PINNED to a specific upstream
# commit (not HEAD) so every build ships the EXACT same look, and a clone/checkout
# failure now ABORTS the build instead of silently shipping a plain unthemed XFCE.
# The Win95 look is a defining feature of partyOS - an image without it is a bug,
# not a degraded-but-fine fallback. To bump the theme, update C95_REF below to a
# new grassmunk/Chicago95 commit you have inspected.
#   pinned ref: grassmunk/Chicago95 @ 11415b568e84795f7e0d6aa702b41a2cf23e9381 (master HEAD, 2026-06)
C95_URL="https://github.com/grassmunk/Chicago95"
C95_REF="11415b568e84795f7e0d6aa702b41a2cf23e9381"

# chicago95_assert ROOTFS -> 0 if the key Chicago95 artifacts are present in the
# rootfs, else 1 (printing what is missing). Pure path checks, no network/chroot,
# so the unit test (scripts/test/test-chicago95-assert.sh) can carve + call it
# directly. Keep this in sync with what the install block copies above.
chicago95_assert() {
  local rfs="$1" missing="" t i ok_icon=0
  # 1) GTK/xfwm theme dir with a real gtk-3.0 subdir (drives the window + widget look)
  t="${rfs}/usr/share/themes/Chicago95"
  [ -d "${t}/gtk-3.0" ] || missing="${missing} themes/Chicago95/gtk-3.0"
  # 2) at least one Chicago95 icon theme (an index.theme makes it a real theme)
  for i in "${rfs}"/usr/share/icons/Chicago95*/index.theme; do
    [ -f "${i}" ] && ok_icon=1 && break
  done
  [ "${ok_icon}" -eq 1 ] || missing="${missing} icons/Chicago95*/index.theme"
  # 3) system-default xfconf that actually selects the theme by name
  t="${rfs}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
  if [ -f "${t}" ] && grep -q 'value="Chicago95"' "${t}"; then :; else
    missing="${missing} xfconf/xsettings.xml(Chicago95)"
  fi
  if [ -n "${missing}" ]; then
    echo "[build] chicago95_assert: MISSING ->${missing}" >&2
    return 1
  fi
  return 0
}

echo "[build] installing Chicago95 Win95 theme (pinned ${C95_REF})..."
C95=/tmp/chicago95
rm -rf "${C95}"
# Clone the full ref history (no --depth: a shallow clone can't `checkout` an
# arbitrary older SHA), then pin. Errors are NOT swallowed - if either the clone
# or the checkout fails, fall through to the fail-loud branch below.
if git clone "${C95_URL}" "${C95}" \
   && git -C "${C95}" checkout --quiet "${C95_REF}" \
   && [ -d "${C95}/Theme/Chicago95" ]; then
  install -d "${ROOTFS}/usr/share/themes" "${ROOTFS}/usr/share/icons" "${ROOTFS}/usr/share/backgrounds"
  cp -r "${C95}/Theme/Chicago95" "${ROOTFS}/usr/share/themes/"
  for d in "${C95}"/Icons/*/;   do [ -f "${d}index.theme" ] && cp -r "${d}" "${ROOTFS}/usr/share/icons/"; done
  for d in "${C95}"/Cursors/*/; do [ -d "${d}cursors" ]   && cp -r "${d}" "${ROOTFS}/usr/share/icons/"; done
  for i in "${ROOTFS}"/usr/share/icons/Chicago95*; do
    [ -f "${i}/index.theme" ] && arch-chroot "${ROOTFS}" gtk-update-icon-cache -q -f "/usr/share/icons/$(basename "${i}")" 2>/dev/null || true
  done

  # system-default xfconf (applies regardless of username). NB the cursor dir uses
  # underscores: Chicago95_Standard_Cursors.
  XDIR="${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"; install -d "${XDIR}"
  bake "etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
  bake "etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"

  # Also seed the SAME theme selection into the gamer HOME so it lands in the baked
  # home-skel (cp -a /home/gamer -> /usr/share/partyos/home-skel). /etc/xdg above is a
  # read-only SYSTEM default; a freshly-seeded home carries no user-side xsettings/xfwm4
  # channel file, so on first boot the session (xfdesktop + the autostart setup wizard)
  # can come up before the settings daemon applies that system default and renders the
  # plain GTK/hicolor default (blue folder / default zenity). A CONCRETE user-home
  # xsettings.xml + xfwm4.xml makes full Chicago95 (GTK + icons + wm) render from the
  # first frame, before the wizard. Identical content to the /etc/xdg files above.
  GHXCONF="${ROOTFS}/home/gamer/.config/xfce4/xfconf/xfce-perchannel-xml"
  install -d -o 1000 -g 1000 "${GHXCONF}"
  cp -f "${XDIR}/xsettings.xml" "${GHXCONF}/xsettings.xml"
  cp -f "${XDIR}/xfwm4.xml"     "${GHXCONF}/xfwm4.xml"
  chown 1000:1000 "${GHXCONF}/xsettings.xml" "${GHXCONF}/xfwm4.xml"

  # NB: do NOT bake a full xfce4-session.xml / xfce4-keyboard-shortcuts.xml here - those
  # paths are OWNED by xfce4-session / libxfce4ui and overwriting them wipes the failsafe
  # session definition + default keybinds (xfce4-session then refuses to start). The
  # LockCommand + Win+L are set at RUNTIME via xfconf-query in partyos-lock-setup instead.

  # teal Win95 wallpaper (#008080) + first-login applier (the monitor name is only
  # known at runtime, so a per-session autostart sets the backdrop).
  printf 'P3\n1 1\n255\n0 128 128\n' > "${ROOTFS}/usr/share/backgrounds/partyos.ppm"
  bake "usr/local/bin/partyos-desktop-setup"
  install -d "${ROOTFS}/etc/xdg/autostart"
  bake "etc/xdg/autostart/partyos-desktop-setup.desktop"

  # --- partyos-desktop-layout: FORCE the Win95 icon order --------------
  # xfdesktop 4.20 persists icon positions as grid row/col in
  # ~/.config/xfce4/desktop/icons.screen0.yaml, keyed by absolute path + a
  # per-monitor id hash. A statically-baked yaml can't match (username, monitor
  # id, geometry all vary), so we PATCH xfdesktop's OWN yaml at runtime: it
  # already has the right monitor id + paths, we just overwrite row/col for our
  # known icons. Grid indices are resolution-independent (col0/col1 always
  # exist), so the layout holds on any display. Runs ONCE (sentinel) so the
  # player can rearrange afterwards and it sticks (the home is on the USB).
  bake "usr/local/bin/partyos-desktop-layout"
  bake "etc/xdg/autostart/partyos-desktop-layout.desktop"
  echo "[build] baked partyos-desktop-layout (forces Win95 icon order)"

  # Win95 single bottom taskbar + Start menu. The Chicago95 panel-prefs tarball is
  # the xfce4-panel-profiles format (no raw xfce4-panel.xml), so ship the known-good
  # panel config + whiskermenu rc directly (scripts/build/chicago95/, captured from a
  # working image). Single panel at p=10 (bottom) with the Start (whiskermenu) plugin.
  PCFG="$(dirname "${BASH_SOURCE[0]}")/chicago95"; [ -d "${PCFG}" ] || PCFG=/scripts/chicago95
  install -d "${ROOTFS}/home/gamer/.config/xfce4/xfconf/xfce-perchannel-xml" "${ROOTFS}/home/gamer/.config/xfce4/panel"
  [ -f "${PCFG}/xfce4-panel.xml" ] && cp -f "${PCFG}/xfce4-panel.xml" "${ROOTFS}/home/gamer/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
  [ -f "${PCFG}/whiskermenu-1.rc" ] && cp -f "${PCFG}/whiskermenu-1.rc" "${ROOTFS}/home/gamer/.config/xfce4/panel/whiskermenu-1.rc"
  chown -R 1000:1000 "${ROOTFS}/home/gamer/.config"
  echo "[build] Chicago95 theme + Start menu + bottom taskbar installed"

  # --- partyos-panel-layout: FORCE the Win95 bottom Start bar (belt-and-suspenders) ---
  # The ordering fix (PULL_RAN wait in partyos-xfce-launch) makes xfce4-panel read the
  # pulled Win95 config instead of racing xfconfd. This is the resilient net UNDER it: a
  # sentinel-guarded first-session helper (modelled on partyos-desktop-layout, which does
  # the same for the icon order) that, if the LIVE panel is still the default two-panel
  # layout, RE-APPLIES the baked Win95 xfce4-panel.xml from the home-skel and reloads. So
  # even if a custom user still loses the race, the single bottom Start bar is restored on
  # first boot, then the player owns the layout (sentinel + synced home). Operates ONLY on
  # the USER-owned ~/.config/xfce4 perchannel xml - never the package-owned /etc/xdg files.
  bake "usr/local/bin/partyos-panel-layout"
  install -d "${ROOTFS}/etc/xdg/autostart"
  bake "etc/xdg/autostart/partyos-panel-layout.desktop"
  echo "[build] baked partyos-panel-layout (restores Win95 bottom Start bar if clobbered)"

  # FAIL-LOUD post-install assertion: prove the key theme artifacts actually
  # landed in the rootfs. A successful clone is necessary but not sufficient - an
  # upstream layout change could move/rename dirs so the copies above no-op while
  # the build keeps going. If any required artifact is missing, ABORT rather than
  # ship a half-themed image. (chicago95_assert is defined just above for reuse by
  # the standalone installer + the unit test.)
  if ! chicago95_assert "${ROOTFS}"; then
    echo "[build] ERROR: Chicago95 theme missing after install - refusing to ship unthemed image" >&2
    exit 1
  fi
  echo "[build] Chicago95 artifacts verified in rootfs"
else
  echo "[build] ERROR: Chicago95 clone/checkout failed (ref ${C95_REF}) - refusing to ship unthemed image" >&2
  exit 1
fi
rm -rf "${C95}" /tmp/c95pt

# Hide the archiso console boot text ("Welcome to Arch Linux", "To install ...").
: > "${ROOTFS}/etc/motd"; printf '\n' > "${ROOTFS}/etc/issue"; rm -f "${ROOTFS}"/etc/motd.d/* 2>/dev/null || true
echo "[build] cleared motd/issue (console boot text hidden)"

# --- partyos-setup-wizard: first-boot LOCAL prefs wizard ----------------
# A one-time zenity GUI for the hardware prefs registration can't know: keyboard
# layout, a welcome/MOTD explaining the RAM-OS model, and optional display/audio.
# NICK/STATIC_IP are NOT here - those are pre-provisioned on the stick at party
# registration. Gate: a sentinel on the USB home so it shows exactly once;
# re-runnable with --force (a Control Panel / menu entry). Chosen values are
# written into the USB user.conf so they persist + feed the userconf pipeline
# (KEYBOARD is applied system-wide on the next boot by partyos-userconf-setup;
# we also apply it live here via setxkbmap so it takes effect immediately).
bake "usr/local/bin/partyos-setup-wizard"
# autostart entry (self-gates via the sentinel) + a menu entry to re-run it
install -d "${ROOTFS}/etc/xdg/autostart" "${ROOTFS}/usr/share/applications"
bake "etc/xdg/autostart/partyos-setup-wizard.desktop"
bake "usr/share/applications/partyos-setup.desktop"
echo "[build] baked partyos-setup-wizard (first-run keyboard/welcome/display/audio)"

# --- audio: default to the ONBOARD ANALOG jack, not HDMI ---------------------
# Out of the box ALSA's default is card 0 = NVidia/Intel HDMI (to the monitor), which
# is WRONG for a party rig: the speakers/headphones hang off the onboard analog jack
# (Intel sof-hda-dsp OR a Realtek ALC codec). A static wireplumber default-sink config
# differs wildly between wireplumber 0.4 (lua) and 0.5+ (SPA-JSON), so instead we set
# the default LIVE per session with wpctl - version-independent and it works whatever
# node ids the hardware enumerates. wireplumber persists the chosen default in the home
# (on the USB), so this only has to win on a fresh stick; the wizard's audio step (an
# explicit user override) runs later and takes precedence. The setup-wizard runs on the
# SAME autologin session, so we order this BEFORE it (the wizard override, if used, then
# overwrites our default).
#
# Pick by preference order over all sinks. Do not route to HDMI/DP when another output sink exists.
#
# Preference order (highest wins), rationale - most LAN gamers plug into the 3.5mm jack
# or a USB headset, almost never the monitor's HDMI audio:
#   1. Onboard analog  - "analog", "Speaker", "Headphone(s)", sof-hda, Realtek/ALC,
#                        a pulse node like alsa_output.pci-*.analog-stereo. The point of
#                        the fix.
#   2. USB DAC/headset - "usb", "headset", "Headset" (common for gamers; a deliberate
#                        external choice, reasonable to honour over the onboard jack).
#   3. HDMI/DisplayPort - "hdmi", "displayport", "DP" - LAST RESORT, used only when it
#                        is the ONLY sink (HDMI-only rig: e.g. an HDMI monitor with
#                        built-in speakers and no onboard analog at all).
# Falls back gracefully: if nothing matches any tier we leave the system default alone.
# user.conf override: AUDIO_SINK=<substr> forces the first sink whose name contains that
# (case-insensitive) substring - e.g. AUDIO_SINK=HDMI for a player who DOES want monitor
# audio. Empty/absent => the heuristic above runs.
bake "usr/local/bin/partyos-default-sink"
bake "etc/xdg/autostart/partyos-default-sink.desktop"
echo "[build] baked partyos-default-sink autostart (preference-ordered analog>USB>HDMI, AUDIO_SINK= override)"

