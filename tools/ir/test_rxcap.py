"""Self-checks for rxcap.py (M9 step 1 capture decoder). Prints PASS or FAIL.

Synthesises receiver captures from the reference encoder (demodulated with
stretched marks, and raw with carrier pulses, both polarities), packs them the
way ir_rx_cap.v does, and checks that the analysis finds the polarity, raw vs
demodulated, the carrier, the protocol and code, and the library entry.
"""

import random
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import irproto as ir  # noqa: E402
import library as lib  # noqa: E402
import rxcap  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CLK = ir.CLK_HZ
errors = []


def check(cond, what):
    if not cond:
        errors.append(what)


def envelope(name, d, f, t=0, frames=1, stretch_us=0):
    """Reference press as envelope runs (1 = mark, clocks), from the first mark;
    marks longer and spaces shorter by stretch_us (demodulating receivers do this)."""
    p = ir.PROTOCOLS[name]
    u = ir.tick_cycles()
    out = []
    for i in range(max(frames, p.min_frames)):
        ops = p.frame if (i == 0 or p.repeat is None) else p.repeat
        for lvl, n in ir.frame_ticks(p, ops, d, f, t):
            if out and out[-1][0] == lvl:
                out[-1] = (lvl, out[-1][1] + n * u)
            else:
                out.append((lvl, n * u))
    while out and out[0][0] == 0:
        out.pop(0)
    s = round(stretch_us * CLK / 1e6)
    return [(lvl, n + s if lvl else n - s) for lvl, n in out]


def capture(env, idle, raw=None, duty=0.33):
    """Envelope -> one buffer's entries as the RTL records them."""
    if raw:
        runs = rxcap.modulate(env, raw, duty, idle)
    else:
        runs = [(1 - idle if lvl else idle, n) for lvl, n in env]
    return rxcap.entries_from_runs(runs, idle)


def save_file(bufs, active):
    return bytes(32) + rxcap.build(bufs, active)


image = bytes(int(x, 16) for x in (ROOT / "src/fpga/core/lib/ir_lib.hex").read_text().split())
types = lib.read_library(image)


def lib_code(tname, bname, func, set_index=0):
    for t, brands in types:
        if t == tname:
            for b, sets in brands:
                if b == bname:
                    return sets[set_index][1][func]
    raise KeyError((tname, bname))


# ---- 1. layout round trip
ent = capture(envelope("NEC", 0x04, 0x08), idle=1)
cap = rxcap.parse(save_file([None, (ent, 1, {})], active=1))
check(cap["magic"] and cap["active"] == 1 and cap["depth"] == 4096, "header round trip")
check(cap["bufs"][1]["entries"] == ent and cap["bufs"][1]["n"] == len(ent), "entries round trip")
check(cap["bufs"][0]["n"] == 0, "empty buffer")
check(rxcap.parse(bytes(32)) is None, "32-byte file has no capture")
check(rxcap.parse(bytes(32) + struct.pack(">I", 0xFFFFFFFF) + bytes(28))["magic"] is False, "0xFF header = empty")


def first_decode(entries, idle, frame=0):
    a = rxcap.analyse({"entries": entries, "idle": idle})
    return a, (rxcap.decode(a["frames"][frame]) if len(a["frames"]) > frame else [])


def has(matches, proto, d=None, f=None, t=None, repeat=False):
    return any(m["proto"] == proto and m["repeat"] == repeat and
               (repeat or ((d is None or m["d"] == d) and (f is None or m["f"] == f) and
                           (t is None or m["t"] == t))) for m in matches)


