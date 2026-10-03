# Troubleshooting partyOS

Setup, cert, serving, and real-hardware boot failure modes. For the happy-path operator
flow see [HOSTING.md](HOSTING.md).

## Setup / cert / serving

- **`setup.sh` says Docker is down** - start the Docker daemon (`systemctl start docker`,
  or launch Docker Desktop on macOS) and re-run.
- **`setup.sh` says openssl is too old** - install openssl 3.3+ (see HOSTING.md
  Prerequisites). The certs need `-not_before` for clock tolerance.
- **The client boots into the firmware's next entry (e.g. an installed OS)** instead of
  partyOS - the stick has a wrong/old EFI. An aborted embedded iPXE script returns to UEFI,
  which boots the next BootOrder entry. Re-flash the stick with the EFI `setup.sh` built.
- **TLS cert error during boot** - your server IP is not in the leaf SAN. Re-run `setup.sh`
  with the right IP so the SAN matches the address clients dial.
- **`verify-ipxe-efi` refuses a stale EFI** - the CA was rotated without rebuilding the EFI.
  Run `make ipxe` (or re-run `setup.sh`) to rebuild it against the current CA, then re-flash.
- **`make servers` refuses to start** - the served initramfs is stale or lacks the bundled
  CA. Run `make boot-artifacts` (rebuilds the image then the initramfs in order).

## Real-hardware boot / netboot

### iPXE loops "Waiting for link-up" and DHCP never succeeds (unsupported NIC)

**Symptom.** On some laptops the embedded iPXE loops `Waiting for link-up on net0` and then
DHCP fails for all 15 attempts, e.g. with `dhcp` error `1a086194` (net/netdevice.c). The
same machine, cable and switch boots Ubuntu and gets a lease fine.

**Cause.** iPXE ships its own limited set of native NIC drivers, inherently narrower than
Linux's, and it cannot reliably bring up link on some chips. Confirmed on an Intel I218-LM
(Linux drives it with `e1000e`; iPXE's native `intel` driver never stabilises link, so the
DHCP DISCOVER never even reaches the wire - `tcpdump` on the server sees zero frames from
the client). A version bump does not help (no relevant change to `intel.c`/`netdevice.c`
across the pin), and the SNP build (which would ride the firmware's own NIC driver) hangs
at "Initialising devices" on a laptop whose UEFI exposes no network stack.

**Workarounds / fix.** There is no fix for an unsupported NIC. A machine whose NIC iPXE
cannot drive does not netboot partyOS.

### DHCP fails only on the first few tries after a cold power-on (switch STP)

**Symptom.** A cold-booted client's port links up but the first DHCP attempts fail; it only
gets a lease after several retries. Warm reboots are fine.

**Cause.** Managed-switch spanning-tree (STP): the port links up but drops frames for ~15-30s
during the STP listening/learning phase, which outlasts iPXE's default ~10s DHCP timeout.

**Handling (already built).** The embedded autoboot script raises the per-attempt timeout and
retries in a ladder: `ifopen net0` once, then `dhcp --timeout 30000 net0` (30s/attempt,
outlasts STP) up to 15 times before giving up, and reboots to retry rather than dropping to a
dead-end shell on a headless box. See `build/embed-test-https.ipxe` (and the production
`boot/embed-https.ipxe.tmpl` rendered by `setup.sh`). If a switch has an even longer
convergence, enable PortFast/edge-port on the client ports, or raise the attempt count in the
embed template and rebuild the EFI (`make ipxe`).

### Distinguishing multiple flashed sticks

The generic party USB sticks report a by-id of `usb-General_UDisk-0:0` with no unique serial,
so clones are indistinguishable by by-id alone - be careful which device you pass to
`flash-usb.sh`. Identify the target by size + mountpoint (`lsblk -o NAME,SIZE,LABEL,MODEL`)
rather than by-id when flashing.
