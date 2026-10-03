# Hosting partyOS - Production Setup Guide

This is the operator guide: how to go from a fresh clone to a booting LAN. The whole
flow is three commands plus a USB stick:

```
./scripts/deploy/setup.sh             # bake YOUR server IP into deploy.conf + the CA + the iPXE EFI
sudo ./scripts/deploy/flash-usb.sh /dev/sdX  # flash a USB stick (erases it)
make servers                          # start serving the boot image + blobs
```

Then boot a client from the stick.

## The one idea

partyOS clients trust a private CA and connect to your server by name or IP over HTTPS. So
your server IP/hostname must end up in three places, and `setup.sh` threads one
operator input into all three:

1. **deploy.conf** - the PXE/blob/mirror/irc addresses (the kernel cmdline is rendered
   from this).
2. **The TLS leaf cert SAN** - so the client's HTTPS check (host-vs-cert) passes.
3. **The iPXE EFI** - the embedded autoboot script baked into the EFI chains to
   `https://<your-ip>:8443/...`, and the private CA is compiled in so the chain validates.

Everything else (kernel/initrd/squashfs URLs) reaches clients via the rendered
cmdline, so it is IP-independent. You set the IP once; `setup.sh` does the rest.

## Prerequisites

You need a Linux or macOS host with:

- **Docker** (daemon running). The iPXE EFI and the boot image are built in
  `linux/amd64` containers. On an arm64 Mac, Docker runs the amd64 containers under
  emulation - that is expected and supported (the builds do not execute x86 on the
  host, they run inside the container).
- **openssl 3.3+** - `setup.sh`/`gen-ca.sh` need `openssl x509 -not_before` to backdate
  the certs (party machines often boot with a wrong RTC; a backdated `notBefore`
  avoids "cert not yet valid" TLS errors).
- **exfatprogs** (`mkfs.exfat`) - `create_usb.sh` formats the cross-OS PARTYDATA
  partition with it.
- A **USB stick** (it becomes the boot + data stick - one stick does both).
- Your **server IP** (or a LAN hostname). A static address is best for a party LAN.

### Per-OS install

| | Docker | openssl 3.3+ | exfatprogs |
|---|---|---|---|
| **Debian/Ubuntu** | `apt install docker.io && systemctl start docker` | `apt install openssl` (trixie+ ships 3.3+) | `apt install exfatprogs` |
| **Arch** | `pacman -S docker && systemctl start docker` | `pacman -S openssl` (rolling, already 3.3+) | `pacman -S exfatprogs` |
| **macOS** | `brew install --cask docker` then launch Docker Desktop | `brew install openssl@3` | `brew install exfatprogs` |

`setup.sh` checks all three up front and tells you exactly what is missing.

## Quick start

```bash
git clone <repo> partyOS && cd partyOS

# 1. Turnkey setup. Asks for the server address (default: the DNS name partyos.lan).
./scripts/deploy/setup.sh

# 2. Flash a USB stick. Warning: this erases the device.
sudo ./scripts/deploy/flash-usb.sh /dev/sdX

# 3. Start serving.
make servers

# 4. Boot a client PC from the stick. It auto-chains to your server over HTTPS.
```

## Step by step

### 1. `setup.sh` - bake in your server IP

```bash
./scripts/deploy/setup.sh
```

It will:

