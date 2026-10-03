# Creating partyOS app/game blobs

How to package a game or app for partyOS and get it to show up as a clickable
desktop/start-menu icon on the clients - end to end.

partyOS clients are slim and run from RAM. They ship almost none of a game's
dependencies. So an app reaches a client one of two ways:

1. **Blob** (self-contained): a whole x86_64 rootfs (the app + its *full*
   dependency closure) squashed into one file, run sandboxed with `bwrap`. No
   deps are installed on the client; nothing pollutes it. Use this for anything
   not already mirrored, anything from the AUR, or anything you want frozen.
2. **Mirror package**: the app is added to the LAN pacman mirror and installed
   on-demand from there. Lighter to produce, but the package + its deps must all
   live in the mirror. Use this for plain repo apps (see
   [the mirror section](#alternative-mirror-a-repo-package)).

The server publishes the catalog (`server/games/catalog.v2.json`). Each
row is either `source: "blob"` or `source: "pkg"`. The client reads the compiled
`catalog.json` and turns every row into an icon.

## 1. Build a blob

```
scripts/build/build-app-blob.sh <name> <source> <pkgs> <exec> [title] [category] [id] [ram_min] [ram_max]
```

| arg        | required | meaning |
|------------|----------|---------|
| `name`     | yes | short id, `[a-z0-9]`; also the blob filename (`<name>.squashfs`) |
| `source`   | yes | `repo` (pacman from the pinned snapshot) or `aur` (makepkg in-container) |
| `pkgs`     | yes | space-separated package(s) to install into the rootfs. Include **data packages** (e.g. `0ad 0ad-data`). For `aur`, the AUR pkgbase (prefer `-bin` packages to skip a heavy source build). |
| `exec`     | yes | command run *inside* the sandbox, e.g. `0ad`, `openra-ra`, `java -jar /opt/x.jar`. This is the binary, not the package. |
| `title`    | no | human name shown on the icon (default: `name`) |
| `category` | no | `game` \| `tool` \| `net` \| `media` \| `creative` (default `game`) - drives the icon + folder |
| `id`       | no | stable catalog id (default `partyos.<name>`) |
| `ram_min`  | no | min RAM MB the eviction manager guarantees before launch (default 512) |
| `ram_max`  | no | expected max RAM MB (default 2048) |

Examples:

```bash
# repo game with a separate data package
scripts/build/build-app-blob.sh zeroad repo "0ad 0ad-data" 0ad "0 A.D." game partyos.0ad 2048 4096

# AUR game, prefer the prebuilt -bin pkgbase
scripts/build/build-app-blob.sh veloren aur veloren-bin veloren-voxygen "Veloren" game partyos.veloren 2048 4096
```

What it does (all inside an amd64 `archlinux` container pinned to the same
2025/09 snapshot as the client base, so the bundled libs match the client ABI):

- `repo`: `pacman --root <rootfs> -Sy <pkgs>` installs the app + full dep closure.
- `aur`: clones each pkgbase from `aur.archlinux.org`, `makepkg -s`, installs the
  result (+ deps) into the rootfs.
- Bakes `bin/run.sh` into the rootfs - a `bwrap` launcher that binds the blob's
  `/usr`,`/etc`,`/opt` read-only, the host `$HOME`, `/dev`, `/run/user/$UID`
  (audio/dbus), `/tmp/.X11-unix` (display), sets `LIBGL_ALWAYS_SOFTWARE=1` by
  default, and `exec`s your `<exec>`.
- `mksquashfs ... -comp xz` → `server/games/<name>.squashfs` + `.sha256`.
- Updates the `<name>` row in `catalog.v2.json` with the real `sha256`/`size`.

> **GPU note.** The client boots `nomodeset` in VMs → software GL → 3D games are
> unplayable there. On real hardware with a real GPU (`gpu=real` in the boot
> report) they run. 2D games (openttd, ddnet, hedgewars, unciv, openra) are fine
> either way. Set `PARTYOS_SOFTWARE_GL=0` in the row's environment only if you
> know the client has a working GPU stack.

After building, compile the served catalog:

```bash
scripts/build/build-game-blobs.sh      # renders catalog.v2.json -> catalog.json
```

To build/repair **all** unbuilt blob rows at once, see
`scripts/build/build-all-blobs.sh` (loops the catalog, retries once, logs
unbuildable). `*.squashfs` are git-ignored (too big); `catalog.v2.json` is the
committed source, `catalog.json` is generated.

## 2. The catalog row

`catalog.v2.json` rows must stay rectangular: the client parses them with a
no-`jq`, grep-per-field parser that builds parallel arrays aligned by match
order. Every row must carry every field. A missing key shifts every later
row's arrays and mismaps names to blobs. `pkg` rows use `""`/`0` sentinels for
the blob-only fields.

Required on every row: `id`, `name`, `title`, `source`. `build-app-blob.sh`
writes a rectangular blob row for you; only hand-edit if you know the schema.

Blob row (written by the builder):

```json
{
  "id": "partyos.zeroad", "name": "zeroad", "title": "0 A.D.",
  "source": "blob", "blob": "server/games/zeroad.squashfs",
  "sha256": "<real>", "size": 1234567, "ram_min": 2048, "ram_max": 4096,
  "version": "1.0.0", "category": "game", "icon": "applications-games",
  "exec": "0ad", "pkg": "", "pkgs": "", "entry": "bin/run.sh", "marker": ""
}
```

pkg row (installs from the LAN mirror on click):

```json
{
  "id": "partyos.mumble", "name": "mumble", "title": "Mumble",
  "source": "pkg", "blob": "", "sha256": "", "size": 0,
  "ram_min": 0, "ram_max": 0, "version": "", "category": "net",
  "icon": "applications-internet", "exec": "mumble",
  "pkg": "mumble", "pkgs": "", "entry": "", "marker": ""
}
```

Optional fields the seeder/launcher understand: `config_dir`, `config_template`,
`config_out`, `seed_keys` (first-run config templating from the USB `user.conf`),
`needs_server`, `server_pkg`.

First-run config seed:

- `config_dir` is relative to `~/.config`. A value that starts with `.` or holds a
  `/` is relative to `$HOME` (for example `.local/share/ddnet`).
- `config_template` is a path under `server/` (for example
  `config/ddnet/settings_ddnet.cfg.tmpl`). `config_out` is the file under
  `config_dir`. Both can be a space-separated list of the same length.
- In a template, `@NICK@` becomes the player nick (`INTERNYET_ALIAS`).
- Put the template in `server/config/<game>/`. `make test-catalog-templates`
  fails if a `config_template` file is missing.
- Copy `server/config` to the server with the other payload (see
  docs/PREPARE-LAN.md, Phase 5). If the template is not served, the launch log
  `/tmp/partyos-launch-<name>.log` has a `SEED-FAILED` line.

## 3. How a row becomes a desktop/start-menu icon

On the client, `partyos-appstore.service` runs once per boot →
`partyos-app gen-launchers`, which reads the live `catalog.json` and writes, per
row:

- **Start-menu entry** (Whisker/applications menu):
  `~/.local/share/applications/partyos-app-<name>.desktop`, grouped by the
  freedesktop category.
- **Desktop icon**, placed inside a hidden per-category folder
  `~/Desktop/.apps-<Label>/partyos-app-<name>.desktop`, with one **category
  "folder" launcher** on the desktop (`~/Desktop/<Label>.desktop`) that opens it.

Every launcher's `Exec=` is `/usr/local/bin/partyos-launch <name>`. Clicking it
routes by the row's `source`:
- `blob` → `partyos-app install-launch <name>` (download from LAN to the USB
  cache if not present, mount squashfs+tmpfs overlay at `~/games/<name>`, run
  `bin/run.sh`). If the blob isn't built yet, it shows a friendly "not available
  yet" dialog and exits cleanly.
- `pkg` → install from the `[partyos]` LAN mirror if missing, seed config, exec.

`gen-launchers` re-runs every boot, so the icons always track whatever the server
currently serves. It removes stale `partyos-app-*` launchers + `.apps-*` folders
first, so removing a catalog row makes its icon vanish on next boot.

### category → icon + folder

| `category`           | menu group | desktop folder | default icon |
|----------------------|------------|----------------|--------------|
| `game`               | Game       | `Games`        | `input-gaming` |
| `net`                | Network    | `Internet`     | `applications-internet` |
| `media`              | AudioVideo | `Media`        | `applications-multimedia` |
| `creative`           | Graphics   | `Creative`     | `applications-graphics` |
| `tool`               | System     | `Tools`        | `gnome-nettool` |
| (other)              | Game       | `Apps`         | `applications-other` |

A row's `icon` field **overrides** the category default (e.g. `blender`,
`krita`, `obs`, `internet-group-chat`). Use a real theme icon name.

### top-level desktop apps (special case)

Two rows are pinned as **top-level desktop icons** instead of being filed in the
Internet folder, because they're the "this is the internet" apps:
`browser` (**Internyet Explorer**) and `messenger` (**NYET Messenger**). They
still appear in the start menu. The special-case lives in `gen-launchers`
(`case "${name}" in browser|messenger)`). The static Win95 desktop tools
(`cmd.exe`, `Control Panel`, `My Computer`) are separate baked launchers that
survive refreshes.

## 4. Add a brand-new blob, end to end

```bash
# 1. build it (writes the blob + catalog.v2.json row)
scripts/build/build-app-blob.sh mygame repo "mygame mygame-data" mygame "My Game" game

# 2. compile the served catalog
scripts/build/build-game-blobs.sh

# 3. the server serves server/games/*.squashfs + catalog.json statically -
#    nothing to restart. On the client, reboot (or: systemctl restart
#    partyos-appstore) and the icon appears, grouped by category.
```

To test without a reboot, on a running client:

```bash
ssh root@<client-ip> 'partyos-app install mygame && ls /mnt/usbhome/.partyos-cache/games'
ssh root@<client-ip> 'sudo -u gamer partyos-app gen-launchers'   # refresh icons now
```

## Alternative: mirror a repo package

If the app is a plain repo package and you don't need a frozen blob, add it (and
its full dep closure) to the LAN mirror instead and use a `source: "pkg"` row:

