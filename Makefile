# partyOS Build System

.PHONY: servers usb clean help deps test-harness test-vm test-step1 test-step2 test-step3 test-step4 test-step5 test-step6 test-step7 test-step8 test-step9 test-identity test-metadata test-serversplit test-homeservices test-appstore test-eviction test-torrent-swarm test-usbsplit test-all test-lan test-render test-blob-failover test-ram-gate test-catalog-parse test-identity-reconcile test-gen-guard test-home-pull-gate test-config-seed-gate test-audio-sink test-chicago95-assert test-journal-persist test-cache-policy test-service-churn test-home-select test-copytoram-anchor test-netwait-hook test-timesync test-report-feedback test-https-dualserve test-initramfs-guard test-blob-tooling test-blob-container-quoting test-publish-blob test-announce test-user-provision test-bootwatch test-fleet-verify test-install-hooks test-mirror-quarantine test-mirror-real test-lanrepo-dbsig test-seeder-supervision test-vm-render-isolation test-title-metachars test-personal-site test-appstore-unlock test-newgame-markup test-http-secret-denylist test-http-allowlist test-hotplug-race test-usb-removed-same-stick test-lock-policy test-desktop-bringup test-desktop-ready-report test-proton-runcache-reset test-internyet-identity test-no-dead-addr test-pacman-db-refresh test-xauth-wild test-runsh-prime-offload test-runsh-ezquake-maps test-gpu-env test-lan-bcast-route test-prod fleet-check fleet-verify install-hooks image initramfs boot-artifacts verify-boot-artifacts usbhome gameblobs ipxe ipxe-http verify-ipxe-efi server-name test-server-name test-ca-guard test-install-certs test-prepare-event prepare-event install-server-service reports test-browser-object-crash

# Default target
all: help

# --- VM test harness (autonomous local-QEMU testing) -----------------------

# Install host tooling for the VM harness and verify each binary is present.
deps:
	@echo "Installing harness dependencies via brew..."
	brew install qemu dnsmasq squashfs xorriso
	@echo "Verifying binaries..."
	@/opt/homebrew/bin/qemu-system-x86_64 --version | head -1
	@/opt/homebrew/bin/qemu-img --version | head -1
	@/opt/homebrew/opt/dnsmasq/sbin/dnsmasq --version | head -1
	@/opt/homebrew/bin/mksquashfs -version | head -1
	@/opt/homebrew/bin/xorriso --version 2>&1 | head -1
	@echo "All harness dependencies present."

# Harness self-test: prove the harness can detect a serial marker from a real
# booted VM (exit 0) and correctly fail on a missing marker (non-zero).
test-harness:
	@bash scripts/vm/test-harness.sh

# Generic harness runner. Forward args through ARGS, e.g.:
#   make test-vm ARGS='--marker FOO -- --fda /tmp/x.img'
test-vm:
	@bash scripts/vm/harness.sh $(ARGS)

# Step 1 (Network Boot Foundation + automatic boot): boot a client VM from the
# iPXE USB image AND from the iPXE option ROM, auto-chain partyos.ipxe with no
# keystrokes, and assert the network-boot success marker on serial + the HTTP
# callback in the server access log.
test-step1:
	@bash scripts/vm/test-step1.sh

# Step 2 (RAM-Based Linux Boot): boot a client VM that auto-chains partyos.ipxe,
# loads the Arch kernel/initramfs over HTTP and copies the whole airootfs.sfs
# into RAM (copytoram + cms_verify). Assert a serial login marker, RAM-only
# operation (free -m / findmnt via callback), and that the guest SURVIVES the
# harness killing the HTTP server (the VM-equivalent of removing the USB).
test-step2:
	@bash scripts/vm/test-step2.sh

# Step 3 (Custom OS Image): build a reproducible custom Arch image (XFCE +
# LightDM autologin 'gamer' + browser/file-manager + AMD/NVIDIA/Intel graphics
# and network drivers) in a Docker/amd64 Arch container, then boot it headless
# in QEMU. The desktop comes up HEADLESSLY with no GPU/DRM (LightDM + the dummy
# Xorg driver, or an Xvfb fallback under TCG). Assert: desktop-ready callback +
# an ACTIVE xfce4-session, and the driver/app packages present (pkglist check).
# A QMP screendump is captured as a KVM/physical BONUS (non-blank there), not a
# gate. The VM has no GPU passthrough, so test real GPU acceleration on hardware.
test-step3:
	@bash scripts/vm/test-step3.sh

# Step 4 (USB Home Directory Reading): build a virtual USB home stick (a
# removable qcow2 with an ext4 LANPARTY_HOME filesystem seeded with files), boot
# the custom image headless with the stick attached, and assert that a systemd
# service mounts LANPARTY_HOME at /mnt/usbhome and copies its files into
# /home/gamer. Asserted by serial markers + a step=4 HTTP callback.
test-step4:
	@bash scripts/vm/test-step4.sh

# Step 5 (Continuous Home Synchronization): boot the custom image with the
# LANPARTY_HOME USB stick, mount it READ-WRITE, and run an every-minute systemd
# timer that rsyncs /home/gamer -> the USB stick excluding cache/temp dirs (plus
# a final-sync-on-shutdown unit). The guest writes a uniquely-tagged file; the
# HOST then mounts the USB qcow2 (debugfs in Docker, since macOS has no ext4) and
# verifies the file landed on the stick. A second boot reuses the SAME stick and
# asserts the file persisted across the reboot. STEP5_SKIP_PERSIST=1 skips boot 2.
test-step5:
	@bash scripts/vm/test-step5.sh