1. Check prerequisites (Docker, openssl 3.3+, exfatprogs) and stop if any are missing.
2. Prompt for the server address (press Enter to accept the DNS name `partyos.lan`,
   or type an IP), plus a party name (default `partyOS LAN`). See
   [Server DNS name](#server-dns-name) for the DNS record that the name needs.
3. Write `deploy.conf` with your address (PXE/blob/mirror default to the same box; IRC gets
   `:6667`).
4. Render the iPXE embed (`build/embed-https.ipxe`) with `https://<your-ip>:8443`.
5. Generate the private CA + a leaf cert whose SAN carries your address (for a DNS name,
   also this host's LAN IP). The CA is reused on
   re-runs; only `--fresh` wipes and rotates it.
6. Render `boot/partyos.ipxe` from `deploy.conf`.
7. Build the boot image + initramfs (Docker, several minutes).
8. Build the iPXE EFI with your embed + CA baked in (`build/ipxe-custom-https.efi`).
9. Verify the served initramfs and the EFI embed the current CA.

Useful flags:

- `--server-name=HOST[:PORT]` - set the address (DNS name or IP) non-interactively (no
  port -> `:8080`). `--server-ip=` is the old name of this flag.
- `--party-name=NAME` - the party name (header comment in `deploy.conf`).
- `--blob-servers=CSV` - dedicated blob hosts (default: the same box as PXE).
- `--non-interactive` - no prompts; good for scripted runs. The server name comes from
  the order in [Set the server name](#set-the-server-name).
- `--skip-build` - skip the heavy image+initramfs build, but still build the EFI.
- `--dry-run` - print what it would write/build and touch nothing.
- `--fresh` (a.k.a. `--clean`) - wipe the CA/certs/generated config/artifacts and rebuild
  everything from scratch (= rotate the CA). Re-pins all clients; you must re-flash every
  stick. See [Regenerating / rotating certs](#regenerating--rotating-certs).

`setup.sh` is idempotent - re-run it any time to change the IP. It never flashes a USB
and never starts servers; those are explicit steps below.

### Set the server name

The server name (a DNS name or an IP) is one value. To set it, run this command on the
build host:

```bash
make server-name SERVER_NAME=partyos.lan      # or an IP, e.g. SERVER_NAME=<server-ip>
```

This runs `setup.sh --non-interactive --skip-build --server-name=<name>`. It does these
steps:

1. It writes `PXE_SERVER` (and the blob, mirror and IRC servers) to `deploy.conf`.
2. It signs a new server leaf cert with the name in its SAN. It keeps the same CA.
3. It renders `boot/partyos.ipxe` from `deploy.conf`.
4. It rebuilds `build/ipxe-custom-https.efi` with the name in the embedded `chain` URL.
5. It checks that the EFI has the current CA and the name from `deploy.conf`.

Then flash the sticks with the new EFI, copy `server/tls/` to the server, and restart the
servers. No other file holds the name. If you run `setup.sh` without a name, it uses
`--server-name=`, then the `SERVER_NAME` env, then `PXE_SERVER` from `deploy.conf`, then
`partyos.lan`. If you edit `PXE_SERVER` by hand, run `make server-name` again, or the
sticks keep the old name. `make verify-ipxe-efi` fails when the EFI and `deploy.conf`
do not agree.

If the server is a DNS name, `setup.sh` also puts the IP of the build host in the SAN.
If you build on a different host than the server, add the server IP to the SAN with
the `SANS` env: `SANS=<server-ip> make server-name SERVER_NAME=partyos.lan`.

### Server DNS name

Clients find the server by the DNS name `partyos.lan` by default. `PXE_SERVER` in
`deploy.conf` is the one value, and everything else derives from it: the iPXE embed in
the stick EFI, the kernel cmdline, the tracker URL in the torrents, and the portal,
mirror and blob URLs. If the server IP changes, change the DNS record. You do not
re-flash the sticks. An IP in `PXE_SERVER` still works.

The name resolves in three places:

1. iPXE on the stick. It uses the DNS server from its DHCP lease (the iPXE build keeps
   the default `DNS_RESOLVER`).
2. The initramfs. iPXE passes the DNS server of its lease as `partyos_dns=` on the
   kernel cmdline, and the `partyos_netwait` hook writes it to `/etc/resolv.conf`. This
   needs an initramfs built with that hook change.
3. The running OS. systemd-networkd gets DNS from DHCP.

The LAN needs:

- a DHCP server that hands out a DNS server (DHCP option 6), and
- that DNS server must resolve `partyos.lan` to the server IP.

Clients use the DNS server that the LAN DHCP hands out. partyOS does not bake in a
DNS server, and it does not need DNS or DHCP from the party server.

The record must resolve at boot time, because the stick boot loader chains by name
before the kernel loads. The venue send-list is in docs/PREPARE-LAN.md.

In general, do one of these before the clients boot:

1. Add an A record `partyos.lan -> <server IP>` to the venue DNS.
2. Or set the server IP with `make server-name SERVER_NAME=<server IP>` and re-flash the
   sticks.

If you cannot do either, the clients cannot find the server.

If you run your own dnsmasq for DHCP and DNS on a test network, this is an example
config. Stop it on a network where another DHCP server runs. DNS must be on
(no `port=0`):

```
interface=eth0
bind-dynamic
dhcp-range=<pool-start>,<pool-end>,<netmask>,12h
dhcp-option=3
dhcp-option=6,<server-ip>
address=/<server-name>/<server-ip>
```

Use `bind-dynamic`, not `bind-interfaces`. If eth0 has no link at boot,
NetworkManager does not add its addresses. With `bind-interfaces`,
dnsmasq then fails with "unknown interface eth0" and stays failed. With
`bind-dynamic`, dnsmasq starts without the addresses and binds them when they
appear.

Also add a drop-in, so that systemd restarts dnsmasq after any other start
failure. Put it in `/etc/systemd/system/dnsmasq.service.d/partyos-lab.conf`:

```
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=5
```

Then run `sudo systemctl daemon-reload`. Do not put a backup copy of the
dnsmasq config in `/etc/dnsmasq.d/`. dnsmasq reads all files in that directory.

The server itself must also resolve the name, because `run-servers.sh` resolves it to
find the local roles. If the server does not use its own dnsmasq for DNS, add
`<server IP> <server name>` to its `/etc/hosts`.

### 2. `flash-usb.sh` - flash a stick

```bash
sudo ./scripts/deploy/flash-usb.sh /dev/sdX
```

Warning: this erases the device. It lays down the partyOS stick: an ESP with the iPXE EFI
(`build/ipxe-custom-https.efi`, the one `setup.sh` built), an exFAT `PARTYDATA`
cross-OS share, and an ext4 `PARTYOSHOME` for the player's home + blob cache. These are
the labels of the venue sticks. If the EFI is missing it tells you to run `setup.sh` first.

The client finds the partitions by label. `USB_HOME_LABELS` and `USB_SHARE_LABELS` in
`deploy.conf` are ordered lists: the first label that is on a partition wins. The
defaults are `PARTYOSHOME,LANPARTY_HOME` and `PARTYDATA,PARTYSHARE`, so the venue sticks
and the legacy sticks (`LANPARTY_HOME`, `PARTYSHARE`) both work. If a stick has both,
the venue label wins. `render.sh` passes the lists on the kernel cmdline
(`usb_home_labels=`, `usb_share_labels=`). If a key is empty, the client uses the same
defaults, baked into the image (`/usr/local/lib/partyos-usb-labels.sh`). A new venue
stick has an empty home partition (only `lost+found`). On the first boot the client
creates the layout, seeds `home/` and starts the blob cache there.

`flash-usb.sh` is a thin wrapper over `scripts/create_usb.sh` that defaults to the https
production EFI so you never pick the wrong one. The 2nd positional is an explicit
EFI-path override only (e.g. to flash the plain-http EFI). The server IP is not passed
here - it is already baked into the EFI. `FORCE=1` skips the erase confirm.

### 3. `make servers` - serve

```bash
make servers
```

Starts the server roles described in `deploy.conf`: the netboot/PXE listener plus one
per distinct blob server. A single-box `deploy.conf` collapses to one process. It serves
HTTPS-only by default (re-enable plaintext with `PARTYOS_HTTP_ENABLE=1 make servers` for
recovery). It refuses to start on a stale/no-CA initramfs - run `make boot-artifacts` if
it complains.

#### Run the servers as a service

`make servers` runs in the foreground and dies with the SSH session. For a real
event, install the systemd unit instead. Run this on the party server, as root:

```bash
sudo scripts/deploy/install-server-service.sh
# or, with other values:
sudo scripts/deploy/install-server-service.sh --user user --repo /home/user/partyos
sudo make install-server-service            # the same thing through the Makefile
```

The defaults are the account `user` and the checkout at `/home/user/partyos`.
Use `--user` and `--repo` to change them. The installer renders
`server/systemd/partyos-servers.service.tmpl`, writes
`/etc/systemd/system/partyos-servers.service`, reloads systemd and enables the
unit. `--dry-run` prints the rendered unit and writes nothing. `--no-enable`
installs the file only.

The unit sets `Restart=always`, so a crashed listener comes back, and it starts
at boot. Operate it with:

```bash
systemctl start partyos-servers
systemctl status partyos-servers
journalctl -u partyos-servers -f
```

The unit runs the same `run-servers.sh`, so the boot-artifact guard still
applies: a stale initramfs fails the start. Fix it with `make boot-artifacts`.

### 4. Boot a client

Boot the target PC from the stick. The embedded iPXE autoboots, chains
`https://<your-ip>:8443/boot/partyos.ipxe`, and the whole boot chain runs over TLS
validated against your CA. Headless clients have no keyboard, so the embed reboots and
retries on any failure rather than dropping to a shell.

## Register a player / flash a stick by name

A blank stick boots as the default `gamer` on DHCP. To give a stick a stable identity
(a login name + hostname that survive reprovisioning), register the player in the config
store first, then flash by name. The config store is the operator's source of truth, so
a re-flash always restores the same identity. Clients use DHCP by default. Full format + IP scheme: [../users/README.md](../users/README.md).

```bash
# 1. Register the player - writes users/<name>/config (+ an empty users/<name>/home/
#    skeleton). Networking defaults to DHCP (no STATIC_IP).
scripts/deploy/gen-user-config.sh alice
#    -> users/alice/config  (USERNAME=alice  HOSTNAME=alice-pc  NICK=alice)

# 2. (optional) drop skeleton dotfiles into users/alice/home/ to pre-seed the desktop.

# 3. Flash their stick by name.
sudo scripts/deploy/flash-usb.sh /dev/sdX --user alice
```

- **`gen-user-config.sh <name>`** writes no static IP: the client uses DHCP and the LAN
  DHCP server assigns the address (use a DHCP reservation for a fixed address). A
  client-side static IP is an opt-in: `--ip A.B.C.D[/p]` or `--slot N` (slot 1 =
  `.200`), and the tool refuses a collision with another `users/*/config`. Set
  `--nick`/`--hostname`; `--force` rewrites an existing entry (keeps its `home/`). The
  `--slot` range is `PARTYOS_IP_*` env-overridable for a different LAN.
- **`flash-usb.sh /dev/sdX --user <name>`** flashes the stick as usual, then mounts the
  fresh `PARTYOSHOME` home partition and writes the player's identity onto it: `USERNAME`/`HOSTNAME`
  into `.partyos` (read by `partyos-identity`) and `NICK`/`STATIC_IP`/`GATEWAY`/`DNS`
  (plus optional `FULLNAME`/`EMAIL`/`IRC_SERVER`) into `user.conf` (read by
  `partyos-userconf` + `partyos-staticip`), and rsyncs `users/<name>/home/` into the
  stick's `home/`. `STATIC_IP` lives in `user.conf`, not `.partyos` - that split matches
  what the OS actually reads. On a lookup miss it warns and stops unless you pass
  `--blank` (flash a blank, identity-less stick anyway). Everything under `users/` except
  `README.md` and `example/` is git-ignored (per-deployment operator data).

> **Note:** `scripts/register-stick.sh` provisions one stick from command-line flags, with no
> config store and the plain-HTTP EFI. Prefer `gen-user-config.sh` + `flash-usb.sh --user`.

## Contributor blobs (add games at event time)

A trusted contributor can package a game/app into a partyOS blob themselves and
hand you a deliverable to vouch into your catalog - without repo or catalog
access, and without it being baked into the shipped image. You accept it with
`scripts/blob/add-blob.sh` (host the bytes yourself, or point the catalog at the
contributor's HTTP self-host). The operator's catalog sha256 is the integrity
trust root, so the bytes can come from anywhere; self-host web-seeds are
advertised over HTTP. See
[CREATING-BLOBS.md → For trusted contributors](CREATING-BLOBS.md#for-trusted-contributors-no-repocatalog-access-needed).

## Add a game mid-party (no downtime)

Use `scripts/deploy/publish-blob.sh` on the party server. Nothing restarts. The full
procedure is in [BLOB-GUIDE.md](BLOB-GUIDE.md).

## Add packages to the LAN package mirror

Players install packages that are not in the image with `pacman -S <name>`. The
packages come from the `[partyos]` repo on the party server
(`server/lanmirror`, served at `https://<server>:8443/server/lanmirror`). The
mirror holds the image packages, the store dependencies and the curated list in
`scripts/build/mirror-curated.txt` (terminal tools, editors, network tools,
media, emulators, games and runtimes, about 5.3 GB). Do these steps on a
machine with docker and internet, not at the party:

1. Add the package names to `scripts/build/mirror-curated.txt`. Use only
   packages from core or extra in the pinned 2025/09/01 snapshot.
2. Download the packages and their dependencies, and rebuild `partyos.db`:

   ```
   bash scripts/build/mirror-pkgs.sh $(grep -v '^#' scripts/build/mirror-curated.txt)
   ```

   To add one package, give only its name: `bash scripts/build/mirror-pkgs.sh iperf3`.
3. Read the output. `[mirror] N newly-added package(s) quarantined` names the
   packages that Arch signed with a revoked key. The script moves them to
   `server/lanmirror/.revoked-signer/`. If a package needs one of them, add it
   to `[partyos-local]`:

   ```
   bash scripts/build/mirror-local-pkgs.sh server/lanmirror/.revoked-signer/<file>.pkg.tar.zst
   ```

4. Check the free space on the server first. Keep at least 5 GB free for blob
   publishes during the party.
5. Copy the new packages to the server. Copy the repo databases last, so that
   a client never sees a package in the database before the file is there:

   ```
   rsync -a --partial-dir=.rsync-partial --delay-updates --exclude='partyos.db*' \
     --exclude='partyos.files*' --exclude='.revoked-signer' \
     server/lanmirror/ <server>:<repo>/server/lanmirror/
   rsync -a server/lanmirror-local/ <server>:<repo>/server/lanmirror-local/
   rsync -a server/lanmirror/partyos.db* server/lanmirror/partyos.files* \
     <server>:<repo>/server/lanmirror/
   ```

No restart is necessary. The files are static. A client gets the new packages
after `pacman -Sy`.

The verify step uses the latest `archlinux-keyring`, the same keyring that the
image build puts in the client. `make test-mirror-real` runs the script into a
scratch mirror and checks the verify step (docker and internet are necessary).

## Multi-box (optional)

For a bigger party you can split roles across machines:

- Set `BLOB_SERVERS` to a comma-separated, ordered failover list of `host:port` (or pass
  `--blob-servers=` to `setup.sh`). Clients try each in order; the first that answers
  wins, so a dead blob server does not stop the party.
- Set `MIRROR_SERVER` / `IRC_SERVER` to different addresses in `deploy.conf` as needed.
- Run `scripts/deploy/run-servers.sh` (or `make servers`) on each host - it binds only
  the `ip:port` listeners whose IP is local to that host and skips the rest.

After editing `deploy.conf` by hand, re-run `scripts/deploy/render.sh` to regenerate
`boot/partyos.ipxe`.

## Regenerating / rotating certs

Both operations use the same command, `setup.sh`. There is no separate rotate-ca
script: CA rotation is just `setup.sh --fresh`.

- **Change the server IP / add a SAN** - re-run `setup.sh` (e.g.
  `make server-name SERVER_NAME=10.0.0.5`). This reuses the CA but re-signs the
  leaf and rebuilds the EFI with the new IP baked in. Because the EFI changed, re-flash
  every stick.
- **Rotate the CA itself** - re-run `setup.sh --fresh` (a.k.a. `--clean`). Use this only if
  the CA key is compromised/lost or you want a fresh trust root. It wipes the CA, leaf
  certs, generated `deploy.conf`/embed, and the built EFI, then mints a new CA, re-renders,
  and rebuilds the EFI. It warns loudly and (interactively) asks you to type `ROTATE`
  first. Every stick already flashed trusts the old CA and fails the TLS boot chain,
  so re-flash every stick. The `make verify-ipxe-efi` guard enforces this - a
  stick whose EFI does not embed the current CA is rejected.

Either way: a new IP or a rotated CA changes the EFI, so re-flash every stick afterwards.
`setup.sh` rebuilds the EFI for you and prints the re-flash reminder.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Security notes

- **`ca/partyos-ca.key` is the trust root.** It signs the leaf the server presents and is
  the private half of the CA compiled into every EFI. It is gitignored and chmod 600.
  Back it up somewhere safe and offline. If you lose it, you can only rotate to a new CA
  (which forces re-flashing every stick).
- The pinned CA (`ca/partyos-ca.crt`, public) is compiled into the iPXE EFI, bundled into
  the initramfs, and added to the rootfs trust store. Clients pin trust to it and do not
  consult the system/public trust store.
- The server leaf key (`server/tls/partyos.key`) is also a secret (gitignored, chmod 600).
- Rotating the CA invalidates every flashed stick - treat it as an all-clients operation.
- **Never copy `ca/partyos-ca.crt` into a checkout by hand.** The certificate is not
  tracked in git for this reason. If a certificate is present without its key,
  `gen-ca.sh` refuses to run, because a new CA would invalidate every flashed stick. To use a
  CA signed by someone else, install it with its leaf:
  `scripts/deploy/install-certs.sh --ca <ca.crt> --cert <leaf.crt> --key <leaf.key>`.
- **`CA_FINGERPRINT` in `deploy.conf` records the anchor.** `gen-ca.sh` and
  `install-certs.sh` write it. `check-ipxe-efi.sh` compares the certificate on disk
  against it and fails when they differ, so a swapped CA is caught before the build.
  Read the current value with
  `openssl x509 -in ca/partyos-ca.crt -noout -fingerprint -sha256`.