```bash
scripts/build/mirror-pkgs.sh mumble blender krita      # downloads pkg+deps, repo-add
```

This downloads each package + closure (pinned to the snapshot) into
`server/lanmirror/` and rebuilds `partyos.db`. The client's `[partyos]` repo
points at `https://<server>:8443/server/lanmirror`, so a `pkg` row installs
offline from the LAN. Verify resolution: `pacman -Sy && pacman -Sp <pkg>` on a
client - every URL should be under `/server/lanmirror`.

## For trusted contributors (no repo/catalog access needed)

A curated, trusted contributor can package a game/app into a complete partyOS
deliverable **without** touching the operator's catalog or knowing the build
system. They run **one** script, `scripts/blob/make-blob.sh`, which wraps the same
builders documented above but never writes the operator catalog - it emits a
self-contained deliverable the operator then vouches in.

### make-blob.sh (contributor side)

```bash
# native (a repo or AUR app)
scripts/blob/make-blob.sh native <name> <repo|aur> <pkgs> <exec> [title] [category] [ram_min] [ram_max]

# proton (a Windows/Wine game)
scripts/blob/make-blob.sh proton <name> <game-src> <exe-rel> [title] [ram_min] [ram_max]

# options
#   --webseed <http-url>   your self-host base URL (baked into the torrent web-seed)
#   --out <dir>            output dir (default ./blob-out/<name>)
```

