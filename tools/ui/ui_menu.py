"""Device menu (M7 step 5, M9): reference model, page layout, renderer, constants.

The hardware (lib/dev_ctrl.v draws pages, lib/menu.v navigates, ui/ui_video.v
draws the menu background) is checked against this model:

  * levels: 0 home (RECENT DEVICES, LEARN FROM REMOTE, then the device types),
    1 brand, 2 code set, 3 recent devices, 4 learn (listening), 5 matching devices
  * navigation: Menu.press(func) and Menu.burst(result, list) (a remote button
    identified by lib/ir_match.v; model: rxcap.identify) -> events
    ("load", t, b, s) / ("codes", t, b, s) / ("test",) / ("close",) / ("page",)
  * page(): text slots + rectangle parameters (highlight-bar row, scroll thumb,
    divider row) for the current state
  * render(): the exact frame (flat background, rectangles, text layer)

Slots: 0 title, 1 breadcrumb, 2 counter, 3..11 row names, 12..20 row details,
21..26 footer hint (key, action) x 3. Learn screen: 3..5 instructions,
6 LISTENING..., 7..8 the last try's result.
The recent list mirrors lib/recent.v: the current device moves to the front.

Usage:  python tools/ui/ui_menu.py   -> src/fpga/core/ui/ui_menu.vh, docs/ui/m9_hw_*.png
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
DIV_DY = -14                                    # divider: 1 px line in the gap above a row

L_HOME, L_BRAND, L_SET, L_RECENT, L_LEARN, L_MATCH = range(6)
HOME_ROWS = 2                                   # RECENT DEVICES, LEARN FROM REMOTE, then the types
RECENT_N = 20                                   # lib/recent.v

FUNCS = lib.FUNCS
HINTS = {  # variant: [(key const, action const), ...]
    "nav":   [("ENTER", "CHOOSE"), ("BACK", "UP"), ("SELECT+START", "EXIT")],
    "brand": [("LEFT/RIGHT", "A-Z"), ("ENTER", "CHOOSE"), ("BACK", "UP")],
    "set":   [("POWER", "TEST"), ("ENTER", "USE"), ("BACK", "UP")],
    "learn": [("BACK", "CANCEL")],
    "match": [("POWER", "TEST"), ("ENTER", "USE"), ("BACK", "RETRY")],
}
HINT_VARIANT = ["nav", "brand", "set", "set", "learn", "match"]   # by level
C = lib.M9_CONSTS
LEARN_RESULT = {1: (C["NOMATCH"], C["ANOTHER"]), 2: (C["UNREAD"], C["CLOSER"])}


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


def learn_slots(msg=0):
    """Learn screen slots 3..8: instructions, LISTENING..., the last try's result."""
    r = LEARN_RESULT.get(msg, ("", ""))
    return ([tx.slot(200, ROW_Y0 + (i + 1) * ROW_H, C[k], "m", colour=LABEL)
             for i, k in enumerate(("AIM1", "AIM2", "AIM3"))] +
            [tx.slot(200, ROW_Y0 + 5 * ROW_H, C["LISTENING"], "m", font=1, colour=ACC),
             tx.slot(200, ROW_Y0 + 6 * ROW_H + 6, r[0], "m", colour=TITLE),
             tx.slot(200, ROW_Y0 + 7 * ROW_H + 6, r[1], "m", colour=SUB)])


def sets_word(n):
    return f"{n} SET" if n == 1 else f"{n} SETS"


def plural(n, one, many):
    return f"{n}{one if n == 1 else many}"


