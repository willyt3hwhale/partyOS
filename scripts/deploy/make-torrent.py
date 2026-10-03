#!/usr/bin/env python3
"""make-torrent.py - write a single-file .torrent with no external tools.

The party server is an aarch64 Raspberry Pi. It has no mktorrent package, and the
archlinux fallback container in gen-blob-torrents.sh is amd64-only. A mid-party
publish must not depend on either, so this module makes the torrent in pure
Python. It is byte-compatible with what gen-blob-torrents.sh produces: the same
piece-size tiers, the same name, the same comment, and the announce URL as a
top-level sibling of `info`.

Usage:
  make-torrent.py <file> <output.torrent> [--announce URL] [--comment TEXT]

The output is written to <output.torrent>.tmp and renamed, so a reader never sees
a half-written torrent.
"""

import hashlib
import os
import sys
import time


def bencode(value):
    """Return the bencoded form of value. Supports int, bytes, str, list, dict."""
    if isinstance(value, bool):
        raise TypeError("bencode does not accept bool")
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, str):
        value = value.encode("utf-8")
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, (list, tuple)):
        return b"l" + b"".join(bencode(v) for v in value) + b"e"
    if isinstance(value, dict):
        out = [b"d"]
        # Keys are sorted as raw byte strings. BEP 3 requires this order.
        for key in sorted(value):
            key_bytes = key.encode("utf-8") if isinstance(key, str) else key
            out.append(bencode(key_bytes))
            out.append(bencode(value[key]))
        out.append(b"e")
        return b"".join(out)
    raise TypeError("cannot bencode %r" % type(value))


def piece_length(size_bytes):
    """Return the piece size for a blob of size_bytes.

    The tiers match piece_l() in gen-blob-torrents.sh:
      below 1 GiB -> 256 KiB, 1 to 4 GiB -> 1 MiB, above 4 GiB -> 2 MiB.
    """
    if size_bytes >= 4 * 1024 * 1024 * 1024:
        return 1 << 21
    if size_bytes >= 1 * 1024 * 1024 * 1024:
        return 1 << 20
    return 1 << 18


def make_torrent(path, out_path, announce=None, comment=None):
    """Write a single-file torrent for path. Return the info-hash as hex."""
    size = os.path.getsize(path)
    plen = piece_length(size)

    pieces = bytearray()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(plen)
            if not chunk:
                break
            pieces += hashlib.sha1(chunk).digest()

    info = {
        "name": os.path.basename(path),
        "length": size,
        "piece length": plen,
        "pieces": bytes(pieces),
    }
    meta = {"info": info, "creation date": int(time.time())}
    if announce:
        meta["announce"] = announce
    if comment:
        meta["comment"] = comment

    info_hash = hashlib.sha1(bencode(info)).hexdigest()

    tmp = out_path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(bencode(meta))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, out_path)
    return info_hash


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    src, out = argv[1], argv[2]
    announce = comment = None
    rest = argv[3:]
    while rest:
        flag = rest.pop(0)
        if flag == "--announce":
            announce = rest.pop(0)
        elif flag == "--comment":
            comment = rest.pop(0)
        else:
            sys.stderr.write("make-torrent: unknown option: %s\n" % flag)
            return 2
    print(make_torrent(src, out, announce, comment))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