Examples:

```bash
# package an AUR game, hand it to the operator to host
scripts/blob/make-blob.sh native mindustry aur mindustry mindustry "Mindustry" game

# package a Windows game and advertise your own HTTP self-host as the web-seed
scripts/blob/make-blob.sh proton flatout2 ~/games/FlatOut2 FlatOut2.exe "FlatOut 2" \
    --webseed http://blobs.mybox.lan/partyos
```

It produces a **deliverable directory** (`blob-out/<name>/`) containing:

| file | what it is |
|------|------------|
| `<name>.squashfs` | the blob |
| `<name>.squashfs.sha256` | its sha256 - **this is what the operator vouches in** |
| `<name>.squashfs.torrent` | BEP19 torrent (with your web-seed if `--webseed`) |
| `<name>.catalog-fragment.json` | one rectangular catalog row (real sha/size/ram/entry/marker) |
| `HANDOFF.txt` | exactly what to send + the sha/size + the hosting note |

Under the hood it calls `build-app-blob.sh` / `build-proton-blob.sh` with
`SKIP_CATALOG=1` and a private temp catalog, so **the operator's
`catalog.v2.json` is never touched**. The Arch snapshot is **hard-pinned to
2025/09/01** and cannot be overridden - a blob built against another snapshot
carries libs whose ABI may not match the client base image.

### Two hosting models

