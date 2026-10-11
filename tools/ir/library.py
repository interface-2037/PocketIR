"""Build the on-chip IR code library (M7) from Flipper-IRDB.

    python tools/ir/library.py [--db ../Flipper-IRDB]

Reads the curated AV folders of Flipper-IRDB (CC0), maps each remote's signals
to the 12 Pocket functions, converts them to engine form ({protocol id, D, F}
as ir_engine.v sends them), removes duplicate code sets and writes:

    src/fpga/core/lib/ir_lib.hex   one byte per line (ROM image)
    src/fpga/core/lib/ir_lib.vh    IR_LIB_BYTES and layout constants
    docs/library-report.md         coverage / size report

The binary format is documented in docs/codes-format.md; `read_library()`
below is the reference reader used by the tests.
"""

import argparse
import re
import struct
import subprocess
import sys
import zlib
from collections import Counter, OrderedDict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import ircompile  # noqa: E402
import irproto as ir  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DB = ROOT.parent / "Flipper-IRDB"

FUNCS = ["POWER", "VOL_UP", "VOL_DOWN", "MUTE", "UP", "DOWN", "LEFT", "RIGHT",
         "OK", "BACK", "MENU", "INPUT"]

# Flipper-IRDB category folder -> device type shown in the menu (order = menu order)
TYPES = OrderedDict([
    ("TV", ["TVs"]),
    ("RECEIVER", ["Audio_and_Video_Receivers"]),
    ("SOUNDBAR", ["SoundBars"]),
    ("SPEAKER", ["Speakers"]),
    ("PROJECTOR", ["Projectors"]),
    ("STREAMING", ["Streaming_Devices"]),
    ("CABLE BOX", ["Cable_Boxes", "TV_Tuner", "DVB-T"]),
    ("DISC PLAYER", ["Blu-Ray", "DVD_Players", "CD_Players", "Laserdisc", "MiniDisc", "VCR"]),
    ("MONITOR", ["Monitors"]),
    ("OTHER AV", ["Multimedia", "Consoles", "Converters", "Videoconferencing",
                  "Head_Units", "Car_Multimedia"]),
])

# Flipper protocol name -> irproto protocol name
PROTO_MAP = {"NEC": "NEC", "NECext": "NECext", "Samsung32": "Samsung32", "RC5": "RC5",
             "RC5X": "RC5X", "RC6": "RC6", "SIRC": "SIRC12", "SIRC15": "SIRC15",
             "SIRC20": "SIRC20", "Kaseikyo": "Kaseikyo", "RCA": "RCA", "Pioneer": "Pioneer"}

