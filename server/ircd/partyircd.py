#!/usr/bin/env python3
"""partyircd - a tiny LAN IRC server for partyOS (NYET Messenger).

Minimal but functional: registration, channels, PRIVMSG/NOTICE relay, PING/PONG,
NAMES/TOPIC, PART/QUIT. No services, no modes beyond the basics - enough for a LAN
party to chat. Bind: 0.0.0.0:6667 by default (override: partyircd.py [host] [port]).
"""
import socket, select, sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "0.0.0.0"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 6667
SRV = "partyos.lan"
clients = {}        # sock -> {"nick","user","reg","chans":set()}


def send(sock, line):
    try:
        sock.sendall((line + "\r\n").encode("utf-8", "replace"))
    except OSError:
        pass


def prefix(c):
    return f"{c['nick']}!{c.get('user','x')}@lan"


def members(chan):
    return [s for s, c in clients.items() if chan in c["chans"]]


def to_chan(chan, line, exclude=None):
    for s in members(chan):
        if s is not exclude:
            send(s, line)


def register(sock):
    c = clients[sock]
    if c["reg"] or not (c.get("nick") and c.get("user")):
        return
    c["reg"] = True
    n = c["nick"]
    send(sock, f":{SRV} 001 {n} :Welcome to the partyOS LAN, {n}")
    send(sock, f":{SRV} 002 {n} :Your host is {SRV}, partyircd")
    send(sock, f":{SRV} 003 {n} :This is the party")
    send(sock, f":{SRV} 004 {n} {SRV} partyircd o o")
    send(sock, f":{SRV} 375 {n} :- {SRV} Message of the Day -")
    send(sock, f":{SRV} 372 {n} :- No internet. All party. Welcome to partyOS.")
    send(sock, f":{SRV} 376 {n} :End of /MOTD command.")


def join(sock, chan):
    c = clients[sock]
    if chan in c["chans"]:
        return
    c["chans"].add(chan)
    to_chan(chan, f":{prefix(c)} JOIN {chan}")
    names = " ".join(clients[s]["nick"] for s in members(chan))
    send(sock, f":{SRV} 332 {c['nick']} {chan} :Welcome to {chan} - chat away!")
    send(sock, f":{SRV} 353 {c['nick']} = {chan} :{names}")
    send(sock, f":{SRV} 366 {c['nick']} {chan} :End of /NAMES list.")


def handle(sock, raw):
    c = clients[sock]
    for line in raw.replace("\r", "\n").split("\n"):
        if not line:
            continue
        parts = line.split(" ")
        cmd = parts[0].upper()
        if cmd == "NICK":
            c["nick"] = parts[1] if len(parts) > 1 else "guest"
            register(sock)
        elif cmd == "USER":
            c["user"] = parts[1] if len(parts) > 1 else "guest"
            register(sock)
        elif cmd == "PING":
            send(sock, f":{SRV} PONG {SRV} :{line.split(':',1)[-1] if ':' in line else (parts[1] if len(parts)>1 else SRV)}")
        elif cmd == "JOIN":
            for ch in parts[1].split(","):
                if ch.startswith("#"):
                    join(sock, ch)
        elif cmd in ("PRIVMSG", "NOTICE"):
            tgt = parts[1]
            msg = line.split(" :", 1)[-1] if " :" in line else ""
            if tgt.startswith("#"):
                to_chan(tgt, f":{prefix(c)} {cmd} {tgt} :{msg}", exclude=sock)
            else:
                for s, cc in clients.items():
                    if cc.get("nick") == tgt:
                        send(s, f":{prefix(c)} {cmd} {tgt} :{msg}")
        elif cmd == "PART":
            ch = parts[1]
            if ch in c["chans"]:
                to_chan(ch, f":{prefix(c)} PART {ch}")
                c["chans"].discard(ch)
        elif cmd == "QUIT":
            drop(sock)
            return


def drop(sock):
    c = clients.pop(sock, None)
    if c:
        for ch in list(c["chans"]):
            to_chan(ch, f":{prefix(c)} QUIT :left")
    try:
        sock.close()
    except OSError:
        pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(50)
    srv.setblocking(False)
    print(f"partyircd on {HOST}:{PORT}", flush=True)
    while True:
        socks = [srv] + list(clients.keys())
        r, _, _ = select.select(socks, [], [], 1)
        for s in r:
            if s is srv:
                conn, _ = srv.accept()
                conn.setblocking(False)
                clients[conn] = {"nick": "", "user": "", "reg": False, "chans": set()}
            else:
                try:
                    data = s.recv(4096)
                except OSError:
                    data = b""
                if not data:
                    drop(s)
                else:
                    handle(s, data.decode("utf-8", "replace"))


if __name__ == "__main__":
    main()
