#!/usr/bin/env python3
"""make-selftest-image.py - generate a trivial 512-byte MBR boot sector that
writes a marker string to the COM1 serial port (0x3F8) and then halts.

This is the fixture for the harness self-test: a minimal bootable
"VM payload" with no kernel, no OS, no downloads - it exists only to prove that
the harness can boot a real VM and detect a known string on the serial console.

The boot sector is hand-assembled real-mode x86 (the BIOS loads it at
0000:7C00 and jumps there in 16-bit mode). For each character it polls the
UART Line Status Register (0x3FD, bit 5 = transmit-holding-register empty),
then writes the byte to the Transmit Holding Register (0x3F8). After the whole
string it does `cli; hlt` in a loop.

Usage: make-selftest-image.py OUTPUT.img [MARKER_STRING]
"""
import sys

DEFAULT_MARKER = "PARTYOS-HARNESS-SELFTEST-OK"


def build(marker: str) -> bytes:
    msg = (marker + "\r\n").encode("ascii")

    code = bytearray()

    def emit(*bs):
        code.extend(bs)

    # cli
    emit(0xFA)
    # xor ax,ax ; mov ds,ax ; mov es,ax  (flat-ish segments)
    emit(0x31, 0xC0)              # xor ax, ax
    emit(0x8E, 0xD8)              # mov ds, ax
    emit(0x8E, 0xC0)             # mov es, ax
    # mov si, msg   (absolute offset of the message within the loaded sector;
    # loaded at 0x7C00, so SI = 0x7C00 + msg_offset. We patch this after layout.)
    si_patch = len(code) + 1
    emit(0xBE, 0x00, 0x00)        # mov si, 0x0000 (patched)

    # .next_char:
    next_char = len(code)
    emit(0xAC)                    # lodsb            ; AL = [DS:SI], SI++
    # test al,al ; jz .done
    emit(0x84, 0xC0)             # test al, al
    jz_done_at = len(code)
    emit(0x74, 0x00)             # jz rel8 (patched)
    # mov ah, al   (save char)
    emit(0x88, 0xC4)             # mov ah, al
    # .wait_thre: poll LSR (0x3FD) bit5
    wait_thre = len(code)
    emit(0xBA, 0xFD, 0x03)        # mov dx, 0x03FD
    emit(0xEC)                   # in al, dx
    emit(0xA8, 0x20)            # test al, 0x20
    je_wait_at = len(code)
    emit(0x74, 0x00)            # jz rel8 -> wait_thre (patched)
    # write char: mov al, ah ; mov dx, 0x3F8 ; out dx, al
    emit(0x88, 0xE0)            # mov al, ah
    emit(0xBA, 0xF8, 0x03)       # mov dx, 0x03F8
    emit(0xEE)                  # out dx, al
    # jmp .next_char
    jmp_next_at = len(code)
    emit(0xEB, 0x00)            # jmp rel8 (patched)

    # .done: cli ; hlt ; jmp .done
    done = len(code)
    emit(0xFA)                 # cli
    halt = len(code)
    emit(0xF4)                 # hlt
    emit(0xEB, 0xFD)           # jmp halt (-3)

    # message bytes follow the code
    msg_off = len(code)
    code.extend(msg)

    # --- patch relative jumps (rel8 = target - (addr_of_rel_byte + 1)) ---
    code[jz_done_at + 1] = (done - (jz_done_at + 2)) & 0xFF
    code[je_wait_at + 1] = (wait_thre - (je_wait_at + 2)) & 0xFF
    code[jmp_next_at + 1] = (next_char - (jmp_next_at + 2)) & 0xFF

    # patch SI = 0x7C00 + msg_off
    si_val = 0x7C00 + msg_off
    code[si_patch] = si_val & 0xFF
    code[si_patch + 1] = (si_val >> 8) & 0xFF

    if len(code) > 510:
        raise SystemExit("boot sector too large: %d bytes" % len(code))

    sector = bytearray(512)
    sector[: len(code)] = code
    sector[510] = 0x55   # boot signature
    sector[511] = 0xAA
    return bytes(sector)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: make-selftest-image.py OUTPUT.img [MARKER]", file=sys.stderr)
        return 2
    out = sys.argv[1]
    marker = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_MARKER
    with open(out, "wb") as f:
        f.write(build(marker))
    print("wrote %s (marker=%r)" % (out, marker))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