1. **Operator hosts (default).** Send the whole `blob-out/<name>/` directory. The
   operator runs `add-blob.sh ... --host <blob>` (below), which copies the blob
   into `server/games/` and re-bakes the torrent with the operator's web-seeds.
2. **You self-host.** Build with `--webseed http://<your-host>/<base>`, host the
   blob at `<your-host>/<base>/<name>.squashfs` **over HTTP**, and send only the
   fragment + sha256. The operator runs `add-blob.sh ... --webseed http://<your-host>/<base>`
   and points the catalog at your host. The sha256 in the catalog verifies your
   bytes regardless of where they come from.

> **Why HTTP for self-host web-seeds?** Clients reject HTTPS hosts not signed by the
> private CA, and the catalog sha256 checks the blob integrity.

### For the operator: add-blob.sh (vouch a contributor blob in)

The operator accepts a fragment with `scripts/blob/add-blob.sh`:

```bash
# A. host the contributor's bytes yourself
scripts/blob/add-blob.sh <name>.catalog-fragment.json --host <name>.squashfs

# B. point the catalog at the contributor's HTTP self-host
scripts/blob/add-blob.sh <name>.catalog-fragment.json --webseed http://<their-host>/<base>

# register the row only (you'll host the bytes out-of-band)
scripts/blob/add-blob.sh <name>.catalog-fragment.json
```

`add-blob.sh`:

1. **Validates** the fragment: the row must be rectangular **and** carry a
   **non-empty 64-hex sha256**. It fails on an empty sha, mirroring the
   client's fail-closed `get_blob` (an empty sha would mount an unverified blob).
2. **Upserts** the row into `catalog.v2.json` by name - idempotent, and it
   preserves any operator-tuned fields (`config_*`, `server_pkg`, `version`,
   `icon`, ...) on a re-add, only updating the build-derived `sha256`/`size`/blob
   facts.
3. With `--host`, verifies the supplied blob hashes to the fragment sha **before**
   copying it into `server/games/`, then re-bakes the torrent. With `--webseed`,
   records the contributor's HTTP self-host on the row and bakes it into the
   torrent web-seed.
4. Re-runs `build-game-blobs.sh` to render `catalog.json` (the file clients fetch).

These blobs are added to the operator's catalog **at event time** - they are
**not** baked into the shipped image. `gen-launchers` rebuilds the desktop/start
-menu icons from `catalog.json` on every boot, so a vouched-in row becomes a
clickable icon on the next client boot with no image rebuild and no app-store
change.

## Windows games via Proton (operator side)

A Windows game runs under Wine, so its blob has the same shape as a native blob (squashfs
ro + tmpfs overlay at `~/games/<name>`, run by `partyos-app` via `bin/run.sh`) - only
what is inside the rootfs differs. The operator builds one with:

```
scripts/build/build-proton-blob.sh <name> <game-src> <exe-rel> [title] [ram_min] [ram_max]
```

- `game-src` is the staged game (a dir or a `.zip`); `exe-rel` is the game exe relative
  to the game dir inside `drive_c` (e.g. `"Warcraft III/Frozen Throne.exe"`).
- The rootfs bundles the whole Wine runtime - `wine-staging` + the 32-bit GL/Vulkan
  closure (`lib32-mesa`/`lib32-vulkan-*`) + DXVK (and optionally vkd3d) - plus a prebuilt
  wineprefix with the game installed and `wine-mono`/`wine-gecko` baked in, so the party
  launch never touches the network (no internet at the party).
- `[multilib]` is enabled in this script's build container only (the base image + LAN
  mirror stay core+extra). `run.sh` redirects `WINEPREFIX` to the USB stick
  (`/mnt/usbhome/.partyos-runcache/<name>/prefix`) because the ~3GB prefix does not fit
  the 4GB airootfs RAM overlay; it falls back to `~/.cache` (RAM) when no USB home is
  mounted.
