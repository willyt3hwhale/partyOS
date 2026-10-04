# partyOS

PXE booted LAN OS for gaming events.

partyOS boots player PCs from a USB stick over the LAN, straight into RAM. Nothing is installed on the PC's own disk. Each player's home directory lives on their own stick, and games are shared between players over BitTorrent.

## Features

- **Network boot into RAM.** The PC's own disk is never touched.
- **A Windows 95 style desktop.** XFCE with the Chicago95 theme.
- **Your home on your stick.** Settings and saves follow you to the next party.
- **Games shared peer to peer.** Players download games from each other and cache them on their stick.
- **Linux and Windows games.** Windows games run through Proton.

## Quick start

You need a Linux or macOS host with Docker, openssl 3.3+ and exfatprogs, plus a USB stick for each player.

```bash
git clone https://github.com/willyt3hwhale/partyOS.git && cd partyOS
./scripts/deploy/setup.sh                    # set the server address, make the CA and the iPXE EFI
sudo ./scripts/deploy/flash-usb.sh /dev/sdX  # flash a stick (this erases it)
make servers                                 # start serving
```

Then boot a PC from the stick.
