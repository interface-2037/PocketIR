"""M7 screen mockups: main screen with runtime labels, and the device menu.

Drawn under the constraints the hardware text layer will have:
  * background = ui_hires.render(text=False): graphics only, no words
  * text = a pre-rendered glyph sheet per size (Inter, hinted at native
    400x360, 16 alpha levels), placed at whole-pixel positions by advance
    widths, in fixed slots with left / centre / right alignment
  * colours per slot: normal, dimmed (function missing), highlight (sending)
  * menu = flat background + text rows + one highlight bar (a rectangle)
Content comes from the real library ROM (src/fpga/core/lib/ir_lib.hex).

Usage:  python tools/ui/ui_m7.py        -> docs/ui/m7_*.png (400x360 + panel 4x)
"""

import sys
from pathlib import Path

from PIL import Image, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parents[1] / "ir"))
import library as lib  # noqa: E402
import ui_hires as hr  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
W, H = 400, 360
CHARSET = "".join(chr(c) for c in range(32, 96)) + "+-/."   # space .. '_' (uppercase)

BG, TITLE, LABEL, DIM, ACC, ACC_DARK = hr.BODY, hr.TITLE, hr.LABEL, (92, 94, 102), hr.ACC, hr.ACC_DARK
SUB = (150, 152, 160)          # secondary text (model line, breadcrumb): readable, not dimmed
BAR = (52, 54, 60)


