"""M5 UI mockup renderer for the Pocket IR Remote.

Renders the screen exactly the way the planned hardware will draw it:
a 40x30 grid of 8x8 tiles over the 320x240 picture, each tile = one 1-bpp
glyph + a foreground and background colour from a 4-colour palette.
The same tile map / glyph data will later be exported as ROM files for the
FPGA, so an approved mockup is what the Pocket shows.

Font: font8x8_basic.h by Daniel Hepper, public domain
(https://github.com/dhepper/font8x8). Custom glyphs live at 0x80+.

Usage:  python tools/ui/ui_design.py            -> docs/ui/*.png
"""

import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
COLS, ROWS, TILE = 40, 30, 8
SCALE = 3

# ---------------------------------------------------------------- constraints
RULES = {
    "R1": "everything is 8x8 tiles on the 40x30 grid",
    "R2": "max 4 colours on screen",
    "R3": "each tile uses exactly one fg + one bg colour",
    "R4": "uppercase ASCII + custom glyphs only (no lowercase)",
    "R5": "1-tile safe margin: nothing but background in col 0/39, row 0/29",
    "R6": "labels <= 10 characters, never truncated",
    "R7": "pressed state readable without colour (inverted tile)",
    "R8": "layout mirrors physical button positions in the 180-degree grip",
    "R9": "nothing may overwrite a panel frame tile",
}


# ---------------------------------------------------------------- font
def load_font():
    text = (Path(__file__).parent / "font8x8_basic.h").read_text()
    rows = re.findall(r"\{\s*((?:0x[0-9A-Fa-f]{2}\s*,?\s*){8})\}", text)
    font = {}
    for code, row in enumerate(rows[:128]):
        font[code] = [int(b, 16) for b in re.findall(r"0x[0-9A-Fa-f]{2}", row)]
    return font


def glyph(pattern):
    """8 strings of '#'/'.' -> 8 bytes, LSB = leftmost pixel (font8x8 order)."""
    out = []
    for line in pattern:
        assert len(line) == 8, line
        out.append(sum(1 << i for i, c in enumerate(line) if c == "#"))
    return out


def big16(pattern):
    """16 strings of 16 chars -> 4 glyphs (TL, TR, BL, BR)."""
    assert len(pattern) == 16 and all(len(l) == 16 for l in pattern)
    q = lambda r0, c0: glyph([l[c0:c0 + 8] for l in pattern[r0:r0 + 8]])
    return [q(0, 0), q(0, 8), q(8, 0), q(8, 8)]


BIG_PLUS = big16([
    "................",
    "......####......",
    "......####......",
    "......####......",
    "......####......",
    "......####......",
    ".##############.",
    ".##############.",
    ".##############.",
    ".##############.",
    "......####......",
    "......####......",
    "......####......",
    "......####......",
    "......####......",
    "................"])
BIG_MINUS = big16([
    "................", "................", "................", "................",
    "................", "................",
    ".##############.", ".##############.", ".##############.", ".##############.",
    "................", "................", "................", "................",
    "................", "................"])