# (function, label, pattern) -- first match wins; the label is what the screen shows
NAME_RULES = [
    ("VOL_UP",   "VOL +",   r"^(VOL(UME)?[ _-]*(\+|UP|PLUS)|VOL\+|KEY VOLUMEUP|VOLUP)$"),
    ("VOL_DOWN", "VOL -",   r"^(VOL(UME)?[ _-]*(-|DOWN|DN|MINUS)|VOL-|KEY VOLUMEDOWN|VOLDOWN|VOLDN)$"),
    ("MUTE",     "MUTE",    r"^(MUTE|MUTING|AUDIO MUTE|KEY MUTE)$"),
    ("POWER",    "POWER",   r"^(POWER|PWR|POWER TOGGLE|POWER ON ?/ ?OFF|ON ?/ ?OFF|STANDBY|KEY POWER)$"),
    ("UP",       "UP",      r"^(UP|CURSOR UP|ARROW UP|NAV UP|MENU UP|KEY UP|DIRECTION UP)$"),
    ("DOWN",     "DOWN",    r"^(DOWN|CURSOR DOWN|ARROW DOWN|NAV DOWN|MENU DOWN|KEY DOWN|DIRECTION DOWN|DN)$"),
    ("LEFT",     "LEFT",    r"^(LEFT|CURSOR LEFT|ARROW LEFT|NAV LEFT|MENU LEFT|KEY LEFT|DIRECTION LEFT)$"),
    ("RIGHT",    "RIGHT",   r"^(RIGHT|CURSOR RIGHT|ARROW RIGHT|NAV RIGHT|MENU RIGHT|KEY RIGHT|DIRECTION RIGHT)$"),
    ("OK",       "OK",      r"^(OK|CURSOR OK|KEY OK|CONFIRM)$"),
    ("OK",       "ENTER",   r"^(ENTER|CURSOR ENTER|MENU ENTER|KEY ENTER)$"),
    ("OK",       "SELECT",  r"^(SELECT|SEL)$"),
    ("BACK",     "BACK",    r"^(BACK|KEY BACK|PREVIOUS MENU|PREV MENU)$"),
    ("BACK",     "RETURN",  r"^(RETURN|RTN|RET)$"),
    ("BACK",     "EXIT",    r"^(EXIT|KEY EXIT)$"),
    ("MENU",     "MENU",    r"^(MENU|MAIN MENU|KEY MENU|SETUP MENU)$"),
    ("MENU",     "HOME",    r"^(HOME|KEY HOME|SMART HUB|SMARTHUB)$"),
    ("MENU",     "SETUP",   r"^(SETUP|SET UP)$"),
    ("INPUT",    "SOURCE",  r"^(SOURCE|SRC|SOURCE SELECT|KEY SOURCE)$"),
    ("INPUT",    "INPUT",   r"^(INPUT|INPUT SELECT|INPUT SOURCE|KEY INPUT)$"),
    ("INPUT",    "TV/AV",   r"^(TV ?/ ?AV|AV ?/ ?TV|TV ?/ ?VIDEO|AV)$"),
]
NAME_RULES = [(f, lab, re.compile(p)) for f, lab, p in NAME_RULES]

# Hand-verified codes that must not regress: Sony STR-DH790 (v0.1.1/v0.5.x on hardware).
# The 12th slot (INPUT) carries the receiver's OPTIONS key, as on today's screen.
SONY_DH790 = {
    "POWER": ("SIRC15", 48, 21, "POWER"), "MUTE": ("SIRC15", 48, 20, "MUTE"),
    "VOL_UP": ("SIRC15", 48, 18, "VOL +"), "VOL_DOWN": ("SIRC15", 48, 19, "VOL -"),
    "UP": ("SIRC15", 176, 120, "UP"), "DOWN": ("SIRC15", 176, 121, "DOWN"),
    "LEFT": ("SIRC15", 176, 122, "LEFT"), "RIGHT": ("SIRC15", 176, 123, "RIGHT"),
    "OK": ("SIRC15", 48, 12, "ENTER"), "BACK": ("SIRC20", 272, 125, "BACK"),
    "MENU": ("SIRC15", 48, 83, "AMP MENU"), "INPUT": ("SIRC20", 272, 115, "OPTIONS"),
}


# ---------------------------------------------------------------- parsing
def classify(name):
    n = re.sub(r"[_\s]+", " ", name.strip().upper())
    for f, lab, rx in NAME_RULES:
        if rx.match(n):
            return f, lab
    return None, None


def parse_ir(path):
    sigs, cur = [], None
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        k, v = (x.strip() for x in line.split(":", 1))
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
    return sum(int(x, 16) << (8 * i) for i, x in enumerate(hexbytes.split()))


def model_name(path, brand):
    n = path.stem.replace("_", " ").upper()
    b = brand.replace("_", " ").upper()
    if n.startswith(b + " "):
        n = n[len(b) + 1:]
    elif n == b:
        n = "GENERIC"
    return re.sub(r"[^A-Z0-9 +./-]", "", n)[:20].strip() or "GENERIC"


def code_set(path, unmapped):
    """{function: (proto id, D, F, label)} for one .ir file."""
    out = {}
    for s in parse_ir(path):
        f, label = classify(s.get("name", ""))
        if f is None:
            unmapped[re.sub(r"[_\s]+", " ", s.get("name", "").upper())] += 1
            continue
        if f in out or s.get("type") != "parsed" or s.get("protocol") not in PROTO_MAP:
            continue
        pname = PROTO_MAP[s["protocol"]]
        try:
            addr, cmd = le(s["address"]), le(s["command"])
        except (KeyError, ValueError):
            continue
        d, fw = ir.PROTOCOLS[pname].pack(addr, cmd)
        out[f] = (ircompile.PROTO_ORDER.index(pname), d, fw, label)
    return out


