#!/usr/bin/env python3
"""Build a minimum-RSSI admission patch from a supported, owner-supplied umac.ko.

Install keystone-engine==0.9.2. Run this on a workstation:
  python tools/build_umac.py stock.ko patched.ko [--exempt-mac MAC]

This tool only creates a new local file. A factory -90 dBm threshold retains
the original behavior. After separate integration, a configured business BSS
can use its native min_asoc_rssi value (-89 through -30 dBm). An invalid RX
sample does not cause a rejection. A configured exception bypasses only the
new admission policy. An independent low-signal kick policy must honor its
own exception. No credentials, login mechanism or firmware image are used.
"""

import argparse
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import struct
import tempfile


@dataclass(frozen=True)
class Layout:
    model: str
    text_size: int
    rx_hook: int
    stock_rx: int
    assoc_hook: int
    pass_assoc: int
    check_level: int
    vap_threshold: int
    node_rssi: int
    rx_expected: bytes


PROFILES = {
    "54171772269e778d3133174dcb6e5d677539e501a1cef2c975ca6a61fbda2319":
        Layout("AX1800MI / AX5RM 7.1_2022032400", 0x1483ac, 0x5706c, 0x5748c,
               0x5b518, 0x5b548, 0x5c240, 0xde8, 0x297, bytes.fromhex("0601001a")),
    "f8f83ac4c34a3eacbd32126785ed0cf61ff945eda09044335192c9fd2e25e0cc":
        Layout("N3000 7.2_2022111500", 0x165040, 0x57bf0, 0x57f7c,
               0x5c214, 0x5c240, 0x5d160, 0x122c, 0x2c7, bytes.fromhex("e100001a")),
    "9ece3e2c6bef524d0ee78fdc4af8363f44618e2b22978ad135631ca9b926cb50":
        Layout("N3000 8.0_2024061700", 0x165060, 0x57bf0, 0x57f7c,
               0x5c214, 0x5c240, 0x5d160, 0x122c, 0x2c7, bytes.fromhex("e100001a")),
}


def parse_mac(text):
    if not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", text):
        raise ValueError("Use a station MAC with six colon-separated hexadecimal octets.")
    address = bytes.fromhex(text.replace(":", ""))
    if address == bytes(6) or address[0] & 1:
        raise ValueError("The exception must be a nonzero unicast station address.")
    return address


def exception_check(address, node, offset, destination):
    """Match the aligned first four and remaining two octets of ni_macaddr."""
    if address is None:
        return ""
    first, middle, last = struct.unpack("<HHH", address)
    return f"""
        ldr r2,[{node},#{offset}]
        movw r3,#{first}
        movt r3,#{middle}
        cmp r2,r3
        addeq r2,{node},#{offset & ~255}
        ldrheq r2,[r2,#{(offset & 255)+4}]
        movweq r3,#{last}
        cmpeq r2,r3
        beq {destination}
    """


def build(original, exempt_mac=None):
    """Return new module bytes. Unknown stock inputs are rejected before assembly."""
    profile = PROFILES.get(hashlib.sha256(original).hexdigest())
    if profile is None:
        raise ValueError("Unsupported stock SHA-256. Extract an exact, unmodified supported ROM module.")
    address = None if exempt_mac is None else parse_mac(exempt_mac)
    from keystone import Ks, KS_ARCH_ARM, KS_MODE_ARM

    section_headers = struct.unpack_from("<I", original, 32)[0]
    entry_size, count = struct.unpack_from("<HH", original, 46)
    text_header = section_headers + entry_size
    text_offset, text_size = struct.unpack_from("<II", original, text_header + 16)
    if entry_size != 40 or text_offset != 0x38 or text_size != profile.text_size:
        raise ValueError("Unexpected ELF section layout.")
    assembler = Ks(KS_ARCH_ARM, KS_MODE_ARM)

    def assemble(source, address):
        return bytes(assembler.asm(source, addr=address)[0])

    # These ABIs share the same operand registers. The offsets and original
    # continuation addresses above are specific to the three exact binaries.
    mac_offset = profile.node_rssi + 1
    stock_rx = hex(profile.stock_rx)
    rx = assemble(f"""
        movw r2,#{profile.vap_threshold}
        ldrb r2,[r5,r2]
        cmp r2,#166
        beq {stock_rx}
        {exception_check(address, "r6", mac_offset, stock_rx)}
        ldr r3,[r1,#12]
        cmp r3,#0
        movge r3,#0
        cmn r3,#126
        movlt r3,#0
        b {profile.rx_hook+8:#x}
    """, text_size)

    # On original firmware r0 must be NULL when entering the native RSSI
    # comparison: its rejection branch forwards r0 as an optional IE pointer.
    # A -90 setting or an exempt station returns to the original OCE call.
    admit_offset = text_size + len(rx)
    admit = assemble(f"""
        movw r3,#{profile.vap_threshold}
        ldrb r3,[r6,r3]
        cmp r3,#166
        beq original_policy
        {exception_check(address, "r8", mac_offset, "original_policy")}
        movw r2,#{profile.node_rssi}
        ldrsb r2,[r8,r2]
        cmp r2,#0
        bge {profile.pass_assoc:#x}
        cmn r2,#126
        blt {profile.pass_assoc:#x}
        mov r0,#0
        b {profile.check_level:#x}
        original_policy:
        mov r0,r6
        b {profile.assoc_hook+4:#x}
    """, admit_offset)
    payload = rx + admit
    # Preserve the alignment of every section following .text.
    payload += bytes((-len(payload)) % 64)

    output = bytearray(original)
    hooks = [
        (profile.rx_hook, profile.rx_expected, f"bne {text_size:#x}"),
        (profile.assoc_hook, bytes.fromhex("0600a0e1"), f"b {admit_offset:#x}"),
    ]
    for relative, expected, jump in hooks:
        pos = text_offset + relative
        if original[pos:pos+4] != expected:
            raise ValueError(f"Unexpected instruction at .text+{relative:#x}")
        output[pos:pos+4] = assemble(jump, relative)

    insertion = text_offset + text_size
    for index in range(count):
        field = section_headers + index * entry_size + 16
        offset = struct.unpack_from("<I", original, field)[0]
        if offset >= insertion:
            struct.pack_into("<I", output, field, offset + len(payload))
    struct.pack_into("<I", output, text_header + 20, text_size + len(payload))
    struct.pack_into("<I", output, 32, section_headers + len(payload))
    output[insertion:insertion] = payload
    return bytes(output)


def create_output(destination, data):
    # Publish complete bytes only, and never overwrite an existing file, link,
    # or ROM module. Creating a hard link is atomic on NTFS and POSIX filesystems.
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as tmp:
        staging = Path(tmp.name)
    try:
        staging.write_bytes(data)
        os.link(staging, destination)
    finally:
        staging.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, help="Original ELF kernel module extracted from your ROM")
    parser.add_argument("output", type=Path, help="New local file on a filesystem supporting hard links")
    parser.add_argument("--exempt-mac", help="Optional single unicast station exception; default: none")
    args = parser.parse_args()
    try:
        original = args.source.read_bytes()
        data = build(original, args.exempt_mac)
        create_output(args.output, data)
    except (ValueError, OSError, ImportError) as exc:
        parser.exit(1, f"Build failed: {exc}\n")
    digest = hashlib.sha256(original).hexdigest()
    print(PROFILES[digest].model)
    print(f"Stock SHA-256   {digest}")
    print(f"Patched SHA-256 {hashlib.sha256(data).hexdigest()}")
    print(f"Wrote {len(data)} bytes to {args.output}")


if __name__ == "__main__":
    main()
