#!/usr/bin/env python3
# bt_tracker.py - a minimal HTTP BitTorrent tracker for partyOS blob distribution.
#
# partyOS blobs are distributed P2P only (no HTTP download path). On a LAN, LSD
# multicast can find peers, but multicast is switch-dependent and dies across some
# managed switches. This tracker gives clients a switch-independent unicast peer
# discovery path: every torrent's announce URL points here, peers register, and
# each announce reply hands back the current swarm. The server also runs a
# persistent seed that registers here, so a fresh client always finds at least the
# server. The default torrents have no web-seed. A completed download then proves
# real P2P.
#
# Stdlib only (no deps). BEP3 (bencode + compact peers, BEP23). Thread-safe.
#
# Usage: python3 server/bt_tracker.py [PORT] [BIND_IP]
#   defaults PORT=6969 BIND_IP=0.0.0.0 (all interfaces; run-servers.sh passes the real IP)
#   env PARTYOS_TRACKER_PORT / PARTYOS_TRACKER_IP override the CLI/defaults.
import ipaddress
import os
import signal
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote_to_bytes

INTERVAL = 30          # announce interval handed to clients (seconds)
MIN_INTERVAL = 15
PEER_TTL = 2 * INTERVAL  # prune peers not seen within this window
DEFAULT_NUMWANT = 50


# --- bencode encoder (no decoder needed for a tracker's announce path) --------
def bencode(x):
    if isinstance(x, bool):
        # bool is an int subclass; a stray bool would encode as 0/1 silently.
        raise TypeError("refusing to bencode a bool")
    if isinstance(x, int):
        return b"i" + str(x).encode("ascii") + b"e"
    if isinstance(x, bytes):
        return str(len(x)).encode("ascii") + b":" + x
    if isinstance(x, str):
        b = x.encode("utf-8")
        return str(len(b)).encode("ascii") + b":" + b
    if isinstance(x, (list, tuple)):
        return b"l" + b"".join(bencode(i) for i in x) + b"e"
    if isinstance(x, dict):
        # Keys must be byte strings, sorted by raw bytes (BEP3).
        items = []
        for k, v in x.items():
            kb = k if isinstance(k, bytes) else str(k).encode("utf-8")
            items.append((kb, v))
        items.sort(key=lambda kv: kv[0])
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in items) + b"e"
    raise TypeError("cannot bencode %r" % type(x))


def valid_ipv4(s):
    try:
        ipaddress.IPv4Address(s)
        return True
    except Exception:
        return False


def parse_raw_query(qs):
    # qs is the raw query string (str). info_hash/peer_id are RAW 20-byte binary
    # url-encoded, so parse_qs would corrupt them as utf-8: we unquote_to_bytes
    # each value ourselves and keep it as bytes. Returns {key(str): [bytes, ...]}.
    out = {}
    if not qs:
        return out
    for pair in qs.split("&"):
        if not pair:
            continue
        k, _sep, v = pair.partition("=")
        try:
            key = unquote_to_bytes(k).decode("ascii", "ignore")
        except Exception:
            continue
        out.setdefault(key, []).append(unquote_to_bytes(v))
    return out


class Tracker:
    # info_hash(bytes) -> { peer_id(bytes): [ip(str), port(int), last_seen(float), left(int)] }
    def __init__(self):
        self.lock = threading.Lock()
        self.swarms = {}

    def _prune(self, swarm, now):
        dead = [pid for pid, p in swarm.items() if now - p[2] > PEER_TTL]
        for pid in dead:
            del swarm[pid]

    def announce(self, info_hash, peer_id, ip, port, left, event, compact, numwant):
        now = time.time()
        with self.lock:
            swarm = self.swarms.setdefault(info_hash, {})
            if event == "stopped":
                swarm.pop(peer_id, None)
            else:
                swarm[peer_id] = [ip, port, now, left]
            self._prune(swarm, now)

            complete = sum(1 for p in swarm.values() if p[3] == 0)
            incomplete = len(swarm) - complete

            # Build the peer list, EXCLUDING the announcing peer from its own reply.
            if compact:
                peers = b""
                n = 0
                for pid, p in swarm.items():
                    if pid == peer_id:
                        continue
                    if n >= numwant:
                        break
                    try:
                        peers += socket.inet_aton(p[0]) + struct.pack(">H", p[1] & 0xFFFF)
                    except OSError:
                        continue
                    n += 1
            else:
                peers = []
                for pid, p in swarm.items():
                    if pid == peer_id:
                        continue
                    if len(peers) >= numwant:
                        break
                    peers.append({b"peer id": pid, b"ip": p[0], b"port": p[1]})

        resp = {
            b"interval": INTERVAL,
            b"min interval": MIN_INTERVAL,
            b"complete": complete,
            b"incomplete": incomplete,
            b"peers": peers,
        }
        return resp, complete, incomplete

    def scrape(self, info_hashes):
        now = time.time()
        files = {}
        with self.lock:
            keys = info_hashes if info_hashes else list(self.swarms.keys())
            for ih in keys:
                swarm = self.swarms.get(ih)
                if swarm is None:
                    continue
                self._prune(swarm, now)
                complete = sum(1 for p in swarm.values() if p[3] == 0)
                incomplete = len(swarm) - complete
                files[ih] = {
                    b"complete": complete,
                    b"incomplete": incomplete,
                    b"downloaded": 0,
                }
        return {b"files": files}

    def summary(self):
        with self.lock:
            torrents = len(self.swarms)
            total = sum(len(s) for s in self.swarms.values())
        return torrents, total


