"""Receiver capture (M9 step 1): decode and analyse the ir_rx_cap region of irremote.sav.

The core records every edge of port_ir_rx as {level after the edge, clocks
since the previous edge} (src/fpga/core/ir/ir_rx_cap.v). This module turns
that into answers:

  - idle level (polarity) and whether the receiver gives raw carrier pulses
    or a demodulated envelope;
  - carrier frequency and duty (raw receivers only);
  - the mark/space envelope, split into frames;
  - the protocol, address and command (decoded with irproto's definitions,
    then checked by re-encoding), how far the timing is from the reference,
    and which library entries send that code.

Used by tools/ir/read_save.py; tested by tools/ir/test_rxcap.py.
"""

import statistics
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import ircompile  # noqa: E402
import irproto as ir  # noqa: E402

CLK_HZ = ir.CLK_HZ
MAGIC = 0x49524331          # "IRC1"
HDR_OFF = 0x20              # capture header offset in the save file
CARRIER_MAX_US = 50         # active pulses shorter than this are carrier cycles
MERGE_US = 150              # idle gaps shorter than this are inside a mark (raw receivers)
FRAME_GAP_US = 7000         # spaces longer than this separate frames (longest in-frame: 4.5 ms)
TOL_REL, TOL_ABS = 0.30, 200   # timing tolerance when matching a protocol


def us(clocks):
    return clocks * 1e6 / CLK_HZ


