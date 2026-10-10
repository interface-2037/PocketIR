"""IR protocol definitions and reference encoder (M6).

Protocols are described with a handful of operations that map 1:1 onto the
FPGA protocol engine's microcode (docs/m6-plan.md, tools/ir/ircompile.py):

    Mark(us)             carrier on
    Space(us)            carrier off
    Send(src, lsb, n)    n bits of a field using the protocol's bit encoding
    GapTo(us)            carrier off until `us` after the frame started

All times are in microseconds and are quantised to the engine tick, TICK_US =
4 us (exactly 297 clocks at 74.25 MHz). Every timing below is a multiple of
4 us or within 2 us of one, far inside IR receiver tolerance.

A protocol has a `frame` (sent first) and an optional `repeat` frame (sent while
the button is held; defaults to `frame`), a minimum number of frames per tap,
a carrier and a bit encoding. Field packing that needs checksums (Kaseikyo) is
done here by `pack`, so the engine only ever sends plain bit fields.

Behaviour follows Flipper Zero's encoders (flipperdevices/flipperzero-firmware,
lib/infrared/encoder_decoder), because the code library comes from Flipper-IRDB
and was captured/verified with them: same field packing, bit order, stop bits,
repeat codes and silences. Deviations: carrier duty is 50 % (best range on the
Pocket, M3) instead of 33 %, transmissions start without a leading silence, and
Manchester frames keep their final half-bit space (< 1 ms longer gap).

The reference encoder turns {protocol, address, command, toggle, frames} into
an exact list of (level, clock cycles) runs. It is the test oracle for the RTL.

Fields:  D = address word, F = command word, T = toggle bit (flips once per
         press, starting at 0), C = constant (Send.const).
"""

from dataclasses import dataclass
from typing import Callable, List, Optional, Tuple, Union

CLK_HZ = 74_250_000
TICK_US = 4


# ----------------------------------------------------------------- operations
@dataclass(frozen=True)
class Mark:
    us: int


@dataclass(frozen=True)
class Space:
    us: int


@dataclass(frozen=True)
class Send:
    src: str                 # "D", "F", "T" or "C"
    lsb: int = 0             # first bit index taken from the field
    count: int = 8
    msb_first: bool = False
    invert: bool = False
    const: int = 0           # value when src == "C"
    shift: int = 0           # bit timings scaled by 2**shift (RC6 toggle bit: 1)


@dataclass(frozen=True)
class GapTo:
    us: int


Op = Union[Mark, Space, Send, GapTo]


# ----------------------------------------------------------------- bit encodings
@dataclass(frozen=True)
class PulseCode:
    """Pulse-distance / pulse-width: bit 0 = (mark m0, space s0), bit 1 = (m1, s1), in us."""
    m0: int
    s0: int
    m1: int
    s1: int


@dataclass(frozen=True)
class Biphase:
    """Manchester, half-bit `half` us.
    one_mark_first=False (RC5): 1 = space then mark, 0 = mark then space.
    one_mark_first=True  (RC6): 1 = mark then space, 0 = space then mark."""
    half: int
    one_mark_first: bool


def _identity(address: int, command: int) -> Tuple[int, int]:
    return address, command


@dataclass(frozen=True)
class Protocol:
    name: str
    carrier_hz: int
    duty_pct: int
    bits: Union[PulseCode, Biphase]
    frame: List[Op]
    repeat: Optional[List[Op]] = None     # None: repeat the frame itself
    min_frames: int = 1
    pack: Callable[[int, int], Tuple[int, int]] = _identity   # (address, command) -> (D, F)


# ----------------------------------------------------------------- protocols
def _sirc(nbits: int) -> Protocol:
    addr_bits = {12: 5, 15: 8, 20: 13}[nbits]
    return Protocol(
        name=f"SIRC{nbits}", carrier_hz=40_000, duty_pct=50,
        bits=PulseCode(m0=600, s0=600, m1=1200, s1=600),
        frame=[Mark(2400), Space(600), Send("F", 0, 7), Send("D", 0, addr_bits), GapTo(45_000)],
        min_frames=3)