# Step 6 (Hot-Plug USB Support): boot the custom image with the LANPARTY_HOME USB
# stick, then drive the QMP socket to device_del the stick mid-run (the autonomous
# stand-in for yanking it) and assert the system keeps running, udev pauses the
# sync, and a USB-removed notification fires. A file is written while the stick is
# gone; device_add reinserts it, udev resumes the sync and flushes the offline
# file. The HOST then mounts the USB qcow2 (debugfs) to confirm the offline file
# landed. STEP6_RAM_MB / STEP6_TIMEOUT tune the boot.
test-step6:
	@bash scripts/vm/test-step6.sh

# Step 7 (Game Blob Distribution): build a game catalog + compressed game blobs
# (two tiny DUMMY games whose run.sh prints a marker), then boot the custom image
# headless. step7-script.sh fetches the catalog, downloads each blob, mounts it
# via squashfs+overlayfs to /home/gamer/games/<name>, runs the dummy game (marker
# via serial + callback), and proves BOTH games mount simultaneously. The HOST
# confirms the server served the catalog + both blobs (HTTP access log).
# STEP7_RAM_MB / STEP7_TIMEOUT tune the boot.
test-step7:
	@bash scripts/vm/test-step7.sh

# Step 8 (Game Blob Caching): boot the custom image with a FRESH LANPARTY_HOME USB
# stick. step8-script.sh mounts it rw and uses .partyos-cache/games on it as a
# persistent blob cache. BOOT 1 (cold): every game is a cache MISS -> downloads
# from the server + writes the blob to the USB cache (the HOST then mounts the
# qcow2 to confirm the blobs landed). BOOT 2 (warm, SAME qcow2): every game is a
# cache HIT -> NO server GET for any blob (asserted against the timestamped
# http_access.log) and games still mount+run from the cached blobs. Cache
# management is a size-limit LRU eviction. STEP8_RAM_MB / STEP8_TIMEOUT tune the
# boot; STEP8_SKIP_WARM=1 runs only the cold boot.
test-step8:
	@bash scripts/vm/test-step8.sh

# Step 9 (Server Boot Scripts): the SERVER hosts a per-boot script
# (server/boot-config.sh) that every client FETCHES + RUNS on each boot, BEFORE the
# desktop. BOOT 1 (boot-script server up): step9-script.sh fetches + runs it, the
# server-driven effect (announce=...) is applied on the client + carried in the
# step=9 callback, and the headless XFCE desktop comes up. BOOT 2: the harness
# KILLS the separate boot-script server before boot; the fetch fails, step9-script.sh
# TOLERATES it (PARTYOS-STEP9-SERVER-SCRIPT-MISSING) and the client STILL reaches the
# desktop (failure tolerance). The OS server stays up both boots so the image still
# RAM-boots. STEP9_RAM_MB / STEP9_TIMEOUT tune the boot; STEP9_SKIP_FAILTEST=1 runs
# only the server-up boot.
test-step9:
	@bash scripts/vm/test-step9.sh

# Dynamic IDENTITY (USB .partyos -> desktop account name + hostname): boot the
# custom image three times with differently-seeded LANPARTY_HOME sticks and
# assert the BAKED partyos-identity.service resolves them, from a real booted VM
# (serial markers + a step=identity HTTP callback). (a) USERNAME=raver7 -> session
# user raver7 at uid 1000 with passwordless sudo, /home/raver7 seeded from the
# USB, hostname derived raver7-<4hex-of-MAC-hash>. (b) explicit HOSTNAME= -> that
# hostname verbatim. (c) no .partyos -> user gamer, hostname partyos-<4hex>.
# IDENTITY_RAM_MB / IDENTITY_TIMEOUT tune each boot. Heavy under TCG - run on
# a KVM host via scripts/vm/remote-test.sh test-identity.
test-identity:
	@bash scripts/vm/test-identity.sh

# Blob metadata: check the catalog and embedded game.meta fields on a booted client (KVM host).
test-metadata:
	@bash scripts/vm/test-metadata.sh

# Server split: boot from the netboot server, fetch blobs from blob server 1, fail over to 2 (KVM host).
test-serversplit:
	@bash scripts/vm/test-serversplit.sh

# Home services: start ~/.partyos/services/<name>.sh as the user at boot, or no-op (KVM host).
test-homeservices:
	@bash scripts/vm/test-homeservices.sh

# App store: drive partyos-app list/install/launch/installed/remove on a booted client (KVM host).
test-appstore:
	@bash scripts/vm/test-appstore.sh

# RAM eviction: partyos-ram evicts the idle blob, keeps the in-use one, mounts pong (KVM host).
test-eviction:
	@bash scripts/vm/test-eviction.sh

# Torrent swarm: client B downloads a blob from client A alone; host aria2 processes, no VMs.
test-torrent-swarm:
	@bash scripts/vm/test-torrent-swarm.sh

# USB split: read .partyos from the exFAT partition and mount the ext4 home; legacy stick too (KVM host).
test-usbsplit:
	@bash scripts/vm/test-usbsplit.sh

# --- PROD-path unit/integration tests ---------------------------------------
# Hardware-FREE pure-shell tests for the PRODUCTION boot path (render.sh +
# boot/partyos.ipxe.prod.tmpl + the baked partyos-app/partyos-ram logic) - the
# path make test-step1..9 do NOT cover (those exercise the VM iPXE templates).
# No VM, no network, no hardware: runs locally/CI in seconds. Each exits non-zero
# on any failed assertion and prints PASS/FAIL per check.

# render.sh: drive it with representative deploy.conf inputs and assert the rendered
# boot/partyos.ipxe kernel cmdline (static-ip boot-wedge param, blob_urls failover
# order, report_url=/archiso/copytoram/retry-ladder, single-box param omission).
test-render:
	@bash scripts/test/test-render.sh