# ---------------------------------------------------------------- model
def build_model(db):
    """[(type, [(brand, [(model, codeset), ...]), ...]), ...] plus stats."""
    unmapped, files_seen, files_used = Counter(), 0, 0
    types = []
    for tname, folders in TYPES.items():
        brands = {}
        for folder in folders:
            for path in sorted((db / folder).rglob("*.ir")):
                rel = path.relative_to(db / folder).parts
                brand = rel[0] if len(rel) > 1 else "GENERIC"
                files_seen += 1
                cs = code_set(path, unmapped)
                if not cs:
                    continue
                files_used += 1
                bkey = brand.replace("_", " ").upper()
                brands.setdefault(bkey, []).append((model_name(path, brand), cs))
        if tname == "RECEIVER":
            sony = {f: (ircompile.PROTO_ORDER.index(p), *ir.PROTOCOLS[p].pack(a, c), lab)
                    for f, (p, a, c, lab) in SONY_DH790.items()}
            brands.setdefault("SONY", []).insert(0, ("STR-DH790 VERIFIED", sony))
        merged = []
        for bname in sorted(brands):
            # merge models with identical code sets; most complete sets first
            sets = OrderedDict()
            for model, cs in brands[bname]:
                key = tuple(sorted(cs.items()))
                sets.setdefault(key, []).append(model)
            entries = []
            for key, models in sets.items():
                label = models[0] if len(models) == 1 else f"{models[0]} +{len(models) - 1}"
                entries.append((label[:24], dict(key), len(models)))
            verified = [e for e in entries if "VERIFIED" in e[0]]
            rest = sorted((e for e in entries if "VERIFIED" not in e[0]),
                          key=lambda e: (-len(e[1]), -e[2], e[0]))
            merged.append((bname[:20], [(m, cs) for m, cs, _ in verified + rest]))
        types.append((tname, merged))
    stats = {"files_seen": files_seen, "files_used": files_used, "unmapped": unmapped}
    return types, stats


# ---------------------------------------------------------------- binary format
MAGIC = b"IRL1"
FUNC_COUNT = len(FUNCS)


def split_model(m):
    """'BN59-01180A +5' -> ('BN59-01180A', 5): display name and how many more remotes share the set."""
    if " +" in m:
        base, n = m.rsplit(" +", 1)
        return base, int(n)
    return m, 0


class Blob:
    def __init__(self):
        self.b = bytearray()

    def here(self):
        return len(self.b)

    def put(self, data):
        off = len(self.b)
        self.b += data
        return off

    def align(self, n=4):
        while len(self.b) % n:
            self.b.append(0)


def encode_codeset(cs, label_ids):
    """proto u8, present-count u8, mask u16, D u32, then per present function (in
    FUNCS order) cmd u16, label u8, flags u8 [+ override: proto u8, 3 pad, D u32, F u32]."""
    present = [f for f in FUNCS if f in cs]
    hdr_p, hdr_d = Counter((cs[f][0], cs[f][1]) for f in present).most_common(1)[0][0]
    mask = sum(1 << FUNCS.index(f) for f in present)
    out = bytearray(struct.pack("<BBHI", hdr_p, len(present), mask, hdr_d))
    for f in present:
        p, d, fw, label = cs[f]
        override = (p, d) != (hdr_p, hdr_d) or fw > 0xFFFF
        out += struct.pack("<HBB", fw & 0xFFFF, label_ids[label], 1 if override else 0)
        if override:
            out += struct.pack("<B3xII", p, d, fw)
    return bytes(out)