NEC_BITS = PulseCode(m0=560, s0=560, m1=560, s1=1690)
NEC_REPEAT = [Mark(9000), Space(2250), Mark(560), GapTo(110_000)]

NEC = Protocol(
    name="NEC", carrier_hz=38_000, duty_pct=50, bits=NEC_BITS,
    frame=[Mark(9000), Space(4500), Send("D", 0, 8), Send("D", 0, 8, invert=True),
           Send("F", 0, 8), Send("F", 0, 8, invert=True), Mark(560), GapTo(110_000)],
    repeat=NEC_REPEAT)

NECEXT = Protocol(
    name="NECext", carrier_hz=38_000, duty_pct=50, bits=NEC_BITS,
    frame=[Mark(9000), Space(4500), Send("D", 0, 16), Send("F", 0, 16), Mark(560), GapTo(110_000)],
    repeat=NEC_REPEAT)

SAMSUNG32 = Protocol(
    name="Samsung32", carrier_hz=38_000, duty_pct=50,
    bits=PulseCode(m0=550, s0=550, m1=550, s1=1650),
    frame=[Mark(4500), Space(4500), Send("D", 0, 8), Send("D", 0, 8),
           Send("F", 0, 8), Send("F", 0, 8, invert=True), Mark(550), Space(46_000)],
    repeat=[Mark(4500), Space(4500), Mark(550), Space(1650), Mark(550), Space(97_000)])


def _rc5(name: str, s2: int) -> Protocol:
    return Protocol(
        name=name, carrier_hz=36_000, duty_pct=50, bits=Biphase(half=888, one_mark_first=False),
        frame=[Send("C", count=1, const=1), Send("C", count=1, const=s2), Send("T", 0, 1),
               Send("D", 0, 5, msb_first=True), Send("F", 0, 6, msb_first=True), Space(27_000)])


RC6 = Protocol(
    name="RC6", carrier_hz=36_000, duty_pct=50, bits=Biphase(half=444, one_mark_first=True),
    frame=[Mark(2666), Space(889), Send("C", count=1, const=1), Send("C", count=3, const=0),
           Send("T", 0, 1, shift=1), Send("D", 0, 8, msb_first=True), Send("F", 0, 8, msb_first=True),
           Space(27_000)])


def _pack_kaseikyo(address: int, command: int) -> Tuple[int, int]:
    """Flipper's Kaseikyo packing: address = id[25:24] vendor[23:8] genre1[7:4] genre2[3:0],
    command 10 bits; vendor parity and an XOR checksum byte. Returns (D = bytes 0-3, F = bytes 4-5)."""
    ident = (address >> 24) & 3
    vendor = (address >> 8) & 0xFFFF
    genre1, genre2 = (address >> 4) & 0xF, address & 0xF
    b = [vendor & 0xFF, vendor >> 8, 0, 0, 0, 0]
    b[2] = ((b[0] ^ b[1]) & 0xF) | (genre1 << 4)
    b[3] = (genre2 & 0xF) | ((command & 0xF) << 4)
    b[4] = ((ident << 6) | (command >> 4)) & 0xFF
    b[5] = b[2] ^ b[3] ^ b[4]
    return b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24, b[4] | b[5] << 8


KASEIKYO = Protocol(
    name="Kaseikyo", carrier_hz=38_000, duty_pct=50,
    bits=PulseCode(m0=432, s0=432, m1=432, s1=1296),
    frame=[Mark(3456), Space(1728), Send("D", 0, 32), Send("F", 0, 16), Mark(432), Space(130_000)],
    pack=_pack_kaseikyo)

RCA = Protocol(
    name="RCA", carrier_hz=38_000, duty_pct=50,
    bits=PulseCode(m0=500, s0=1000, m1=500, s1=2000),
    frame=[Mark(4000), Space(4000), Send("D", 0, 4), Send("F", 0, 8),
           Send("D", 0, 4, invert=True), Send("F", 0, 8, invert=True), Mark(500), Space(8000)])