# The server-name knob (setup.sh --server-name) reaches deploy.conf, the embed, the
# cert SAN, the rendered boot script and the EFI guard. Hardware-free.
test-server-name:
	@bash scripts/test/test-server-name.sh

# The CA overwrite guards. A CA cert present without its key must REFUSE (never
# overwrite it with a new CA of the same subject), a mismatched pair must error clearly, a correct pair must be
# reused, --force must rotate, and the recorded CA_FINGERPRINT must catch a swapped
# CA. Temp dirs only, EFI build stubbed, hardware-free.
test-ca-guard:
	@bash scripts/test/test-ca-guard.sh

# Bring-your-own-certificate (install-certs.sh): install a venue-signed leaf + its
# CA instead of minting our own, and refuse a mismatched key / wrong CA / SAN that
# misses a deploy.conf address. Also guards that gen-ca.sh cannot sign while an
# external CA is installed. Temp dirs only, hardware-free.
test-install-certs:
	@bash scripts/test/test-install-certs.sh

# The event wizard (prepare-event.sh): the deploy.conf defaults and writes, the
# idempotent re-run and the confirmation gate. Hardware-free, setup.sh stubbed.
test-prepare-event:
	@bash scripts/test/test-prepare-event.sh

# Identity source: the per-player identity now comes from `internyet.env` on
# the stick's shared exFAT partition (PARTYSHARE), not from the deleted .partyos /
# user.conf on the home partition. Covers the parse, the key mapping, the USERNAME
# home gate, the legacy fallback, a malformed file, and that the p12 password never
# reaches a log line.
test-internyet-identity:
	@bash scripts/test/test-internyet-identity.sh

# partyos-app blob failover: extract blob_bases/blob_fetch from the baked
# heredoc and unit-test the ordered failover with a mocked fetch (no network).
test-blob-failover:
	@bash scripts/test/test-blob-failover.sh

# partyos-ram RAM gate: extract required_mb/effective_shm_mb/blob_squashfs_mb
# from the baked heredoc and unit-test the honest projection + the 8GB-refuses /
# 16GB-fits gate decision against a synthetic catalog.
test-ram-gate:
	@bash scripts/test/test-ram-gate.sh

# partyos-app load_catalog robustness: extract the per-object catalog parser from
# the baked heredoc and assert a malformed row is skipped (not store-wide ragged-abort)
# + the parse stays byte-identical to json across the real catalog.
test-catalog-parse:
	@bash scripts/test/test-catalog-parse.sh

# Every catalog config_template (the first-run config seed) must exist under
# server/, so the launch does not fetch a missing template.
test-catalog-templates:
	@bash scripts/test/test-catalog-templates.sh

# partyos-identity-setup reconcile: a failed account rename must degrade to the
# actual uid-1000 account (self-consistent autologin) or fail loud, never write a
# dangling autologin-user. Carve the heredoc + assert the reconcile branches.
test-identity-reconcile:
	@bash scripts/test/test-identity-reconcile.sh

# home-sync generation guard: an equal-gen cross-box replug must NOT silently
# last-writer-wins, and a corrupt gen counter must NOT read as 0 and clobber. Carve
# the COMMON heredoc + assert push/standdown/tie/corrupt verdicts + the bounded
# conflict backup that preserves the about-to-be-overwritten side.
test-gen-guard:
	@bash scripts/test/test-gen-guard.sh

# home-pull data-safety gate: a boot pull that dies mid-copy must NOT open the
# push gate (PULL_DONE) - else the 45s push --delete-mirrors the partial RAM home
# over the stick and wipes it. Carve the baked partyos-home-pull + partyos-sync-home,
# drive them with a stubbed rsync that simulates a mid-copy SIGKILL, and assert the
# gate stays closed + the stick is byte-untouched + the push no-ops. Also proves the
# `rsync -ani` tie-detection fix is live (old `-an` printed nothing = dead code).
test-home-pull-gate:
	@bash scripts/test/test-home-pull-gate.sh

# first-run config-seed gate: partyos-seed-config must gate on the .partyos-seeded
# completion SENTINEL, not the config DIR's existence - else a transient first-run
# failure that made the dir but never wrote the sentinel skips the nick/IRC/game seed
# FOREVER on the player's USB home. Carve the baked seeder + drive it against a temp
# HOME: interrupted seed (dir, no sentinel) re-seeds; completed seed (sentinel) skipped.
test-config-seed-gate:
	@bash scripts/test/test-config-seed-gate.sh

# Unit-test the baked partyos-default-sink picker: carve pick_sink() out of the
# build heredoc and assert its choice against synthetic `wpctl status` dumps - prefer
# onboard analog (incl. Realtek/ALC naming) over HDMI, USB headset over HDMI, fall back
# to HDMI only when it is the lone sink. Hardware-free (no wpctl/pipewire).
test-audio-sink:
	@bash scripts/test/test-audio-sink.sh

# Unit-test the Chicago95 theme FAIL-LOUD assertion: carve chicago95_assert()
# out of the build script and prove a complete rootfs passes while each missing
# theme artifact (gtk theme, icon theme, xfconf default) FAILS - so the build can
# no longer silently ship a plain unthemed XFCE. Hardware-free (no clone/chroot).
test-chicago95-assert:
	@bash scripts/test/test-chicago95-assert.sh

# partyos-journal-snapshot (diagnosability): the journal is snapshotted to the USB per
# boot so partyos-lastboot-log can read the PREVIOUS boot after a reboot; assert the
# snapshot/prune/helper contract + the watchdog timeout consistency (chip >= RuntimeWatchdogSec).
test-journal-persist:
	@bash scripts/test/test-journal-persist.sh

