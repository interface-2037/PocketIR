"""Self-checks for irproto.py and test vectors for the RTL.

Checks the reference encoder against facts proven on hardware (the Sony
STR-DH790 codes that work through ir_sirc_tx.v), then writes
build/ir_expected/sirc_ref.txt for sim/tb_ir_sirc_ref.v, which compares the
old SIRC encoder's envelope with these runs cycle for cycle.

Usage:  python tools/ir/test_irproto.py        (prints PASS or FAIL)
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import irproto as ir  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SIM_CLK = 1_000_000          # testbench clock: 1 MHz -> 600 us unit = 600 cycles

# Sony STR-DH790 table (mirror of src/fpga/core/ir/ir_code_rom.v), as
# (button, protocol, address, command). Verified on hardware at v0.1.1.
SONY_DH790 = [
    ("Start",  "SIRC15", 48, 21),  ("Select", "SIRC15", 48, 20),
    ("L1",     "SIRC15", 48, 18),  ("R1",     "SIRC15", 48, 19),
    ("Down",   "SIRC15", 176, 120), ("Up",    "SIRC15", 176, 121),
    ("Right",  "SIRC15", 176, 122), ("Left",  "SIRC15", 176, 123),
    ("Y",      "SIRC15", 48, 12),  ("X",      "SIRC20", 272, 125),
    ("B",      "SIRC15", 48, 83),  ("A",      "SIRC20", 272, 115),
]

errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


# 1. bit packing matches the codes proven on hardware / in LIRC
check(ir.sent_word("SIRC15", 48, 21) == 0x540C, "SIRC15 power word != 0x540C")
check(ir.sent_word("SIRC12", 16, 21) == 0xA81, "SIRC12 amp power word != 0xA81")

# 2. timing facts: 2.4 ms header, 600 us unit, 45 ms frames, 3 frames per tap
runs = ir.encode("SIRC15", 48, 21, clk_hz=SIM_CLK)
check(runs[0] == (1, 2400), f"header mark {runs[0]}")
check(runs[1] == (0, 600), f"header space {runs[1]}")
check(sum(n for _, n in runs) == 3 * 45_000, "tap is not 3 x 45 ms")
check(ir.unit_cycles(ir.PROTOCOLS["SIRC15"]) == 44_550, "600 us != 44550 cycles at 74.25 MHz")
check(len(ir.encode("SIRC15", 48, 21, frames=6, clk_hz=SIM_CLK)) > len(runs), "holding does not repeat")

# 3. every frame of every protocol fits inside its GapTo
for name in ir.PROTOCOLS:
    ir.frame_units(ir.PROTOCOLS[name], ir.PROTOCOLS[name].frame, 0x1FFF, 0x7F, 0)

# 4. vectors for the RTL comparison
out = ROOT / "build" / "ir_expected"
out.mkdir(parents=True, exist_ok=True)
with open(out / "sirc_ref.txt", "w") as f:
    for button, proto, addr, cmd in SONY_DH790:
        nbits = int(proto[4:])
        r = ir.encode(proto, addr, cmd, frames=3, clk_hz=SIM_CLK)
        f.write(f"{nbits} {addr} {cmd} {len(r)}\n")
        for level, n in r:
            f.write(f"{level} {n}\n")

# 5. engine vectors: microcode ROM at the test clock + cases to replay
import random  # noqa: E402
import ircompile  # noqa: E402

(out / "ir_proto_sim.hex").write_text("".join(f"{w:08X}\n" for w in ircompile.compile_rom(SIM_CLK)))
rng = random.Random(1)
cases = [(proto, addr, cmd, 1) for _, proto, addr, cmd in SONY_DH790]          # taps
cases += [("SIRC15", 48, 18, 5), ("SIRC20", 272, 125, 8)]                      # holds
for name in ircompile.PROTO_ORDER:                                             # random fields
    abits = {"SIRC12": 5, "SIRC15": 8, "SIRC20": 13}.get(name, 16)
    for _ in range(4):
        cases.append((name, rng.randrange(1 << abits), rng.randrange(128), rng.choice([1, 4])))
with open(out / "engine_cases.txt", "w") as f:
    for name, addr, cmd, frames in cases:
        p = ir.PROTOCOLS[name]
        r = ir.encode(name, addr, cmd, frames=frames, clk_hz=SIM_CLK)
        n = max(frames, p.min_frames)
        period = sum(c for _, c in r) // n
        # hold the key until halfway through the last wanted frame (tap: 2 cycles)
        hold = 2 if frames <= p.min_frames else (frames - 1) * period + period // 2
        f.write(f"{ircompile.PROTO_ORDER.index(name)} {addr} {cmd} {hold} {len(r)}\n")
        for level, c in r:
            f.write(f"{level} {c}\n")

if errors:
    print("FAIL test_irproto")
    for e in errors:
        print("  " + e)
    sys.exit(1)
print(f"PASS test_irproto ({len(SONY_DH790)} Sony vectors, {len(cases)} engine cases -> build/ir_expected/)")