# Fixed strings the on-Pocket loader (dev_ctrl.v) needs, addressed by index via the
# header's constant-string table. Order is part of the format: append only.
CONSTS = ["REMOTE ", "VOLUME DOWN", "VOLUME UP", "NAVIGATE", "MENU", "INPUT", "OK", "BACK",
          "POWER", "MUTE", " ",
          # device menu (M7 step 5)
          "CHOOSE DEVICE", "DEVICE TYPE", " BRAND", " SETS", " SET", " KEYS", " & ", " MORE",
          " / ", " > ", "ENTER", "CHOOSE", "UP", "SELECT+START", "EXIT", "LEFT/RIGHT", "A-Z",
          "TEST", "USE",
          # M9: recent devices, learn from remote (indices -> ir_lib.vh M9_C_*)
          "RECENT DEVICES", "LEARN FROM REMOTE", " DEVICES", " DEVICE", "RECENT, LEARN, OR BY TYPE",
          "MOST RECENT FIRST", "FIND YOUR DEVICE BY ITS REMOTE", "AIM THE REMOTE AT THE POCKET'S",
          "BOTTOM EDGE, 1 TO 3 INCHES AWAY", "AND TAP ONE BUTTON.", "LISTENING...", "COULDN'T READ THAT",
          "MOVE THE REMOTE CLOSER", "NO MATCH IN THE LIBRARY", "TRY ANOTHER BUTTON", " MATCH", " MATCHES",
          " BUTTON: TAP MORE TO NARROW", " BUTTONS: TAP MORE TO NARROW", "NONE OF THESE MATCH THAT BUTTON",
          "COULDN'T READ THAT BUTTON", "CANCEL", "RETRY"]
M9_CONSTS = {"RECENT": "RECENT DEVICES", "LEARN": "LEARN FROM REMOTE", "DEVICES": " DEVICES",
             "DEVICE": " DEVICE", "HOME_CRUMB": "RECENT, LEARN, OR BY TYPE", "RECENT_CRUMB": "MOST RECENT FIRST",
             "LEARN_CRUMB": "FIND YOUR DEVICE BY ITS REMOTE", "AIM1": "AIM THE REMOTE AT THE POCKET'S",
             "AIM2": "BOTTOM EDGE, 1 TO 3 INCHES AWAY", "AIM3": "AND TAP ONE BUTTON.", "LISTENING": "LISTENING...",
             "UNREAD": "COULDN'T READ THAT", "CLOSER": "MOVE THE REMOTE CLOSER", "NOMATCH": "NO MATCH IN THE LIBRARY",
             "ANOTHER": "TRY ANOTHER BUTTON", "MATCH": " MATCH", "MATCHES": " MATCHES",
             "BUTTON": " BUTTON: TAP MORE TO NARROW", "BUTTONS": " BUTTONS: TAP MORE TO NARROW",
             "NONE": "NONE OF THESE MATCH THAT BUTTON", "UNREAD_BTN": "COULDN'T READ THAT BUTTON"}
assert all(len(c) <= 31 for c in CONSTS), "a constant string doesn't fit a 31-character text slot"

# Library id, saved with the device (lib/dev_save.v) and the recent list: CRC-32 of the
# device data only (types, brands, sets, codes, labels), so UI strings can change
# without invalidating saves. Builds up to v0.10.0 saved the CRC of the whole image;
# that id is accepted once more (IR_LIB_ID_V1) while the device data is unchanged.
V1_IMAGE_CRC, V1_DEVICE_ID = 0xFD097E4D, 0xB597EE78


def device_id(data):
    return zlib.crc32(repr(read_library(data)).encode())