# Blob-policy robustness: carve get_blob + the hidden gate out of the build heredoc
# and assert that a stale-sha cached blob is KEPT, not re-downloaded, unless a forced
# reinstall; that hidden catalog rows refuse install-by-name while the load-url
# share-code path stays open; and that catalog.json stays in sync with catalog.v2.json.
# Hardware-free (no network/VM).
test-cache-policy:
	@bash scripts/test/test-cache-policy.sh

# Service churn: assert partyos-usb-poll is a
# long-lived loop service (not a per-~8s oneshot+timer that spams SERVICE_START/STOP + audit)
# and that partyos-journal-snapshot serializes with a non-blocking flock so a slow stick can
# never stack overlapping rsyncs. Carves the heredocs out of the build script. Hardware-free.
test-service-churn:
	@bash scripts/test/test-service-churn.sh

# Multi-stick home selection: with two sticks that
# both carry the LANPARTY_HOME label, `blkid -L` is nondeterministic. Carve resolve_home_dev
# out of the build heredoc, mock blkid, and assert a deterministic, boot-stable, UUID-driven,
# logged pick (and that one stick / no stick is unchanged). Hardware-free.
test-home-select:
	@bash scripts/test/test-home-select.sh

# The copytoram curl-retry/watchdog override is sed-anchored to archiso's exact
# fetch string. Carve the anchor-application block and assert a missed anchor / missing
# hook FAILS the build (no silent WARN-and-ship of an initramfs without copytoram
# resilience), and that a present anchor injects the flags idempotently. Hardware-free.
test-copytoram-anchor:
	@bash scripts/test/test-copytoram-anchor.sh

# Initramfs partyos_netwait link-wait hook: carve the run_hook body, point its
# /sys/class/net at a mock carrier tree, and assert it reads the mkinitcpio
# parse_cmdline vars (${ip}/${netwait}) and ACTUALLY enters a bounded wait when the
# link is down (no longer a getarg no-op) + returns promptly when link is up.
test-netwait-hook:
	@bash scripts/test/test-netwait-hook.sh

# partyos-timesync (client clock from the server Date header): carve the script,
# drive it with a mock server + a CLOCK-SAFE date shim, and assert --check works and
# every failure path is fail-safe (log + exit 0, clock untouched, never wedges boot).
test-timesync:
	@bash scripts/test/test-timesync.sh

# No dead fallback address (10.0.2.2 / lab IP) in the baked image; a missing server
# parameter fails loudly; systemd-resolved has no public fallback DNS.
test-no-dead-addr:
	@bash scripts/test/test-no-dead-addr.sh

# Client pacman sync db refresh: the boot oneshot and partyos-pkg-install run -Sy (never
# -u), a failed boot sync is logged and not fatal, and the image and the mirror pin
# the same SNAPSHOT.
test-pacman-db-refresh:
	@bash scripts/test/test-pacman-db-refresh.sh

# The X cookie of step3 is FamilyWild, so a later hostname change does not lock out XFCE.
test-xauth-wild:
	@bash scripts/test/test-xauth-wild.sh

# Blob run.sh on a hybrid laptop: PRIME render offload for the nvidia vendor, or Mesa on the iGPU.
test-runsh-prime-offload:
	@bash scripts/test/test-runsh-prime-offload.sh

# The ezquake run.sh seeds the free nQuake deathmatch maps into ~/quake on every launch.
test-runsh-ezquake-maps:
	@bash scripts/test/test-runsh-ezquake-maps.sh

# partyos-gpu-env gives the PRIME offload env (or DRI_PRIME) to every game launch, so served blobs work on hybrid laptops.
test-gpu-env:
	@bash scripts/test/test-gpu-env.sh

# partyos-lpd-route adds 255.255.255.255/32 on the LAN NIC, so a box with no default route can broadcast (WC3 LAN discovery).
test-lan-bcast-route:
	@bash scripts/test/test-lan-bcast-route.sh

# partyos-browser hides <object type=text/html> subframes with a user stylesheet,
# because WebKitGTK 2.48.5 crashes the Epiphany UI process on them (wiki.c.nyet).
test-browser-object-crash:
	@bash scripts/test/test-browser-object-crash.sh

# In-session "Report an Issue" player INBOX (opt-in context): start the real
# http_server.py and assert BOTH shapes persist under server/reports/ - a
# message-ONLY report (nick + message, NO system info) and a bug report (opt-in:
# build_id + log_tail attached) - and that legacy /report is unchanged. Carve
# partyos-report's collect_context and assert the LEAN bug bundle (build/game/
# mem_free/log_tail) with a BOUNDED log tail; carve partyos-report-flush and assert
# the offline queue SURVIVES an unreachable server (no delete-on-failure).
# Hardware-free (loopback server only, no VM).
test-report-feedback:
	@bash scripts/test/test-report-feedback.sh

# Operator inbox reader: list (or with REPORT=<file>, show) the player reports that
# landed under server/reports/. server/reports/ IS the inbox - each *.json is one
# entry (a plain message, or a bug with system info). Read-only convenience.
reports:
	@bash scripts/deploy/show-reports.sh $(REPORT)

# HTTPS dual-serve: gen-ca.sh mints a private CA + a CA-signed server leaf
# whose SAN carries the server IP; the server presents it on :8443 while keeping
# :8080 plaintext. Asserts the leaf is CA-signed with the IP SAN, that HTTPS works
# only WITH the pinned --cacert (and fails without - no system-trust leak), that
# plain HTTP is unchanged, and that a missing cert degrades to HTTP-only (no crash).
# Hardware-free (loopback server + curl + openssl).
test-https-dualserve:
	@bash scripts/test/test-https-dualserve.sh

