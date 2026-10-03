# Prepare for a LAN event

This is a decision checklist, not an inventory. Every row below is a choice a human
must make for one specific event. Get one wrong and the event breaks or degrades.

Everything the build derives by itself is left out. The appendix lists the other
classes of setting and where each lives in the repo.

partyOS does not run DHCP or DNS. The LAN must provide them.

## Start here: the wizard

`scripts/deploy/prepare-event.sh` is the documented way to prepare an event. It runs a
pre-flight, asks five questions, prints a summary, takes ONE confirmation, and then
writes.

Start the Docker daemon before you run it. The apply step calls `setup.sh`, which builds
the iPXE EFI in a container. The pre-flight checks Docker and openssl 3.3+ before the
first question, so a missing prerequisite stops the wizard before it writes anything.

```sh
scripts/deploy/prepare-event.sh          # or: make prepare-event
```

The five questions, each with a default that Enter accepts:

| # | Question | Default | What it writes |
|---|---|---|---|
| 1 | Server address (DNS name[:port]) | the current PXE_SERVER, else partyos.lan:8080 | runs setup.sh: deploy.conf, the cert SAN, the embed, the EFI |
| 2 | Blob server address(es) | the current BLOB_SERVERS, else the server | BLOB_SERVERS and BLOB_SERVER |
| 3 | Package mirror address | the current MIRROR_SERVER, else the server | MIRROR_SERVER |
| 4 | Chat/IRC server address | the current IRC_SERVER, else the server host on port 6667 | IRC_SERVER |
| 5 | Party name | the current PARTY_NAME, else Internyet | PARTY_NAME |

The wizard registers no players. Each stick carries the player identity in
`internyet.env` on its shared exFAT partition (INTERNYET_USER_NAME,
INTERNYET_ALIAS, INTERNYET_DEFAULT_FQDN). If your venue provisions the sticks, it writes this file.
`gen-user-config.sh` and `users/` stay for self-provisioned events only.

The wizard also shows the game roster with the payload size and lets you drop
titles, shows the stick-size arithmetic, and offers a CA rotation only when a CA
already exists. It prints the remaining commands in order at the end.

The wizard does not ask about these defaults: every stick is provisioned fresh,
clients are DHCP only, the keyboard is SE and the timezone is Europe/Stockholm,
the venue supplies the DNS name and record, and the client VLAN has no internet.

Replay it without a TTY with `--answers FILE`, where FILE holds the same
`KEY=value` answers (see `prepare-event.sh --help`).

The tables below are the reference behind those questions, plus every decision
the wizard does not make for you.

Column meanings:

- **Decision**: what you must choose.
- **Default**: what the repo holds today.
- **How to set**: the command or the file to edit.
- **When**: build time (a change needs a rebuild), deploy time (server only), or
  boot time (applied by the client each boot).

---

## Decide these first

Seven decisions. Everything else follows from them.

1. **Server address**. A DNS name or an IP, plus the port, for example
   `<server-name>:8080` (deploy.conf). It is baked into the iPXE EFI on every
   stick. A change after flashing forces a re-flash of every stick.
2. **The server IP at the venue**. Give the server a static address. Put it in the
   TLS SAN. Get the netmask and the gateway from the venue (see C1).
3. **The CA**. If the venue supplies the CA and the leaf, install them with
   `install-certs.sh`. Otherwise, `setup.sh --fresh` makes a new CA and
   invalidates every stick already flashed. Decide before mass-flashing, never after.
4. **The game and app roster**. `server/games/catalog.v2.json`, 28 rows today. It
   drives the server disk, the stick size and the icons baked into the image.
5. **The stick count**. One stick per attendee, plus spares. If your venue provisions
   the sticks, it writes the player identity to `internyet.env` on each one.
6. **Static IPs or plain DHCP**. Default is DHCP for all. Static needs a range
   outside the venue pool, and a DNS value per client.
7. **The party name and the event content**. The name, the portal schedule and
   rules, and the boot announcement.