- Env knobs: `DXVK=1` (bake d3d8/9/10/11), `VKD3D=0` (d3d12; only D3D12 titles need it),
  `WINVER=winxp`, `MAXFPS=` (DXVK frame cap, e.g. for FlatOut 2's frame-tied physics), and
  `WINE_REG_EXTRA` (newline-separated `wine reg add` arg-sets baked into the prefix
  template for per-game polish). Output: `server/games/<name>.squashfs` + `.sha256` and the
  catalog row updated; run `build-game-blobs.sh` afterwards to recompile `catalog.json`.

> **Where to build it.** `build-proton-blob.sh` initializes a real wineprefix (it executes
> 32-bit Wine), so run it on an x86_64 build host. An arm64 host cannot init a 32-bit
> wineprefix under Rosetta. The base-env repack below executes no
> Wine and runs anywhere.

#### A build host with no internet

`build-proton-blob.sh` gets its packages from the archive.archlinux.org snapshot and
dxvk-bin from the AUR. If the build host has no internet, make an offline build image
first, on a host with internet (an arm64 host works, nothing in it executes 32-bit x86):

```
bash scripts/build/build-proton-offline-image.sh --save /tmp/protonbuild.tar.zst \
     --host-pkgs /tmp/protonbuild-hostpkgs
```

The image holds a local package repo at `/offline/pkgs`: the full package set of the
build, a prebuilt dxvk-bin, and the docker packages for the build host. Then, on the
build host:

1. Copy both outputs to the USB stick. The RAM root is 4 GB, so keep everything there.
2. Run `pacman -U --needed <hostpkgs>/*.pkg.tar.zst`. Set `data-root` in
   `/etc/docker/daemon.json` to a dir on the stick, then start docker.
3. Run `zstd -dc protonbuild.tar.zst | docker load`.
4. Build with the image and its repo:

   ```
   OUT_DIR=<dir on the stick> ARCH_IMAGE=partyos-protonbuild-offline:20250901 \
   PB_MIRROR=file:///offline/pkgs bash scripts/build/build-proton-blob.sh <name> ...
   ```

The same image also runs `stage-avp2.sh` (below) with no network. Install wine in it from
`/offline/pkgs` first.

### A title that only ships as installers: Aliens versus Predator 2

`build-proton-blob.sh` takes a staged game directory. AvP2 does not ship as one. It
ships as four Windows installers, so it needs a staging step first.

1. Fetch the archives. This runs on any host, including an arm64 host, because it only
   downloads. About 690 MB, almost all of it the all-in-one archive.

   ```
   bash scripts/build/fetch-avp2-installers.sh          # -> ~/Downloads/avp2-installers
   ```

   The archives are game binaries. They stay in that cache directory and are never
   committed. Copy the directory to the build host if you fetched it elsewhere.

2. Run the installers. This step executes 32-bit Windows installers, so it needs an
   x86_64 build host with wine and a live X display. An arm64 host
   cannot do it: Rosetta does not run 32-bit x86.

   ```
   bash scripts/build/stage-avp2.sh                     # -> ~/Downloads/avp2-staged
   ```

   Install order, which the script follows: the all-in-one base game, then the
   1.0.9.6 update, then the single-player map update, then the multiplayer map
   update. The base-game installer is NSIS, so `/S` installs it silently. It ignores
   `/D=` and installs to `C:\Program Files (x86)\Aliens vs. Predator 2`, so the
   script finds the game by `AVP2.exe`. The three updates are 2002 InstallShield
   archives. They ignore `/s` and show their wizard, so each one needs a click
   through on the live display: Next, Next, Next (the destination is already the
   game dir), Finish. The script checks each update by the readme it leaves
   (`readme1096.txt`, `readmesp1.txt`, `readmemp1.txt`), so a rerun skips an update
   that is already applied. It scrubs player state before staging.

   If the partyOS lock screen is up on the build host, no click reaches the wizard.
   Keep the screensaver from starting while you click (`xscreensaver-command
   -deactivate` once a minute as the desktop user).

   To run it in the offline build image, bind the X socket and the X cookie into
   the container, and give the container the host name of the build host. The cookie
   is bound to that host name, so with a different one the wizard cannot open.

3. Build the blob and publish it.

   ```
   bash scripts/build/build-proton-blob.sh avp2 ~/Downloads/avp2-staged "AVP2.exe" \
        "Aliens versus Predator 2" 2048 4096
   bash scripts/build/build-game-blobs.sh
   bash scripts/build/gen-blob-torrents.sh
   ```

Notes on the title:

- The all-in-one build has the no-CD patch built in, so the game needs no disc and no
  CD key.
- LAN play uses Host LAN Game inside the game, on UDP 27888 and upward in steps of 8.
  The avpunknown master server is for internet play and is not needed on a LAN.
- A dedicated server exists as a native 32-bit Linux binary (`avp2linux_096.gz`,
  in the all-in-one archive), which suits the party server better than a listen host.
- The installers write three values under
  `HKLM\Software\Wow6432Node\Monolith Productions\Aliens vs. Predator 2\1.0`:
  `InstallDir`, `Language` and `Update Command Line` (`-rez AVP2P1.REZ -rez
  AVP2SP.REZ`). The blob makes a fresh prefix, so `build-proton-blob.sh` bakes them
  for `avp2`, with `InstallDir` set to `C:\game`.

### The hidden `protonenv` base blob

The on-client "New Windows Game" wizard (below) clones a base **proton-env** blob: the
reusable Wine runtime + a clean wineprefix with no baked game. It is a hidden catalog
row (`protonenv`) - players never see it as an app; the `partyos-proton-env` engine uses
it. Produce or refresh it by repacking an existing proton game blob:

```
scripts/build/build-baseenv-blob.sh [SRC_BLOB]     # default: server/games/flatout2.squashfs
```

It `unsquashfs`es the source blob (which already bundles the Wine runtime + an initialized
prefix at `opt/prefix-template/`), strips the baked game out of the template, swaps in a
parameterized launcher, and re-squashes to `server/games/protonenv.squashfs` + `.sha256`
(both git-ignored). It only moves files and runs no Wine or wineboot, so it also
works on an arm64 host. Refresh it whenever the underlying proton blob's
Wine runtime changes.

## On-client: New Windows Game (Proton env)

Everything above is the **operator/contributor** side - prepacked blobs the LAN
serves. There is also a **player** side: at a booted partyOS client you can bring
your *own* Windows game, install it, and play it - all from the desktop, no
terminal. It runs in a wine env (a writable wine prefix) cloned from the base
proton-env blob the LAN already serves.

1. **Open it.** Apps & Games -> **New Windows Game**.
2. **Create + name your env.** Type a name (e.g. *Age of Empires*). partyOS sets
   up a fresh wine env for it - this takes a minute the first time.
3. **Say how it is packaged.** partyOS asks: an **installer** or a **ready-to-run**
   game (a folder or a single `.exe`).
   - **Installer:** pick the game's `setup.exe` (or `.msi`) - off your USB stick, a
     download, wherever - click through the real installer, then pick the game's
     `.exe` it installed (under the env's `drive_c`).
   - **Ready-to-run (portable):** pick a single `.exe`, or a folder containing the
     game; partyOS copies it into the env, and for a folder you pick which `.exe`
     to run. It launches with its own folder as the working directory, so sibling
     assets and DLLs are found.
4. **Play.** The game gets its own **tile** in Apps & Games. Click it any time -
   no reinstall.

The env lives on your USB stick, so install once and it is there all weekend (and
the next event). An env is local to your stick: you cannot share it with another
player.

## Testing every app (`test-apps.sh`)

After building blobs, verify they actually launch with the automated harness:

```
scripts/test/test-apps.sh --dry-run                 # enumerate only (works anywhere)
scripts/test/test-apps.sh --user <name>             # launch-test every non-hidden entry
scripts/test/test-apps.sh --user <name> --category games
scripts/test/test-apps.sh --user <name> --only flatout2,xonotic --timeout 45
```

It drives the real client launch path (`partyos-app install` + `launch` for `source=blob`;
`partyos-launch` for `source=pkg` - the same path a desktop icon click takes) for each
catalog entry, one at a time, and records whether each comes up. It is the automated
stand-in for a human clicking every icon and watching. Liveness is judged by several
signals so "runs but renders wrong" is still caught: the app process is up, an X window
appeared, and the launch log shows the catalog `marker`. Per-app verdict is
`PASS` / `WARN` / `FAIL-NOSTART` / `FAIL-INSTALL` / `SKIP-*`.

- **It runs on a booted partyOS client**, as root, with a live X
  session. It launches real games, so it is not a hardware-free unit test. Do a
  `--dry-run` (enumeration only) first; that works anywhere.
- Output lands under a timestamped dir in `scripts/test/results/` (git-ignored): per-app
  `<id>.log` + `<id>.png` screenshot, a machine-readable `summary.json` + human
  `summary.md`, and a final PASS/FAIL/WARN tally.
- Sequential only (two concurrent blob installs can freeze the box). `--include-hidden` adds
  hidden rows (`wc3`, `protonenv`). Warning: `--concurrent-test a,b` is off by default. It
  races two installs to reproduce the freeze, and it can wedge the box.
