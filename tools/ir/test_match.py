"""M9 identify: model self-checks + vectors for the testbenches. Prints PASS or FAIL.

Writes (all from the bit-exact model in rxcap.py):
  build/ir_expected/m9_synth.txt  per code: proto d f t, then its first-frame
                                  mark-start intervals (tb_ir_synth)
  build/ir_expected/m9_marks.txt  raw receiver edges -> intervals (tb_rx_marks)
  build/ir_expected/m9_match.txt  a sequence of identify runs, fresh and
                                  narrowing, with the expected list (tb_ir_match)
Formats are whitespace-separated numbers, documented at each writer.
"""

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import ircompile  # noqa: E402
import irproto as ir  # noqa: E402
import library as lib  # noqa: E402
import rxcap  # noqa: E402
import test_rxcap as trx  # noqa: E402  (reuses its capture synthesis; runs its checks too)

ROOT = Path(__file__).resolve().parents[2]
EXP = ROOT / "build" / "ir_expected"
EXP.mkdir(parents=True, exist_ok=True)
types = trx.types
errors = []


def check(cond, what):
    if not cond:
        errors.append(what)


def edge_iv(name, d, f, t=0, frames=2, jitter=30, seed=1):
    ent = rxcap.edge_only(rxcap.envelope(name, d, f, t=t, frames=frames), jitter_us=jitter, seed=seed)
    return ent, rxcap.cap_intervals(rxcap.mark_starts(ent, 1))


# ---------------------------------------------------------------- synth vectors
# line: proto d(hex) f(hex) t n iv0 .. iv(n-1)
rng = random.Random(5)
lines = []
for pid, name in enumerate(ircompile.PROTO_ORDER):
    p = ir.PROTOCOLS[name]
    for trial in range(4):
        d, f = rng.getrandbits(32), rng.getrandbits(32)
        for t in (0, 1):
            iv = rxcap.intervals(rxcap.ref_starts(p, d, f, t))
            lines.append(f"{pid} {d:08x} {f:08x} {t} {len(iv)} " + " ".join(map(str, iv)))
(EXP / "m9_synth.txt").write_text(f"{len(lines)}\n" + "\n".join(lines) + "\n")

# ---------------------------------------------------------------- receiver vectors
# case: n_entries, then (level delta_clocks) pairs, then n_iv iv0 .. (expected)
cap = rxcap.parse((Path(__file__).parent / "fixtures" / "rx_v0.10.0_sony_power.sav").read_bytes())
p_sam, d_sam, f_sam, _ = trx.lib_code("TV", "SAMSUNG", "VOL_UP")
mark_cases = [(b["entries"], b["idle"]) for b in cap["bufs"]]
mark_cases.append((edge_iv("Samsung32", d_sam, f_sam)[0], 1))
mark_cases.append((edge_iv("RC6", 0x12, 0x34, t=1, frames=1)[0], 1))
out = [str(len(mark_cases))]
for ent, idle in mark_cases:
    assert idle == 1
    iv = rxcap.cap_intervals(rxcap.mark_starts(ent, idle))
    out.append(f"{len(ent)} " + " ".join(f"{lvl} {dl if i else 0}" for i, (lvl, dl) in enumerate(ent)))
    out.append(f"{len(iv)} " + " ".join(map(str, iv)))
(EXP / "m9_marks.txt").write_text("\n".join(out) + "\n")

# ---------------------------------------------------------------- identify sequence
# run: narrow n_iv iv... result n t b s ...
hw_iv = [rxcap.cap_intervals(rxcap.mark_starts(b["entries"], b["idle"])) for b in cap["bufs"]]
p_pw, d_pw, f_pw, _ = trx.lib_code("TV", "SAMSUNG", "POWER")
nec_none = (0x5A, 0x77)
assert not rxcap.match_library(edge_iv("NEC", *nec_none)[1], types)[0], "pick a NEC code that isn't in the library"
runs = [("sony hardware", False, hw_iv[0]),
        ("leaders only", False, hw_iv[1]),
        ("samsung vol+", False, edge_iv("Samsung32", d_sam, f_sam)[1]),
        ("samsung power (narrow)", True, edge_iv("Samsung32", d_pw, f_pw, seed=2)[1]),
        ("nec not in library (narrow)", True, edge_iv("NEC", *nec_none)[1]),
        ("leaders only (narrow)", True, hw_iv[1]),
        ("samsung vol+ again (narrow)", True, edge_iv("Samsung32", d_sam, f_sam, seed=3)[1]),
        ("nec not in library", False, edge_iv("NEC", *nec_none)[1])]
first = {}
for _, brands in types:
    for _, sets in brands:
        for _, cs in sets:
            for p, d, f, _l in cs.values():
                first.setdefault(p, (d, f))
for p, (d, f) in sorted(first.items()):
    name = ircompile.PROTO_ORDER[p]
    runs.append((f"{name} {d:X} {f:X}", False, edge_iv(name, d, f, t=1, jitter=40, seed=p)[1]))

prev, out, expect = None, [str(len(runs))], {}
for label, narrow, iv in runs:
    result, lst = rxcap.identify(iv, types, prev if narrow else None)
    expect[label] = (result, len(lst))
    if result in (0, 3) or (narrow and result == 2):
        prev = lst
    words = " ".join(f"{t} {b} {s}" for t, b, s in lst)
    out.append(f"{int(narrow)} {len(iv)} " + " ".join(map(str, iv)) + f" {result} {len(lst)} {words}")
(EXP / "m9_match.txt").write_text("\n".join(out) + "\n")

check(expect["sony hardware"] == (0, 10), f"sony hardware {expect['sony hardware']}")
check(expect["leaders only"] == (2, 0), f"leaders only {expect['leaders only']}")
check(expect["samsung vol+"] == (0, 44), f"samsung vol+ {expect['samsung vol+']}")
check(expect["samsung power (narrow)"] == (0, 28), f"narrow {expect['samsung power (narrow)']}")
check(expect["nec not in library (narrow)"] == (3, 28), f"no overlap {expect['nec not in library (narrow)']}")
check(expect["leaders only (narrow)"] == (2, 28), f"unreadable narrow {expect['leaders only (narrow)']}")
check(expect["samsung vol+ again (narrow)"] == (0, 28), f"same button again {expect['samsung vol+ again (narrow)']}")
check(expect["nec not in library"] == (1, 0), f"no match {expect['nec not in library']}")
check(all(r == 0 for k, (r, _) in expect.items() if k.split()[0] in ircompile.PROTO_ORDER), "every protocol found")
n_entries = sum(len(s) for _, br in types for _, s in br)
check(n_entries <= 1024 and max(len(s) for _, br in types for _, s in br) < 4096, "entry / set limits of ir_match")

if errors:
    for e in errors:
        print("  " + e)
    print(f"FAIL test_match ({len(errors)} errors)")
    sys.exit(1)
print(f"PASS test_match ({len(lines)} synth codes, {len(mark_cases)} receiver cases, {len(runs)} identify runs "
      "-> build/ir_expected/m9_*.txt)")
