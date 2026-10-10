"""Self-checks for irproto.py and test vectors for the RTL.

1. The reference encoder against facts independent of our definitions: codes
   proven on hardware (Sony STR-DH790) and well-known published codes (LG,
   Samsung, Philips power), plus timing facts and Kaseikyo checksums.
2. Vectors:
   build/ir_expected/ir_proto_sim.hex (microcode at the 1 MHz test clock) and
   build/ir_expected/engine_cases.txt (every protocol: taps, holds, toggles).

Usage:  python tools/ir/test_irproto.py        (prints PASS or FAIL)
"""

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import ircompile  # noqa: E402
import irproto as ir  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SIM_CLK = 1_000_000          # testbench clock: 1 tick (4 us) = 4 cycles

# Sony STR-DH790 table (mirror of src/fpga/core/ir/ir_code_rom.v), as
# (button, protocol, address, command). Verified on hardware at v0.1.1 / v0.5.0.
SONY_DH790 = [
    ("Start",  "SIRC15", 48, 21),  ("Select", "SIRC15", 48, 20),
    ("L1",     "SIRC15", 48, 18),  ("R1",     "SIRC15", 48, 19),
    ("Down",   "SIRC15", 176, 120), ("Up",    "SIRC15", 176, 121),
    ("Right",  "SIRC15", 176, 122), ("Left",  "SIRC15", 176, 123),
    ("Y",      "SIRC15", 48, 12),  ("X",      "SIRC20", 272, 125),
    ("B",      "SIRC15", 48, 83),  ("A",      "SIRC20", 272, 115),
]

# address / command widths per protocol (for random test fields)
WIDTHS = {"SIRC12": (5, 7), "SIRC15": (8, 7), "SIRC20": (13, 7), "NEC": (8, 8),
          "NECext": (16, 16), "Samsung32": (8, 8), "RC5": (5, 6), "RC5X": (5, 6),
          "RC6": (8, 8), "Kaseikyo": (26, 10), "RCA": (4, 8), "Pioneer": (8, 8)}

errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


# ---------------------------------------------------------------- 1. facts
# bit packing: hardware-proven Sony codes and well-known published codes
check(ir.sent_word("SIRC15", 48, 21) == 0x540C, "SIRC15 STR-DH790 power != 0x540C")
check(ir.sent_word("SIRC12", 16, 21) == 0xA81, "SIRC12 amp power != 0xA81")
check(ir.sent_word("NEC", 0x04, 0x08) == 0x20DF10EF, "NEC LG TV power != 0x20DF10EF")
check(ir.sent_word("Samsung32", 0x07, 0x02) == 0xE0E040BF, "Samsung32 TV power != 0xE0E040BF")
check(ir.sent_word("RC5", 0, 12) == 0x300C, "RC5 Philips TV power != 0x300C")
check(ir.sent_word("NECext", 0x7201, 0xE11E) == int(f"{0x7201:016b}"[::-1] + f"{0xE11E:016b}"[::-1], 2),
      "NECext is not 16-bit address + 16-bit command, LSB first")

# timings
s = ir.encode("SIRC15", 48, 21, clk_hz=SIM_CLK)
check(s[0] == (1, 2400) and s[1] == (0, 600), f"SIRC header {s[:2]}")
check(sum(n for _, n in s) == 3 * 45_000, "SIRC tap is not 3 x 45 ms")
check(ir.tick_cycles() == 297, "4 us != 297 cycles at 74.25 MHz")
n = ir.encode("NEC", 4, 8, frames=3, clk_hz=SIM_CLK)
check(n[0] == (1, 9000) and n[1] == (0, 4500), f"NEC header {n[:2]}")
check(sum(c for _, c in n) == 3 * 110_000, "NEC frames are not 110 ms apart")
check(n[-4] == (1, 9000) and n[-3][1] in (2248, 2252) and n[-2] == (1, 560), f"NEC repeat code {n[-4:]}")
r5 = ir.encode("RC5", 0, 12, clk_hz=SIM_CLK)
check(r5[0] == (0, 888), "RC5 does not start with a half-bit space")
r6a = ir.encode("RC6", 0, 12, toggle=0, clk_hz=SIM_CLK)
r6b = ir.encode("RC6", 0, 12, toggle=1, clk_hz=SIM_CLK)
check(r6a != r6b, "RC6 toggle bit has no effect")
check(r6a[0] == (1, 2668) or r6a[0] == (1, 2664), f"RC6 leader {r6a[0]}")