# ---- 2. Samsung32 from the library, demodulated, idle high, marks +80 us
p, d, f, _ = lib_code("TV", "SAMSUNG", "VOL_UP")
check(p == 5, "Samsung TV set 0 uses Samsung32")
ent = capture(envelope("Samsung32", d, f, frames=2, stretch_us=80), idle=1)
a, m = first_decode(ent, 1)
check(a["idle"] == 1 and not a["raw"] and a["alternates"], "Samsung: demodulated, idle high")
check(len(a["frames"]) == 2, f"Samsung: 2 frames (got {len(a['frames'])})")
check(has(m, "Samsung32", d, f), f"Samsung32 decode {m}")
check(any(abs(x["mark_err"] - 80) < 2 and abs(x["space_err"] + 80) < 2 for x in m), "Samsung: timing error measured")
hits = rxcap.library_hits(types, next(x for x in m if x["proto"] == "Samsung32"))
check(any("SAMSUNG" in h and h.endswith("VOL_UP") for h in hits), "Samsung: library hit")
_, m2 = first_decode(ent, 1, frame=1)
check(has(m2, "Samsung32", repeat=True), f"Samsung repeat frame {m2}")

# ---- 3. Sony SIRC15 (STR-DH790 power), raw 40 kHz carrier, idle low
ent = capture(envelope("SIRC15", 48, 21), idle=0, raw=40_000, duty=0.33)
a, m = first_decode(ent, 0)
check(a["raw"] and a["idle"] == 0, "SIRC: raw, idle low")
check(a["carrier_hz"] and abs(a["carrier_hz"] - 40_000) < 400, f"SIRC carrier {a['carrier_hz']}")
check(a["duty"] and abs(a["duty"] - 0.33) < 0.03, f"SIRC duty {a['duty']}")
check(len(a["frames"]) == 3, f"SIRC: 3 frames (got {len(a['frames'])})")
check(has(m, "SIRC15", 48, 21) and not has(m, "SIRC12") and not has(m, "SIRC20"), f"SIRC15 decode {m}")

# ---- 4. NEC raw 38 kHz, active low; NECext reads the same frame
ent = capture(envelope("NEC", 0x04, 0x08, frames=2), idle=1, raw=38_000, duty=0.5)
a, m = first_decode(ent, 1)
check(a["raw"] and abs(a["carrier_hz"] - 38_000) < 400, f"NEC raw carrier {a['carrier_hz']}")
check(has(m, "NEC", 0x04, 0x08) and has(m, "NECext", 0xFB04, 0xF708), f"NEC decode {m}")
_, m2 = first_decode(ent, 1, frame=1)
check(has(m2, "NEC", repeat=True), f"NEC repeat {m2}")

# ---- 5. RC5 (toggle 1) and RC6, demodulated, slight stretch
for name, dd, ff, tt in (("RC5", 0, 12, 1), ("RC5X", 5, 40, 0), ("RC6", 0, 0x0C, 1), ("RC6", 0x12, 0x80, 0)):
    ent = capture(envelope(name, dd, ff, t=tt, stretch_us=60), idle=1)
    a, m = first_decode(ent, 1)
    check(has(m, name, dd, ff, tt), f"{name} D={dd} F={ff} T={tt} decode {m}")
    others = [x["proto"] for x in m if x["proto"] != name]
    check(not others, f"{name}: also matched {others}")

# ---- 6. Kaseikyo stores packed words (library convention)
pd, pf = ir.PROTOCOLS["Kaseikyo"].pack(0x02002020 & 0x3FFFFFF, 0x3D)
ent = capture(envelope("Kaseikyo", pd, pf), idle=1, raw=36_700, duty=0.4)
a, m = first_decode(ent, 1)
check(has(m, "Kaseikyo", pd, pf), f"Kaseikyo decode {m}")

