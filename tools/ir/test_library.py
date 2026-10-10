"""Self-checks for the IR code library ROM (src/fpga/core/lib/ir_lib.hex).

Reads the committed ROM back with library.read_library() (no Flipper-IRDB
checkout needed) and checks it against facts that don't depend on the builder:
the hardware-verified Sony STR-DH790 codes and the well-known Samsung TV codes.

Usage:  python tools/ir/test_library.py        (prints PASS or FAIL)
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import ircompile  # noqa: E402
import library as lib  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


data = bytes(int(x, 16) for x in (ROOT / "src/fpga/core/lib/ir_lib.hex").read_text().split())
types = lib.read_library(data)                      # also checks magic, size, counts
by_type = {t: dict(brands) for t, brands in types}
P = ircompile.PROTO_ORDER.index

# size budget: the whole on-chip memory is ~385 KB; picture + fonts need ~60 KB
check(len(data) < 150 * 1024, f"library is {len(data)} bytes (> 150 KB budget)")
check(list(by_type) == list(lib.TYPES), "device types missing or out of order")

# every code uses a protocol the engine knows, labels fit the screen
for t, brands in types:
    for b, sets in brands:
        check(all(len(b) <= 20 for _ in [0]), f"brand name too long: {b}")
        for model, cs in sets:
            for f, (p, d, fw, label) in cs.items():
                check(0 <= p < len(ircompile.PROTO_ORDER), f"{t}/{b}/{model} {f}: protocol {p}")
                check(len(label) <= 9, f"{t}/{b}/{model} {f}: label {label!r} too long")

# Sony STR-DH790: first Sony receiver set, identical to the verified table
sony = by_type["RECEIVER"].get("SONY", [])
check(bool(sony) and sony[0][0] == "STR-DH790 VERIFIED", "verified Sony set is not first under RECEIVER/SONY")
if sony:
    # compare with the table that runs on hardware today (ir_code_rom.v), not the builder's copy
    import re
    bit_to_func = {15: "POWER", 14: "MUTE", 8: "VOL_UP", 9: "VOL_DOWN", 1: "UP", 0: "DOWN",
                   3: "LEFT", 2: "RIGHT", 7: "OK", 6: "BACK", 5: "MENU", 4: "INPUT"}
    rom = (ROOT / "src/fpga/core/ir/ir_code_rom.v").read_text()
    hw = {bit_to_func[int(b)]: (P("SIRC" + s), int(a), int(c)) for b, s, a, c in re.findall(
        r"4'd(\d+):\s*begin proto = S(15|20); address = 13'd(\d+);\s*command = 7'd(\d+);", rom)}
    check(len(hw) == 12, f"parsed {len(hw)} entries from ir_code_rom.v")
    cs = sony[0][1]
    for f, code in hw.items():
        check(f in cs and cs[f][:3] == code, f"Sony {f}: library {cs.get(f)} != hardware {code}")

# Samsung TVs: the standard Samsung32 set (device 7) with the published commands
sam = by_type["TV"].get("SAMSUNG", [])
std = [cs for _, cs in sam if all(cs.get(f, (0, 0, -1))[:3] == (P("Samsung32"), 7, c) for f, c in
                                  [("POWER", 2), ("VOL_UP", 7), ("VOL_DOWN", 11), ("MUTE", 15), ("INPUT", 1)])]
check(len(sam) >= 10, f"only {len(sam)} Samsung TV sets")
check(len(std) >= 3, f"only {len(std)} standard Samsung TV sets (Samsung32 dev 7, power 2, vol 7/11, mute 15, source 1)")

if errors:
    print("FAIL test_library")
    for e in errors[:20]:
        print("  " + e)
    sys.exit(1)
n = sum(len(s) for _, br in types for _, s in br)
print(f"PASS test_library ({n} menu entries, {len(data) / 1024:.1f} KB; Sony verified set + {len(std)} standard Samsung TV sets)")
