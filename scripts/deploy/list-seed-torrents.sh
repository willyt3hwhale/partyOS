#!/usr/bin/env bash
# list-seed-torrents.sh - print the *.torrent files in a games dir that have a
# backing data blob, so the P2P seeder never tries to seed an orphan torrent.
#
# THE PROBLEM: server/games/ can accumulate orphan hash-named torrents
# (e.g. <sha1>.torrent) with no *.squashfs behind them. A blind `*.torrent` glob
# hands these to aria2c, which then carries them as failed/leech entries with no
# data to serve - noise at best, a stuck download attempt at worst.
#
# THE RULE: a torrent NAME.squashfs.torrent is seedable iff its backing data file
# NAME.squashfs exists next to it. Generically: strip the trailing .torrent; if
# that path is an existing regular file, the torrent has backing data and is
# printed. Orphan torrents (<sha1>.torrent with no <sha1> file) are skipped.
#
# Usage: list-seed-torrents.sh <games-dir>
#   Prints one torrent path per line (only the seedable ones), glob-sorted.
#   Exit 0 always - an empty list is not an error; the caller decides.
set -euo pipefail

DIR="${1:?usage: list-seed-torrents.sh <games-dir>}"
[ -d "${DIR}" ] || exit 0

shopt -s nullglob
for t in "${DIR}"/*.torrent; do
    data="${t%.torrent}"          # NAME.squashfs.torrent -> NAME.squashfs
    [ -f "${data}" ] || continue  # orphan torrent, no backing blob -> skip
    printf '%s\n' "${t}"
done
