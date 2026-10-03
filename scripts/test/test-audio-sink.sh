#!/usr/bin/env bash
# test-audio-sink.sh - hardware-FREE unit test for the BAKED partyos-default-sink
# picker. The image bakes it from
# scripts/build/files/rootfs/usr/local/bin/partyos-default-sink.
# This test awk-extracts pick_sink() from that file, sources it, and asserts
# its choice against SYNTHETIC `wpctl status` dumps. No VM, no network, no hardware,
# no wpctl/pipewire (pick_sink is pure text - it parses a dump piped on stdin).
#
# The bug this guards: the OLD selector grepped a WHITELIST of
# `analog|sof-hda|sof_hda` over the Sinks block. That whitelist only matches the
# Intel `sof-hda-dsp` driver. On a REALTEK ALC rig the onboard analog sink is described
# differently (e.g. "Family 17h/19h HD Audio Controller Analog Stereo",
# "Realtek ALC1220 Analog", "Built-in Audio ... Speaker") and the literal lowercase
# `analog`/`sof-hda` token need not survive - so sink_id came back EMPTY, the script
# no-op'd, and the ALSA HDMI default stood: NO sound to the player's speakers. The fix
# picks by PREFERENCE ORDER over ALL sinks (analog/onboard > USB headset > HDMI/DP) and
# never routes to HDMI when a real output sink exists. NOTE: this is a HEURISTIC -
# real-world audio routing is rig-dependent and cannot be fully hardware-verified here;
# these asserts lock in the SELECTION logic against representative sink names.
#
# Asserts:
#   (a) analog + HDMI present              -> picks the analog sink (Intel sof-hda)
#   (b) Realtek ALC analog + HDMI present  -> picks the Realtek analog sink (THE fix:
#                                             the OLD grep missed this and chose HDMI)
#   (c) HDMI only                          -> picks HDMI (graceful fall-back)
#   (d) USB headset + analog + HDMI        -> picks analog (onboard preferred over USB)
#   (e) USB headset + HDMI (no onboard)    -> picks the USB headset, not HDMI
#   (f) no sinks at all                    -> picks nothing (no-op safe)
#   (g) AUDIO_SINK=HDMI override           -> forces the HDMI sink even with analog present
#   (h) pulse-style node names (analog-stereo) -> picks the analog one over HDMI
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

PDS="${REPO_ROOT}/scripts/build/files/rootfs/usr/local/bin/partyos-default-sink"
[ -f "${PDS}" ] || { echo "FAIL: partyos-default-sink baked file not found at ${PDS}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-sinktest.XXXXXX")"
trap 'rm -rf "${TMPDIR_T}"' EXIT

# --- the baked partyos-default-sink is the body; carve out pick_sink ----------
PDS_BODY="${PDS}"
[ -s "${PDS_BODY}" ] || { echo "FAIL: partyos-default-sink baked file is empty (${PDS_BODY})"; exit 1; }

# Carve pick_sink (def -> its col-0 closing brace). Standalone, runs nothing at top
# level. The runtime tail of the script is gated by [ "${BASH_SOURCE}" = "${0}" ] so
# even sourcing the whole body would be inert - but we carve just the function to keep
# the unit narrow.
PICKLIB="${TMPDIR_T}/picklib.sh"
awk '/^pick_sink\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "${PDS_BODY}" > "${PICKLIB}"
[ -s "${PICKLIB}" ] || { echo "FAIL: could not carve pick_sink out of PDS"; exit 1; }
grep -q '^pick_sink() {' "${PICKLIB}" || { echo "FAIL: pick_sink missing from carve"; exit 1; }
# shellcheck disable=SC1090
source "${PICKLIB}"

# pick FILE [OVERRIDE] -> echo the chosen sink id for the synthetic dump in FILE.
pick() { pick_sink "${2:-}" < "$1"; }

# ---------------------------------------------------------------------------
echo "================ (a) analog (Intel sof-hda) + HDMI -> analog ==="
DUMP="${TMPDIR_T}/a.txt"
cat > "${DUMP}" <<'WP'
PipeWire 'pipewire-0' [1.0.0]
Audio
 ├─ Devices:
 │      45. Built-in Audio                        [alsa]
 ├─ Sinks:
 │      53. sof-hda-dsp Speaker + Headphones      [vol: 0.40]
 │  *   54. GP104 High Definition Audio Controller Digital Stereo (HDMI) [vol: 1.00]
 ├─ Sources:
 │      55. sof-hda-dsp Mic                       [vol: 1.00]
WP
assert_eq "$(pick "${DUMP}")" "53" "(a) analog sof-hda sink (53) chosen over HDMI (54)"

echo
echo "================ (b) Realtek ALC analog + HDMI -> analog ========"
DUMP="${TMPDIR_T}/b.txt"
cat > "${DUMP}" <<'WP'
Audio
 ├─ Sinks:
 │  *   48. Family 17h/19h HD Audio Controller Analog Stereo [vol: 1.00]
 │      49. NVIDIA GA104 HD Audio Controller Digital Stereo (HDMI) [vol: 1.00]
 ├─ Sources:
WP
assert_eq "$(pick "${DUMP}")" "48" "(b) Realtek analog sink (48) chosen over HDMI (49) - the Realtek regression"

DUMP="${TMPDIR_T}/b2.txt"
cat > "${DUMP}" <<'WP'
Audio
 ├─ Sinks:
 │      60. Realtek ALC1220 Analog                [vol: 0.55]
 │  *   61. Tigerlake HDMI Audio Digital Stereo (HDMI) [vol: 1.00]
 ├─ Sources:
WP
assert_eq "$(pick "${DUMP}")" "60" "(b2) 'Realtek ALC1220 Analog' (60) chosen over HDMI (61)"

DUMP="${TMPDIR_T}/b3.txt"
cat > "${DUMP}" <<'WP'
Audio
 ├─ Sinks:
 │      70. Built-in Audio Speaker                [vol: 0.50]
 │  *   71. GP104 Digital Stereo (HDMI)           [vol: 1.00]
 ├─ Sources:
WP
assert_eq "$(pick "${DUMP}")" "70" "(b3) 'Built-in Audio Speaker' (70) chosen over HDMI (71)"

echo
echo "================ (c) HDMI only -> HDMI (fall-back) =============="
DUMP="${TMPDIR_T}/c.txt"
cat > "${DUMP}" <<'WP'
Audio
 ├─ Sinks:
 │  *   54. GP104 High Definition Audio Controller Digital Stereo (HDMI) [vol: 1.00]
 ├─ Sources:
WP
assert_eq "$(pick "${DUMP}")" "54" "(c) HDMI-only rig falls back to the HDMI sink (54)"

echo
echo "================ (d) USB headset + analog + HDMI -> analog ======"
DUMP="${TMPDIR_T}/d.txt"
cat > "${DUMP}" <<'WP'
Audio
 ├─ Sinks:
 │      53. sof-hda-dsp Speaker + Headphones      [vol: 0.40]
 │      54. GP104 Digital Stereo (HDMI)           [vol: 1.00]
 │  *   55. Generic USB Audio Headset             [vol: 1.00]
 ├─ Sources:
WP
assert_eq "$(pick "${DUMP}")" "53" "(d) onboard analog (53) preferred over USB headset (55) and HDMI (54)"

echo
echo "================ (e) USB headset + HDMI (no onboard) -> USB ====="
DUMP="${TMPDIR_T}/e.txt"
cat > "${DUMP}" <<'WP'
Audio
 ├─ Sinks:
 │  *   54. GP104 Digital Stereo (HDMI)           [vol: 1.00]
 │      55. Generic USB Audio Headset             [vol: 1.00]
 ├─ Sources:
WP
assert_eq "$(pick "${DUMP}")" "55" "(e) USB headset (55) chosen over HDMI (54) when no onboard analog"

echo
echo "================ (f) no sinks -> nothing (no-op safe) =========="
DUMP="${TMPDIR_T}/f.txt"
cat > "${DUMP}" <<'WP'
Audio
 ├─ Sinks:
 ├─ Sources:
 │      55. sof-hda-dsp Mic                       [vol: 1.00]
WP
assert_eq "$(pick "${DUMP}")" "" "(f) empty Sinks block -> empty pick (script will no-op)"

echo
echo "================ (g) AUDIO_SINK=HDMI override -> HDMI ==========="
DUMP="${TMPDIR_T}/g.txt"
cat > "${DUMP}" <<'WP'
Audio
 ├─ Sinks:
 │      53. sof-hda-dsp Speaker + Headphones      [vol: 0.40]
 │  *   54. GP104 Digital Stereo (HDMI)           [vol: 1.00]
 ├─ Sources:
WP
assert_eq "$(pick "${DUMP}" "HDMI")" "54" "(g) AUDIO_SINK=HDMI forces HDMI (54) despite analog present"
assert_eq "$(pick "${DUMP}" "USB")" "53" "(g2) AUDIO_SINK=USB (no match) -> heuristic still picks analog (53)"

echo
echo "================ (h) pulse-style node names -> analog ==========="
DUMP="${TMPDIR_T}/h.txt"
cat > "${DUMP}" <<'WP'
Audio
 ├─ Sinks:
 │      80. alsa_output.pci-0000_00_1f.3.analog-stereo [vol: 0.50]
 │  *   81. alsa_output.pci-0000_01_00.1.hdmi-stereo   [vol: 1.00]
 ├─ Sources:
WP
assert_eq "$(pick "${DUMP}")" "80" "(h) pulse-style analog-stereo node (80) chosen over hdmi-stereo (81)"

assert_summary "test-audio-sink" || exit 1
echo "test-audio-sink: ALL PASS"