class Menu:
    def __init__(self, types, dev, recent=None):
        self.types = types                 # library.read_library() result
        self.dev = dev                     # current device (t, b, s)
        self.recent = list(recent) if recent is not None else [dev]
        self.open = False
        self.level = 0
        self.cur = [0] * 6
        self.top = [0] * 6
        self.tsel = 0                      # type of levels 1-2 (home cursor - HOME_ROWS)
        self.matches = []                  # level 5 list (lib/ir_match.v)
        self.buttons = 0                   # remote buttons that built it
        self.msg = 0                       # last result shown (learn / match screens)
        self.entry = None                  # levels 3/5: highlighted device (its codes are loaded)

    # ---------------------------------------------------------------- data
    def items(self, level=None):
        lv = self.level if level is None else level
        if lv == L_HOME:
            return [("RECENT",), ("LEARN",)] + self.types
        if lv == L_BRAND:
            return self.types[self.tsel][1]
        if lv == L_SET:
            return self.types[self.tsel][1][self.cur[1]][1]
        if lv == L_RECENT:
            return self.recent
        if lv == L_MATCH:
            return self.matches
        return []

    def letter(self, i):
        return self.types[self.tsel][1][i][0][0]

    def _use(self, dev):
        """The current device changes; recent.v moves it to the front of the list."""
        self.dev = dev
        if dev in self.recent:
            self.recent.remove(dev)
        self.recent.insert(0, dev)
        del self.recent[RECENT_N:]

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

    def _close(self, dev=None):
        if dev is not None:
            self._use(dev)
        self.open = False
        return [("load",) + self.dev, ("close",)]

    def press(self, func):
        """func: 'CHORD' or a library function name. Returns a list of events."""
        if func == "CHORD":
            if not self.open:
                self.open = True
                self._enter_level(L_HOME, 0)
                return [("page",)]
            return self._close()
        if not self.open:
            return []
        lv = self.level
        if lv == L_LEARN:                                 # only BACK does anything while listening
            if func != "BACK":
                return []
            self.level = L_HOME
            return [("page",)]
        n = len(self.items())
        if func in ("UP", "DOWN"):
            self.cur[lv] = max(0, min(n - 1, self.cur[lv] + (1 if func == "DOWN" else -1)))
        elif func in ("LEFT", "RIGHT"):
            if lv == L_BRAND:                             # A-Z jump
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
            if lv == L_HOME:
                c = self.cur[0]
                if c == 0:
                    self._enter_level(L_RECENT, 1 if len(self.recent) > 1 else 0)
                elif c == 1:
                    self.level, self.msg, self.buttons = L_LEARN, 0, 0
                    return [("page",)]
                else:
                    self.tsel = c - HOME_ROWS
                    self._enter_level(L_BRAND, self.dev[1] if self.dev[0] == self.tsel else 0)
            elif lv == L_BRAND:
                same = (self.tsel, self.cur[1]) == self.dev[:2]
                self._enter_level(L_SET, self.dev[2] if same else 0)
            elif lv == L_SET:
                return self._close((self.tsel, self.cur[1], self.cur[2]))
            else:                                         # recent / match list: use it
                return self._close(self.entry)
        elif func == "BACK":
            if lv == L_HOME:
                return self._close()
            if lv == L_MATCH:                             # retry: listen again from scratch
                self.level, self.msg, self.buttons = L_LEARN, 0, 0
                return [("page",)]
            self.level = {L_BRAND: L_HOME, L_SET: L_BRAND, L_RECENT: L_HOME}[lv]
        elif func == "POWER" and lv in (L_SET, L_RECENT, L_MATCH):
            return [("test",)]
        else:
            return []
        self._scroll()
        return self._codes() + [("page",)]

    def _codes(self):
        """At the set / recent / match levels every cursor change loads the highlighted
        device's codes (CODES), so POWER (TEST) sends the right code."""
        if self.level == L_SET:
            return [("codes", self.tsel, self.cur[1], self.cur[2])]
        if self.level in (L_RECENT, L_MATCH):
            self.entry = self.items()[self.cur[self.level]]
            return [("codes",) + self.entry]
        return []

    def burst(self, result, lst):
        """The matcher finished a remote button (levels 4-5; rxcap.identify(..., prev) when
        narrowing at level 5). result 0: new list; else the message, list unchanged."""
        if not self.open or self.level not in (L_LEARN, L_MATCH):
            return []
        if result == 0:
            self.buttons = 1 if self.level == L_LEARN else min(255, self.buttons + 1)
            self.matches, self.msg = list(lst), 0
            self._enter_level(L_MATCH, 0)
            return self._codes() + [("page",)]
        self.msg = result
        return [("page",)]

    @property
    def listening(self):
        return self.open and self.level in (L_LEARN, L_MATCH)

    # ---------------------------------------------------------------- page
    def device_row(self, d):
        t, b, s = d
        tname, brands = self.types[t]
        bname, sets = brands[b]
        base, more = lib.split_model(sets[s][0])
        return (f"{bname} {base}" + (f" & {more} MORE" if more else ""))[:31], tname

    def page(self):
        """-> (slots, bar_row or None, scroll (y0, y1) or None, divider row or None)"""
        lv = self.level
        if lv == L_LEARN:
            slots = [tx.slot(20, 29, C["LEARN"], font=1, colour=TITLE),
                     tx.slot(20, 47, C["LEARN_CRUMB"], colour=SUB),
                     tx.slot(380, 29, "", "r", colour=SUB)] + learn_slots(self.msg)
            slots += [tx.Slot(0, 0)] * (21 - len(slots))
            return slots + hint_slots("learn"), None, None, None
        items = self.items()
        n, c, top = len(items), self.cur[lv], self.top[lv]
        tname = self.types[self.tsel][0]
        bname = self.types[self.tsel][1][self.cur[1]][0] if lv in (L_BRAND, L_SET) else ""
        if lv == L_MATCH:
            title = plural(n, C["MATCH"], C["MATCHES"])
            crumb = (plural(self.buttons, C["BUTTON"], C["BUTTONS"]) if self.msg == 0 else
                     C["NONE"] if self.msg == 3 else C["UNREAD_BTN"])
        else:
            title = {L_HOME: "CHOOSE DEVICE", L_BRAND: f"{tname} BRAND", L_SET: f"{bname} {tname}",
                     L_RECENT: C["RECENT"]}[lv]
            crumb = {L_HOME: C["HOME_CRUMB"], L_BRAND: tname, L_SET: f"{tname} > {bname}",
                     L_RECENT: C["RECENT_CRUMB"]}[lv]
        slots = [tx.slot(20, 29, title[:31], font=1, colour=TITLE),
                 tx.slot(20, 47, crumb[:31], colour=SUB),
                 tx.slot(380, 29, f"{c + 1} / {n}", "r", colour=SUB)]
        names, details = [], []
        for r in range(ROWS):
            k = top + r
            y = ROW_Y0 + r * ROW_H
            on = k == c
            if k >= n:
                name, det = "", ""
            elif lv == L_HOME and k == 0:
                name, det = C["RECENT"], plural(len(self.recent), C["DEVICE"], C["DEVICES"])
            elif lv == L_HOME and k == 1:
                name, det = C["LEARN"], ""
            elif lv == L_HOME:
                t = items[k]
                name, det = t[0], sets_word(sum(len(s) for _, s in t[1]))
            elif lv == L_BRAND:
                name, det = items[k][0], sets_word(len(items[k][1]))
            elif lv == L_SET:
                base, more = lib.split_model(items[k][0])
                name = f"{base} & {more} MORE" if more else base
                keys = len(items[k][1])
                det = "" if keys == 12 else f"{keys} KEYS"
            else:
                name, det = self.device_row(items[k])
            names.append(tx.slot(28, y, name[:31], colour=ACC_DARK if on else LABEL))
            details.append(tx.slot(372, y, det, "r", colour=ACC_DARK if on else DIM))
        slots += names + details + hint_slots(HINT_VARIANT[lv])
        scroll = None
        if n > ROWS:
            scroll = (SCROLL_Y0 + SCROLL_LEN * top // n, SCROLL_Y0 + SCROLL_LEN * min(n, top + ROWS) // n)
        div = HOME_ROWS - top if lv == L_HOME and 0 < HOME_ROWS - top < ROWS else None
        return slots, c - top, scroll, div

    # ---------------------------------------------------------------- render
    def render(self):
        slots, bar_row, scroll, div = self.page()
        img = Image.new("RGB", (W, H), BG_RGB)
        px = img.load()
        for x in range(BAR_X0, BAR_X1):
            for y in SEP_Y:
                px[x, y] = BAR_RGB
            if div is not None:
                px[x, ROW_Y0 + div * ROW_H + DIV_DY] = BAR_RGB
        if bar_row is not None:
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
    """Slot words, hint words + constant-string indices per level, menu geometry, for the RTL."""
    lines = ["// generated by tools/ui/ui_menu.py -- do not edit",
             f"localparam MENU_ROWS = {ROWS}, MENU_ROW_Y0 = {ROW_Y0}, MENU_ROW_H = {ROW_H};",
             f"localparam MENU_BAR_X0 = {BAR_X0}, MENU_BAR_X1 = {BAR_X1};",
             f"localparam MENU_SEP_Y0 = {SEP_Y[0]}, MENU_SEP_Y1 = {SEP_Y[1]};",
             f"localparam MENU_SCROLL_X = {SCROLL_X}, MENU_SCROLL_Y0 = {SCROLL_Y0}, MENU_SCROLL_LEN = {SCROLL_LEN};",
             f"localparam MENU_DIV_DY = {DIV_DY}, MENU_HOME_ROWS = {HOME_ROWS};",
             "localparam [23:0] MENU_BG = 24'h%02X%02X%02X, MENU_BAR = 24'h%02X%02X%02X;" % (BG_RGB + BAR_RGB)]
    # fixed-position slot words (text written at runtime); colours are the "off cursor" ones
    proto = Menu(load_types(), (0, 0, 0))
    proto.open = True
    proto.cur[0] = ROWS                 # cursor below the visible rows: every row word is "off cursor"
    slots = proto.page()[0]
    for i in range(21):
        lines.append(f"localparam [31:0] MENU_SLOT_{i} = 32'h{slots[i].word():08X};")
    for i, s in enumerate(learn_slots()):
        lines.append(f"localparam [31:0] LEARN_SLOT_{i} = 32'h{s.word():08X};")
    lines.append(f"localparam [2:0] TXT_ACC_DARK = 3'd{ACC_DARK};")
    # footer hints per level, flattened: entry (level * 6 + i), highest first in the vector
    hs = [hint_slots(name) for name in HINT_VARIANT]
    slot = [(hs[lv][i] if i < len(hs[lv]) else hs[lv][0]) for lv in range(6) for i in range(6)]
    lines.append("// footer hints by level: count, then slot word / CONSTS index of entry level*6+i")
    lines.append("localparam [17:0] HINT_NS = {" + ", ".join(f"3'd{len(h)}" for h in reversed(hs)) + "};")
    lines.append("localparam [36*32-1:0] HINT_SLOTS = {" +
                 ", ".join(f"32'h{s.word():08X}" for s in reversed(slot)) + "};")
    lines.append("localparam [36*8-1:0] HINT_STRS = {" +
                 ", ".join(f"8'd{lib.CONSTS.index(s.text)}" for s in reversed(slot)) + "};")
    (ROOT / "src/fpga/core/ui/ui_menu.vh").write_text("\n".join(lines) + "\n")


def main():
    types = load_types()
    export_constants()
    out = ROOT / "docs" / "ui"
    tv = [t for t, _ in types].index("TV")
    rx = [t for t, _ in types].index("RECEIVER")
    sony = (rx, [b for b, _ in types[rx][1]].index("SONY"), 0)
    sam = (tv, [b for b, _ in types[tv][1]].index("SAMSUNG"), 0)
    m = Menu(types, sam, recent=[sam, sony])
    m.press("CHORD")
    m.render().save(out / "m9_hw_home.png")
    m.press("OK")
    m.render().save(out / "m9_hw_recent.png")
    m.press("BACK")
    m.press("DOWN")
    m.press("OK")
    m.burst(2, [])
    m.render().save(out / "m9_hw_learn.png")
    m.burst(0, [sam, (tv, sam[1], 1)])
    m.render().save(out / "m9_hw_matches.png")
    print("ui_menu.vh + docs/ui/m9_hw_{home,recent,learn,matches}.png")


if __name__ == "__main__":
    main()
