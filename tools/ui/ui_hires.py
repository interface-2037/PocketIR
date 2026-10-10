"""M5 high-resolution UI mockup: the Pocket's own controls, drawn as seen in
the 180-degree grip (small buttons at the top, face buttons left, d-pad
right, shoulders at the bottom), with every v4 label kept in place.

Layout is defined on a 640x480 base grid and rendered at any 4:3 size with
4x supersampling for smooth edges.

Font: Inter (SIL Open Font License 1.1), tools/ui/fonts/.

Usage:  python tools/ui/ui_hires.py          -> docs/ui/m5_hires_*.png
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FONT = Path(__file__).parent / "fonts" / "Inter-Variable.ttf"
SS = 4  # supersampling

# colours
BODY_TOP, BODY_BOT = (44, 45, 49), (28, 29, 32)   # 4:3 draft only (bands on hardware)
BODY = (34, 35, 38)                                 # flat background
BTN, BTN_HI, BTN_SH = (22, 23, 26), (58, 60, 66), (12, 12, 14)
ENGRAVE = (70, 72, 78)
LABEL, TITLE, DIM = (205, 206, 212), (236, 236, 240), (110, 112, 120)
ACC, ACC_DARK = (255, 200, 40), (60, 44, 0)


class Canvas:
    """Shapes are drawn at SS x and downsampled (smooth curves). With
    native_text, text is queued and drawn after the downsample at the final
    resolution, so FreeType hints glyphs to the real pixel grid (crisp)."""

    def __init__(self, w, h, base_w=640, native_text=False):
        self.k = w / base_w * SS
        self.img = Image.new("RGB", (w * SS, h * SS))
        self.d = ImageDraw.Draw(self.img)
        self.w, self.h = w, h
        self.fonts = {}
        self.native_text = native_text
        self.texts = []

    def s(self, *v):
        return [round(x * self.k) for x in v]

    def font(self, size, weight="SemiBold", scale=None):
        px = round(size * (self.k if scale is None else scale))
        key = (px, weight)
        if key not in self.fonts:
            f = ImageFont.truetype(str(FONT), px)
            f.set_variation_by_name(weight)
            self.fonts[key] = f
        return self.fonts[key]

    # ------------------------------------------------------------ primitives
    def flat(self):
        self.d.rectangle([0, 0, self.img.width, self.img.height], fill=BODY)

    def gradient(self):
        H = self.img.height
        for y in range(H):
            t = y / (H - 1)
            c = tuple(round(a + (b - a) * t) for a, b in zip(BODY_TOP, BODY_BOT))
            self.d.line([(0, y), (self.img.width, y)], fill=c)

    def circle_btn(self, cx, cy, r, pressed=False):
        d, s = self.d, self.s
        d.ellipse(s(cx - r, cy - r + 2, cx + r, cy + r + 2), fill=BTN_SH)            # drop shadow
        if pressed:
            d.ellipse(s(cx - r - 4, cy - r - 4, cx + r + 4, cy + r + 4), fill=ACC)     # glow ring
            d.ellipse(s(cx - r, cy - r, cx + r, cy + r), fill=ACC_DARK)
            d.ellipse(s(cx - r + 3, cy - r + 3, cx + r - 3, cy + r - 3), fill=ACC)
        else:
            d.ellipse(s(cx - r, cy - r, cx + r, cy + r), fill=BTN_HI)                  # rim light
            d.ellipse(s(cx - r, cy - r + 1.5, cx + r, cy + r), fill=(27, 28, 31))       # matte top
            d.ellipse(s(cx - r * 0.92, cy - r * 0.8, cx + r * 0.92, cy + r), fill=BTN)  # body

    def dpad(self, cx, cy, arm, half_w, pressed=None):
        d, s = self.d, self.s
        rad = half_w * 0.35
        for off, col in [(3, BTN_SH), (0, BTN_HI)]:
            d.rounded_rectangle(s(cx - half_w, cy - arm + off, cx + half_w, cy + arm + off), s(rad)[0], fill=col)
            d.rounded_rectangle(s(cx - arm, cy - half_w + off, cx + arm, cy + half_w + off), s(rad)[0], fill=col)
        d.rounded_rectangle(s(cx - half_w, cy - arm + 2, cx + half_w, cy + arm), s(rad)[0], fill=BTN)
        d.rounded_rectangle(s(cx - arm, cy - half_w + 2, cx + arm, cy + half_w), s(rad)[0], fill=BTN)
        # pressed arm
        arms = {"UP": (cx - half_w, cy - arm, cx + half_w, cy - half_w),
                "DOWN": (cx - half_w, cy + half_w, cx + half_w, cy + arm),
                "LEFT": (cx - arm, cy - half_w, cx - half_w, cy + half_w),
                "RIGHT": (cx + half_w, cy - half_w, cx + arm, cy + half_w)}
        if pressed in arms:
            d.rounded_rectangle(s(*arms[pressed]), s(rad)[0], fill=ACC)
        # engraved arrows
        t = half_w * 0.45
        n = arm * 0.13
        tips = {"UP": [(cx, cy - arm + n), (cx - t, cy - arm + n + t), (cx + t, cy - arm + n + t)],
                "DOWN": [(cx, cy + arm - n), (cx - t, cy + arm - n - t), (cx + t, cy + arm - n - t)],
                "LEFT": [(cx - arm + n, cy), (cx - arm + n + t, cy - t), (cx - arm + n + t, cy + t)],
                "RIGHT": [(cx + arm - n, cy), (cx + arm - n - t, cy - t), (cx + arm - n - t, cy + t)]}
        for name, pts in tips.items():
            d.polygon([tuple(s(*p)) for p in pts], fill=ACC_DARK if pressed == name else ENGRAVE)
        # centre dimple
        e = half_w * 0.26
        d.ellipse(s(cx - e, cy - e, cx + e, cy + e), fill=(18, 19, 21))

    def shoulder(self, x0, y0, x1, y1, pressed=False):
        d, s = self.d, self.s
        r = s(14)[0]
        d.rounded_rectangle(s(x0, y0 + 3, x1, y1 + 3), r, fill=BTN_SH)
        if pressed:
            d.rounded_rectangle(s(x0 - 3, y0 - 3, x1 + 3, y1 + 3), r, fill=ACC)
            d.rounded_rectangle(s(x0, y0, x1, y1), r, fill=ACC)
        else:
            d.rounded_rectangle(s(x0, y0, x1, y1), r, fill=BTN_HI)
            d.rounded_rectangle(s(x0, y0 + 2, x1, y1), r, fill=BTN)

    def text(self, x, y, txt, size, colour, anchor="mm", weight="SemiBold"):
        if self.native_text:
            self.texts.append((x, y, txt, size, colour, anchor, weight))
        else:
            self.d.text(tuple(self.s(x, y)), txt, font=self.font(size, weight), fill=colour, anchor=anchor)

    def done(self):
        out = self.img.resize((self.w, self.h), Image.LANCZOS)
        if self.texts:
            kn = self.k / SS                       # base units -> final pixels
            d = ImageDraw.Draw(out)
            for x, y, txt, size, colour, anchor, weight in self.texts:
                d.text((round(x * kn), round(y * kn)), txt,
                       font=self.font(size, weight, scale=kn), fill=colour, anchor=anchor)
        return out


def render_4x3(w, h, pressed=None, tx=None):
    """tx: TX lamp lit (default: lit whenever a button is pressed)."""
    c = Canvas(w, h)
    c.gradient()
    lab = lambda f: ACC if pressed == f else LABEL

    # header: device + TX lamp
    c.text(32, 34, "SONY STR-DH790", 22, TITLE, "lm", "Bold")
    tx_on = (pressed is not None) if tx is None else tx
    c.d.rounded_rectangle(c.s(548, 20, 608, 48), c.s(14)[0],
                          outline=ACC if tx_on else DIM, width=c.s(2)[0])
    c.text(570, 34, "TX", 15, ACC if tx_on else DIM, "mm", "Bold")
    c.d.ellipse(c.s(588, 29, 598, 39), fill=ACC if tx_on else DIM)

    # small buttons row (top of the grip): Start = POWER (left), home, Select = MUTE (right)
    y = 96
    c.circle_btn(262, y, 15, pressed == "POWER")
    c.circle_btn(320, y, 15)
    c.circle_btn(378, y, 15, pressed == "MUTE")
    c.text(232, y, "POWER", 17, lab("POWER"), "rm")
    c.text(408, y, "MUTE", 17, lab("MUTE"), "lm")

    # face buttons (left in the grip)
    fx, fy, off, r = 212, 262, 66, 28
    for dx, dy, f in [(0, -off, "AMP MENU"), (-off, 0, "OPTIONS"), (off, 0, "ENTER"), (0, off, "BACK")]:
        c.circle_btn(fx + dx, fy + dy, r, pressed == f)
    c.text(fx, fy - off - r - 18, "AMP MENU", 17, lab("AMP MENU"))
    c.text(fx - off - r - 14, fy, "OPTIONS", 17, lab("OPTIONS"), "rm")
    c.text(fx + off + r + 14, fy, "ENTER", 17, lab("ENTER"), "lm")
    c.text(fx, fy + off + r + 20, "BACK", 17, lab("BACK"))

    # d-pad (right in the grip)
    dx0 = 508
    c.dpad(dx0, fy, 78, 27, pressed if pressed in ("UP", "DOWN", "LEFT", "RIGHT") else None)
    c.text(dx0, fy + 78 + 22, "MENU", 17, LABEL)

    # shoulders (bottom edge of the grip): R1 left = VOLUME DOWN, L1 right = VOLUME UP
    for x0, x1, f, sign, word in [(24, 248, "VOL-", "−", "VOLUME DOWN"), (392, 616, "VOL+", "+", "VOLUME UP")]:
        on = pressed == f
        c.shoulder(x0, 404, x1, 458, on)
        col = ACC_DARK if on else LABEL
        c.text(x0 + 30, 431, sign, 30, col, "mm", "Bold")
        c.text(x0 + 56, 431, word, 17, col, "lm")
    return c.done()


def render(w=800, h=720, pressed=None, tx=None):
    """800x720 (10:9): exactly 2x into the Pocket's 1600x1440 panel.
    tx: TX lamp lit (default: lit whenever a button is pressed)."""
    c = Canvas(w, h, base_w=800, native_text=True)
    c.flat()
    lab = lambda f: ACC if pressed == f else LABEL
    L = 22                                     # label size

    # header: device + TX lamp
    c.text(40, 58, "SONY STR-DH790", 30, TITLE, "lm", "Bold")
    tx_on = (pressed is not None) if tx is None else tx
    c.d.rounded_rectangle(c.s(682, 38, 760, 78), c.s(20)[0],
                          outline=ACC if tx_on else DIM, width=c.s(3)[0])
    c.text(710, 58, "TX", 20, ACC if tx_on else DIM, "mm", "Bold")
    c.d.ellipse(c.s(733, 51, 747, 65), fill=ACC if tx_on else DIM)

    # small buttons row (top of the grip): Start = POWER (left), home, Select = MUTE (right)
    y = 176
    c.circle_btn(330, y, 19, pressed == "POWER")
    c.circle_btn(400, y, 19)
    c.circle_btn(470, y, 19, pressed == "MUTE")
    c.text(294, y, "POWER", L, lab("POWER"), "rm")
    c.text(506, y, "MUTE", L, lab("MUTE"), "lm")

    # face buttons (left in the grip)
    fx, fy, off, r = 282, 404, 86, 36
    for dx, dy, f in [(0, -off, "AMP MENU"), (-off, 0, "OPTIONS"), (off, 0, "ENTER"), (0, off, "BACK")]:
        c.circle_btn(fx + dx, fy + dy, r, pressed == f)
    c.text(fx, fy - off - r - 26, "AMP MENU", L, lab("AMP MENU"))
    c.text(fx - off - r - 18, fy, "OPTIONS", L, lab("OPTIONS"), "rm")
    c.text(fx + off + r + 18, fy, "ENTER", L, lab("ENTER"), "lm")
    c.text(fx, fy + off + r + 28, "BACK", L, lab("BACK"))

    # d-pad (right in the grip)
    dx0 = 652
    c.dpad(dx0, fy, 102, 35, pressed if pressed in ("UP", "DOWN", "LEFT", "RIGHT") else None)
    c.text(dx0, fy + 102 + 30, "MENU", L, LABEL)

    # shoulders (bottom edge of the grip): R1 left = VOLUME DOWN, L1 right = VOLUME UP
    for x0, x1, f, sign, word in [(40, 380, "VOL-", MINUS, "VOLUME DOWN"), (420, 760, "VOL+", "+", "VOLUME UP")]:
        on = pressed == f
        c.shoulder(x0, 604, x1, 674, on)
        col = ACC_DARK if on else LABEL
        c.text(x0 + 40, 639, sign, 40, col, "mm", "Bold")
        c.text(x0 + 76, 639, word, L, col, "lm")
    return c.done()


MINUS = chr(0x2212)


def main():
    out = ROOT / "docs" / "ui"
    out.mkdir(parents=True, exist_ok=True)
    for state in [None, "ENTER", "VOL+", "UP"]:
        tag = "idle" if state is None else state.lower().replace("+", "plus")
        path = out / f"m5_800x720_{tag}.png"
        render(800, 720, state).save(path)
        print(path.relative_to(ROOT))
        if state is None:   # as it lands on the 1600x1440 panel: exactly 2x
            Image.open(path).resize((1600, 1440), Image.NEAREST).save(
                out / "m5_800x720_idle_on_panel_1600x1440.png")


if __name__ == "__main__":
    main()