CUSTOM = {
    0x80: glyph(["........", "..####..", ".##..##.", ".#....#.",
                 ".#....#.", ".##..##.", "..####..", "........"]),   # face button
    0x81: glyph(["........", "..####..", ".######.", ".######.",
                 ".######.", ".######.", "..####..", "........"]),   # face button pressed
    0x82: glyph(["...##...", "..####..", ".######.", "########",
                 "...##...", "...##...", "...##...", "........"]),   # arrow up
    0x83: glyph(["........", "...##...", "...##...", "...##...",
                 "########", ".######.", "..####..", "...##..."]),   # arrow down
    0x84: glyph(["...#....", "..##....", ".###....", "########",
                 "########", ".###....", "..##....", "...#...."]),   # arrow left
    0x85: glyph(["....#...", "....##..", "....###.", "########",
                 "########", "....###.", "....##..", "....#..."]),   # arrow right
    0x86: glyph(["...##...", ".#.##.#.", "#..##..#", "#..##..#",
                 "#......#", "#......#", ".#....#.", "..####.."]),   # power
    0x87: glyph(["........", "........", "..####..", "..####..",
                 "..####..", "..####..", "........", "........"]),   # small dot / lamp
    # box drawing (2-px line on the tile centre, NES-menu style)
    0x90: glyph(["........", "........", "........", "...#####",
                 "...#####", "...##...", "...##...", "...##..."]),   # top-left corner
    0x91: glyph(["........", "........", "........", "#####...",
                 "#####...", "...##...", "...##...", "...##..."]),   # top-right corner
    0x92: glyph(["...##...", "...##...", "...##...", "...#####",
                 "...#####", "........", "........", "........"]),   # bottom-left corner
    0x93: glyph(["...##...", "...##...", "...##...", "#####...",
                 "#####...", "........", "........", "........"]),   # bottom-right corner
    0x94: glyph(["........", "........", "........", "########",
                 "########", "........", "........", "........"]),   # horizontal
    0x95: glyph(["...##...", "...##...", "...##...", "...##...",
                 "...##...", "...##...", "...##...", "...##..."]),   # vertical
    0xA0: glyph(["....#...", "...##...", "##.##.#.", "####..#.",
                 "####..#.", "##.##.#.", "...##...", "....#..."]),   # speaker + wave
}
CUSTOM.update(zip((0x98, 0x99, 0x9A, 0x9B), BIG_PLUS))
CUSTOM.update(zip((0x9C, 0x9D, 0x9E, 0x9F), BIG_MINUS))


