"""Measure Flipper-IRDB for a 12-function, deduplicated code library.

Parsed signals are stored parametrically; raw signals as a per-signal table of
distinct durations + packed index stream.

usage: python -I measure_flipper.py <flipper_root>
"""
import math
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from measure_irdb import FUNCS, classify  # noqa: E402

EXTRA = [  # Flipper-style names not covered by the IRDB rules
    ("VOL_UP", r"^(VOL ?UP|VOLUME ?UP|VOL\+|VOL_UP)$"),
    ("VOL_DOWN", r"^(VOL ?(DN|DOWN)|VOLUME ?(DN|DOWN)|VOL-)$"),
    ("OK", r"^(OK|ENTER|SELECT)$"),
    ("MENU", r"^(MENU|HOME|SETUP)$"),
    ("INPUT", r"^(INPUT|SOURCE|SRC|TV ?/ ?AV|AV)$"),
    ("POWER", r"^(POWER|PWR|ON ?/ ?OFF|STANDBY)$"),
]
EXTRA = [(f, re.compile(p)) for f, p in EXTRA]


def classify2(name):
    n = re.sub(r"[_\s]+", " ", name.strip().upper())
    f = classify(n)
    if f:
        return f
    for fn, rx in EXTRA:
        if rx.match(n):
            return fn
    return None


def parse(path):
    sigs, cur = [], {}
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        k, v = k.strip(), v.strip()
        if k == "name":
            if cur:
                sigs.append(cur)
            cur = {"name": v}
        elif cur is not None:
            cur[k] = v
    if cur:
        sigs.append(cur)
    return sigs


def le(hexbytes):
    b = [int(x, 16) for x in hexbytes.split()]
    return sum(v << (8 * i) for i, v in enumerate(b))


def nbytes(v):
    return max(1, (v.bit_length() + 7) // 8)


def raw_size(sig):
    try:
        t = [abs(int(x)) for x in sig["data"].split()]
    except Exception:
        return None
    # cluster durations within 15 % (receivers tolerate ~25 %)
    levels = []
    for d in sorted(set(t)):
        if not levels or d > levels[-1][0] * 1.15:
            levels.append([d])
        else:
            levels[-1].append(d)
    n = len(levels)
    bits = max(1, math.ceil(math.log2(n))) if n > 1 else 1
    return 2 + 2 * n + 1 + math.ceil(len(t) * bits / 8), len(t), n   # freq+duty, table, count, stream


AV_ONLY = {"TVs", "Audio_and_Video_Receivers", "SoundBars", "Speakers", "Projectors", "Streaming_Devices",
           "Cable_Boxes", "Blu-Ray", "DVD_Players", "Monitors", "TV_Tuner", "DVB-T", "Multimedia", "CD_Players",
           "Consoles", "Converters", "Laserdisc", "MiniDisc", "VCR", "Videoconferencing", "Head_Units", "Car_Multimedia"}


def main(root, av_only=False):
    files = sorted(Path(root).rglob("*.ir"))
    if av_only:
        files = [f for f in files if f.relative_to(root).parts[0] in AV_ONLY]
    sets, protos, hits = [], Counter(), Counter()
    raw_bytes, raw_count, raw_pulses, raw_levels = 0, 0, [], []
    brands = set()
    for f in files:
        rel = f.relative_to(root).parts
        dtype, brand = rel[0], rel[1] if len(rel) > 2 else "?"
        chosen = {}
        for s in parse(f):
            fn = classify2(s.get("name", ""))
            if fn is None or fn in chosen:
                continue
            if s.get("type") == "parsed" and "protocol" in s:
                try:
                    chosen[fn] = ("P", s["protocol"], le(s["address"]), le(s["command"]))
                except Exception:
                    continue
            elif s.get("type") == "raw" and "data" in s:
                r = raw_size(s)
                if r:
                    chosen[fn] = ("R", r[0], s["data"])
                    raw_pulses.append(r[1]); raw_levels.append(r[2])
        if not chosen:
            continue
        brands.add(brand)
        for fn in chosen:
            hits[fn] += 1
        parsed = [v for v in chosen.values() if v[0] == "P"]
        hdr = Counter((p, a) for _, p, a, _ in parsed).most_common(1)[0][0] if parsed else None
        if hdr:
            protos[hdr[0]] += 1
        key = (hdr, tuple((fn,) + (chosen[fn][3:] if chosen[fn][0] == "P" and chosen[fn][1:3] == hdr
                                   else chosen[fn][1:]) for fn in FUNCS if fn in chosen))
        sets.append((brand, dtype, key))

    uniq = {k for _, _, k in sets}

    def size(key):
        hdr, fns = key
        b = 2 + (1 + 4 if hdr else 0)                        # mask + proto/address
        for t in fns:
            if len(t) == 2:                                   # (fn, cmd): parsed, header match
                b += nbytes(t[1])
            elif len(t) == 4:                                 # (fn, proto, addr, cmd): override
                b += 1 + 4 + nbytes(t[3])
            else:                                             # (fn, size, data): raw timings
                b += 1 + t[1]
        return b

    total = sum(size(k) for k in uniq)
    raw_in_uniq = sum(1 for k in uniq for t in k[1] if len(t) == 3 and isinstance(t[1], int))
    raw_bytes_uniq = sum(t[1] + 1 for k in uniq for t in k[1] if len(t) == 3 and isinstance(t[1], int))
    dev_bytes = len(sets) * 5
    brand_bytes = sum(len(b) + 1 for b in brands)
    print(f".ir files: {len(files)}; with >=1 of the 12 functions: {len(sets)}; brands: {len(brands)}")
    print(f"unique 12-function code sets after dedupe: {len(uniq)}")
    print("coverage per function (% of devices):")
    for fn in FUNCS:
        print(f"   {fn:9s} {100 * hits[fn] / len(sets):5.1f}%")
    full = sum(1 for _, _, k in sets if {"POWER", "VOL_UP", "VOL_DOWN"} <= {t[0] for t in k[1]})
    print(f"devices with power + both volume keys: {full} ({100 * full / len(sets):.0f}%)")
    print(f"top protocols: {protos.most_common(15)}")
    print(f"raw-timing signals kept after dedupe: {raw_in_uniq} ({raw_bytes_uniq/1024:.1f} KB of the total)")
    if raw_pulses:
        print(f"raw signals: median {sorted(raw_pulses)[len(raw_pulses)//2]} pulses, "
              f"median {sorted(raw_levels)[len(raw_levels)//2]} distinct durations")
    print(f"size: code sets {total/1024:.1f} KB + device list {dev_bytes/1024:.1f} KB + brand names "
          f"{brand_bytes/1024:.1f} KB = {(total + dev_bytes + brand_bytes)/1024:.1f} KB")


if __name__ == "__main__":
    main(sys.argv[1], len(sys.argv) > 2 and sys.argv[2] == "av")