Freeze order: CA, then server name, then image build, then boot artifacts, then
render, then flash sticks, then pre-seed blob caches.

---

## A) USB sticks and the PXE chain

Group A is one address plus two physical choices.

| Decision | Default | How to set | When |
|---|---|---|---|
| The server address (PXE_SERVER) | `<server-name>:8080` | `make server-name SERVER_NAME=<name-or-ip>` | build |
| The TLS leaf and its CA | SAN: DNS:<server-name>, DNS:*.<server-name>, IP:<server-ip> | `scripts/deploy/install-certs.sh --ca --cert --key`, then `make server-name` | build |
| Stick size and the share (PARTYDATA) size | 512 MB ESP, 4096 MB share, home takes the rest | `--esp-mb` / `--share-mb` to create_usb.sh; buy 64 GB or larger | deploy |
| Stick partition labels | home `PARTYOSHOME,LANPARTY_HOME`, share `PARTYDATA,PARTYSHARE` (venue label first, legacy label second) | `USB_HOME_LABELS` / `USB_SHARE_LABELS` in deploy.conf, then render | build |

`make server-name` derives the rest of group A for you, in one run: it rewrites
`deploy.conf` (PXE, blob, mirror and IRC addresses), re-signs the TLS leaf with the
name in the SAN, re-renders the boot script `boot/partyos.ipxe` and the portal, and
rebuilds the iPXE EFI with the new chain URL embedded. You never edit the EFI embed,
the chain URL, the HTTPS port map (+363, 8080 to 8443) or the cert by hand.

Warning: `make ipxe` alone bakes a development embed that hardcodes `partyos.lan`.
Always build through `make server-name` or `setup.sh`.

Warning: `flash-usb.sh --user` always erases the stick. For a returning player's
stick use `register-stick.sh --no-format`.

Stick sizing: a 16 GB stick leaves about 11 GB of home after the ESP and the 4 GB
share. The 8 GB cache reserve then leaves about 3 GB of blob cache, and the largest
blob is 3.1 GB. Buy 64 GB or larger.

---

## B) Services, blobs and disk

The portal address is not a separate decision today. The wizard asks for the blob,
mirror and chat addresses; `make server-name` on its own writes them from the
server address: `BLOB_SERVERS` and
`MIRROR_SERVER` take the PXE host and port, `IRC_SERVER` takes the same host on port
6667, the portal is the PXE host plus `PORTAL_PATH`, and the torrent announce URL is
the first blob host on port 6969. The render also omits the blob and mirror kernel
parameters while they equal the PXE server. Set a row below only to break that
default apart.

| Decision | Default | How to set | When |
|---|---|---|---|
| Run blobs on other hosts (BLOB_SERVERS) | = the PXE server | `BLOB_SERVERS=h1:8080,h2:8080` in deploy.conf, then `scripts/deploy/render.sh` | deploy |
| Run the pacman mirror on another host (MIRROR_SERVER) | = the PXE server | question 3 of `prepare-event.sh`, or edit deploy.conf, then render.sh | deploy |
| Run IRC on another host or port (IRC_SERVER) | = the PXE host, port 6667 | question 4 of `prepare-event.sh`, or edit deploy.conf, then render.sh | deploy |
| The game and app roster (catalog.v2.json) | 28 rows: 17 blob, 11 package | edit the JSON, then `bash scripts/build/build-game-blobs.sh` | build |
| Which commercial titles ship | 3 commercial titles | pull the rows | build |
| Hidden rows and their unlock codes | for example, wc3, flatout2 and haloce share the code EXAMPLE1 | set `hidden` and `unlock_code` per row | deploy |
| Server disk for the served payload | about 22 GB: 15 GB blobs, 4.1 GB images, 1.8 GB mirror | prune catalog rows, or give the server a bigger disk | deploy |
| USB blob-cache reserve (BLOB_CACHE_RESERVE_GB) | 8 | edit deploy.conf, then render.sh | deploy |
| Per-client seed upload cap (BLOB_SEED_UP_LIMIT) | 0, unlimited | set e.g. `20M` in deploy.conf, then render.sh | deploy |