TRACKER = Tracker()


def _log(*parts):
    print(("[tracker %s] " % time.strftime("%H:%M:%S")) + " ".join(str(p) for p in parts), flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "partyos-tracker/1.0"

    # Silence the default per-request stderr spam; we log announces ourselves.
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="text/plain"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _fail(self, reason):
        self._send(400, bencode({b"failure reason": reason}))

    def do_GET(self):
        try:
            path, _sep, qs = self.path.partition("?")
            if path in ("/", "/health"):
                return self._health()
            if path == "/announce":
                return self._announce(qs)
            if path == "/scrape":
                return self._scrape(qs)
            self._send(404, "not found")
        except Exception as e:  # never crash a worker thread on a bad request
            try:
                self._fail("tracker error: %s" % e)
            except Exception:
                pass

    def _health(self):
        torrents, total = TRACKER.summary()
        self._send(
            200,
            "partyos-tracker ok\ntorrents=%d peers=%d\n" % (torrents, total),
        )

    def _announce(self, qs):
        params = parse_raw_query(qs)
        ih = params.get("info_hash", [b""])[0]
        pid = params.get("peer_id", [b""])[0]
        if len(ih) != 20:
            return self._fail("invalid info_hash (need 20 bytes)")
        if len(pid) != 20:
            return self._fail("invalid peer_id (need 20 bytes)")

        def as_int(name, default):
            vals = params.get(name)
            if not vals:
                return default
            try:
                return int(vals[0].decode("ascii", "ignore"))
            except Exception:
                return default

        port = as_int("port", 0)
        left = as_int("left", 0)
        numwant = as_int("numwant", DEFAULT_NUMWANT)
        if numwant < 0:
            numwant = DEFAULT_NUMWANT

        # compact defaults ON (aria2 sends compact=1; omit -> compact per spec here).
        compact_vals = params.get("compact")
        if compact_vals:
            try:
                compact = int(compact_vals[0].decode("ascii", "ignore")) != 0
            except Exception:
                compact = True
        else:
            compact = True

        event = params.get("event", [b""])[0].decode("ascii", "ignore") or "empty"

        # Peer IP: prefer a valid ip= param (aria2 --bt-external-ip sends it), else
        # the TCP source address of this announce.
        ip = None
        ipp = params.get("ip")
        if ipp:
            cand = ipp[0].decode("latin-1", "ignore").strip()
            if valid_ipv4(cand):
                ip = cand
        if ip is None:
            ip = self.client_address[0]

        resp, complete, incomplete = TRACKER.announce(
            ih, pid, ip, port, left, event, compact, numwant
        )
        _log(
            ih.hex()[:8],
            "event=%s" % event,
            "peer=%s:%d" % (ip, port),
            "left=%d" % left,
            "-> complete=%d incomplete=%d" % (complete, incomplete),
        )
        self._send(200, bencode(resp))

    def _scrape(self, qs):
        params = parse_raw_query(qs)
        ihs = [h for h in params.get("info_hash", []) if len(h) == 20]
        self._send(200, bencode(TRACKER.scrape(ihs)))


def main():
    port = 6969
    bind_ip = "0.0.0.0"
    if len(sys.argv) > 1 and sys.argv[1].strip():
        try:
            port = int(sys.argv[1])
        except ValueError:
            print("bt_tracker: bad PORT %r" % sys.argv[1], file=sys.stderr)
            sys.exit(2)
    if len(sys.argv) > 2 and sys.argv[2].strip():
        bind_ip = sys.argv[2].strip()
    # env overrides CLI/defaults
    if os.environ.get("PARTYOS_TRACKER_PORT"):
        port = int(os.environ["PARTYOS_TRACKER_PORT"])
    if os.environ.get("PARTYOS_TRACKER_IP"):
        bind_ip = os.environ["PARTYOS_TRACKER_IP"].strip()

    httpd = ThreadingHTTPServer((bind_ip, port), Handler)
    httpd.daemon_threads = True

    def _sig(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)

    _log("listening on %s:%d (interval=%ds)" % (bind_ip, port, INTERVAL))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        _log("shutting down")
        httpd.server_close()


if __name__ == "__main__":
    main()
