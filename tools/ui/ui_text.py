"""Runtime text layer (M7): fonts, slots, exact reference renderer, ROM export.

The same code draws the mockups (ui_m7.py) and generates the hardware data, so
what the mockups show is what src/fpga/core/ui/ui_text.v draws, pixel for pixel.

Hardware model (ui_text.v):
  * fonts: glyph sheets for ASCII 32..95, alpha 0..16 per pixel, each glyph
    cropped to its advance width (<= 16 px, stored in a 16-px cell)
  * 32 slots: y_top, x, align (0 left, 1 centre, 2 right), font (0 small,
    1 big), colour id, lit colour id, lit region (0 = never lit); text in a
    32-byte string RAM per slot, NUL-terminated (empty = slot off)
  * a slot is drawn in its lit colour while its region is the active one
  * pixel = (background * (16 - a) + colour * a) >> 4, per channel
  * slots must not overlap (later slots would overwrite earlier ones)

Usage:  python tools/ui/ui_text.py
  -> src/fpga/core/ui/font_small.bin, font_big.bin, font_adv.bin (5-bit binary),
     text_slots.hex, text_str.hex, ui_text.vh
  -> build/ui_expected/idle.hex, enter.hex (picture from ui_rom.py + text)
"""

import sys
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
import ui_hires as hr  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
W, H = 400, 360
FIRST, NCHARS, CELL = 32, 64, 16            # ASCII 32..95, 16-px cells
NSLOTS, SLOT_CHARS = 32, 32

# colour ids (text palette)
COLOURS = [hr.TITLE, hr.LABEL, (150, 152, 160), (92, 94, 102), hr.ACC, hr.ACC_DARK]
TITLE, LABEL, SUB, DIM, ACC, ACC_DARK = range(6)