Clients must reach each other on TCP 6881-6999.

Warning: game icons are baked into the image, but the catalog is served. A title
added after the image build shows a generic icon. Freeze the roster before
`make image`.

---

## C) Venue, players and logistics

### C1. What to ask the venue for

The venue runs DHCP and DNS. Send this list to their network contact. Each
item is a thing you must get from them, not a thing you can set.

1. **The DNS records**: `<server-name>` A `<server-ip>`, and the chat server name if
   the venue hosts chat. `<server-name>` must resolve at boot time, because the stick
   boot loader chains by name and the tracker name is in every torrent.
2. **The netmask and the gateway** of the client network, and of the server
   address.
3. **One subnet or routed**: are the server address and the client pool in one subnet
   (a /16 or a /23, no routing), or in separate /24s with routing between them?
4. **DHCP option 121** (classless static routes): does their DHCP send it? If it
   does, clients ignore the router option (RFC 3442). The initramfs adds the
   option 121 routes (the partyos_routes hook).
5. **Reachability**: clients reach the server on TCP 8443, 6969 and 6881-6999.
6. **No client isolation**: clients reach each other on TCP 6881-6999. Blobs are
   P2P only. Isolation means no games.
7. **Chat**: if the venue hosts chat, which port does it use, and is it plain or
   TLS? `IRC_SERVER` in deploy.conf must match.
8. **DHCP option 6** hands out their resolver, and that resolver has
   the records above.
9. **No DHCP option 66 or 67**. We boot from the stick EFI.
10. **Pool size and lease time**: each machine takes two leases, iPXE and the
    running OS.
11. **PortFast or edge-port on the player ports**: spanning tree drops frames for
    15 to 30 seconds after link-up.
12. **A wired port per seat and a gigabit server port**: the image has no wifi
    firmware.
13. **Internet on the client network: yes or no**. The design assumes an offline LAN.
14. **Power circuits and outlets per table**. Keep the server off a circuit
    players can trip.
15. **A load-in window**, early enough to boot one test client before players arrive.

Also confirm on the server:

- The static server address with the venue netmask and gateway.
- Your own DHCP and DNS server, if any, is stopped and disabled. No second DHCP
  server runs on the venue LAN.
- `partyos-servers.service` runs (systemd, Restart=always).

Full port list for the firewall request: TCP 8443 (the whole boot chain and every
runtime fetch), TCP 6969 (tracker), TCP 6881-6889 (server seeder), TCP 6881-6999
(client to client), TCP 8080 (plaintext recovery only, off by default), TCP 6800
(aria2 RPC, loopback). UDP 53, 67, 68 and 5353. Chat runs on the venue server, on
the port they confirm, if the venue hosts chat.

### C2. Per-player provisioning

| Decision | Default | How to set | When |
|---|---|---|---|
| The player identity per stick | `internyet.env` on the stick | if your venue provisions sticks, it writes the file. For self-provisioned events only: `scripts/deploy/gen-user-config.sh <username> --nick <nick>`. The wizard does not register players. | deploy |
| Static IP or DHCP per player | DHCP for all | `--ip A.B.C.D[/p]` or `--slot N` | deploy |
| The static range, if used (PARTYOS_IP_PREFIX / _LO / _HI) | unset | export them before gen-user-config.sh; stay outside the venue pool | deploy |
| GATEWAY and DNS for static clients | unset | hand-add to users/<name>/config, or `register-stick.sh --gateway --dns` | deploy |
| Keyboard layout | se | add `KEYBOARD=` to the stick user.conf, or let the first-run wizard ask | boot |
| Timezone | Europe/Stockholm | add `TIMEZONE=` to the stick user.conf | boot |
| Pre-seed the account password | none; the wizard forces one at first boot | `register-stick.sh --password` | deploy |
| Returning sticks: keep or erase the home | flash-usb.sh always erases | `register-stick.sh --no-format` to keep | deploy |