PIONEER = Protocol(
    name="Pioneer", carrier_hz=40_000, duty_pct=50,
    bits=PulseCode(m0=500, s0=500, m1=500, s1=1500),
    frame=[Mark(8500), Space(4225), Send("D", 0, 8), Send("D", 0, 8, invert=True),
           Send("F", 0, 8), Send("F", 0, 8, invert=True), Send("C", count=1, const=0),
           Mark(500), Space(26_000)],
    min_frames=2)

PROTOCOLS = {p.name: p for p in [
    _sirc(12), _sirc(15), _sirc(20), NEC, NECEXT, SAMSUNG32,
    _rc5("RC5", 1), _rc5("RC5X", 0), RC6, KASEIKYO, RCA, PIONEER]}


# ----------------------------------------------------------------- encoder
def ticks(us: float) -> int:
    """Microseconds -> engine ticks (rounded to the nearest TICK_US)."""
    return int(us / TICK_US + 0.5)


def tick_cycles(clk_hz: int = CLK_HZ) -> int:
    c = TICK_US * clk_hz / 1e6
    assert abs(c - round(c)) < 1e-9, f"{TICK_US} us is not a whole number of cycles at {clk_hz} Hz"
    return round(c)


def _bits(op: Send, d: int, f: int, t: int) -> List[int]:
    v = {"D": d, "F": f, "T": t, "C": op.const}[op.src]
    bits = [(v >> (op.lsb + i)) & 1 for i in range(op.count)]
    if op.msb_first:
        bits.reverse()
    if op.invert:
        bits = [b ^ 1 for b in bits]
    return bits


def frame_ticks(p: Protocol, ops: List[Op], d: int, f: int, t: int) -> List[tuple]:
    """One frame as (level, ticks) runs, merged, ending after its last op."""
    runs, elapsed = [], 0

    def emit(level, n):
        nonlocal elapsed
        if n <= 0:
            return
        if runs and runs[-1][0] == level:
            runs[-1] = (level, runs[-1][1] + n)
        else:
            runs.append((level, n))
        elapsed += n

    for op in ops:
        if isinstance(op, Mark):
            emit(1, ticks(op.us))
        elif isinstance(op, Space):
            emit(0, ticks(op.us))
        elif isinstance(op, GapTo):
            assert ticks(op.us) >= elapsed, f"{p.name}: frame longer than GapTo({op.us})"
            emit(0, ticks(op.us) - elapsed)
        elif isinstance(op, Send):
            k = 1 << op.shift
            for b in _bits(op, d, f, t):
                if isinstance(p.bits, PulseCode):
                    emit(1, k * ticks(p.bits.m1 if b else p.bits.m0))
                    emit(0, k * ticks(p.bits.s1 if b else p.bits.s0))
                else:
                    first = 1 if (b == 1) == p.bits.one_mark_first else 0
                    emit(first, k * ticks(p.bits.half))
                    emit(1 - first, k * ticks(p.bits.half))
    return runs


def encode(name: str, address: int, command: int, toggle: int = 0,
           frames: int = 1, clk_hz: int = CLK_HZ) -> List[tuple]:
    """Whole button press as (level, cycles) runs: max(frames, min_frames) frames.
    Leading space (if a frame starts with one) is kept; callers comparing from the
    first mark should drop it."""
    p = PROTOCOLS[name]
    d, f = p.pack(address, command)
    u = tick_cycles(clk_hz)
    out = []
    for i in range(max(frames, p.min_frames)):
        ops = p.frame if (i == 0 or p.repeat is None) else p.repeat
        for level, n in frame_ticks(p, ops, d, f, toggle):
            if out and out[-1][0] == level:
                out[-1] = (level, out[-1][1] + n * u)
            else:
                out.append((level, n * u))
    return out


def sent_word(name: str, address: int, command: int) -> int:
    """Bits of the first frame in send order, first bit = MSB (LIRC style)."""
    p = PROTOCOLS[name]
    d, f = p.pack(address, command)
    word = 0
    for op in p.frame:
        if isinstance(op, Send):
            for b in _bits(op, d, f, 0):
                word = (word << 1) | b
    return word
