# Testing partyOS

This guide tells you how to run the test suites and what each suite covers. The suites
go from hardware-free shell tests to the physical test machines. For failure modes see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md). For the operator flow see [HOSTING.md](HOSTING.md).

## 1. `make test-prod` - hardware-free shell tests

These tests need no VM and no hardware. They live in `scripts/test/` and run the
production scripts against fixtures. The suite takes seconds.

Run the whole suite with `make test-prod`. Run a single test with `make test-<name>`.
Examples:

- `make test-render` - config template rendering
- `make test-catalog-parse` - app catalog parsing
- `make test-blob-failover` - blob source failover logic
- `make test-initramfs-guard` - the staleness guard for the served initramfs
- `make test-user-provision` - per-player provisioning
- `make test-bootwatch` - the boot-watch library
- `make test-fleet-verify` - fleet-verify against a mock ssh and access log

Run `make test-prod` for every change, before you build an image.

### Add a test

If you fix a bug in a script that `scripts/test/` can reach, add a test that fails
before the fix and passes after it. To add a new test:

1. Copy an existing `scripts/test/test-*.sh`.
2. Copy its Makefile target.
3. Add the new target to the `test-prod` prerequisites and to `.PHONY`.

### Pre-commit hook

`make install-hooks` installs a git pre-commit hook. The hook runs `make test-prod` and
stops the commit if a test fails. To skip the hook for one commit, use
`SKIP_TESTS=1 git commit`. The installer backs up an existing hook to `pre-commit.bak`.
Nothing installs the hook automatically. Run it once per clone.

## 2. VM harness - full boot flow under QEMU

`scripts/vm/harness.sh` boots the real image in a VM and runs the step scripts.

- `make test-step1` through `make test-step9` - one boot step each
- `make test-identity`, `make test-appstore`, ... - scenario tests
- `make test-all` - `test-prod`, then VM steps 1-9 in headless VMs. It stops with a
  non-zero exit at the first step that fails.
- `make test-lan` - a LAN scenario with more than one client

If the host has no x86 KVM (for example an arm64 Mac), QEMU falls back to slow TCG.
Run the VM targets on an x86 KVM host with `scripts/vm/remote-test.sh <make-target>`.
Set `REMOTE_HOST` to the ssh host of that machine. The script copies the tree to that
host with rsync and runs the target there.

## 3. Real hardware - PXE boot the test machines

Only real hardware shows bugs that depend on the GPU, the firmware or the NIC. These
bugs often occur on one GPU vendor only, so test one machine per vendor (AMD, NVIDIA,
Intel).

### Fleet configuration

Copy `scripts/deploy/fleet.conf.example` to `scripts/deploy/fleet.conf`. Write one host
per line as `name|ip|gpu|quirks`. You can also set `FLEET_HOSTS` or `FLEET_CONF`.

### Build and serve an image

1. Run `make test-prod`.
2. Commit the source change. Build the image from committed source only.
3. Run `FORCE=1 make image`. Without `FORCE=1`, `make image` does nothing if the sfs
   already exists.
4. Run `make boot-artifacts`. This makes the served initramfs again from the new sfs.
5. Run `make servers`. The staleness guards (`scripts/deploy/check-initramfs.sh`,
   `verify-ipxe-efi`) must pass. If a guard fails, fix the artifact.
6. Note the sfs sha from `server/images/custom/arch/x86_64/airootfs.sha512`.
7. Run `scripts/vm/remote-test.sh test-all` on the KVM host.

### fleet-check and fleet-verify

`scripts/deploy/fleet-verify.sh` runs the checks on every host in `fleet.conf`.

- `make fleet-check` - a read-only ssh probe of each host. It does not reboot a host.
  It checks that:
  - the host is up and runs partyOS from RAM (`/run/archiso`)
  - the sha512 of the sfs in RAM is the same as the served `airootfs.sha512`
  - the desktop process and the home-sync timer run
  - the GPU renderer is not llvmpipe (`nvidia-smi` on NVIDIA, `glxinfo` on others)
  - the blob is mounted
- `make fleet-verify HOST=<name|ip|all>` - reboots each host over ssh to PXE boot it
  again. Then it watches the netboot access log for `step=copytoram` and
  `step=3 status=ok desktop=ready`, and runs the same checks as fleet-check. It does
  not run without `HOST`. A machine that does not start after a poweroff needs a manual
  power-on. The reboot mode passes against mocks. It has not been tested on real hardware.

Both targets write results to `scripts/test/results/fleet-<timestamp>/`. The results are
one JSON file per host and a `matrix.md` with the date and the served sfs sha. The exit
code is non-zero if a host fails. A host that does not reply is recorded as UNREACHABLE.

### Boot progress

The server receives `/report` callbacks from each client:

- `step=copytoram` - the initramfs network is up and the sfs download starts
- `step=3 status=ok desktop=ready` - the desktop is up. The callback names the X server
  and the user.

A booted client can have a different IP than at boot time. Get the real IP from the
`/report` logs of the stage3 server.

If the boot stops before stage3, there is no `/report` and no ssh. Take a photo of the
monitor. After X starts, take screenshots of the client screen.

To watch a boot from a script, use `bootwatch_wait` in `scripts/test/lib-bootwatch.sh`.
It has a hard timeout, a stall detector (no new bytes gives STALL, with an exit code
different from TIMEOUT), an optional fail marker, and heartbeat lines on stderr.

### Apps and games

Start apps and games from the desktop icon, as a player does. Take a screenshot of the
client screen to see the window. Use `partyos-app` and `scripts/test/test-apps.sh` to
read the result: install state, unlock markers and processes.

### Fleet smoke checklist

Do these checks on each machine after a rebuild:

1. `head -1 /etc/partyos-build-id` shows the expected `BUILD_ID`. The sha512 of the
   sfs in /run/archiso/copytoram is the same as the served `airootfs.sha512`.
2. BOOTIF is on /proc/cmdline, `systemctl --failed` is empty, the desktop is up, and
   `pgrep -c -x aria2c` is 1.
3. /mnt/usbhome and /mnt/share are mounted, and each appears once in
   /proc/self/mountinfo.
4. `journalctl -b | grep -E 'PARTYOS-USB-REMOVED|NO-SERVER'` is empty.
5. Home sync advances. Read
   `cat /run/partyos-home-generation /mnt/usbhome/.partyos-home-state` two times,
   3 minutes apart. Both numbers go up, and they are equal (or the stick is one ahead
   while a push runs). `journalctl -b -u partyos-home-sync | grep -c 'standing down'`
   is 0.
6. On one machine, pull the home stick: the desktop shows "Home stick removed". Put it
   back: the desktop shows "Home stick back".

### Record the results

Write down the date, the host and the sfs sha for each hardware result.

## Live patches

You can edit a script on a running RAM client over ssh to find a cause or try a fix.
A live-patched client is not the image. The file layout, the service order and the boot
state are different. Put the fix in the image source, rebuild, and test it from a clean
PXE boot.