Warning: `gen-user-config.sh` writes only USERNAME, HOSTNAME, NICK and an optional
STATIC_IP. GATEWAY, DNS, FULLNAME, EMAIL, IRC_SERVER, KEYBOARD, TIMEZONE and
MUMBLE_SERVER are hand-added, or set by `register-stick.sh`.

Warning: a static client with no DNS value cannot resolve the server name. If
PXE_SERVER is a DNS name, every static client must carry a DNS value.

Warning: the stick mount is gated on USERNAME. A player who boots someone else's
stick gets no home, silently. Brief the door desk.

### C3. Logistics and event content

| Decision | Default | How to set | When |
|---|---|---|---|
| The party name | Internyet | question 5 of `prepare-event.sh`, or the `PARTY_NAME=` line in deploy.conf | deploy |
| Portal content: schedule, rules, FAQ | the repo default FAQ text | edit `portal/index.html.tmpl`, then render.sh | deploy |
| The boot announcement and MOTD | GLHF-LANPARTY | edit `server/boot-config.sh` | deploy |
| The per-boot operator hook (BOOT_CONFIG_URL) | on, pointed at the main server's `/server/boot-config.sh` | setup.sh sets it; empty the `BOOT_CONFIG_URL=` line in deploy.conf to switch it off | deploy |
| Which box is the server, and how it stays up | a systemd unit with Restart=always | `sudo scripts/deploy/install-server-service.sh` on the server | deploy |
| The server clock | unset | set it before the event; clients take their time from it | deploy |
| The flashing station | the build host may lack mkfs.exfat and sgdisk | nominate a Linux box with exfatprogs, gptfdisk, dosfstools, e2fsprogs | deploy |
| Stick count and spares | no count defined | one per attendee plus blank spares, one model, 64 GB or larger | build |
| The door desk owner and kit | unassigned | name the person; give them the Linux box, the https EFI, users/ and spares | deploy |
| Dedicated game servers | 11 catalog rows want one; none start by themselves | pick the titles, pick a host, start them, publish the addresses | deploy |
| Pre-seed the popular blobs onto sticks | by hand, no tooling | copy blobs and .torrent files after the final render | deploy |

Four more items have no table row because each is one line of policy. Set a calendar
date to freeze the server address, after which flashing starts. Copy `ca/`, `users/`
and `server/games/` to an external disk. Publish the attendee PC spec: UEFI x86_64,
wired ethernet, Secure Boot off, USB boot allowed, and a RAM floor. Decide whether
sticks are kept after the event and whether `server/reports/` is deleted.

---

## Before you flash: the pre-event checks

These are tests, not settings. Run them in the build order below, at the points shown.

- `make test-prod` - the unit gate, 38 targets.
- `make verify-ipxe-efi` - the EFI embeds the current CA and the current chain URL.
  A missing EFI exits 0 with a note. Do not read that skip as a pass.
- `bash scripts/deploy/list-seed-torrents.sh server/games` - every torrent has a blob.
- `make fleet-check` then `make fleet-verify HOST=all` - a real boot on each test machine (see TESTING.md).
- By hand on a booted client: open the store, install one blob from a cold cache,
  launch it, lock the screen, and send one broadcast.
- Test the netboot on every attending machine model you can reach. iPXE does not
  support every NIC, for example the Intel I218-LM.

Full test procedure: `docs/TESTING.md`.

---

## Build order for an event

Run these in order. Do not reorder. Each step depends on the one before it.

### Phase 1: freeze the identity (build host)