# All prod-path shell tests in one shot. Fast, hardware-free; run before the heavy
# VM gate. Stops non-zero on the first failing suite.
# Mutation test for the boot-artifact guard (scripts/deploy/check-initramfs.sh):
# synthesize minimal microcode+xz-cpio initramfs fixtures and prove the guard
# PASSES a good one (CA + --cacert + newer than the sfs) and FAILS each regression
# (CA stripped / --cacert stripped / older than the sfs). Hardware-free.
test-initramfs-guard:
	@bash scripts/test/test-initramfs-guard.sh

# Contributor blob tooling (scripts/blob/make-blob.sh + add-blob.sh): assert the
# fragment emitter writes a rectangular row with a real sha WITHOUT mutating the
# operator catalog, add-blob REFUSES an empty-sha fragment (fail-closed), upserts a
# valid fragment into a TEMP catalog + renders catalog.json with the row+sha, and is
# idempotent on re-add. Uses a stub blob - no docker build. Hardware-free.
test-blob-tooling:
	@bash scripts/test/test-blob-tooling.sh

# Static check: no bare apostrophe breaks the single-quoted container script of the
# blob builders. Hardware-free.
test-blob-container-quoting:
	@bash scripts/test/test-blob-container-quoting.sh

test-publish-blob:
	@bash scripts/test/test-publish-blob.sh

# announce.sh (operator-broadcast push tool) appends valid JSON notices with
# auto-incrementing ids, honours --title/--level/--expires, keeps the feed valid +
# bounded, and --list/--clear work - all against a temp feed (never the live one).
test-announce:
	@bash scripts/test/test-announce.sh

# Per-player provisioning tooling (gen-user-config.sh + flash-usb.sh --user): assert
# the generator assigns a free, non-colliding static IP from the player range (--slot
# / --ip / --force honoured), and flash-usb --user writes the correct identity split
# (.partyos vs user.conf, pinned IP where the OS reads it) + seeds home, warns+stops on
# an unknown player, and --blank bypasses. Temp store + dry-run seam - no USB, no sudo.
test-user-provision:
	@bash scripts/test/test-user-provision.sh

# lib-bootwatch (scripts/test/lib-bootwatch.sh): the boot-watch library with a hard
# timeout and a stall detector (exit codes OK/FAIL-MARKER/TIMEOUT/STALL + heartbeats).
# Exercised against temp logs, runs in seconds.
test-bootwatch:
	@bash scripts/test/test-bootwatch.sh

# fleet-verify.sh (cross-host matrix tool): mock ssh via a PATH shim (one healthy
# host, one llvmpipe failure, one unreachable - NO real network) and assert the
# matrix.md/JSON evidence, exit codes, that --check never sends a state-modifying
# command, that --reboot refuses to run without an explicit target, and the
# --reboot paths end to end against a synthetic access log (boot=ok, and a
# STALLed boot overriding a green probe).
test-fleet-verify:
	@bash scripts/test/test-fleet-verify.sh

# install-hooks.sh (opt-in pre-commit gate): temp git repo + stub Makefile; assert
# hook installed + .bak backup (and that a re-run can never destroy the original
# backup), a failing test-prod blocks the commit, and the SKIP_TESTS=1 escape
# hatch works.
test-install-hooks:
	@bash scripts/test/test-install-hooks.sh

# LAN-mirror quarantine step: prove a keyring drift can only ever touch THIS run
# newly-added closure and never re-verify/wipe the already-published mirror.
test-mirror-quarantine:
	@bash scripts/test/test-mirror-quarantine.sh

# LAN-mirror real run: the real mirror-pkgs.sh (docker + archive.archlinux.org) into a
# scratch mirror. A validly signed package with deps that are not installed is kept, a
# revoked-signer package is quarantined, and partyos.db is rebuilt.
# Needs docker and internet, so it is not in test-prod.
test-mirror-real:
	@bash scripts/test/test-mirror-pkgs-real.sh

# LAN repo db-signature contract: the repo db is built sign-less (no partyos.db.sig)
# and the client [partyos] repo stays on DatabaseOptional, so the client-side
# partyos.db.sig 404 is benign and never a fatal abort.
test-lanrepo-dbsig:
	@bash scripts/test/test-lanrepo-dbsig.sh

# P2P seeder hardening in run-servers.sh: drive the extracted seed-list filter
# (list-seed-torrents.sh) with mock files - backed torrents seed, orphan
# hash-named torrents drop - and statically pin the respawn-supervision +
# idempotent-restart wiring.
test-seeder-supervision:
	@bash scripts/test/test-seeder-supervision.sh

# VM iPXE renderer output isolation: plant a sentinel on the LIVE prod
# boot/partyos.ipxe, run a no-arg VM render, and assert the prod script is
# byte-for-byte untouched while the render lands on boot/partyos.ipxe.vm instead.
test-vm-render-isolation:
	@bash scripts/test/test-vm-render-isolation.sh

# player/catalog TITLE with shell metacharacters ($ ` " ; & ${...}) must land in the
# generated .desktop launchers verbatim - never expanded, executed, or aborting
# generation under set -u. Carves
# write_app_desktop + cmd_gen_tiles out of the builder and drives them with a hostile
# title plus a benign exact-format check.
test-title-metachars:
	@bash scripts/test/test-title-metachars.sh

