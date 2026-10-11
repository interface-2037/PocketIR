"""Device menu (M7 step 5): reference model, page layout, renderer, constants.

The hardware (lib/dev_ctrl.v draws pages, lib/menu.v navigates, ui/ui_video.v
draws the menu background) is checked against this model:

  * navigation: Menu.press(func) -> events ("load", t, b, s) / ("codes", ...) /
    ("test",) / ("close",); levels 0 type, 1 brand, 2 code set
  * page(): text slots 0..26 + rectangle parameters (highlight-bar row, scroll
    thumb) for the current state
  * render(): the exact frame (flat background, rectangles, text layer)

Slots: 0 title, 1 breadcrumb, 2 counter, 3..11 row names, 12..20 row details,
21..26 footer hint (key, action) x 3.

Usage:  python tools/ui/ui_menu.py   -> src/fpga/core/ui/ui_menu.vh, docs/ui/m7_menu_*.png
"""

import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parents[1] / "ir"))
import library as lib  # noqa: E402
import ui_text as tx  # noqa: E402
from ui_text import ACC, ACC_DARK, DIM, LABEL, SUB, TITLE  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
W, H = 400, 360
ROWS, ROW_Y0, ROW_H = 9, 80, 28
BAR_X0, BAR_X1 = 16, 385                       # highlight bar and separators: x in [16, 385)
SEP_Y = (62, 326)
SCROLL_X, SCROLL_Y0, SCROLL_LEN = 390, 66, 250  # thumb: 2 px wide at x 390-391
BG_RGB, BAR_RGB = (34, 35, 38), (52, 54, 60)

FUNCS = lib.FUNCS
HINTS = {  # variant: [(key const, action const), ...]
    "nav":   [("ENTER", "CHOOSE"), ("BACK", "UP"), ("SELECT+START", "EXIT")],
    "brand": [("LEFT/RIGHT", "A-Z"), ("ENTER", "CHOOSE"), ("BACK", "UP")],
    "set":   [("POWER", "TEST"), ("ENTER", "USE"), ("BACK", "UP")],
}
HINT_VARIANT = ["nav", "brand", "set"]           # by level


def hint_slots(variant):
    """Footer: key names bright, actions SUB, centred as one line (as the mockups)."""
    f = tx.FONTS[0]
    gap, sp = f.width("     "), f.width(" ")
    pairs = HINTS[variant]
    total = sum(f.width(k) + sp + f.width(a) for k, a in pairs) + gap * (len(pairs) - 1)
    x = 200 - total // 2
    out = []
    for k, a in pairs:
        out.append(tx.slot(x, 342, k, colour=TITLE))
        x += f.width(k) + sp
        out.append(tx.slot(x, 342, a, colour=SUB))
        x += f.width(a) + gap
    return out


def sets_word(n):
    return f"{n} SET" if n == 1 else f"{n} SETS"


