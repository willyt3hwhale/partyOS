# Blob guide for live use

This guide is for the operator at the party. Use it to build a game or app
blob and to make it live on the running party server. Nothing restarts, and
players do not reboot.

- `<server>` is the party server name, `<user>` is the account that runs the
  servers, and `<repo>` is the checkout on the server.
- `<name>` is the blob name, in lower case `a-z` and `0-9`, for
  example `xonotic`. The file is always `<name>.squashfs`.
- Blobs go to players over BitTorrent only, never over HTTP. The torrent gets
  the tracker `http://<server>:6969/announce` from `deploy.conf`.

## Before the party: build and download

The party LAN has no internet. Do these steps while you have internet:

1. Build every Linux blob on a build host with internet. `build-app-blob.sh` gets its packages
   from archive.archlinux.org and the AUR. It cannot use the server LAN mirror
   (`server/lanmirror`), which only feeds client package installs.
2. Build every Windows blob on an x86 host (see "Windows game").
3. If you want to build Windows blobs at the party, make the offline build
   image and copy the Windows game files to a stick. See
   [CREATING-BLOBS.md](CREATING-BLOBS.md), "A build host with no internet".

## Cheat sheet: add a Linux game at the party

1. On the build host, before the party, build the blob:

   ```bash
   OUT_DIR="$HOME/blobs" SKIP_CATALOG=1 bash scripts/build/build-app-blob.sh \
       <name> repo "<packages>" "<command>" "<Title>"
   ```

2. Check the free space on the server. You need two times the blob size:

   ```bash
   ssh <user>@<server> 'df -h <repo>/server/games; mkdir -p ~/incoming'
   ```

3. Copy the blob to the server:

   ```bash
   scp "$HOME/blobs/<name>.squashfs" <user>@<server>:incoming/
   ```

4. Log in to the server. All other commands in this guide run there, as `<user>`:

   ```bash
   ssh <user>@<server>
   cd <repo>
   ```

5. Do a dry run, then publish:

   ```bash
   bash scripts/deploy/publish-blob.sh ~/incoming/<name>.squashfs --title "<Title>" --dry-run
   bash scripts/deploy/publish-blob.sh ~/incoming/<name>.squashfs --title "<Title>"
   ```

   For a hidden game, add `--hidden --unlock-code <CODE>` to both commands.

6. Remove the copy in `~/incoming`, then do the checks in "Verify".

At the venue, connect a laptop to the party LAN and use `ssh <user>@<server>`.

## Linux (native) game

```bash
OUT_DIR="$HOME/blobs" SKIP_CATALOG=1 bash scripts/build/build-app-blob.sh \
    <name> <repo|aur> "<packages>" "<command>" "<Title>"
```

- Use `repo` for an Arch package and `aur` for an AUR package.
- If the game needs more libraries, set `EXTRA_PKGS="<lib1> <lib2>"`.
- The store folder comes from `--category game|app|tool` on the publish
  command. The default is `game`.
- On an arm64 host the build runs in an amd64 Docker container under emulation
  and is slow.
- `build-all-blobs.sh` builds every blob row of the repo catalog that has no
  blob yet. Run it from the repo root, before the party.
  From another dir, it builds every blob again.

## Windows game

An arm64 host cannot build a Windows blob. The build starts a new 32-bit Wine
prefix, and that needs a host that runs 32-bit x86 code. Use one of these:

1. Before the party, on an x86 Linux host with Docker and internet (for example
   a partyOS client with Docker on its stick):

   ```bash
   OUT_DIR=<dir> CATALOG_V2=none bash scripts/build/build-proton-blob.sh \
       <name> <game-dir-or-zip> "<game.exe>" "<Title>" 2048 4096
   ```

2. At the party, on the same host, with the offline build image. Add
   `ARCH_IMAGE=partyos-protonbuild-offline:20250901 PB_MIRROR=file:///offline/pkgs`
   to the command above.
3. With no build: a player opens Apps & Games, then New Windows Game, and
   installs the game from their own stick into a Wine env.

`<game.exe>` is the path of the exe inside the game dir. If the game only
ships as installers, stage it first on an x86 host with Wine and a display.
`scripts/build/stage-avp2.sh` is the example.

To publish, do the cheat sheet steps 2 to 6. The Windows games in the catalog
are hidden, so add `--hidden --unlock-code <CODE>`. `publish-blob.sh` reads the
Windows fields and the RAM from the blob. The dry run shows `kind     : proton`.

## Hidden games and unlock codes

A row with `"hidden": true` has no tile. A player sees it only after they type
its `unlock_code` in the store (Enter a Code). To publish a hidden game, add
`--hidden --unlock-code <CODE>` to `publish-blob.sh`. The row is hidden from
the first catalog write. The code uses `A-Z a-z 0-9 . _ -`, and case does not
matter. If you publish the same `<name>` again, it keeps the fields that you set.

This example uses two codes:

- `EXAMPLE1`: the Windows games that work.
- `EXAMPLE2`: every game that is not verified. Publish a new game with
  `--hidden --unlock-code EXAMPLE2`. The game stays behind `EXAMPLE2` until its current
  blob reaches the main menu on real hardware, with a screenshot or a launch
  log. Then set `"hidden": false` (see "Set fields on a row"). If you publish a
  new blob of a visible game, set the row back to `EXAMPLE2` until you verify the
  new blob. `publish-blob.sh` keeps the old fields, so it does not do this.

## Set fields on a row

Use this to change a game that is already published. Run it on the server, in
`<repo>`. Put your fields in `SET`:

```bash
NAME=<name> SET='{"hidden": true, "unlock_code": "<CODE>"}' python3 - server/games/catalog.v2.json <<'PY'
import json, os, sys
p = sys.argv[1]; d = json.load(open(p))
row = next(r for r in d["games"] if r.get("name") == os.environ["NAME"])
row.update(json.loads(os.environ["SET"]))
json.dump(d, open(p + ".tmp", "w"), indent=2); os.replace(p + ".tmp", p)
print(row)
PY
```

Then run `bash scripts/build/build-game-blobs.sh` to publish the catalog.

## Update or remove a game

- Update: warning, a player who has the old blob in the cache keeps the old
  blob. New titles are not affected.
  1. Build the blob again with the same `<name>`. You need three times the blob
     size free on the server (the copy in `~/incoming`, the new blob and the old
     blob).
  2. Publish it again with the same command. `publish-blob.sh` replaces the old
     torrent in the running seeder. It adds the new torrent, waits until the
     seeder seeds it, then removes the old info-hash. The output has
     `removed the old info-hash <hash> from the seeder`. You do not remove
     anything by hand.
  3. Do the checks in "Verify". Check 4 must show one line for `<name>`.
  4. On each client with the old blob, run `partyos-app reinstall <name>`.

  Until the seeder restarts, the new torrent seeds from
  `server/games/.publish/<name>-<sha>/`. Do not delete that dir. The next
  publish of `<name>` deletes it when the seeder no longer uses it.
- Remove: set `SET='{"hidden": true, "unlock_code": ""}'`, then run
  `bash scripts/build/build-game-blobs.sh`. The store then refuses the install.
  Do not delete the squashfs, because the seeder still uses it.
- Do not use `scripts/blob/add-blob.sh` at the party. It takes a contributor
  `catalog-fragment.json`, not a squashfs. Its torrent has no tracker URL, and
  it does not add the torrent to the running seeder.

## Verify

Run these on the server, in `<repo>`:

1. The blob, the `.sha256` sidecar and the `.torrent` are there:
   `ls -l server/games/<name>.squashfs*`
2. The served catalog has the row. The output must be `1`:

   ```bash
   curl -s --cacert ca/partyos-ca.crt https://<server>:8443/server/games/catalog.json | grep -c '"name": "<name>"'
   ```

3. The served catalog is the same as the source. The output must be `CHECK OK`:
   `bash scripts/build/build-game-blobs.sh --check`
4. The seeder has the torrent. The output must be one line,
   `active <name>.squashfs`:

   ```bash
   python3 -c 'import json,urllib.request as u;r=lambda m,*p:json.load(u.urlopen("http://127.0.0.1:6800/jsonrpc",json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":["token:partyos",*p]}).encode()))["result"];[print(t["status"],t["bittorrent"]["info"]["name"]) for t in r("aria2.tellActive",["status","bittorrent"])]' | grep <name>
   ```

5. The tracker answers. The output must be `400`. `000` means it is down:
   `curl -s -o /dev/null -w '%{http_code}\n' http://<server>:6969/announce`
6. On a client, the tile comes in 3 minutes or less. The store gets the
   catalog every 180 seconds.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `could not ask the running seeder over RPC` | The server stack is down. Run `systemctl status partyos-servers`. If it is stopped, run `sudo systemctl start partyos-servers`, then publish again. |
| `the running seeder does not seed the torrent` or `does not seed the new torrent` | The seeder could not verify the bytes in 30 minutes. The catalog and the old torrent did not change. Check the blob (`unsquashfs -l`) and the free space, then publish again. |
| `could not remove the old info-hash` | The new torrent seeds, but the old one is still in the seeder. The catalog did not change. Publish again. |
| `No space left on device` | Run `df -h /`. Delete the copies in `~/incoming`. You need two times the blob size free. |
| The build stops at `Could not resolve host` | The build host has no internet. Build before the party, or connect the build host to the internet. |
| The Windows build fails at `wineboot` on an arm64 host | The host cannot run 32-bit x86 code. Build on an x86 host. |
| `unsquashfs required` | The server has no `squashfs-tools`. Run `sudo apt install squashfs-tools` (needs internet, so do it before the party), then publish again. |
| No tile after 3 minutes | Do the "Verify" checks. If the row is hidden, type its code in the store. |
| Players still get the old version | Run `partyos-app reinstall <name>` on that client. |

## After the party

1. Copy `server/games/catalog.v2.json` from the server to the repo on the build host,
   then commit it.
2. Run `scripts/build/extract-game-icons.sh` before the next image build. It
   puts the real game icons in the image.