# Auto-hosted personal sites (server/sites/ served at /sites/): a guest drops an
# .html file and it is served over the LAN, while the route stays STRICTLY scoped -
# ../ traversal, an escaping symlink and encoded %2e%2e all 403 (never the CA key /
# certs / configs). Loopback server + curl.
test-personal-site:
	@bash scripts/test/test-personal-site.sh

# App-store "Enter a Code" hidden-blob unlock: a hidden catalog row with an
# unlock_code is excluded by default; entering the code (case-insensitive, trimmed)
# reveals it + every blob sharing that code, persists to the USB home (survives reboot),
# and a wrong/empty code reveals nothing. Carve-and-mock of the real partyos-app helpers.
test-appstore-unlock:
	@bash scripts/test/test-appstore-unlock.sh

# The zenity text of partyos-newgame must be valid Pango markup. If it is not, zenity
# shows its default text. Loads the real functions and stubs zenity and the engine.
test-newgame-markup:
	@bash scripts/test/test-newgame-markup.sh

# Secret denylist in http_server.py: the
# server serves the whole repo as docroot, so a bare denylist must 403 the CA private
# key, TLS leaf key, users/ PII, deploy.conf and .git - including traversal / encoded
# / double-slash variants - while STILL serving boot artifacts, the catalog and
# /sites. Loopback server + curl; plants a decoy key so it is meaningful in a clean tree.
test-http-secret-denylist:
	@bash scripts/test/test-http-secret-denylist.sh

# Public allowlist in http_server.py: only the boot and blob artifacts are served,
# there are no directory listings, and backups, templates, dotfiles and keys are
# refused. Loopback server on a temp tree + curl.
test-http-allowlist:
	@bash scripts/test/test-http-allowlist.sh

# Home-sync HOTPLUG-RACE mechanics (coldplug reinsert pull gate, removed/reinserted
# ordering, safe-eject barrier): carve-and-mock of the
# baked hotplug heredocs - the push stands down on the pull-in-progress marker, the
# removed/reinsert handlers serialize on the shared hotplug lock, and safe-eject detects
# open writers + an in-flight push before it toasts "safe to remove". The RUNTIME timing
# itself needs real USB hotplug (fleet-verify); this covers the lock/marker/gate logic.
test-hotplug-race:
	@bash scripts/test/test-hotplug-race.sh

# The home stick removal acts only when the device behind /mnt/usbhome is gone: a
# second stick with a home label or a stacked mount must not unmount the home.
test-usb-removed-same-stick:
	@bash scripts/test/test-usb-removed-same-stick.sh

# Screen-lock POLICY: no password -> no lock (a passwordless kiosk must never lock
# itself out) but the screen still blanks/DPMS-sleeps; a passworded user keeps the lock.
# Carves partyos-lock-setup + partyos-lock and drives them under stubbed X tooling.
test-lock-policy:
	@bash scripts/test/test-lock-policy.sh

# Real-HW XFCE failsafe-session regression guard: no systemd-udev-settle deps survive,
# and partyos-xfce-launch only adopts the systemd --user bus once it answers a ListNames
# probe (else falls back to dbus-run-session), waits on the boot home-pull, and guards
# the panel reload. Static wiring asserts + a behavioural adopt-vs-fallback drive.
test-desktop-bringup:
	@bash scripts/test/test-desktop-bringup.sh

# Honest step-3 desktop-ready report: status=ok&desktop=ready only when XFCE is up AND an
# X server is running, else status=degraded&desktop=notready - in both step3-script.sh
# paths and the baked partyos-desktop-ready. Evals the real carved derive blocks + drives
# the runner under stubbed pgrep/curl (a black seat must not report a false green).
test-desktop-ready-report:
	@bash scripts/test/test-desktop-ready-report.sh

# A new Proton blob resets the Wine registry in the stick upper of its prefix. Saves stay.
# uncache and reinstall also cause the reset.
test-proton-runcache-reset:
	@bash scripts/test/test-proton-runcache-reset.sh

test-prod: test-render test-server-name test-ca-guard test-install-certs test-prepare-event test-blob-failover test-ram-gate test-catalog-parse test-catalog-templates test-identity-reconcile test-gen-guard test-home-pull-gate test-config-seed-gate test-audio-sink test-chicago95-assert test-journal-persist test-cache-policy test-service-churn test-home-select test-copytoram-anchor test-netwait-hook test-timesync test-report-feedback test-https-dualserve test-initramfs-guard test-blob-tooling test-blob-container-quoting test-publish-blob test-announce test-user-provision test-bootwatch test-fleet-verify test-install-hooks test-mirror-quarantine test-lanrepo-dbsig test-seeder-supervision test-vm-render-isolation test-title-metachars test-personal-site test-appstore-unlock test-newgame-markup test-http-secret-denylist test-http-allowlist test-hotplug-race test-usb-removed-same-stick test-lock-policy test-desktop-bringup test-desktop-ready-report test-proton-runcache-reset test-internyet-identity test-no-dead-addr test-pacman-db-refresh test-xauth-wild test-runsh-prime-offload test-runsh-ezquake-maps test-gpu-env test-lan-bcast-route test-browser-object-crash
	@echo "test-prod: all prod-path shell tests passed"

# Cross-host verification matrix (docs/TESTING.md).
# READ-ONLY ssh probes of every fleet box: partyOS-from-RAM detection, booted-sfs
# sha vs the served sha, desktop/home-sync/GPU/blob smoke checks. Never reboots.
# Evidence lands in scripts/test/results/fleet-<timestamp>/ (per-host JSON +
# matrix.md stamped with date + served sfs sha). Non-zero if any host FAILs or is
# UNREACHABLE.
fleet-check:
	@bash scripts/deploy/fleet-verify.sh --check