class GlyphFont:
    """A glyph sheet: per character an alpha mask (16 levels) and an advance."""

    def __init__(self, size, weight="SemiBold"):
        f = ImageFont.truetype(str(hr.FONT), size)
        f.set_variation_by_name(weight)
        asc, desc = f.getmetrics()
        self.h = asc + desc
        self.cap = -f.getbbox("H", anchor="ls")[1]          # cap height in px
        self.asc = asc
        self.glyphs = {}
        for ch in set(CHARSET):
            adv = int(round(f.getlength(ch)))
            img = Image.new("L", (max(adv, 1) + 2, self.h))
            from PIL import ImageDraw
            ImageDraw.Draw(img).text((0, asc), ch, font=f, fill=255, anchor="ls")
            q = img.point(lambda v: (v * 15 + 127) // 255 * 17)  # 16 levels
            self.glyphs[ch] = (q, adv)

    def width(self, s):
        return sum(self.glyphs[c][1] for c in s)

    def draw(self, img, x, y, s, colour, anchor="lm"):
        """anchor: l/m/r horizontally; y is the vertical centre of capitals."""
        w = self.width(s)
        x0 = {"l": x, "m": x - w // 2, "r": x - w}[anchor[0]]
        top = y - self.cap // 2 - (self.asc - self.cap)
        px = img.load()
        for ch in s:
            mask, adv = self.glyphs[ch]
            m = mask.load()
            for gy in range(mask.height):
                for gx in range(mask.width):
                    a = m[gx, gy]
                    X, Y = x0 + gx, top + gy
                    if a and 0 <= X < W and 0 <= Y < H:
                        b = px[X, Y]
                        px[X, Y] = tuple((c * a + bb * (255 - a)) // 255 for c, bb in zip(colour, b))
            x0 += adv
        return w


SMALL, BIG = GlyphFont(11), GlyphFont(15, "Bold")

# main-screen text slots (native 400x360 coordinates, from the ui_hires layout / 2)
SLOTS = {
    "POWER":    (147, 88,  "r"), "MUTE": (253, 88, "l"),
    "MENU":     (141, 115, "m"), "INPUT": (71, 202, "r"), "OK": (211, 202, "l"),
    "BACK":     (141, 291, "m"),
    "VOL_DOWN": (58, 320, "l"), "VOL_UP": (248, 320, "l"),
}
VOL_WORDS = {"VOL_DOWN": "VOLUME DOWN", "VOL_UP": "VOLUME UP"}


def main_screen(brand, dtype, model, cs, pressed=None):
    pic = {"VOL_UP": "VOL+", "VOL_DOWN": "VOL-", "OK": "ENTER", "MENU": "AMP MENU",
           "INPUT": "OPTIONS", "BACK": "BACK", "POWER": "POWER", "MUTE": "MUTE"}.get(pressed, pressed)
    img = hr.render(W, H, pressed=pic, tx=pressed is not None, text=False).copy()
    BIG.draw(img, 20, 29, f"{brand} {dtype}", TITLE)
    SMALL.draw(img, 20, 47, "REMOTE " + model.split(" +")[0], SUB)
    for f, (x, y, a) in SLOTS.items():
        present = f in cs
        word = VOL_WORDS.get(f) or (cs[f][3] if present else {"MENU": "MENU", "INPUT": "INPUT",
                                                              "OK": "OK", "BACK": "BACK"}.get(f, f))
        # labels on a filled shape (shoulder tabs) go dark when lit; labels beside a button go yellow
        lit = ACC_DARK if f in VOL_WORDS else ACC
        colour = lit if pressed == f else (LABEL if present else DIM)
        SMALL.draw(img, x, y, word, colour, a + "m")
    nav = all(f in cs for f in ("UP", "DOWN", "LEFT", "RIGHT"))
    SMALL.draw(img, 326, 268, "NAVIGATE", LABEL if nav else DIM, "mm")
    return img


def model_row(m):
    """'BN59-01180A +5' -> 'BN59-01180A & 5 MORE' (5 other remotes share this set)."""
    if " +" in m:
        base, n = m.rsplit(" +", 1)
        return f"{base} & {n} MORE"
    return m


def hint_line(img, pairs):
    """Footer: key names bright, actions dim, centred as one line."""
    gap, sp = SMALL.width("     "), SMALL.width(" ")
    total = sum(SMALL.width(k) + sp + SMALL.width(a) for k, a in pairs) + gap * (len(pairs) - 1)
    x = 200 - total // 2
    for k, a in pairs:
        x += SMALL.draw(img, x, 342, k, TITLE) + sp
        x += SMALL.draw(img, x, 342, a, SUB) + gap


def menu_screen(title, crumb, rows, cursor, top=0, right=None, hint=()):
    img = Image.new("RGB", (W, H), BG)
    px = img.load()
    BIG.draw(img, 20, 29, title, TITLE)
    SMALL.draw(img, 20, 47, crumb, SUB)
    if right:
        SMALL.draw(img, 380, 29, right, DIM, "rm")
    for x in range(16, 385):
        px[x, 62] = BAR
    row_h, n = 28, 9
    for i in range(n):
        k = top + i
        if k >= len(rows):
            break
        y = 80 + i * row_h
        name, extra = rows[k]
        if k == cursor:
            for yy in range(y - 12, y + 12):
                for xx in range(16, 385):
                    px[xx, yy] = ACC
        col, dim = (ACC_DARK, ACC_DARK) if k == cursor else (LABEL, DIM)
        SMALL.draw(img, 28, y, name, col)
        if extra:
            SMALL.draw(img, 372, y, extra, dim, "rm")
    # scroll bar
    if len(rows) > n:
        h0 = 66 + int(250 * top / len(rows))
        h1 = 66 + int(250 * min(len(rows), top + n) / len(rows))
        for yy in range(h0, h1):
            for xx in (390, 391):
                px[xx, yy] = DIM
    for x in range(16, 385):
        px[x, 326] = BAR
    hint_line(img, hint)
    return img


def main():
    data = bytes(int(x, 16) for x in (ROOT / "src/fpga/core/lib/ir_lib.hex").read_text().split())
    types = lib.read_library(data)
    by = {t: dict(b) for t, b in types}
    out = ROOT / "docs" / "ui"
    shots = {}

    sony_model, sony = by["RECEIVER"]["SONY"][0]
    sam_model, sam = by["TV"]["SAMSUNG"][0]
    shots["m7_main_sony"] = main_screen("SONY", "RECEIVER", sony_model, sony)
    shots["m7_main_samsung"] = main_screen("SAMSUNG", "TV", sam_model, sam)
    shots["m7_main_samsung_volup"] = main_screen("SAMSUNG", "TV", sam_model, sam, pressed="VOL_UP")
    # a sparse device: fewest functions among streaming sets
    sb, sm, scs = min(((b, m, cs) for b, sets in by["STREAMING"].items() for m, cs in sets),
                      key=lambda t: len(t[2]))
    shots["m7_main_sparse"] = main_screen(sb, "STREAMING", sm, scs)

    hint_nav = [("ENTER", "CHOOSE"), ("BACK", "UP"), ("SELECT+START", "EXIT")]
    hint_brand = [("LEFT/RIGHT", "A-Z"), ("ENTER", "CHOOSE"), ("BACK", "UP")]
    sets = lambda n: f"{n} SET" + ("" if n == 1 else "S")
    trows = [(t, sets(sum(len(s) for s in b.values()))) for t, b in by.items()]
    shots["m7_menu_type"] = menu_screen("CHOOSE DEVICE", "DEVICE TYPE", trows, 0,
                                        right=f"1 / {len(trows)}", hint=hint_nav)
    brands = list(by["TV"].items())
    bnames = [(b, sets(len(s))) for b, s in brands]
    cur = [b for b, _ in bnames].index("SAMSUNG")
    shots["m7_menu_brand"] = menu_screen("TV BRAND", "TV", bnames, cur, top=cur - 4,
                                         right=f"{cur + 1} / {len(bnames)}", hint=hint_brand)
    srows = [(model_row(m), "" if len(cs) == 12 else f"{len(cs)} KEYS") for m, cs in by["TV"]["SAMSUNG"]]
    shots["m7_menu_codeset"] = menu_screen("SAMSUNG TV", "TV > SAMSUNG", srows, 0,
                                           right=f"1 / {len(srows)}",
                                           hint=[("POWER", "TEST"), ("ENTER", "USE"), ("BACK", "UP")])
    for name, img in shots.items():
        img.save(out / f"{name}.png")
        img.resize((W * 4, H * 4), Image.NEAREST).save(out / f"{name}_panel.png")
        print(f"docs/ui/{name}.png")


if __name__ == "__main__":
    main()
