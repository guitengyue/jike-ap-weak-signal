#!/usr/bin/env python3
"""Verify supplied ROM modules; no images are included.

Dependencies: keystone-engine==0.9.2, unicorn==2.1.4, pyelftools==0.33
Usage: python tests/test_umac.py path/to/stock.ko [another/stock.ko ...]
All addressing is in private emulator memory. No AP, radio or network is used.
"""

import argparse
from hashlib import sha256
from io import BytesIO
from itertools import product
from pathlib import Path
import struct
import sys
from tempfile import TemporaryDirectory

from elftools.elf.elffile import ELFFile
from unicorn import Uc, UC_ARCH_ARM, UC_HOOK_CODE, UC_MODE_ARM
from unicorn.arm_const import (
    UC_ARM_REG_CPSR, UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2,
    UC_ARM_REG_R3, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R8, UC_ARM_REG_SP,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"tools"))
from build_umac import PROFILES, build, create_output, parse_mac


# IANA's EUI-48 documentation range, not a device from a real installation.
EXAMPLE = bytes.fromhex("00 00 5e 00 53 01")
REGULAR = bytes.fromhex("00 00 5e 00 53 a0")


def check_elf(original, patched, layout):
    before = ELFFile(BytesIO(original))
    after = ELFFile(BytesIO(patched))
    assert before.num_sections() == after.num_sections()
    assert len(patched) > len(original)
    for old, new in zip(before.iter_sections(), after.iter_sections()):
        assert old.name == new.name
        alignment = max(old["sh_addralign"], 1)
        assert old["sh_offset"] % alignment == new["sh_offset"] % alignment
        if old.name == ".text":
            assert new["sh_size"] - old["sh_size"] == len(patched) - len(original)
            changed = {i & ~3 for i,(a,b) in enumerate(zip(old.data(),new.data())) if a!=b}
            assert changed == {layout.assoc_hook, layout.rx_hook}
        else:
            assert old.data() == new.data(), old.name
    relocs = after.get_section_by_name(".rel.text")
    assert not any(r["r_offset"] in (layout.assoc_hook, layout.rx_hook) for r in relocs.iter_relocations())
    return after.get_section_by_name(".text").data()


def emulate(text, layout, exception_enabled):
    arm = Uc(UC_ARCH_ARM, UC_MODE_ARM)
    arm.mem_map(0, (len(text)+0xfff) & ~0xfff)
    arm.mem_write(0, text)
    vap, node, frame, stack = 0x210000, 0x218000, 0x219000, 0x21a000
    arm.mem_map(vap, 0x10000)

    stops, hit = set(), []
    def interrupt_at_endpoint(cpu, pc, size, userdata):
        if pc in stops:
            hit.append(pc)
            cpu.emu_stop()
    arm.hook_add(UC_HOOK_CODE, interrupt_at_endpoint)

    def run(address, endpoints):
        hit.clear()
        stops.clear()
        stops.update(endpoints)
        arm.emu_start(address, 0, count=80)
        assert len(hit) == 1
        return hit[0]

    # Stop just before the native call that sends the response to the station.
    send_response = 0x5c268 if layout.node_rssi == 0x297 else 0x5d188
    macs = [EXAMPLE, REGULAR]
    for i in range(6):
        neighbor = bytearray(EXAMPLE)
        neighbor[i] ^= 2 if i == 0 else 1
        macs.append(bytes(neighbor))
    thresholds = (-90,-89,-75,-70,-30)
    samples = [-32768,-129,*range(-128,128),128,199,255,511]
    count = 0
    for threshold, dbm, mac in product(thresholds, samples, macs):
        native = threshold == -90 or (exception_enabled and mac == EXAMPLE)
        arm.mem_write(vap+layout.vap_threshold, bytes([threshold%256]))
        arm.mem_write(node+layout.node_rssi, b"\x42"+mac)
        arm.mem_write(frame+12, struct.pack("<i", dbm))
        arm.reg_write(UC_ARM_REG_R5, vap)
        arm.reg_write(UC_ARM_REG_R6, node)
        arm.reg_write(UC_ARM_REG_R1, frame)
        arm.reg_write(UC_ARM_REG_SP, stack)
        arm.reg_write(UC_ARM_REG_CPSR, 0x13)  # Z=0 at the stock non-6 GHz dispatch.
        target = run(layout.rx_hook, {layout.stock_rx, layout.rx_hook+12})
        assert target == (layout.stock_rx if native else layout.rx_hook+12)
        expected_sample = 0x42 if native else dbm%256 if -126 <= dbm < 0 else 0
        assert arm.mem_read(node+layout.node_rssi,1) == bytes([expected_sample])
        arm.reg_write(UC_ARM_REG_R6, vap)
        arm.reg_write(UC_ARM_REG_R8, node)
        arm.reg_write(UC_ARM_REG_R0, 0x1234)
        target = run(layout.assoc_hook, {layout.assoc_hook+4, layout.pass_assoc, send_response})
        if native:
            assert target == layout.assoc_hook+4 and arm.reg_read(UC_ARM_REG_R0) == vap
        elif -126 <= dbm < threshold:
            assert target == send_response
            assert arm.reg_read(UC_ARM_REG_R2) == 34 and arm.reg_read(UC_ARM_REG_R3) == 0
        else:
            assert target == layout.pass_assoc
        count += 1
    return count


def check_inputs():
    for bad in ("*", "", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:00:5e:00:53:01",
                "0:0:5e:0:53:1", "00:00:5e:00:53:01 extra"):
        try:
            parse_mac(bad)
        except ValueError:
            continue
        raise AssertionError("Malformed or non-station address accepted")
    try:
        build(b"not a supported module")
    except ValueError:
        pass
    else:
        raise AssertionError("Unknown module accepted")

    with TemporaryDirectory() as temp:
        dest = Path(temp)/"demo.ko"
        create_output(dest,b"original")
        try:
            create_output(dest,b"replacement")
        except FileExistsError:
            pass
        else:
            raise AssertionError("Existing output overwritten")
        assert dest.read_bytes() == b"original"
        assert list(Path(temp).iterdir()) == [dest]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", nargs="+", type=Path)
    args = parser.parse_args()
    if not __debug__:
        parser.error("Run without -O so the offline checks are active.")
    check_inputs()
    total = 0
    for path in args.source:
        original = path.read_bytes()
        digest = sha256(original).hexdigest()
        if digest not in PROFILES:
            parser.error("The supplied file is not a supported stock module.")
        layout = PROFILES[digest]
        for mode in ("default", "explicit exception"):
            mac = None if mode == "default" else EXAMPLE.hex(":")
            patched = build(original, mac)
            assert patched == build(original, mac)
            text = check_elf(original, patched, layout)
            count = emulate(text, layout, mac is not None)
            total += count
            print(f"{layout.model} | {mode} | {count} RX + association cases | {sha256(patched).hexdigest()}")
        assert sha256(path.read_bytes()).hexdigest() == digest
    print(f"PASS: {total} paired ARM cases; ELF layout, input rejection and output retention verified.")


if __name__ == "__main__":
    main()