# Full re-PXE verification: ssh-reboot HOST (a fleet name/IP, or 'all') and
# boot-watch the netboot access log (timeout + stall detection + heartbeats) for
# step=copytoram then step=3 desktop=ready, then rerun the smoke checks. Needs an
# EXPLICIT HOST= - it refuses to reboot anything by default.
# FLEET_ACCESS_LOG= points at the file capturing http_server.py stdout.
fleet-verify:
	@if [ -z "$(HOST)" ]; then \
		echo "Usage: make fleet-verify HOST=<fleet-name|ip|all> [FLEET_ACCESS_LOG=path]"; \
		echo "  (refuses to reboot anything without an explicit HOST; use make fleet-check for the read-only probe)"; \
		exit 1; \
	fi
	@bash scripts/deploy/fleet-verify.sh --reboot $(HOST)

# OPT-IN pre-commit hook: run `make test-prod` before every commit and block on
# failure (SKIP_TESTS=1 bypasses; an existing hook is backed up to .bak first).
install-hooks:
	@bash scripts/dev/install-hooks.sh

# Run step1..9 headless in sequence (the unattended acceptance gate). Non-zero on
# the first failing step. Heavy: each step boots a full VM, so on a host without KVM
# (TCG) this is very slow - run it on a KVM host via scripts/vm/remote-test.sh test-all.
# The fast hardware-free prod-path tests run FIRST as a cheap pre-gate.
test-all: test-prod
	@bash scripts/vm/test-all.sh

# Multi-client LAN realism: launch N client VMs sharing one server and assert all
# reach the desktop (the VM proxy for "many PCs at the party"). N defaults to 2;
# host RAM caps concurrency - the script logs the limitation if it
# must reduce N rather than silently capping. STEP_LAN_N / STEP_LAN_RAM_MB tune it.
test-lan:
	@bash scripts/vm/test-lan.sh

# Build the game catalog + compressed game blobs only (no boot). Output defaults
# to server/games/ (blobs + catalog.json are git-ignored). DIR overrides.
gameblobs:
	@bash scripts/build/build-game-blobs.sh $(if $(DIR),$(DIR),server/games)

# Build the custom image only (no boot). FORCE=1 rebuilds.
# NOTE: this rebuilds ONLY the squashfs - NOT the served initramfs. After changing
# anything in an initramfs hook or mkinitcpio drop-in (e.g. the bundled CA),
# you MUST also run `make initramfs`. Use `make boot-artifacts` to do both in order.
image:
	@bash scripts/build/build-image.sh

# Regenerate the SERVED initramfs (server/images/initramfs-linux.img) from the
# freshly-built sfs. Runs scripts/build/slim-initramfs.sh in a PRIVILEGED
# linux/amd64 Arch container (honors the mkinitcpio drop-ins - the bundled
# CA + the archiso_pxe_http --cacert override), installs its output ATOMICALLY, and
# self-verifies with the boot-artifact guard. Run this AFTER `make image`. Kept a
# SEPARATE target (privileged) on purpose; `make boot-artifacts` chains image+this.
initramfs:
	@bash scripts/build/build-initramfs.sh

# The full boot-artifact rebuild in the correct order: the sfs THEN the served
# initramfs (so the initramfs can never go stale relative to the sfs). FORCE=1
# forwards to the image build.
boot-artifacts: image initramfs
	@echo "boot-artifacts: sfs + served initramfs rebuilt and guard-verified"

# Run ONLY the boot-artifact guard against the currently-served initramfs + sfs.
# FAILS (non-zero) if the served initramfs lacks the bundled CA / the --cacert hook
# flag, or is older than the sfs (stale). Wired into `make servers` startup too.
verify-boot-artifacts:
	@bash scripts/deploy/check-initramfs.sh

# Build the boot iPXE EFI reproducibly. Runs
# scripts/build/build-ipxe.sh in a linux/amd64 docker container: clone iPXE at a
# PINNED ref, embed our autoboot script, and (https) compile the pinned partyOS CA
# in with BOTH CERT= and TRUST= (TRUST= alone embeds only the fingerprint -> a
# private-CA-only chain fails 0216eb8f). Self-verifies the produced binary (valid
# PE/EFI; https: the current ca/partyos-ca.crt DER embedded + HTTPS compiled in)
# and FAILS CLOSED otherwise. Output is gitignored (*.efi).
#   make ipxe                 -> build/ipxe-custom-https.efi (default, https+CA)
#   make ipxe VARIANT=http    -> build/ipxe-custom.efi       (plain http, no CA)
#   make ipxe-http            -> same as VARIANT=http
# Overrides forward via env: EMBED= CA= OUT= IPXE_REF=. Kept OUT of the default
# build chain (like `make initramfs`); a deployed EFI is rebuilt only on a CA
# rotation, an iPXE/embed change, or binary loss.
ipxe:
	@VARIANT=$(if $(VARIANT),$(VARIANT),https) bash scripts/build/build-ipxe.sh

# Convenience alias for the plain-http variant (build/ipxe-custom.efi, no CA).
ipxe-http:
	@VARIANT=http bash scripts/build/build-ipxe.sh

# Guard: the built https iPXE EFI (build/ipxe-custom-https.efi) embeds the CURRENT
# ca/partyos-ca.crt. Catches a CA rotation (gen-ca.sh --force) without an EFI
# rebuild (the stale EFI would still trust the OLD CA -> TLS boot chain fails).
# TOLERANT of the EFI being absent (it is gitignored + host-local): NOTE+skip, not
# fail, so a box that never built it is not blocked. FAILS only on a present+stale EFI.
verify-ipxe-efi:
	@bash scripts/deploy/check-ipxe-efi.sh

