"""Measure IRDB for a 12-function, deduplicated, parametric code library.

usage: python -I measure_irdb.py <irdb_root>
"""
import csv
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

FUNCS = ["POWER", "VOL_UP", "VOL_DOWN", "MUTE", "UP", "DOWN", "LEFT", "RIGHT",
         "OK", "BACK", "MENU", "INPUT"]

# first matching rule wins; patterns run on the upper-cased, space-normalised name
RULES = [
    ("VOL_UP",   r"^(VOL(UME)?[ _]*(\+|UP|PLUS)|VOL\+|KEY_VOLUMEUP|VOLUP)$"),
    ("VOL_DOWN", r"^(VOL(UME)?[ _]*(-|DOWN|DN|MINUS)|VOL-|KEY_VOLUMEDOWN|VOLDOWN)$"),
    ("MUTE",     r"^(MUTE|MUTING|KEY_MUTE|AUDIO MUTE)$"),
    ("POWER",    r"^(POWER|POWER TOGGLE|POWER ON/OFF|ON/OFF|STANDBY|PWR|KEY_POWER|POWER ON / OFF)$"),
    ("UP",       r"^(UP|CURSOR UP|ARROW UP|MENU UP|NAV UP|KEY_UP|DIRECTION UP)$"),
    ("DOWN",     r"^(DOWN|CURSOR DOWN|ARROW DOWN|MENU DOWN|NAV DOWN|KEY_DOWN|DIRECTION DOWN)$"),
    ("LEFT",     r"^(LEFT|CURSOR LEFT|ARROW LEFT|MENU LEFT|NAV LEFT|KEY_LEFT|DIRECTION LEFT)$"),
    ("RIGHT",    r"^(RIGHT|CURSOR RIGHT|ARROW RIGHT|MENU RIGHT|NAV RIGHT|KEY_RIGHT|DIRECTION RIGHT)$"),
    ("OK",       r"^(OK|ENTER|SELECT|CURSOR ENTER|MENU ENTER|KEY_OK|KEY_ENTER|CONFIRM)$"),
    ("BACK",     r"^(BACK|RETURN|EXIT|KEY_BACK|KEY_EXIT|PREVIOUS MENU)$"),
    ("MENU",     r"^(MENU|HOME|SETUP|AMP MENU|MAIN MENU|KEY_MENU|KEY_HOME|SETUP MENU)$"),
    ("INPUT",    r"^(INPUT|SOURCE|INPUT SELECT|TV/VIDEO|AV|KEY_INPUT|INPUT SOURCE|SOURCE SELECT|TV/AV|AV/TV)$"),
]
RULES = [(f, re.compile(p)) for f, p in RULES]


def classify(name):
    n = re.sub(r"\s+", " ", name.strip().upper())
    for f, rx in RULES:
        if rx.match(n):
            return f
    return None


def main(root):
    root = Path(root) / "codes"
    files = sorted(root.rglob("*.csv"))
    protos = Counter()
    func_hits = Counter()
    sets = []            # (brand, dtype, key)
    unmapped = Counter()
    max_fn = 0
    for f in files:
        brand, dtype = f.parent.parent.name, f.parent.name
        chosen = {}
        try:
            rows = list(csv.DictReader(open(f, encoding="utf-8", errors="replace")))
        except Exception:
            continue
        for r in rows:
            try:
                fn = classify(r["functionname"])
                proto, dev, sub, cmd = r["protocol"], int(r["device"]), int(r["subdevice"]), int(r["function"])
            except Exception:
                continue
            if fn is None:
                unmapped[re.sub(r"\s+", " ", r["functionname"].strip().upper())] += 1
                continue
            if fn not in chosen:
                chosen[fn] = (proto, dev, sub, cmd)
                max_fn = max(max_fn, cmd)
        if not chosen:
            continue
        # default header = most common (proto, dev, sub) among chosen functions
        hdr = Counter((p, d, s) for p, d, s, _ in chosen.values()).most_common(1)[0][0]
        protos[hdr[0]] += 1
        for fn in chosen:
            func_hits[fn] += 1
        key = (hdr, tuple((fn,) + (chosen[fn][3:] if chosen[fn][:3] == hdr else chosen[fn])
                          for fn in FUNCS if fn in chosen))
        sets.append((brand, dtype, key))

    uniq = {k for _, _, k in sets}
    # size model: header 4 B (proto 1, device 2, subdevice 1) + 2 B presence mask
    #             + 1 B per present function (commands >255 cost 2 B)
    #             + 4 B extra per function overriding the header (proto/device/sub)
    def size(key):
        hdr, fns = key
        b = 6
        for t in fns:
            if len(t) == 2:
                b += 1 if t[1] <= 255 else 2
            else:
                b += 1 + 4 + (1 if t[4] > 255 else 0)
        return b
    lib_bytes = sum(size(k) for k in uniq)
    brands = {b for b, _, _ in sets}
    dtypes = Counter(t for _, t, _ in sets)
    brand_bytes = sum(len(b) + 1 for b in brands)
    # device list: brand idx (2) + type idx (1) + code-set idx (2) per file
    dev_bytes = len(sets) * 5

    print(f"csv files: {len(files)}; with >=1 of the 12 functions: {len(sets)}")
    print(f"brands: {len(brands)}; device types: {len(dtypes)}; protocols in use: {len(protos)}")
    print(f"unique 12-function code sets after dedupe: {len(uniq)}")
    print(f"max command value: {max_fn}")
    print("coverage per function (% of devices):")
    for fn in FUNCS:
        print(f"   {fn:9s} {100 * func_hits[fn] / len(sets):5.1f}%")
    full = sum(1 for _, _, k in sets if {"POWER", "VOL_UP", "VOL_DOWN"} <= {t[0] for t in k[1]})
    print(f"devices with power + both volume keys: {full} ({100 * full / len(sets):.0f}%)")
    print(f"top protocols: {protos.most_common(12)}")
    print(f"size: code sets {lib_bytes/1024:.1f} KB + device list {dev_bytes/1024:.1f} KB + brand names {brand_bytes/1024:.1f} KB"
          f" = {(lib_bytes + dev_bytes + brand_bytes)/1024:.1f} KB")
    print("most common unmapped names (to improve the mapping):")
    for n, c in unmapped.most_common(40):
        print(f"   {c:6d}  {n}")


if __name__ == "__main__":
    main(sys.argv[1])