class Menu:
    def __init__(self, types, dev):
        self.types = types                 # library.read_library() result
        self.dev = dev                     # current device (t, b, s)
        self.open = False
        self.level = 0
        self.cur = [0, 0, 0]
        self.top = [0, 0, 0]

    # ---------------------------------------------------------------- data
    def items(self, level=None):
        lv = self.level if level is None else level
        t, b = self.cur[0], self.cur[1]
        if lv == 0:
            return self.types
        if lv == 1:
            return self.types[t][1]
        return self.types[t][1][b][1]

    def letter(self, i):
        return self.types[self.cur[0]][1][i][0][0]

    # ---------------------------------------------------------------- navigation
    def _scroll(self):
        lv = self.level
        if self.cur[lv] < self.top[lv]:
            self.top[lv] = self.cur[lv]
        elif self.cur[lv] >= self.top[lv] + ROWS:
            self.top[lv] = self.cur[lv] - (ROWS - 1)

    def _enter_level(self, lv, cursor):
        self.level, self.cur[lv], self.top[lv] = lv, cursor, 0
        self._scroll()

    def press(self, func):
        """func: 'CHORD' or a library function name. Returns a list of events."""
        ev = []
        if func == "CHORD":
            if not self.open:
                self.open = True
                self._enter_level(0, self.dev[0])
                return [("page",)]
            self.open = False
            return [("load",) + self.dev, ("close",)]
        if not self.open:
            return []
        lv, n = self.level, len(self.items())
        if func in ("UP", "DOWN"):
            self.cur[lv] = max(0, min(n - 1, self.cur[lv] + (1 if func == "DOWN" else -1)))
        elif func in ("LEFT", "RIGHT"):
            if lv == 1:                                   # A-Z jump
                c = self.cur[1]
                if func == "RIGHT":
                    j = c
                    while j < n and self.letter(j) == self.letter(c):
                        j += 1
                    self.cur[1] = j if j < n else c
                else:
                    s0 = c
                    while s0 > 0 and self.letter(s0 - 1) == self.letter(c):
                        s0 -= 1
                    if s0 < c:
                        self.cur[1] = s0
                    elif s0 > 0:
                        p = s0 - 1
                        while p > 0 and self.letter(p - 1) == self.letter(s0 - 1):
                            p -= 1
                        self.cur[1] = p
            else:                                         # page jump
                step = ROWS if func == "RIGHT" else -ROWS
                self.cur[lv] = max(0, min(n - 1, self.cur[lv] + step))
        elif func == "OK":
            if lv == 0:
                same = self.cur[0] == self.dev[0]
                self._enter_level(1, self.dev[1] if same else 0)
            elif lv == 1:
                same = (self.cur[0], self.cur[1]) == self.dev[:2]
                self._enter_level(2, self.dev[2] if same else 0)
            else:
                self.dev = (self.cur[0], self.cur[1], self.cur[2])
                self.open = False
                return [("load",) + self.dev, ("close",)]
        elif func == "BACK":
            if lv == 0:
                self.open = False
                return [("load",) + self.dev, ("close",)]
            self.level = lv - 1
        elif func == "POWER" and lv == 2:
            return [("test",)]
        else:
            return []
        self._scroll()
        if self.level == 2:
            ev.append(("codes", self.cur[0], self.cur[1], self.cur[2]))
        return ev + [("page",)]

    # ---------------------------------------------------------------- page
    def page(self):
        lv = self.level
        t, b = self.cur[0], self.cur[1]
        tname = self.types[t][0]
        bname = self.types[t][1][b][0] if lv >= 1 else ""
        items = self.items()
        n, c, top = len(items), self.cur[lv], self.top[lv]
        title = ["CHOOSE DEVICE", f"{tname} BRAND", f"{bname} {tname}"][lv][:31]
        crumb = ["DEVICE TYPE", tname, f"{tname} > {bname}"][lv][:31]
        slots = [tx.slot(20, 29, title, font=1, colour=TITLE),
                 tx.slot(20, 47, crumb, colour=SUB),
                 tx.slot(380, 29, f"{c + 1} / {n}", "r", colour=SUB)]
        names, details = [], []
        for r in range(ROWS):
            k = top + r
            y = ROW_Y0 + r * ROW_H
            on = k == c
            if k < n:
                if lv == 0:
                    name, det = items[k][0], sets_word(sum(len(s) for _, s in items[k][1]))
                elif lv == 1:
                    name, det = items[k][0], sets_word(len(items[k][1]))
                else:
                    base, more = lib.split_model(items[k][0])
                    name = f"{base} & {more} MORE" if more else base
                    keys = len(items[k][1])
                    det = "" if keys == 12 else f"{keys} KEYS"
            else:
                name, det = "", ""
            names.append(tx.slot(28, y, name[:31], colour=ACC_DARK if on else LABEL))
            details.append(tx.slot(372, y, det, "r", colour=ACC_DARK if on else DIM))
        slots += names + details + hint_slots(HINT_VARIANT[lv])
        bar_row = c - top
        scroll = None
        if n > ROWS:
            scroll = (SCROLL_Y0 + SCROLL_LEN * top // n, SCROLL_Y0 + SCROLL_LEN * min(n, top + ROWS) // n)
        return slots, bar_row, scroll

    # ---------------------------------------------------------------- render
    def render(self):
        slots, bar_row, scroll = self.page()
        img = Image.new("RGB", (W, H), BG_RGB)
        px = img.load()
        for x in range(BAR_X0, BAR_X1):
            for y in SEP_Y:
                px[x, y] = BAR_RGB
        y0 = ROW_Y0 + bar_row * ROW_H - 12
        for y in range(y0, y0 + 24):
            for x in range(BAR_X0, BAR_X1):
                px[x, y] = tx.COLOURS[ACC]
        if scroll:
            for y in range(*scroll):
                for x in (SCROLL_X, SCROLL_X + 1):
                    px[x, y] = tx.COLOURS[DIM]
        tx.check_no_overlap(slots)
        return tx.draw(img, slots)


def load_types():
    data = bytes(int(x, 16) for x in (ROOT / "src/fpga/core/lib/ir_lib.hex").read_text().split())
    return lib.read_library(data)


def export_constants():
    """Hint slot words + constant-string indices per variant, and menu geometry, for the RTL."""
    lines = ["// generated by tools/ui/ui_menu.py -- do not edit",
             f"localparam MENU_ROWS = {ROWS}, MENU_ROW_Y0 = {ROW_Y0}, MENU_ROW_H = {ROW_H};",
             f"localparam MENU_BAR_X0 = {BAR_X0}, MENU_BAR_X1 = {BAR_X1};",
             f"localparam MENU_SEP_Y0 = {SEP_Y[0]}, MENU_SEP_Y1 = {SEP_Y[1]};",
             f"localparam MENU_SCROLL_X = {SCROLL_X}, MENU_SCROLL_Y0 = {SCROLL_Y0}, MENU_SCROLL_LEN = {SCROLL_LEN};",
             "localparam [23:0] MENU_BG = 24'h%02X%02X%02X, MENU_BAR = 24'h%02X%02X%02X;" % (BG_RGB + BAR_RGB)]
    # fixed-position slot words (text written at runtime); colours are the "off cursor" ones
    proto = Menu(load_types(), (0, 0, 0))
    proto.open = True
    proto.cur[0] = ROWS                 # cursor below the visible rows: every row word is "off cursor"
    slots, _, _ = proto.page()
    for i in range(21):
        lines.append(f"localparam [31:0] MENU_SLOT_{i} = 32'h{slots[i].word():08X};")
    lines.append(f"localparam [2:0] TXT_ACC_DARK = 3'd{ACC_DARK};")
    for v, name in enumerate(HINT_VARIANT):
        for i, s in enumerate(hint_slots(name)):
            lines.append(f"localparam [31:0] HINT{v}_SLOT_{i} = 32'h{s.word():08X};")
            lines.append(f"localparam [7:0]  HINT{v}_STR_{i} = 8'd{lib.CONSTS.index(s.text)};")
    (ROOT / "src/fpga/core/ui/ui_menu.vh").write_text("\n".join(lines) + "\n")


def main():
    types = load_types()
    export_constants()
    out = ROOT / "docs" / "ui"
    tv = [t for t, _ in types].index("TV")
    sam = [b for b, _ in types[tv][1]].index("SAMSUNG")
    m = Menu(types, (1, [b for b, _ in types[1][1]].index("SONY"), 0))
    m.press("CHORD")
    m.render().save(out / "m7_menu_hw_type.png")
    m.press("UP")                                  # RECEIVER -> TV
    m.press("OK")
    for _ in range(10):
        m.press("RIGHT")
        if m.cur[1] >= sam:
            break
    while m.cur[1] < sam:
        m.press("DOWN")
    m.render().save(out / "m7_menu_hw_brand.png")
    m.press("OK")
    m.render().save(out / "m7_menu_hw_set.png")
    print("ui_menu.vh + docs/ui/m7_menu_hw_{type,brand,set}.png")


if __name__ == "__main__":
    main()