```sh
# 1. Check the prerequisites. Docker, openssl 3.3+, exfatprogs.
openssl version
docker info

# 2. If your venue provides certificates, install them. Then nothing is signed
#    locally. Otherwise, skip this step: setup.sh makes a self-minted CA.
scripts/deploy/install-certs.sh --ca <ca.crt> --cert <leaf.crt> --key <leaf.key>

# 3. Run the wizard. It asks the five questions and sets the server name. That
#    rewrites deploy.conf, re-signs the leaf, re-renders the boot script and
#    rebuilds the iPXE EFI. It registers no players.
scripts/deploy/prepare-event.sh

#    The one knob by itself, when you only change the server name:
#    make server-name SERVER_NAME=<server-name>:8080

# 4. Back up the CA now. Back up users/ too if you use it.
cp -a ca users <encrypted external disk>
```

### Phase 2: build the image and the blobs

```sh
# 5. Finalise the game roster in server/games/catalog.v2.json first.
#    Then extract the icons, because they are baked into the image.
bash scripts/build/extract-game-icons.sh

# 6. Build the patched Thunar package.
bash scripts/build/build-thunar-patched.sh

# 7. Build the squashfs image.
FORCE=1 make image

# 8. Build the served kernel and initramfs. make image does NOT do this.
make boot-artifacts

# 9. Build or rebuild the game blobs, then render the catalog.
make gameblobs DIR=server/games
bash scripts/build/build-game-blobs.sh
bash scripts/build/build-game-blobs.sh --check

# 10. Populate the LAN pacman mirror.
bash scripts/build/mirror-pkgs.sh
bash scripts/build/mirror-local-pkgs.sh
```

### Phase 3: edit the event content

```sh
# 11. Write the event content before the render.
#     - portal/index.html.tmpl: schedule, rules, FAQ.
#     - server/boot-config.sh: PARTYOS_ANNOUNCE and PARTYOS_MOTD.
#     - deploy.conf: add a literal PARTY_NAME= line.
#     - deploy.conf: BLOB_CACHE_RESERVE_GB, BLOB_SEED_UP_LIMIT, BOOT_CONFIG_URL.

# 12. Render. This rewrites the boot script, the portal and EVERY blob torrent
#     with the announce URL. Do this BEFORE flashing or pre-seeding.
scripts/deploy/render.sh
```

### Phase 4: verify before flashing

```sh
# 13. Run the unit gate.
make test-prod

# 14. Confirm the EFI embeds the current CA and the current chain URL.
make verify-ipxe-efi

# 15. Confirm every torrent has a backing blob.
bash scripts/deploy/list-seed-torrents.sh server/games
```

### Phase 5: provision the server

```sh
# 16. Copy the payload to the server host. Exclude the CA private key.
#     WARNING: this leaves the server host with a CA certificate and no CA key.
#     Do NOT run setup.sh, gen-ca.sh or make ipxe there. Those belong on the box
#     that holds the key. gen-ca.sh refuses in this state rather than minting a
#     different CA over the certificate, but keep the build on one box anyway.
rsync -a --info=progress2 \
  server/images server/games server/config server/lanmirror server/lanmirror-local \
  ca/partyos-ca.crt server/tls portal boot deploy.conf \
  <server>:~/partyOS/

# 17. On the server: set the static server address with the venue netmask,
#     gateway and DNS. Stop and disable your own DHCP and DNS server, if any.
#     A second DHCP server on the venue LAN breaks the venue DHCP.
#     If you change the network over SSH, connect through another link first.

# 18. On the server: confirm the static address on the wired port, and that
#     /etc/hosts resolves the server name to that address.

# 19. On the server: set the clock. Clients take their time from it.
sudo date -s "<correct UTC time>"

# 20. On the server: install the service and start it. Restart=always, so it
#     survives a dropped SSH session and a crash. Logs go to the journal.
sudo scripts/deploy/install-server-service.sh
sudo systemctl start partyos-servers
journalctl -u partyos-servers -f

# 21. Chat: nothing to start if the venue hosts chat.

# 22. Clear any stale notices.
scripts/deploy/announce.sh --clear
```

### Phase 6: flash the sticks (Linux flashing station)

