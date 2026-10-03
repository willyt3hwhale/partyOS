# phase b0-ram-seed - sourced by build-custom-image.sh; not standalone
# --- partyos-ram: the RAM lifecycle / eviction manager -------------------
# The OS sits in RAM; blobs stack on top. RAM is finite. On EACH launch the
# manager projects the new blob's RAM need (ram_min/ram_max from the catalog
# metadata) against effective free RAM, and if it won't fit it PROMPTS the
# user to unmount blobs to free RAM - offering BOTH idle and in-use blobs (the
# user decides; not a silent LRU). Safe unmount = drop the overlay + free the
# squashfs from RAM. A refcount tracks idle vs in-use so an in-use blob is
# protected (never offered as the auto choice in non-interactive mode).
#
# This is a CLI BACKEND partyos-app calls (so a real click and the headless test
# drive the same path). It parses the catalog with grep/sed (no jq), mirroring
# partyos-blob-meta / partyos-app.
echo "[build] baking partyos-ram (RAM lifecycle / eviction manager)..."
bake "usr/local/bin/partyos-ram"
echo "[build] baked partyos-ram (RAM lifecycle / eviction manager)"

# --- partyos-seed: offline operator seeding station ------------------
# Drop a server-built <name>.squashfs into a USB stick's blob cache so the first
# click is a guaranteed zero-download CACHE-HIT. Verifies the blob's sha256
# against the catalog BEFORE placing it (a corrupt/wrong blob is rejected, never
# seeded). This is the OPERATOR side; runtime seeding already works via get_blob's
# sha-verified HIT - this just pre-populates the cache from a known-good source.
echo "[build] baking partyos-seed (offline cache seeding station)..."
bake "usr/local/bin/partyos-seed"
echo "[build] baked partyos-seed (offline cache seeding station)"