class GlyphFont:
    def __init__(self, size, weight="SemiBold"):
        f = ImageFont.truetype(str(hr.FONT), size)
        f.set_variation_by_name(weight)
        asc, desc = f.getmetrics()
        self.h, self.asc = asc + desc, asc
        self.cap = -f.getbbox("H", anchor="ls")[1]
        self.adv, self.alpha = [], []
        for code in range(FIRST, FIRST + NCHARS):
            ch = chr(code)
            adv = int(round(f.getlength(ch)))
            assert adv <= CELL, f"glyph {ch!r} advance {adv} > {CELL}"
            img = Image.new("L", (CELL, self.h))
            ImageDraw.Draw(img).text((0, asc), ch, font=f, fill=255, anchor="ls")
            px = img.load()
            self.adv.append(adv)
            self.alpha.append([[(px[x, y] * 16 + 127) // 255 if x < adv else 0 for x in range(CELL)]
                               for y in range(self.h)])

    def width(self, s):
        return sum(self.adv[ord(c) - FIRST] for c in s)

    def top(self, y_centre):
        """glyph-cell top row for capitals centred on y_centre"""
        return y_centre - self.cap // 2 - (self.asc - self.cap)


FONTS = [GlyphFont(11), GlyphFont(15, "Bold")]


@dataclass
class Slot:
    x: int
    y_top: int
    align: int = 0          # 0 left, 1 centre, 2 right
    font: int = 0
    colour: int = LABEL
    lit_colour: int = ACC
    lit_region: int = 0
    text: str = ""

    def word(self):
        return ((self.y_top & 0x1FF) | (self.x & 0x1FF) << 9 | self.align << 18 | self.font << 20 |
                self.colour << 21 | self.lit_colour << 24 | self.lit_region << 27)


def slot(x, y_centre, text, align="l", font=0, colour=LABEL, lit_colour=ACC, lit_region=0):
    return Slot(x, FONTS[font].top(y_centre), "lmr".index(align), font, colour, lit_colour,
                lit_region, text)


def draw(img, slots, active_region=0):
    """Exact reference of the hardware: draw slots onto img (RGB, in place)."""
    px = img.load()
    for s in slots:
        if not s.text:
            continue
        f = FONTS[s.font]
        w = f.width(s.text)
        x = [s.x, s.x - w // 2, s.x - w][s.align]
        col = COLOURS[s.lit_colour if s.lit_region and s.lit_region == active_region else s.colour]
        for ch in s.text:
            g = ord(ch) - FIRST
            for gx in range(f.adv[g]):
                for gy in range(f.h):
                    a = f.alpha[g][gy][gx]
                    X, Y = x + gx, s.y_top + gy
                    if a and 0 <= X < W and 0 <= Y < H:
                        bg = px[X, Y]
                        px[X, Y] = tuple((b * (16 - a) + c * a) >> 4 for b, c in zip(bg, col))
            x += f.adv[g]
    return img


# ---------------------------------------------------------------- main screen layout
# region ids match tools/ui/ui_rom.py: key bit k -> k+1 (k <= 9), Select 11, Start 12
REGION = {"POWER": 12, "MUTE": 11, "VOL_UP": 9, "VOL_DOWN": 10, "OK": 8, "BACK": 7,
          "MENU": 6, "INPUT": 5}
LABEL_SLOTS = {   # function: (x, y_centre, align); from the ui_hires layout / 2
    "POWER": (147, 88, "r"), "MUTE": (253, 88, "l"), "MENU": (141, 115, "m"),
    "INPUT": (71, 202, "r"), "OK": (211, 202, "l"), "BACK": (141, 291, "m"),
    "VOL_DOWN": (58, 320, "l"), "VOL_UP": (248, 320, "l"),
}
VOL_WORDS = {"VOL_DOWN": "VOLUME DOWN", "VOL_UP": "VOLUME UP"}
DEFAULT_WORD = {"MENU": "MENU", "INPUT": "INPUT", "OK": "OK", "BACK": "BACK",
                "POWER": "POWER", "MUTE": "MUTE"}


def main_slots(name, model, cs):
    """Slots for the main screen of a device ({function: (proto, D, F, label)})."""
    out = [slot(20, 29, name, font=1, colour=TITLE),
           slot(20, 47, ("REMOTE " + model.split(" +")[0])[:SLOT_CHARS - 1], colour=SUB)]
    for f, (x, y, a) in LABEL_SLOTS.items():
        present = f in cs
        word = VOL_WORDS.get(f) or (cs[f][3] if present else DEFAULT_WORD[f])
        out.append(slot(x, y, word, a, colour=LABEL if present else DIM,
                        lit_colour=ACC_DARK if f in VOL_WORDS else ACC, lit_region=REGION[f]))
    nav = all(f in cs for f in ("UP", "DOWN", "LEFT", "RIGHT"))
    out.append(slot(326, 268, "NAVIGATE", "m", colour=LABEL if nav else DIM))
    return out


def check_no_overlap(slots):
    boxes = []
    for s in slots:
        if not s.text:
            continue
        f = FONTS[s.font]
        w = f.width(s.text)
        x = [s.x, s.x - w // 2, s.x - w][s.align]
        boxes.append((x, s.y_top, x + w, s.y_top + f.h, s.text))
    for i, a in enumerate(boxes):
        for b in boxes[i + 1:]:
            assert a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1], f"slots overlap: {a[4]} / {b[4]}"


# ---------------------------------------------------------------- export
def export(slots):
    out = ROOT / "src" / "fpga" / "core" / "ui"
    for i, f in enumerate(FONTS):
        name = ["font_small", "font_big"][i]
        # 5-bit binary (alpha 0..16): exactly the ROM width, so Quartus has nothing to truncate
        (out / f"{name}.bin").write_text("".join(
            f"{f.alpha[g][y][x]:05b}\n" for g in range(NCHARS) for y in range(f.h) for x in range(CELL)))
    (out / "font_adv.bin").write_text("".join(f"{a:05b}\n" for f in FONTS for a in f.adv))
    slots = (slots + [Slot(0, 0)] * NSLOTS)[:NSLOTS]
    (out / "text_slots.hex").write_text("".join(f"{s.word():08X}\n" for s in slots))
    strs = bytearray(NSLOTS * SLOT_CHARS)
    for i, s in enumerate(slots):
        assert len(s.text) < SLOT_CHARS and all(FIRST <= ord(c) < FIRST + NCHARS for c in s.text), s.text
        strs[i * SLOT_CHARS:i * SLOT_CHARS + len(s.text)] = s.text.encode("ascii")
    (out / "text_str.hex").write_text("".join(f"{b:02X}\n" for b in strs))
    (out / "ui_text.vh").write_text(
        "// generated by tools/ui/ui_text.py -- do not edit\n"
        f"localparam TXT_H_SMALL = {FONTS[0].h};\nlocalparam TXT_H_BIG = {FONTS[1].h};\n"
        f"localparam TXT_NSLOTS = {NSLOTS};\nlocalparam TXT_SLOT_CHARS = {SLOT_CHARS};\n"
        "localparam [23:0] TXT_COL0 = 24'h%06X, TXT_COL1 = 24'h%06X, TXT_COL2 = 24'h%06X,\n"
        "                  TXT_COL3 = 24'h%06X, TXT_COL4 = 24'h%06X, TXT_COL5 = 24'h%06X;\n"
        % tuple(r << 16 | g << 8 | b for r, g, b in COLOURS)
        + "// main-screen slot words (colour = normal; dev_ctrl.v swaps in DIM for missing keys)\n"
          "// 0 title, 1 model, 2 POWER, 3 MUTE, 4 MENU, 5 INPUT, 6 OK, 7 BACK, 8 VOL_DOWN, 9 VOL_UP, 10 NAVIGATE\n"
        + "".join(f"localparam [31:0] MAIN_SLOT_{i} = 32'h{s.word():08X};\n"
                  for i, s in enumerate(main_slots("X", "X", {f: (0, 0, 0, "X") for f in LABEL_SLOTS} |
                                                   {f: (0, 0, 0, "X") for f in ("UP", "DOWN", "LEFT", "RIGHT")})))
        + f"localparam [2:0] TXT_DIM = 3'd{DIM};\n")


def sony_slots():
    sys.path.insert(0, str(ROOT / "tools" / "ir"))
    import library as lib
    data = bytes(int(x, 16) for x in (ROOT / "src/fpga/core/lib/ir_lib.hex").read_text().split())
    model, cs = dict(dict(lib.read_library(data))["RECEIVER"])["SONY"][0]
    return main_slots("SONY RECEIVER", model, cs)


def main():
    slots = sony_slots()
    check_no_overlap(slots)
    export(slots)
    # expected frames for tb_ui_video: ui_rom.py's picture + this text layer
    exp = ROOT / "build" / "ui_expected"
    for name, region in [("idle", 0), ("enter", REGION["OK"])]:
        img = Image.open(exp / f"{name}_picture.png").convert("RGB")
        draw(img, slots, region)
        img.save(exp / f"{name}.png")
        (exp / f"{name}.hex").write_text("".join(f"{r:02X}{g:02X}{b:02X}\n" for r, g, b in img.getdata()))
    print(f"fonts {FONTS[0].h}/{FONTS[1].h} px high, {len([s for s in slots if s.text])} slots "
          f"-> src/fpga/core/ui, build/ui_expected")


if __name__ == "__main__":
    main()