# ---- 7. every protocol with random codes, demodulated and raw
rng = random.Random(9)
for name, p in ir.PROTOCOLS.items():
    sends = [op for op in p.frame if isinstance(op, ir.Send)]
    width = {s: max([op.lsb + op.count for op in sends if op.src == s] or [0]) for s in "DF"}
    for trial in range(4):
        dd, ff = rng.getrandbits(width["D"] or 1) % (1 << width["D"]), rng.getrandbits(width["F"] or 1) % (1 << width["F"])
        raw = (None, 38_000)[trial % 2]
        ent = capture(envelope(name, dd, ff, stretch_us=40 if raw is None else 0), idle=trial // 2 % 2, raw=raw)
        a, m = first_decode(ent, trial // 2 % 2)
        check(has(m, name, dd, ff), f"random {name} D={dd:X} F={ff:X} raw={raw}: {m}")

# ---- 8. mark-start matching, edge-only receiver (hardware v0.10.0: carrier pulses for the
#         first ~100-300 us of each mark only, idle high)
def edge_only(env, onset_us=120, jitter_us=0, seed=1):
    """Envelope -> what the Pocket's receiver shows: carrier pulses at each mark's start only;
    each mark start moved by up to +-jitter_us."""
    r = random.Random(seed)
    on = round(onset_us * CLK / 1e6)
    out, carry = [], 0
    for lvl, n in env:
        n += carry
        carry = 0
        if lvl:
            j = round(r.uniform(-jitter_us, jitter_us) * CLK / 1e6)
            if out:
                out[-1] = (0, out[-1][1] + j)
            n -= j
            out += [(1, min(n, on)), (0, n - min(n, on))]
        elif out and out[-1][0] == 0:
            out[-1] = (0, out[-1][1] + n)
        else:
            out.append((0, n))
    return capture([(lvl, n) for lvl, n in out if n > 0], idle=1, raw=40_000, duty=0.5)


def starts_of(entries):
    return rxcap.mark_starts(entries, 1)


ent = edge_only(envelope("SIRC15", 48, 21), jitter_us=30)
codes, hits = rxcap.match_library(starts_of(ent), types)
check(codes == {(1, 48, 21)}, f"edge-only SIRC15: codes {codes}")
check(any(types[t][1][b][1][s][0].startswith("STR-DH790") and "POWER" in fs for t, b, s, fs in hits),
      "edge-only SIRC15: STR-DH790 POWER")
p, d, f, _ = lib_code("TV", "SAMSUNG", "VOL_UP")
codes, hits = rxcap.match_library(starts_of(edge_only(envelope("Samsung32", d, f, frames=2), jitter_us=30)), types)
check((p, d, f) in codes and len(hits) == 44, f"edge-only Samsung VOL_UP: {len(hits)} entries")
# one library code per protocol, with jitter and (biphase) toggle 1
first = {}
for _, brands in types:
    for _, sets in brands:
        for _, cs in sets:
            for p, d, f, _l in cs.values():
                first.setdefault(p, (d, f))
for p, (d, f) in sorted(first.items()):
    name = rxcap.ircompile.PROTO_ORDER[p]
    ent = edge_only(envelope(name, d, f, t=1, frames=2), jitter_us=40, seed=p)
    codes, _ = rxcap.match_library(starts_of(ent), types)
    check((p, d, f) in codes, f"edge-only {name} {d:X} {f:X}: {len(codes)} codes found")
# the real hardware capture (Sony STR-DH790 remote, POWER, v0.10.0)
cap = rxcap.parse((Path(__file__).parent / "fixtures" / "rx_v0.10.0_sony_power.sav").read_bytes())
codes, hits = rxcap.match_library(rxcap.mark_starts(cap["bufs"][0]["entries"], cap["bufs"][0]["idle"]), types)
check(codes == {(1, 48, 21)} and len(hits) == 10, f"hardware capture: {codes}, {len(hits)} entries")
codes, _ = rxcap.match_library(rxcap.mark_starts(cap["bufs"][1]["entries"], cap["bufs"][1]["idle"]), types)
check(not codes, "hardware capture, leaders only: no match")

# ---- 9. report runs on real-looking files (noise buffer, empty, active)
noise = [(0, 0x7FFFFFFF), (1, 500), (0, 70), (1, 10_000), (0, 3)]
txt = "\n".join(rxcap.report(rxcap.parse(save_file([(noise, 1, {"kept": 0}),
                                                     (capture(envelope("SIRC15", 48, 21), 0, 40_000), 0, {})],
                                                    active=1)), types))
check("RAW" in txt and "SIRC15 D=0x30 F=0x15" in txt and "NOT KEPT" in txt, "report text")
check("library:" in txt, "report library lines")

if errors:
    for e in errors:
        print("  " + e)
    print(f"FAIL test_rxcap ({len(errors)} errors)")
    sys.exit(1)
print("PASS test_rxcap")
