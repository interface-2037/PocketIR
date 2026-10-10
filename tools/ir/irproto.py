"""IR protocol definitions and reference encoder (M6).

Protocols are described with a handful of operations that map 1:1 onto the
FPGA protocol engine's microcode (docs/m6-plan.md):

    Mark(n)              carrier on for n units
    Space(n)             carrier off for n units
    Send(src, lsb, n)    n bits of a field using the protocol's bit encoding
    GapTo(n)             carrier off until n units after the frame started

A protocol has a `frame` (sent first) and an optional `repeat` frame (sent
while the button is held; defaults to `frame`), a minimum number of frames per
tap, a carrier, a time unit and a bit encoding.

The reference encoder turns {protocol, address, command, toggle, frames} into
an exact list of (level, clock cycles) runs. It is the test oracle for the RTL.

Fields:  D = address, F = command, T = toggle bit (flips once per press),
         C = constant (value in Send.const).
"""

from dataclasses import dataclass, field
from typing import List, Optional, Union

CLK_HZ = 74_250_000


# ----------------------------------------------------------------- operations
@dataclass(frozen=True)
class Mark:
    n: int


@dataclass(frozen=True)
class Space:
    n: int


@dataclass(frozen=True)
class Send:
    src: str                 # "D", "F", "T" or "C"
    lsb: int = 0             # first bit index taken from the field
    count: int = 8
    msb_first: bool = False
    invert: bool = False
    const: int = 0           # value when src == "C"


@dataclass(frozen=True)
class GapTo:
    n: int


Op = Union[Mark, Space, Send, GapTo]


# ----------------------------------------------------------------- bit encodings
@dataclass(frozen=True)
class PulseCode:
    """Pulse-distance / pulse-width: bit 0 = (mark m0, space s0), bit 1 = (m1, s1)."""
    m0: int
    s0: int
    m1: int
    s1: int


@dataclass(frozen=True)
class Biphase:
    """Manchester: each bit is two half-bits of `half` units.
    one_mark_first=False (RC5): 1 = space then mark, 0 = mark then space.
    one_mark_first=True  (RC6): 1 = mark then space, 0 = space then mark."""
    half: int
    one_mark_first: bool


@dataclass(frozen=True)
class Protocol:
    name: str
    carrier_hz: int
    duty_pct: int
    unit_us: float
    bits: Union[PulseCode, Biphase]
    frame: List[Op]
    repeat: Optional[List[Op]] = None     # None: repeat the frame itself
    min_frames: int = 1


# ----------------------------------------------------------------- protocols
def _sirc(nbits: int) -> Protocol:
    addr_bits = {12: 5, 15: 8, 20: 13}[nbits]
    return Protocol(
        name=f"SIRC{nbits}", carrier_hz=40_000, duty_pct=50, unit_us=600,
        bits=PulseCode(m0=1, s0=1, m1=2, s1=1),
        frame=[Mark(4), Space(1), Send("F", 0, 7), Send("D", 0, addr_bits), GapTo(75)],
        min_frames=3)


PROTOCOLS = {p.name: p for p in [_sirc(12), _sirc(15), _sirc(20)]}


# ----------------------------------------------------------------- encoder
def unit_cycles(p: Protocol, clk_hz: int = CLK_HZ) -> int:
    return round(p.unit_us * clk_hz / 1e6)


def _bits(op: Send, d: int, f: int, t: int) -> List[int]:
    v = {"D": d, "F": f, "T": t, "C": op.const}[op.src]
    bits = [(v >> (op.lsb + i)) & 1 for i in range(op.count)]
    if op.msb_first:
        bits.reverse()
    if op.invert:
        bits = [b ^ 1 for b in bits]
    return bits


def frame_units(p: Protocol, ops: List[Op], d: int, f: int, t: int) -> List[tuple]:
    """One frame as (level, units) runs, merged, ending at its GapTo."""
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
            emit(1, op.n)
        elif isinstance(op, Space):
            emit(0, op.n)
        elif isinstance(op, GapTo):
            assert op.n >= elapsed, f"{p.name}: frame longer than GapTo({op.n})"
            emit(0, op.n - elapsed)
        elif isinstance(op, Send):
            for b in _bits(op, d, f, t):
                if isinstance(p.bits, PulseCode):
                    emit(1, p.bits.m1 if b else p.bits.m0)
                    emit(0, p.bits.s1 if b else p.bits.s0)
                else:
                    first = 1 if (b == 1) == p.bits.one_mark_first else 0
                    emit(first, p.bits.half)
                    emit(1 - first, p.bits.half)
    return runs


def encode(name: str, address: int, command: int, toggle: int = 0,
           frames: int = 1, clk_hz: int = CLK_HZ) -> List[tuple]:
    """Whole button press as (level, cycles) runs: max(frames, min_frames) frames."""
    p = PROTOCOLS[name]
    u = unit_cycles(p, clk_hz)
    out = []
    for i in range(max(frames, p.min_frames)):
        ops = p.frame if (i == 0 or p.repeat is None) else p.repeat
        for level, n in frame_units(p, ops, address, command, toggle):
            if out and out[-1][0] == level:
                out[-1] = (level, out[-1][1] + n * u)
            else:
                out.append((level, n * u))
    return out


def sent_word(name: str, address: int, command: int) -> int:
    """Bits of the first frame in send order, first bit = MSB (LIRC style)."""
    p = PROTOCOLS[name]
    word = 0
    for op in p.frame:
        if isinstance(op, Send):
            for b in _bits(op, address, command, 0):
                word = (word << 1) | b
    return word
