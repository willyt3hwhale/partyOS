# partyOS docs

- [HOSTING.md](HOSTING.md) - operator guide: fresh clone to a booting LAN, plus
  registering a player / flashing a stick by name.
- [PREPARE-LAN.md](PREPARE-LAN.md) - checklist to prepare the server and sticks for an event.
- [CREATING-BLOBS.md](CREATING-BLOBS.md) - packaging games/apps as blobs (native, proton,
  contributor), the catalog row, and the `test-apps.sh` launch harness.
- [BLOB-GUIDE.md](BLOB-GUIDE.md) - publish a new game blob to a running server.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - setup/cert/serving failures and real-hardware
  boot failure modes (iPXE NIC coverage, switch STP).
- [TESTING.md](TESTING.md) - testing process: test layers (test-prod, VM harness, fleet),
  the rebuild-and-reboot verification procedure, the fleet matrix tooling
  (`make fleet-check` / `fleet-verify`), regression gates, evidence and recording rules.

The per-player config store is documented in [../users/README.md](../users/README.md).