# Set the server name (DNS name or IP) that the sticks dial. One command writes
# deploy.conf, reissues the leaf cert with the name in its SAN (same CA), renders
# boot/partyos.ipxe and rebuilds the iPXE EFI. Flash sticks with the new EFI after it.
#   make server-name SERVER_NAME=partyos.lan
server-name:
	@if [ -z "$(SERVER_NAME)" ]; then \
		echo "Usage: make server-name SERVER_NAME=<dns-name-or-ip>"; exit 1; \
	fi
	@bash scripts/deploy/setup.sh --non-interactive --skip-build --server-name=$(SERVER_NAME)

# Prepare one LAN event: the five-question wizard. It asks, prints a summary,
# takes ONE confirmation, then writes deploy.conf.
#   make prepare-event                       interactive
#   make prepare-event ARGS="--answers f"    replay an answers file
prepare-event:
	@bash scripts/deploy/prepare-event.sh $(ARGS)

# Install the server systemd unit ON the party server (Debian). Restart=always,
# so the servers survive a dropped SSH session and a crash.
#   sudo make install-server-service
#   sudo make install-server-service ARGS="--user user --repo /home/user/partyos"
install-server-service:
	@bash scripts/deploy/install-server-service.sh $(ARGS)

# Build the virtual USB home image only (ext4 LANPARTY_HOME, seeded). Output
# defaults to server/images/usbhome.qcow2 (git-ignored). OUT/SIZE/TAG override.
usbhome:
	@bash scripts/create_usb.sh --image-home \
		$(if $(OUT),$(OUT),server/images/usbhome.qcow2) \
		$(if $(SIZE),$(SIZE),256) $(if $(TAG),$(TAG),partyos-step4)

# Start the server ROLES per deploy.conf (server split): one process for the
# netboot/PXE listener + one per distinct blob listener. A single-box deploy.conf
# (BLOB == PXE) collapses to ONE process. Run this helper on
# each host when the blob servers live on different machines. CONF= overrides the
# deploy.conf path.
servers:
	@bash scripts/deploy/run-servers.sh $(if $(CONF),$(CONF),)

# Create bootable USB (requires device parameter). The server IP is baked into the
# https CA EFI by scripts/deploy/setup.sh, NOT passed here - the 2nd positional to
# create_usb.sh is only an explicit EFI-path override (EFI= forwards it). Run setup.sh
# first to build build/ipxe-custom-https.efi.
usb:
	@if [ -z "$(DEVICE)" ]; then \
		echo "Usage: make usb DEVICE=/dev/sdX [EFI=path/to/ipxe.efi]"; \
		echo "Example: make usb DEVICE=/dev/sdb"; \
		echo "  (the server IP is baked into the EFI by scripts/deploy/setup.sh - run it first)"; \
		exit 1; \
	fi
	./scripts/create_usb.sh $(DEVICE) $(EFI)

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	find . -name "*.pyc" -delete
	find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# Show help
help:
	@echo "partyOS Build System"
	@echo ""
	@echo "Available targets:"
	@echo "  servers                Start server roles per deploy.conf (guards boot artifacts first)"
	@echo "  usb                    Create bootable USB drive"
	@echo "  image                  Build the custom OS squashfs only (FORCE=1 rebuilds)"
	@echo "  initramfs              Regenerate the SERVED initramfs (privileged; run AFTER make image)"
	@echo "  boot-artifacts         Rebuild sfs THEN initramfs in the correct order"
	@echo "  verify-boot-artifacts  Guard: served initramfs has the pinned CA + --cacert + is fresh"
	@echo "  ipxe                   Build the boot iPXE EFI reproducibly (default https+CA; VARIANT=http for plain)"
	@echo "  ipxe-http              Build the plain-http iPXE EFI (build/ipxe-custom.efi, no CA)"
	@echo "  verify-ipxe-efi        Guard: the built https iPXE EFI embeds the current CA (skips if absent)"
	@echo "  server-name            Set the server name: make server-name SERVER_NAME=<name> (conf+cert+EFI)"
	@echo "  prepare-event          Interactive event wizard: server, blobs, mirror, chat, party name"
	@echo "  install-server-service Install the server systemd unit (run on the party server, as root)"
	@echo "  test-prod              Hardware-free prod-path shell tests"
	@echo "  fleet-check            READ-ONLY ssh probe matrix of the physical fleet (never reboots)"
	@echo "  fleet-verify           Full re-PXE verification: reboot HOST= and boot-watch (explicit HOST required)"
	@echo "  install-hooks          OPT-IN pre-commit hook: make test-prod gates every commit (SKIP_TESTS=1 bypasses)"
	@echo "  clean                  Clean build artifacts"
	@echo "  help                   Show this help message"
	@echo ""
	@echo "IMPORTANT: a boot rebuild is TWO artifacts. \`make image\` rebuilds ONLY the"
	@echo "squashfs; the served initramfs is regenerated by \`make initramfs\`. Always run"
	@echo "them in order - \`make image && make initramfs\` (or \`make boot-artifacts\`) -"
	@echo "or the served initramfs goes stale (no bundled CA -> HTTPS boot fails closed)."
	@echo ""
	@echo "Examples:"
	@echo "  make servers"
	@echo "  make image && make initramfs    # or: make boot-artifacts"
	@echo "  make verify-boot-artifacts"
	@echo "  ./scripts/deploy/setup.sh              # turnkey: bakes the server IP into deploy.conf + CA + EFI"
	@echo "  sudo ./scripts/deploy/flash-usb.sh /dev/sdb  # flash the https CA-baked EFI setup.sh built"
	@echo "  make test"