def write_library(types, db_commit):
    blob = Blob()
    blob.put(b"\0" * 32)                                  # header, filled in last
    strings, labels = {}, {}

    def string(s):
        if s not in strings:
            strings[s] = None
        return s

    # collect strings and labels
    for tname, brands in types:
        string(tname)
        for bname, sets in brands:
            string(bname)
            for model, cs in sets:
                string(split_model(model)[0])
                for f, (_, _, _, lab) in cs.items():
                    labels.setdefault(lab, len(labels))
                    string(lab)
    for c in CONSTS:
        string(c)
    assert len(labels) < 256
    # string area
    blob.align()
    for s in strings:
        strings[s] = blob.put(s.encode("ascii") + b"\0")
    assert blob.here() < 0x10000, "string area must stay below 64 KB (u16 model-name offsets)"
    blob.align()
    label_off = blob.put(b"".join(struct.pack("<I", strings[l]) for l in labels))
    const_off = blob.put(b"".join(struct.pack("<I", strings[c]) for c in CONSTS))
    # code sets (deduplicated across the whole library)
    cs_off = {}
    for tname, brands in types:
        for bname, sets in brands:
            for model, cs in sets:
                data = encode_codeset(cs, labels)
                if data not in cs_off:
                    blob.align()
                    cs_off[data] = blob.put(data)
    # brand set lists, brand tables, type table
    blob.align()
    brand_tables = []
    for tname, brands in types:
        entries = []
        for bname, sets in brands:
            lst = blob.put(b"".join(struct.pack("<IHH", cs_off[encode_codeset(cs, labels)],
                                                strings[split_model(model)[0]], split_model(model)[1])
                                    for model, cs in sets))
            entries.append(struct.pack("<IIHH", strings[bname], lst, len(sets), 0))
        brand_tables.append(blob.put(b"".join(entries)))
    type_off = blob.put(b"".join(struct.pack("<IIHH", strings[t], bt, len(brands),
                                             sum(len(s) for _, s in brands))
                                 for (t, brands), bt in zip(types, brand_tables)))
    blob.b[0:32] = struct.pack("<4sHHIIIII4x", MAGIC, len(types), len(labels),
                               type_off, label_off, len(blob.b), int(db_commit[:8], 16), const_off)
    return bytes(blob.b), {"codesets": len(cs_off), "labels": len(labels), "strings": len(strings)}


def read_library(data):
    """Reference reader: bytes -> [(type, [(brand, [(model, codeset), ...]), ...]), ...]."""
    magic, ntypes, nlabels, type_off, label_off, size, _ = struct.unpack_from("<4sHHIIII", data, 0)
    assert magic == MAGIC and size == len(data)

    def cstr(off):
        return data[off:data.index(b"\0", off)].decode("ascii")

    labels = [cstr(struct.unpack_from("<I", data, label_off + 4 * i)[0]) for i in range(nlabels)]
    types = []
    for t in range(ntypes):
        tname, btab, nb, _ = struct.unpack_from("<IIHH", data, type_off + 12 * t)
        brands = []
        for b in range(nb):
            bname, lst, ns, _ = struct.unpack_from("<IIHH", data, btab + 12 * b)
            sets = []
            for s in range(ns):
                cso, moff, more = struct.unpack_from("<IHH", data, lst + 8 * s)
                p, n, mask, d = struct.unpack_from("<BBHI", data, cso)
                pos, cs = cso + 8, {}
                for f in FUNCS:
                    if not mask >> FUNCS.index(f) & 1:
                        continue
                    cmd, lab, flags = struct.unpack_from("<HBB", data, pos)
                    pos += 4
                    if flags & 1:
                        op, od, of = struct.unpack_from("<B3xII", data, pos)
                        pos += 12
                        cs[f] = (op, od, of, labels[lab])
                    else:
                        cs[f] = (p, d, cmd, labels[lab])
                assert len(cs) == n
                sets.append((cstr(moff) + (f" +{more}" if more else ""), cs))
            brands.append((cstr(bname), sets))
        types.append((cstr(tname), brands))
    return types


