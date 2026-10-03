# phase 85-repo-runtime - sourced by build-custom-image.sh; not standalone
# ============================================================================
# LAN pacman mirror + on-demand browser (Internet Explorer) + local portal
# ============================================================================
# partyOS ships slim; heavier optional apps (the browser, the IRC client, LAN
# tools) install on demand from the LAN [partyos] repo. The browser is also our
# "Internet Explorer": click it -> installs on first use, homepage = the locally
# cached portal, launch. The portal (FAQ + LAN service directory) is fetched once
# at boot and opened from disk so it works even when the server is busy/offline.

# --- REPO SPLIT: [partyos] (signed stock, Required) + [partyos-local] (Never) --
# The LAN mirror carries TWO classes of package:
#   [partyos]       ~530 STOCK Arch packages, each carrying Arch's OWN gpg signature.
#                   -> SigLevel = Required DatabaseOptional: verified at RUNTIME
#                      against the first-boot-populated keyring, so a rogue/tampered
#                      LAN mirror CANNOT inject a stock package (tests proved
#                      a tampered or sig-stripped pkg is rejected under Required).
#                      DatabaseOptional because repo-add builds an UNSIGNED partyos.db
#                      (only the packages are signed, not the db) - a test showed a
#                      bare "Required" demands a partyos.db.sig and aborts the -Sy.
#   [partyos-local] the genuinely-unsigned CUSTOM packages (thunar-patched + any other
#                   makepkg build we own). NOT Arch-signed -> SigLevel = Never. These
#                   are operator-trusted via the pinned-CA HTTPS transport: this is the
#                   ONE transport-trusted package class, kept minimal on purpose.
# The per-repo SigLevels OVERRIDE the global Required DatabaseOptional. [core]/[extra]/
# snapshot keep the global Required, so a rogue Arch mirror is also rejected.
if ! grep -q '^\[partyos\]' "${ROOTFS}/etc/pacman.conf"; then
    awk '/^\[core\]/ && !d {
        print "[partyos]";
        print "SigLevel = Required DatabaseOptional";
        print "Include = /etc/pacman.d/partyos-mirror";
        print "";
        print "[partyos-local]";
        print "SigLevel = Never";
        print "Include = /etc/pacman.d/partyos-local-mirror";
        print "";
        d=1
    } {print}' \
        "${ROOTFS}/etc/pacman.conf" > "${ROOTFS}/etc/pacman.conf.tmp" \
        && mv "${ROOTFS}/etc/pacman.conf.tmp" "${ROOTFS}/etc/pacman.conf"
fi
# Bake NO server address. partyos-mirror-setup writes the Server= lines at boot from
# mirror_url= or report_url=. Until then pacman has no server and cannot dial a dead one.
for _m in partyos-mirror partyos-local-mirror; do
    printf '# Written at boot by partyos-mirror-setup (mirror_url= or report_url=).\n' \
        > "${ROOTFS}/etc/pacman.d/${_m}"
done

# --- FIRST-BOOT KEYRING GUARD (cheap verify-only; the keyring is BAKED at build) -
# The Arch trust root is populated at BUILD time (pacman-key --init/--populate above,
# ~181 keys in /etc/pacman.d/gnupg) and now SURVIVES to runtime because the archiso
# etc-pacman.d-gnupg.mount (the empty-tmpfs shadow) is masked (boot-speed fixes #3b).
# So on the happy path pacman already sees the full keyring at boot with ZERO init -
# no ~90s entropy-bound master-key generation. This service is just a cheap idempotent
# GUARD: it exits immediately when the baked keyring is visible, and only as a defensive
# fallback (should the baked db ever be missing/wiped) does it re-init/populate. Ordered
# BEFORE partyos-mirror.service so the [partyos] Required db sync + any pkg install always
# see a live keyring. A test proved: build-populated home -> 181 keys with no runtime
# init, a Required verify rc=0, and a tampered package rejected.
bake "usr/local/bin/partyos-keyring-init"
bake "etc/systemd/system/partyos-keyring-init.service"
ln -sf /etc/systemd/system/partyos-keyring-init.service \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants/partyos-keyring-init.service"

# --- boot oneshot: point both repos at the live mirror + sync their dbs --------
bake "usr/local/bin/partyos-mirror-setup"
bake "etc/systemd/system/partyos-mirror.service"
ln -sf /etc/systemd/system/partyos-mirror.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/partyos-mirror.service"

# --- partyos-pkg-install: concurrency-safe LAN installer (flock + db.lck wait +
#     retries). Many callers (browser, messenger, app store) may install at once. -
bake "usr/local/bin/partyos-pkg-install"

# --- partyos-seed-config: reusable FIRST-RUN-ONLY per-app config seeder ---
# partyos-seed-config <config_dir> <template-url|path> <out_relpath> [extra K=V..]
# Renders a server-supplied template into ~/.config/<config_dir>/<out_relpath>
# exactly once. The gate is the ABSENCE of ~/.config/<config_dir>: if that dir
# already exists the app is considered user-configured and we STOP - we never
# clobber an existing config (the USB home persists ~/.config across boots).
# Substitution is data-driven: every @KEY@ in the template is replaced by the
# matching value from /run/partyos-user.conf (NICK/FULLNAME fall back to the
# /run/partyos-* convenience files; further K=V can be passed on the cmdline, e.g.
# the Mumble launcher splitting host:port). Values were already sanitized in /run
# (no quotes/newlines/metachars) so the literal sed replace is injection-safe.
# Runs AS the desktop user: writes land in the caller's own $HOME, never
# root-owned. Atomic write + a .partyos-seeded sentinel.
bake "usr/local/bin/partyos-seed-config"

