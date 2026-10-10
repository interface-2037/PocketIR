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
    # hardware-verified on the STR-DH790 (v0.1.1 - v0.6.0, the retired ir_code_rom.v);
    # deliberately a separate copy, not the builder's SONY_DH790 table
    hw = {"POWER": (P("SIRC15"), 48, 21), "MUTE": (P("SIRC15"), 48, 20),
          "VOL_UP": (P("SIRC15"), 48, 18), "VOL_DOWN": (P("SIRC15"), 48, 19),
          "UP": (P("SIRC15"), 176, 120), "DOWN": (P("SIRC15"), 176, 121),
          "LEFT": (P("SIRC15"), 176, 122), "RIGHT": (P("SIRC15"), 176, 123),
          "OK": (P("SIRC15"), 48, 12), "BACK": (P("SIRC20"), 272, 125),
          "MENU": (P("SIRC15"), 48, 83), "INPUT": (P("SIRC20"), 272, 115)}
    cs = sony[0][1]
    for f, code in hw.items():
        check(f in cs and cs[f][:3] == code, f"Sony {f}: library {cs.get(f)} != hardware {code}")

# Samsung TVs: the standard Samsung32 set (device 7) with the published commands
sam = by_type["TV"].get("SAMSUNG", [])
std = [cs for _, cs in sam if all(cs.get(f, (0, 0, -1))[:3] == (P("Samsung32"), 7, c) for f, c in
                                  [("POWER", 2), ("VOL_UP", 7), ("VOL_DOWN", 11), ("MUTE", 15), ("INPUT", 1)])]
check(len(sam) >= 10, f"only {len(sam)} Samsung TV sets")
check(len(std) >= 3, f"only {len(std)} standard Samsung TV sets (Samsung32 dev 7, power 2, vol 7/11, mute 15, source 1)")

# vectors for sim/tb_remote.v: what dev_ctrl.v must load for Sony and Samsung
sys.path.insert(0, str(ROOT / "tools" / "ui"))
import ui_text  # noqa: E402

out = ROOT / "build" / "ir_expected"
out.mkdir(parents=True, exist_ok=True)
for tag, (tname, bname, si) in {"sony": ("RECEIVER", "SONY", 0), "samsung": ("TV", "SAMSUNG", 0)}.items():
    ti = list(lib.TYPES).index(tname)
    bi = list(by_type[tname]).index(bname)
    model, cs = by_type[tname][bname][si]
    slots = ui_text.main_slots(f"{bname} {tname}"[:31], model, cs)
    with open(out / f"dev_{tag}.txt", "w") as fh:
        fh.write(f"{ti} {bi} {si}\n")
        for k, f in enumerate(lib.FUNCS):
            p, d, fw, _ = cs.get(f, (0, 0, 0, ""))
            fh.write(f"{int(f in cs)} {p:x} {d:x} {fw:x}\n")
        for s in slots:
            t = s.text[:31]
            fh.write(f"{s.word():x} {len(t)} " + " ".join(f"{ord(c):x}" for c in t) + "\n")

if errors:
    print("FAIL test_library")
    for e in errors[:20]:
        print("  " + e)
    sys.exit(1)
n = sum(len(s) for _, br in types for _, s in br)
print(f"PASS test_library ({n} menu entries, {len(data) / 1024:.1f} KB; Sony verified set + {len(std)} standard Samsung TV sets)")