# ---------------------------------------------------------------- tile map
class Screen:
    def __init__(self, palette, bg=0):
        assert len(palette) <= 4, "R2: palette over 4 colours"
        self.palette = palette
        self.bg = bg
        self.tiles = [[(0x20, 3, bg) for _ in range(COLS)] for _ in range(ROWS)]
        self.labels = []   # (text, col, row) for checks
        self.frame = set() # tiles owned by a box border
        self.problems = []

    def put(self, col, row, code, fg, bg, frame=False):
        assert 0 <= col < COLS and 0 <= row < ROWS, f"R1: tile ({col},{row}) off grid"
        if (col, row) in self.frame and not frame:
            self.problems.append(f"R9: overwrote frame tile at ({col},{row})")
        if frame:
            self.frame.add((col, row))
        self.tiles[row][col] = (code, fg, bg)

    def text(self, col, row, s, fg, bg=None, label=True):
        bg = self.bg if bg is None else bg
        assert s == s.upper(), f"R4: lowercase in {s!r}"
        for i, ch in enumerate(s):
            self.put(col + i, row, ord(ch), fg, bg)
        if label:
            self.labels.append((s, col, row))

    def text_c(self, centre_col, row, s, fg, bg=None, label=True):
        self.text(centre_col - len(s) // 2, row, s, fg, bg, label)

    def text_r(self, right_col, row, s, fg, bg=None, label=True):
        self.text(right_col - len(s) + 1, row, s, fg, bg, label)

    def fill(self, c0, r0, c1, r1, colour):
        for r in range(r0, r1 + 1):
            for c in range(c0, c1 + 1):
                self.put(c, r, 0x20, colour, colour)

    def box(self, c0, r0, c1, r1, fg, bg=None, fill=None):
        bg = self.bg if bg is None else bg
        inner = bg if fill is None else fill
        for c in range(c0 + 1, c1):
            self.put(c, r0, 0x94, fg, bg, True); self.put(c, r1, 0x94, fg, bg, True)
        for r in range(r0 + 1, r1):
            self.put(c0, r, 0x95, fg, bg, True); self.put(c1, r, 0x95, fg, bg, True)
            for c in range(c0 + 1, c1):
                self.put(c, r, 0x20, inner, inner)
        self.put(c0, r0, 0x90, fg, bg, True); self.put(c1, r0, 0x91, fg, bg, True)
        self.put(c0, r1, 0x92, fg, bg, True); self.put(c1, r1, 0x93, fg, bg, True)

    def big(self, col, row, sign, fg, bg):
        codes = (0x98, 0x99, 0x9A, 0x9B) if sign == "+" else (0x9C, 0x9D, 0x9E, 0x9F)
        self.put(col, row, codes[0], fg, bg); self.put(col + 1, row, codes[1], fg, bg)
        self.put(col, row + 1, codes[2], fg, bg); self.put(col + 1, row + 1, codes[3], fg, bg)

    # ------------------------------------------------------------ checks
    def check(self):
        problems = list(self.problems)
        for r in range(ROWS):
            for c in range(COLS):
                code, fg, bg = self.tiles[r][c]
                edge = r in (0, ROWS - 1) or c in (0, COLS - 1)
                if edge and (code != 0x20 or bg != self.bg):
                    problems.append(f"R5: non-background tile at margin ({c},{r})")
        for s, c, r in self.labels:
            if len(s.strip()) > 10 and not s.startswith(" "):
                problems.append(f"R6: label {s!r} longer than 10 chars")
        return problems

    # ------------------------------------------------------------ render
    def render(self, font):
        img = Image.new("RGB", (COLS * TILE, ROWS * TILE))
        px = img.load()
        for r in range(ROWS):
            for c in range(COLS):
                code, fg, bg = self.tiles[r][c]
                bits = CUSTOM.get(code) or font.get(code)
                assert bits is not None, f"R4: no glyph for 0x{code:02X}"
                for y in range(TILE):
                    for x in range(TILE):
                        on = (bits[y] >> x) & 1
                        px[c * TILE + x, r * TILE + y] = self.palette[fg if on else bg]
        colours = {px[x, y] for x in range(img.width) for y in range(img.height)}
        assert len(colours) <= 4, f"R2: {len(colours)} colours rendered"
        return img.resize((img.width * SCALE, img.height * SCALE), Image.NEAREST)


# ================================================================= designs
# Buttons by function. "pos" = where the button sits in the 180-degree grip.
FUNCS = ["POWER", "MUTE", "VOL+", "VOL-", "UP", "DOWN", "LEFT", "RIGHT",
         "ENTER", "BACK", "AMP MENU", "OPTIONS"]


def design_v1(pressed=None):
    """First pass: header, two diamonds mirroring the grip, shoulders at bottom."""
    pal = [(16, 16, 24), (80, 84, 110), (200, 196, 210), (250, 208, 60)]
    BG, MID, FG, ACC = 0, 1, 2, 3
    s = Screen(pal, bg=BG)

    def lab(col, row, txt, func, align="c"):
        on = (pressed == func)
        fg, bg = (BG, ACC) if on else (FG, BG)
        {"c": s.text_c, "r": s.text_r, "l": s.text}[align](col, row, txt, fg, bg)

    # header bar
    s.fill(1, 1, 38, 3, MID)
    s.text(3, 2, "SONY STR-DH790", FG, MID)
    s.text_r(36, 2, "SENDING" if pressed else "READY", ACC if pressed else FG, MID)

    # start / select row (start on the left, select on the right in the grip)
    lab(3, 6, "START: POWER", "POWER", "l")
    lab(36, 6, "SELECT: MUTE", "MUTE", "r")

    # face-button diamond (left side of the grip)
    cx, cy = 10, 15
    for dx, dy, func in [(0, -2, "AMP MENU"), (-2, 0, "OPTIONS"), (2, 0, "ENTER"), (0, 2, "BACK")]:
        s.put(cx + dx, cy + dy, 0x81 if pressed == func else 0x80, ACC if pressed == func else FG, BG)
    lab(cx, cy - 4, "AMP MENU", "AMP MENU")
    lab(cx - 4, cy, "OPTIONS", "OPTIONS", "r")
    lab(cx + 4, cy, "ENTER", "ENTER", "l")
    lab(cx, cy + 4, "BACK", "BACK")

    # d-pad diamond (right side of the grip)
    dx0, dy0 = 29, 15
    for dx, dy, code, func in [(0, -2, 0x82, "UP"), (0, 2, 0x83, "DOWN"),
                               (-2, 0, 0x84, "LEFT"), (2, 0, 0x85, "RIGHT")]:
        s.put(dx0 + dx, dy0 + dy, code, ACC if pressed == func else FG, BG)
    s.text_c(dx0, dy0 + 4, "MENU NAV", MID)

    # shoulders (bottom edge of the grip): R1 left = VOL-, L1 right = VOL+
    lab(3, 25, "VOL-", "VOL-", "l")
    lab(36, 25, "VOL+", "VOL+", "r")
    return s


def design_v2(pressed=None):
    """Framed NES-style panels; volume/power promoted; labels hug their buttons;
    one pressed treatment everywhere: accent background, dark glyph."""
    pal = [(14, 14, 22), (96, 104, 140), (226, 222, 232), (255, 200, 40)]
    BG, LINE, FG, ACC = 0, 1, 2, 3
    s = Screen(pal, bg=BG)
    on = lambda f: pressed == f
    ink = lambda f: (BG, ACC) if on(f) else (FG, BG)      # (fg, bg) for labels

    # header: title + TX lamp
    s.box(1, 1, 38, 3, LINE)
    s.text(3, 2, "SONY STR-DH790", FG, label=False)
    s.text(33, 2, "TX", ACC if pressed else LINE)
    s.put(36, 2, 0x87, ACC if pressed else LINE, BG)

    # power (Start, left) and mute (Select, right) -- top edge of the grip
    for c0, c1, func, icon in [(1, 13, "POWER", 0x86), (26, 38, "MUTE", 0xA0)]:
        f, b = ink(func)
        s.box(c0, 5, c1, 7, ACC if on(func) else LINE, fill=b)
        s.put(c0 + 2, 6, icon, f, b)
        s.text(c0 + 4, 6, func, f, b)

    # face-button panel (left in the grip)
    s.box(1, 9, 23, 21, LINE)
    cx, cy = 12, 15
    for dx, dy, func in [(0, -2, "AMP MENU"), (-2, 0, "OPTIONS"), (2, 0, "ENTER"), (0, 2, "BACK")]:
        f, b = ink(func)
        s.put(cx + dx, cy + dy, 0x81 if on(func) else 0x80, ACC if on(func) else FG, BG)
    f, b = ink("AMP MENU"); s.text_c(cx, cy - 3, "AMP MENU", f, b)
    f, b = ink("OPTIONS");  s.text_r(cx - 4, cy, "OPTIONS", f, b)
    f, b = ink("ENTER");    s.text(cx + 4, cy, "ENTER", f, b)
    f, b = ink("BACK");     s.text_c(cx, cy + 3, "BACK", f, b)

    # d-pad panel (right in the grip): a real cross of tiles
    s.box(25, 9, 38, 21, LINE)
    dx0 = 31
    s.put(dx0, cy, 0x20, LINE, LINE)                        # hub
    for dx, dy, code, func in [(0, -1, 0x82, "UP"), (0, 1, 0x83, "DOWN"),
                               (-1, 0, 0x84, "LEFT"), (1, 0, 0x85, "RIGHT")]:
        f, b = (BG, ACC) if on(func) else (FG, LINE)
        s.put(dx0 + dx, cy + dy, code, f, b)
    s.text_c(dx0 + 1, cy + 3, "MENU", FG)

    # shoulders (bottom edge of the grip): R1 left = VOL-, L1 right = VOL+
    for c0, c1, func, sign in [(1, 13, "VOL-", "-"), (26, 38, "VOL+", "+")]:
        f, b = ink(func)
        s.box(c0, 23, c1, 28, ACC if on(func) else LINE, fill=b)
        s.big(c0 + 2, 25, sign, f, b)
        s.text(c0 + 5, 25, "VOL", f, b, label=False)
        s.text(c0 + 5, 26, "+" if sign == "+" else "-", f, b, label=False)
    return s


def design_v3(pressed=None):
    """v2 + real 16-px signs, VOLUME UP/DOWN copy, padded circles, padded label
    chips, 5x5 d-pad, clearer speaker."""
    pal = [(14, 14, 22), (96, 104, 140), (226, 222, 232), (255, 200, 40)]
    BG, LINE, FG, ACC = 0, 1, 2, 3
    s = Screen(pal, bg=BG)
    on = lambda f: pressed == f
    ink = lambda f: (BG, ACC) if on(f) else (FG, BG)

    def chip(col, row, txt, func, align="l"):
        """label with a 1-tile pad each side so the pressed state is a chip"""
        f, b = ink(func)
        padded = f" {txt} "
        start = {"l": col - 1, "r": col - len(txt), "c": col - len(txt) // 2 - 1}[align]
        s.text(start, row, padded, f, b, label=False)
        s.labels.append((txt, start + 1, row))

    s.box(1, 1, 38, 3, LINE)
    s.text(3, 2, "SONY STR-DH790", FG, label=False)
    s.text(33, 2, "TX", ACC if pressed else LINE)
    s.put(36, 2, 0x87, ACC if pressed else LINE, BG)

    for c0, c1, func, icon in [(1, 13, "POWER", 0x86), (26, 38, "MUTE", 0xA0)]:
        f, b = ink(func)
        s.box(c0, 5, c1, 7, ACC if on(func) else LINE, fill=b)
        s.put(c0 + 2, 6, icon, f, b)
        s.text(c0 + 4, 6, func, f, b)

    # face buttons
    s.box(1, 9, 23, 21, LINE)
    cx, cy = 12, 15
    for dx, dy, func in [(0, -2, "AMP MENU"), (-2, 0, "OPTIONS"), (2, 0, "ENTER"), (0, 2, "BACK")]:
        s.put(cx + dx, cy + dy, 0x81 if on(func) else 0x80, ACC if on(func) else FG, BG)
    chip(cx, cy - 3, "AMP MENU", "AMP MENU", "c")
    chip(cx - 4, cy, "OPTIONS", "OPTIONS", "r")
    chip(cx + 4, cy, "ENTER", "ENTER", "l")
    chip(cx, cy + 3, "BACK", "BACK", "c")

    # d-pad: 5x5 cross, arms in LINE, arrow tips in FG (accent when pressed)
    s.box(25, 9, 38, 21, LINE)
    dx0 = 31
    for d in (-1, 0, 1):
        s.put(dx0 + d, cy, 0x20, LINE, LINE)
        s.put(dx0, cy + d, 0x20, LINE, LINE)
    for dx, dy, code, func in [(0, -2, 0x82, "UP"), (0, 2, 0x83, "DOWN"),
                               (-2, 0, 0x84, "LEFT"), (2, 0, 0x85, "RIGHT")]:
        s.put(dx0 + dx, cy + dy, code, BG if on(func) else FG, ACC if on(func) else BG)
    s.text_c(dx0 + 1, cy + 4, "MENU", FG)

    # volume: biggest targets on screen
    for c0, c1, func, sign, word in [(1, 13, "VOL-", "-", "DOWN"), (26, 38, "VOL+", "+", "UP")]:
        f, b = ink(func)
        s.box(c0, 23, c1, 28, ACC if on(func) else LINE, fill=b)
        s.big(c0 + 2, 25, sign, f, b)
        s.text(c0 + 5, 25, "VOLUME", f, b)
        s.text(c0 + 5, 26, word, f, b)
    return s


def design_v4(pressed=None):
    """v3 + face panel 3 tiles wider, 1-tile gap between button and chip,
    frame-overwrite check."""
    pal = [(14, 14, 22), (96, 104, 140), (226, 222, 232), (255, 200, 40)]
    BG, LINE, FG, ACC = 0, 1, 2, 3
    s = Screen(pal, bg=BG)
    on = lambda f: pressed == f
    ink = lambda f: (BG, ACC) if on(f) else (FG, BG)

    def chip(col, row, txt, func, align="l"):
        """label with a 1-tile pad each side so the pressed state is a chip"""
        f, b = ink(func)
        padded = f" {txt} "
        start = {"l": col - 1, "r": col - len(txt), "c": col - len(txt) // 2 - 1}[align]
        s.text(start, row, padded, f, b, label=False)
        s.labels.append((txt, start + 1, row))

    s.box(1, 1, 38, 3, LINE)
    s.text(3, 2, "SONY STR-DH790", FG, label=False)
    s.text(33, 2, "TX", ACC if pressed else LINE)
    s.put(36, 2, 0x87, ACC if pressed else LINE, BG)

    for c0, c1, func, icon in [(1, 13, "POWER", 0x86), (26, 38, "MUTE", 0xA0)]:
        f, b = ink(func)
        s.box(c0, 5, c1, 7, ACC if on(func) else LINE, fill=b)
        s.put(c0 + 2, 6, icon, f, b)
        s.text(c0 + 4, 6, func, f, b)

    # face buttons
    s.box(1, 9, 26, 21, LINE)
    cx, cy = 14, 15
    for dx, dy, func in [(0, -2, "AMP MENU"), (-2, 0, "OPTIONS"), (2, 0, "ENTER"), (0, 2, "BACK")]:
        s.put(cx + dx, cy + dy, 0x81 if on(func) else 0x80, ACC if on(func) else FG, BG)
    chip(cx, cy - 3, "AMP MENU", "AMP MENU", "c")
    chip(cx - 5, cy, "OPTIONS", "OPTIONS", "r")
    chip(cx + 5, cy, "ENTER", "ENTER", "l")
    chip(cx, cy + 3, "BACK", "BACK", "c")

    # d-pad: 5x5 cross, arms in LINE, arrow tips in FG (accent when pressed)
    s.box(28, 9, 38, 21, LINE)
    dx0 = 33
    for d in (-1, 0, 1):
        s.put(dx0 + d, cy, 0x20, LINE, LINE)
        s.put(dx0, cy + d, 0x20, LINE, LINE)
    for dx, dy, code, func in [(0, -2, 0x82, "UP"), (0, 2, 0x83, "DOWN"),
                               (-2, 0, 0x84, "LEFT"), (2, 0, 0x85, "RIGHT")]:
        s.put(dx0 + dx, cy + dy, code, BG if on(func) else FG, ACC if on(func) else BG)
    s.text_c(dx0 + 1, cy + 4, "MENU", FG)

    # volume: biggest targets on screen
    for c0, c1, func, sign, word in [(1, 13, "VOL-", "-", "DOWN"), (26, 38, "VOL+", "+", "UP")]:
        f, b = ink(func)
        s.box(c0, 23, c1, 28, ACC if on(func) else LINE, fill=b)
        s.big(c0 + 2, 25, sign, f, b)
        s.text(c0 + 5, 25, "VOLUME", f, b)
        s.text(c0 + 5, 26, word, f, b)
    return s


DESIGNS = {"v1": design_v1, "v2": design_v2, "v3": design_v3, "v4": design_v4}


def main(argv):
    font = load_font()
    out = ROOT / "docs" / "ui"
    out.mkdir(parents=True, exist_ok=True)
    names = argv[1:] or list(DESIGNS)
    for name in names:
        for state in [None, "ENTER", "VOL+"]:
            scr = DESIGNS[name](state)
            problems = scr.check()
            tag = "idle" if state is None else state.lower().replace(" ", "_").replace("+", "plus")
            path = out / f"m5_{name}_{tag}.png"
            scr.render(font).save(path)
            print(f"{path.relative_to(ROOT)}  {'OK' if not problems else ''}")
            for p in problems:
                print("   ", p)


if __name__ == "__main__":
    main(sys.argv)