# ----------------------------------------------------------------- file layout
def parse(data):
    """Save-file bytes -> capture dict, or None if the file has no capture region."""
    if len(data) < HDR_OFF + 32:
        return None
    w = struct.unpack(">8I", data[HDR_OFF:HDR_OFF + 32])
    if w[0] != MAGIC:
        return {"magic": False}
    depth = 1 << ((w[1] >> 24) & 0xF)
    cap = {"magic": True, "depth": depth, "active": w[1] >> 31,
           "kept": (w[1] >> 8) & 0xFF, "rejected": w[1] & 0xFF, "bufs": []}
    for b in range(2):
        info, total, dur = w[2 + 3 * b:5 + 3 * b]
        n = min(info & 0xFFFF, depth)
        off = HDR_OFF + 32 + 4 * depth * b
        avail = max(0, min(n, (len(data) - off) // 4))
        raw = struct.unpack(f">{avail}I", data[off:off + 4 * avail])
        cap["bufs"].append({
            "index": b, "kept": info >> 31, "idle": (info >> 30) & 1, "tx": (info >> 29) & 1,
            "full": (info >> 28) & 1, "maxed": (info >> 27) & 1, "n": n, "total": total,
            "dur": dur, "truncated": avail < n,
            "entries": [(x >> 31, x & 0x7FFFFFFF) for x in raw]})
    return cap


def build(bufs, active, depth_log2=12, kept=0, rejected=0):
    """Inverse of parse (tests): bufs = [(entries, idle, flags dict) or None] x 2 -> region bytes."""
    depth = 1 << depth_log2
    hdr = [MAGIC, (active << 31) | (depth_log2 << 24) | (kept << 8) | rejected]
    body = b""
    for b in bufs:
        if b is None:
            hdr += [0, 0, 0]
            body += bytes(4 * depth)
            continue
        entries, idle, fl = b
        n = min(len(entries), depth)
        info = ((fl.get("kept", 1) << 31) | (idle << 30) | (fl.get("tx", 0) << 29) |
                (int(len(entries) > depth) << 28) | n)
        hdr += [info, len(entries), sum(d for _, d in entries[1:])]
        words = [(lvl << 31) | min(d, 0x7FFFFFFF) for lvl, d in entries[:n]]
        body += struct.pack(f">{depth}I", *(words + [0] * (depth - n)))
    return struct.pack(">8I", *hdr) + body


def entries_from_runs(runs, idle, idle_before=0x7FFFFFFF):
    """(level, clocks) runs of the receiver output, starting at the first edge -> entries."""
    out, prev = [], idle
    pending = idle_before
    for lvl, n in runs:
        if lvl != prev:
            out.append((lvl, pending))
            pending, prev = 0, lvl
        pending += n
    if prev != idle:
        out.append((idle, pending))
    return out


def modulate(env_runs, carrier_hz, duty, idle=0):
    """Envelope (1 = mark, clocks) -> raw receiver runs: carrier pulses during marks.
    The active level is 1 - idle."""
    period = CLK_HZ / carrier_hz
    act = 1 - idle
    out = []
    for lvl, n in env_runs:
        if lvl == 0:
            out.append((idle, n))
            continue
        k = 0
        while round(k * period) < n:          # pulse k: [start, end), then idle to the next one
            start = round(k * period)
            end = min(start + round(period * duty), n)
            nxt = min(round((k + 1) * period), n)
            out.append((act, end - start))
            out.append((idle, nxt - end))
            k += 1
    merged = []
    for lvl, n in out:
        if n <= 0:
            continue
        if merged and merged[-1][0] == lvl:
            merged[-1] = (lvl, merged[-1][1] + n)
        else:
            merged.append((lvl, n))
    return merged


# ----------------------------------------------------------------- analysis
def runs_of(entries):
    """Entries -> (level, clocks) runs between consecutive edges."""
    return [(entries[i - 1][0], entries[i][1]) for i in range(1, len(entries))]


def analyse(buf):
    entries, idle = buf["entries"], buf["idle"]
    act = 1 - idle
    res = {"idle": idle, "edges": len(entries)}
    res["alternates"] = all(entries[i][0] != entries[i - 1][0] for i in range(1, len(entries))) and \
        (not entries or entries[0][0] != idle)
    runs = runs_of(entries)
    res["glitches"] = sum(1 for _, c in runs if us(c) < 1.0)
    pulses = [us(c) for lvl, c in runs if lvl == act]
    res["raw"] = len(pulses) >= 20 and \
        sum(1 for p in pulses if p < CARRIER_MAX_US) > 0.6 * len(pulses)
    res["carrier_hz"] = res["duty"] = None
    if res["raw"]:
        periods, t, last_start = [], 0.0, None
        for (lvl, c) in runs:
            d = us(c)
            if lvl == act and d < CARRIER_MAX_US:
                if last_start is not None and t - last_start < 2 * CARRIER_MAX_US:
                    periods.append(t - last_start)
                last_start = t
            t += d
        if periods:
            p = statistics.median(periods)
            res["carrier_hz"] = 1e6 / p
            res["duty"] = statistics.median([x for x in pulses if x < CARRIER_MAX_US]) / p
    # envelope: 1 = mark (carrier present)
    env = []
    for lvl, c in runs:
        d, m = us(c), int(lvl == act)
        if not m and res["raw"] and d < MERGE_US and env and env[-1][0] == 1:
            m = 1
        if env and env[-1][0] == m:
            env[-1] = (m, env[-1][1] + d)
        else:
            env.append((m, d))
    while env and env[0][0] == 0:
        env.pop(0)
    frames, cur = [], []
    for m, d in env:
        if not m and d >= FRAME_GAP_US:
            frames.append(cur)
            cur = []
        else:
            cur.append((m, d))
    if cur:
        frames.append(cur)
    res["env"], res["frames"] = env, [f for f in frames if f]
    return res


# ----------------------------------------------------------------- protocol decode
def _close(got, want):
    return abs(got - want) <= max(TOL_ABS, TOL_REL * want)


def _segments(frame):
    """Frame [(level, us)] starting with a mark -> durations, marks at even indices."""
    return [d for _, d in frame]


def _put(fields, masks, src, idx, bit):
    """Store one decoded bit; False if it contradicts an earlier copy (inverted fields)."""
    if masks[src] >> idx & 1:
        return (fields[src] >> idx & 1) == bit
    fields[src] |= bit << idx
    masks[src] |= 1 << idx
    return True


def _decode_pulse(p, segs):
    fields, masks, i = {"D": 0, "F": 0, "T": 0}, {"D": 0, "F": 0, "T": 0}, 0
    for op in p.frame:
        if isinstance(op, ir.Mark):
            if i >= len(segs) or i % 2 or not _close(segs[i], op.us):
                return None
            i += 1
        elif isinstance(op, (ir.Space, ir.GapTo)):
            if i >= len(segs):                       # frame gap
                break
            if isinstance(op, ir.GapTo) or i % 2 == 0 or not _close(segs[i], op.us):
                return None
            i += 1
        elif isinstance(op, ir.Send):
            k = 1 << op.shift
            for j in range(op.count):
                if i >= len(segs) or i % 2:
                    return None
                mark = segs[i]
                space = segs[i + 1] if i + 1 < len(segs) else None
                b = p.bits

                def cost(m, s):
                    c = abs(mark - k * m) / (k * m)
                    return c + (abs(space - k * s) / (k * s) if space is not None else 0)
                bit = int(cost(b.m1, b.s1) < cost(b.m0, b.s0))
                m_want, s_want = (b.m1, b.s1) if bit else (b.m0, b.s0)
                if not _close(mark, k * m_want) or (space is not None and not _close(space, k * s_want)):
                    return None
                v = bit ^ int(op.invert)
                idx = op.lsb + (op.count - 1 - j if op.msb_first else j)
                if op.src == "C":
                    if v != (op.const >> idx & 1):
                        return None
                elif not _put(fields, masks, op.src, idx, v):
                    return None
                i += 2
    if i < len(segs):
        return None
    return fields, masks


def _decode_biphase(p, segs):
    half = p.bits.half
    units = []
    for n, d in enumerate(segs):
        k = round(d / half)
        if k < 1 or abs(d - k * half) > 0.4 * half:
            return None
        units += [1 - n % 2] * k
    # a frame that starts with a space half-bit (RC5's first bit) can't be seen: put it back
    lead = ir.frame_ticks(p, p.frame, 0, 0, 0)
    if lead and lead[0][0] == 0:
        units = [0] * round(lead[0][1] * ir.TICK_US / half) + units
    fields, masks, i = {"D": 0, "F": 0, "T": 0}, {"D": 0, "F": 0, "T": 0}, 0

    def take(level, k):
        nonlocal i
        for _ in range(k):
            got = units[i] if i < len(units) else 0      # past the end: the frame gap
            if got != level:
                return False
            i += 1
        return True
    for op in p.frame:
        if isinstance(op, ir.Mark):
            if not take(1, round(op.us / half)):
                return None
        elif isinstance(op, ir.GapTo) or (isinstance(op, ir.Space) and op.us >= FRAME_GAP_US):
            break                                    # frame gap
        elif isinstance(op, ir.Space):
            if not take(0, round(op.us / half)):     # RC6 leader space
                return None
        elif isinstance(op, ir.Send):
            k = 1 << op.shift
            for j in range(op.count):
                first = units[i] if i < len(units) else 0
                if not (take(first, k) and take(1 - first, k)):
                    return None
                bit = first if p.bits.one_mark_first else 1 - first
                v = bit ^ int(op.invert)
                idx = op.lsb + (op.count - 1 - j if op.msb_first else j)
                if op.src == "C":
                    if v != (op.const >> idx & 1):
                        return None
                elif not _put(fields, masks, op.src, idx, v):
                    return None
    if i < len(units):
        return None
    return fields, masks


def reference_frame(name, d, f, t):
    """First frame of (name, D, F, T) as [(level, us)] from the first mark, without the gap."""
    p = ir.PROTOCOLS[name]
    runs = [(lvl, n * ir.TICK_US) for lvl, n in ir.frame_ticks(p, p.frame, d, f, t)]
    while runs and runs[0][0] == 0:
        runs.pop(0)
    while runs and runs[-1][0] == 0:
        runs.pop()
    return runs


def _compare(frame, ref):
    """Timing errors of a captured frame vs a reference (same length assumed)."""
    pairs = list(zip(frame, ref))
    if not all(_close(g, w) for (_, g), (_, w) in pairs):
        return None
    merr = [g - w for (lvl, g), (_, w) in pairs if lvl == 1]
    serr = [g - w for (lvl, g), (_, w) in pairs if lvl == 0]
    return {"mark_err": statistics.mean(merr) if merr else 0.0,
            "space_err": statistics.mean(serr) if serr else 0.0,
            "worst": max(abs(g - w) / w for (_, g), (_, w) in pairs)}


def decode(frame):
    """Captured frame -> list of matches {proto, d, f, t, masks, repeat, mark_err, space_err, worst}.
    repeat=True: the frame is that protocol's repeat frame (no code in it)."""
    segs = _segments(frame)
    out = []
    for name, p in ir.PROTOCOLS.items():
        if p.repeat is None:
            continue
        ref = [(lvl, n * ir.TICK_US) for lvl, n in ir.frame_ticks(p, p.repeat, 0, 0, 0)]
        while ref and ref[-1][0] == 0:
            ref.pop()
        if len(ref) == len(frame) and (c := _compare(frame, ref)):
            out.append({"proto": name, "repeat": True, **c})
    for name, p in ir.PROTOCOLS.items():
        r = _decode_pulse(p, segs) if isinstance(p.bits, ir.PulseCode) else _decode_biphase(p, segs)
        if r is None:
            continue
        fields, masks = r
        ref = reference_frame(name, fields["D"], fields["F"], fields["T"])
        # the last segment of a frame may end in the gap; compare what both have
        if len(ref) != len(frame) and not (isinstance(p.bits, ir.Biphase) and abs(len(ref) - len(frame)) <= 1):
            continue
        c = _compare(frame, ref)
        if c:
            out.append({"proto": name, "repeat": False, "d": fields["D"], "f": fields["F"],
                        "t": fields["T"], "masks": masks, **c})
    return out


def library_hits(types, match):
    """Library entries whose code for some function equals the decoded one."""
    pid = ircompile.PROTO_ORDER.index(match["proto"])
    md, mf = match["masks"]["D"], match["masks"]["F"]
    hits = []
    for tname, brands in types:
        for bname, sets in brands:
            for sname, cs in sets:
                for func, (p, d, f, _label) in cs.items():
                    if p == pid and (d & md) == match["d"] and (f & mf) == match["f"]:
                        hits.append(f"{tname} / {bname} / {sname}: {func}")
    return hits


# ----------------------------------------------------------------- report
def report(cap, types=None, max_hits=8):
    if cap is None:
        return ["receiver capture: none (file has no capture region; built before v0.10.0?)"]
    if not cap["magic"]:
        return ["receiver capture: empty (no IR burst recorded yet)"]
    lines = [f"receiver capture: 2 buffers x {cap['depth']} edges, latest = buffer {cap['active']}; "
             f"last session kept {cap['kept']} burst(s), rejected {cap['rejected']} (< 20 edges)"]
    order = [cap["active"], 1 - cap["active"]]
    for b in order:
        buf = cap["bufs"][b]
        tag = "latest" if b == cap["active"] else "older"
        if buf["n"] == 0:
            lines.append(f"\nbuffer {b} ({tag}): empty")
            continue
        flags = [x for x, on in (("NOT KEPT (noise?)", not buf["kept"]), ("buffer full", buf["full"]),
                                 ("stopped at 3 s", buf["maxed"]), ("our TX was busy", buf["tx"]),
                                 ("file truncated", buf["truncated"])) if on]
        lines.append(f"\nbuffer {b} ({tag}): {buf['n']} edges stored of {buf['total']}, "
                     f"{us(buf['dur']) / 1000:.1f} ms" + (f"  [{', '.join(flags)}]" if flags else ""))
        if len(buf["entries"]) < 2:
            continue
        a = analyse(buf)
        lines.append(f"  idle level {'HIGH' if a['idle'] else 'LOW'} (active {'LOW' if a['idle'] else 'HIGH'})"
                     + ("" if a["alternates"] else "  WARNING: levels don't alternate"))
        if a["raw"]:
            lines.append(f"  output is RAW: carrier pulses, {a['carrier_hz'] / 1000:.1f} kHz, "
                         f"duty {100 * a['duty']:.0f}%")
        else:
            lines.append("  output is DEMODULATED (no carrier pulses)")
        lines.append(f"  runs shorter than 1 us (chatter): {a['glitches']}")
        lines.append(f"  {len(a['frames'])} frame(s)")
        looked_up = set()
        for k, fr in enumerate(a["frames"][:4]):
            segs = " ".join(f"{'M' if m else 'S'}{d:.0f}" for m, d in fr[:14])
            lines.append(f"  frame {k + 1}: {len(fr)} segments: {segs}{' ...' if len(fr) > 14 else ''}")
            for mt in decode(fr):
                what = "repeat frame" if mt["repeat"] else f"D=0x{mt['d']:X} F=0x{mt['f']:X} T={mt['t']}"
                lines.append(f"    = {mt['proto']} {what}: marks {mt['mark_err']:+.0f} us, "
                             f"spaces {mt['space_err']:+.0f} us vs reference (worst {100 * mt['worst']:.0f}%)")
                key = (mt["proto"], mt.get("d"), mt.get("f"))
                if types is not None and not mt["repeat"] and key not in looked_up:
                    looked_up.add(key)
                    hits = library_hits(types, mt)
                    for h in hits[:max_hits]:
                        lines.append(f"      library: {h}")
                    if len(hits) > max_hits:
                        lines.append(f"      library: ... {len(hits) - max_hits} more")
                    if not hits:
                        lines.append("      library: not found")
    return lines
