# users/ - per-player provisioning config store

One subfolder per player. It records who a stick belongs to (login, hostname, nick
and an optional static IP), so a reflash by name restores the same identity.

```
users/
  example/        committed template (this is the only tracked player folder)
    config        KEY=value identity file (see below)
    home/         skeleton seeded into the stick's home at flash time
  <name>/         one per real player - GIT-IGNORED (per-deployment operator data)
    config
    home/
```

Everything under `users/` is git-ignored EXCEPT `users/README.md` and `users/example/`.
Real player names and IPs are per-deployment and never committed.

## config format

Plain `KEY=value` lines; `#` comments and blank lines ignored; last key wins;
surrounding whitespace trimmed. The file is PARSED, never sourced (a hostile line
never executes). `flash-usb.sh --user <name>` reads it and writes the keys onto the
stick's TWO runtime config files at the LANPARTY_HOME root, because the OS reads them
from different services:

| key(s)                          | written to | read by                          |
|---------------------------------|------------|----------------------------------|
| `USERNAME`, `HOSTNAME`          | `.partyos` | `partyos-identity`               |
| `NICK`, `STATIC_IP`, `GATEWAY`, `DNS` | `user.conf` | `partyos-userconf` + `partyos-staticip` |
| `FULLNAME`, `EMAIL`, `IRC_SERVER` (optional) | `user.conf` | `partyos-userconf` |

`STATIC_IP` goes in `user.conf`, not `.partyos`.

## Networking: DHCP by default

- Clients use DHCP. `gen-user-config.sh` writes no `STATIC_IP`. The LAN DHCP server
  assigns the address. If a player needs a fixed address, add a reservation on the
  DHCP server, not on the stick.
- `STATIC_IP` is an opt-in only. `gen-user-config.sh <name> --ip A.B.C.D` or
  `--slot N` pins a client-side static IP (slot 1 = .200, slot 2 = .201, ...). The
  tool scans every `users/*/config` and refuses a collision.
- The base/range for `--slot` are constants at the top of `gen-user-config.sh`,
  override-able via `PARTYOS_IP_PREFIX` / `PARTYOS_IP_LO` / `PARTYOS_IP_HI`.

## typical operator flow

```bash
# 1. register a player (DHCP, no static IP)
scripts/deploy/gen-user-config.sh alice
#    -> users/alice/config  (USERNAME=alice  HOSTNAME=alice-pc  NICK=alice)

# 2. (optional) drop skeleton dotfiles into users/alice/home/

# 3. flash their stick BY NAME (writes .partyos + user.conf, seeds home)
sudo scripts/deploy/flash-usb.sh /dev/sdX --user alice
```