```sh
# 23. If your venue provisions the event sticks, it writes internyet.env. The
#     wizard registers no players. For a self-provisioned event, register one player like this:
scripts/deploy/gen-user-config.sh <username> --nick <nick>

# 24. Flash one stick per player. The device is ERASED.
sudo scripts/deploy/flash-usb.sh /dev/sdX --user <username>

# 25. Flash the spares blank for walk-ins.
sudo scripts/deploy/flash-usb.sh /dev/sdX --blank

# 26. Copy the CA cert onto the share (PARTYDATA) so players can trust it on their own laptop.
#     create_usb.sh does not do this.

# 27. Optional: pre-seed the popular blobs and their .torrent into
#     .partyos-cache/games on each stick. Do this AFTER step 12, never before.
```

### Phase 7: rehearse

```sh
# 28. Boot each test machine from an event stick.
make fleet-check
make fleet-verify HOST=all

# 29. By hand on a booted client: open the store, confirm the icons are present,
#     install one blob from a cold cache, launch it, lock the screen, and send
#     one broadcast to a fullscreen client.
scripts/deploy/announce.sh "test broadcast" --level info
```

### Recovery at the event

- TLS breaks the boot chain: `PARTYOS_HTTP_ENABLE=1 make servers` re-enables the
  plaintext listener on 8080.
- `make servers` refuses to start on a stale initramfs: run `make boot-artifacts`.
  Use `ALLOW_STALE_INITRAMFS=1` only as a last resort.
- Client behaviour must change with no rebuild: edit `server/boot-config.sh`, or
  push a notice with `scripts/deploy/announce.sh`. The hook is on by default. Confirm
  `BOOT_CONFIG_URL=` in deploy.conf is not empty, then re-run render.sh.
- The tracker or the seeder does not start: the server cannot resolve its own
  BLOB_SERVERS name. Fix `/etc/hosts` and restart.

---

## Appendix: reference, not decisions

The classes of setting that are not decisions, and where each lives in the repo:

- **Derived values.** The chain URL in the EFI embed, the HTTPS port map, the TLS leaf
  and its primary SAN, the rendered `boot/partyos.ipxe`, `portal/index.html`, the blob
  and mirror kernel parameters, and the torrent announce URL. All written by
  `scripts/deploy/setup.sh` and `scripts/deploy/render.sh` from PXE_SERVER.
- **Build knobs that are the same at every event.** The Arch snapshot, the package
  set, the squashfs compression, the locale and firmware slimming, the Chicago95 theme
  pin, the iPXE commit pin. See `scripts/build/build-image.sh`, `phases/*` and
  `scripts/build/build-ipxe.sh`.
- **Baked image behaviour.** Autologin, sudo, masked services, the pacman keyring,
  Plymouth, journald, the home-sync timers and excludes, the idle lock timeouts, the
  screensaver whitelist, desktop names and XFCE defaults. See `phases/*` and
  `files/rootfs/`.
- **Server internals.** The HTTP server docroot and denylist, the tracker constants,
  the aria2 seeder flags, the report directory, the resolver helpers, the escape
  hatches `PARTYOS_HTTP_ENABLE` and `ALLOW_STALE_INITRAMFS`. See
  `scripts/deploy/run-servers.sh`, `server/http_server.py`, `server/bt_tracker.py`.
- **Client network behaviour at boot.** `partyos_dns=`, `netwait=`, `report_url=`, the
  LPD multicast route, the QEMU fallback address. See `boot/partyos.ipxe.prod.tmpl`
  and `files/rootfs/usr/local/bin/`.
- **Blob build internals.** Piece-size tiers, DXVK and WINVER flags, per-blob sha256,
  `extra_pkgs`, the SKIP list. See `scripts/build/`.
- **Test and environment overrides.** FLEET_* variables, `PARTYOS_FLASH_HOME_DIR`,
  OPENSSL paths, OUT and DIR overrides. See `scripts/test/` and each script's header.