# Kaseikyo packing: vendor parity nibble and XOR checksum byte
for addr, cmd in [(0x02002000, 0x1A0), (0x03123456, 0x3FF), (0, 0)]:
    d, f = ir.PROTOCOLS["Kaseikyo"].pack(addr, cmd)
    b = [(d >> 8 * i) & 0xFF for i in range(4)] + [f & 0xFF, f >> 8]
    check(b[5] == b[2] ^ b[3] ^ b[4], f"Kaseikyo checksum {addr:#x}/{cmd:#x}")
    check(b[2] & 0xF == (b[0] ^ b[1]) & 0xF, f"Kaseikyo vendor parity {addr:#x}")
    check(b[0] | b[1] << 8 == (addr >> 8) & 0xFFFF, f"Kaseikyo vendor {addr:#x}")

# every protocol: frames fit their GapTo and compile
for name in ir.PROTOCOLS:
    p = ir.PROTOCOLS[name]
    aw, cw = WIDTHS[name]
    d, f = p.pack((1 << aw) - 1, (1 << cw) - 1)          # all-ones fields: longest frame
    ir.frame_ticks(p, p.frame, d, f, 1)
check(set(ircompile.PROTO_ORDER) == set(ir.PROTOCOLS), "PROTO_ORDER does not list every protocol")

# ---------------------------------------------------------------- 2. vectors
out = ROOT / "build" / "ir_expected"
out.mkdir(parents=True, exist_ok=True)

(out / "ir_proto_sim.hex").write_text("".join(f"{w:08X}\n" for w in ircompile.compile_rom(SIM_CLK)))

rng = random.Random(1)
cases = [(proto, addr, cmd, 1) for _, proto, addr, cmd in SONY_DH790]          # Sony taps
cases += [("SIRC15", 48, 18, 5), ("SIRC20", 272, 125, 8)]                      # Sony holds
cases += [("NEC", 4, 8, 1), ("Samsung32", 7, 2, 1), ("RC5", 0, 12, 1)]         # published codes
for name in ircompile.PROTO_ORDER:                                             # random fields
    aw, cw = WIDTHS[name]
    for frames in (1, 1, 3, 4):
        cases.append((name, rng.randrange(1 << aw), rng.randrange(1 << cw), frames))
with open(out / "engine_cases.txt", "w") as fh:
    for k, (name, addr, cmd, frames) in enumerate(cases):
        p = ir.PROTOCOLS[name]
        toggle = k % 2                       # the engine flips T on every press, starting at 0
        r = ir.encode(name, addr, cmd, toggle=toggle, frames=frames, clk_hz=SIM_CLK)
        # frame lengths -> hold the key until halfway through the last wanted frame
        d, f = p.pack(addr, cmd)
        lens = [sum(t for _, t in ir.frame_ticks(p, p.frame if i == 0 or p.repeat is None else p.repeat,
                                                 d, f, toggle)) * ir.tick_cycles(SIM_CLK)
                for i in range(max(frames, p.min_frames))]
        hold = 2 if frames <= p.min_frames else sum(lens[:-1]) + lens[-1] // 2
        if r and r[0][0] == 0:               # the testbench measures from the first mark
            r = r[1:]
        carrier = round(SIM_CLK / p.carrier_hz)
        # engine inputs are the packed fields (D, F), written in hex
        fh.write(f"{ircompile.PROTO_ORDER.index(name)} {d:x} {f:x} {hold} {carrier} {len(r)}\n")
        fh.writelines(f"{lv} {c}\n" for lv, c in r)

if errors:
    print("FAIL test_irproto")
    for e in errors:
        print("  " + e)
    sys.exit(1)
print(f"PASS test_irproto ({len(ir.PROTOCOLS)} protocols, {len(cases)} engine cases -> build/ir_expected/)")