# ---------------------------------------------------------------- report
def report(types, stats, info, size, db_commit):
    n_sets = sum(len(s) for _, br in types for _, s in br)
    fcount = Counter(f for _, br in types for _, s in br for _, cs in s for f in cs)
    pcount = Counter(ircompile.PROTO_ORDER[cs[f][0]] for _, br in types for _, s in br
                     for _, cs in s for f in cs)
    lines = [f"# IR code library report", "",
             f"Generated by `tools/ir/library.py` from Flipper-IRDB commit `{db_commit[:12]}`.", "",
             f"- Remote files scanned: {stats['files_seen']}, with at least one usable function: {stats['files_used']}",
             f"- Menu entries (brand code sets): {n_sets}; unique code sets stored: {info['codesets']}",
             f"- Labels: {info['labels']}; strings: {info['strings']}",
             f"- **ROM size: {size:,} bytes ({size / 1024:.1f} KB)**", "",
             "| Type | Brands | Code sets |", "|---|---|---|"]
    lines += [f"| {t} | {len(br)} | {sum(len(s) for _, s in br)} |" for t, br in types]
    lines += ["", "| Function | Code sets that have it |", "|---|---|"]
    lines += [f"| {f} | {fcount[f]} ({100 * fcount[f] / n_sets:.0f}%) |" for f in FUNCS]
    lines += ["", "Protocols (signals): " + ", ".join(f"{p} {c}" for p, c in pcount.most_common()), "",
              "Most common unmapped signal names (candidates for new name rules):", ""]
    lines += [f"- {n or '(empty)'}: {c}" for n, c in stats["unmapped"].most_common(25)]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    args = ap.parse_args()
    if not (args.db / "TVs").is_dir():
        sys.exit(f"Flipper-IRDB not found at {args.db} (git clone https://github.com/Lucaslhm/Flipper-IRDB)")
    db_commit = subprocess.run(["git", "-C", str(args.db), "rev-parse", "HEAD"],
                               capture_output=True, text=True).stdout.strip() or "0" * 40
    types, stats = build_model(args.db)
    data, info = write_library(types, db_commit)
    assert read_library(data) == [(t, [(b, list(s)) for b, s in br]) for t, br in types], "round trip"

    out = ROOT / "src" / "fpga" / "core" / "lib"
    out.mkdir(parents=True, exist_ok=True)
    (out / "ir_lib.hex").write_text("".join(f"{x:02X}\n" for x in data))
    def index(tname, bname, model_prefix=""):
        ti = [t for t, _ in types].index(tname)
        brands = types[ti][1]
        bi = [b for b, _ in brands].index(bname)
        si = next(i for i, (m, _) in enumerate(brands[bi][1]) if m.startswith(model_prefix))
        return ti, bi, si
    sony, sam = index("RECEIVER", "SONY", "STR-DH790 VERIFIED"), index("TV", "SAMSUNG")
    (out / "ir_lib.vh").write_text(
        "// generated by tools/ir/library.py -- do not edit\n"
        f"localparam IR_LIB_BYTES = {len(data)};\n"
        f"localparam IR_LIB_FUNCS = {FUNC_COUNT};\n"
        "// device-data CRC (library.device_id): a saved device / recent list is only used with the\n"
        "// same library. IR_LIB_ID_V1: also accepted (the id v0.10.0 and older saved), = IR_LIB_ID\n"
        "// unless the device data is unchanged since then.\n"
        f"localparam [31:0] IR_LIB_ID = 32'h{device_id(data):08X};\n"
        f"localparam [31:0] IR_LIB_ID_V1 = 32'h"
        f"{V1_IMAGE_CRC if device_id(data) == V1_DEVICE_ID else device_id(data):08X};\n"
        + "".join(f"localparam [5:0] M9_C_{k} = 6'd{CONSTS.index(v)};\n" for k, v in M9_CONSTS.items())
        + "// device menu / remote identification limits (lib/ir_match.v, lib/recent.v)\n"
        f"localparam IR_LIB_ENTRIES = {sum(len(s) for _, br in types for _, s in br)};\n"
        "// device = {type, brand, code set} indices into the library tables\n"
        f"localparam [7:0] DEV_SONY_T = {sony[0]}, DEV_SAMSUNG_T = {sam[0]};\n"
        f"localparam [15:0] DEV_SONY_B = {sony[1]}, DEV_SAMSUNG_B = {sam[1]};\n"
        f"localparam [15:0] DEV_SONY_S = {sony[2]}, DEV_SAMSUNG_S = {sam[2]};\n")
    (ROOT / "docs" / "library-report.md").write_text(report(types, stats, info, len(data), db_commit))
    print(f"{info['codesets']} unique code sets, {sum(len(s) for _, br in types for _, s in br)} menu entries, "
          f"{len(data):,} bytes -> {out.relative_to(ROOT)} (report: docs/library-report.md)")


if __name__ == "__main__":
    main()
