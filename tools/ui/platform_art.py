"""Platform banner (521x165) and core icon (36x36) for the Pocket menu and
the openFPGA Library site.

Draws both in grayscale at 4x and downsamples, then writes:
  docs/ui/platform_banner.png, docs/ui/core_icon.png     previews (upright)
  dist/platforms/_images/pocketir.bin, dist/icon.bin     APF images

APF image format (checked against the core template's own images and the
openFPGA Library's converter, which reads int16 LE and shows 255 - value):
16 bits per pixel, INVERTED brightness (255 = black) in the first byte, 0 in
the second; pixels stored row-major from the upright image rotated 90 degrees
counter-clockwise. v0.11.1 stored plain brightness and showed inverted.

Usage:  python tools/ui/platform_art.py [--check]   (--check: decode the .bin
files back and compare with the previews, write nothing)
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FONT = Path(__file__).parent / "fonts" / "Inter-Variable.ttf"
S = 4                                   # supersampling factor

BG, BODY, EDGE, SCREEN, KEY, TEXT, SUB = 26, 200, 235, 60, 110, 255, 150


def font(size, weight="Bold"):
    f = ImageFont.truetype(str(FONT), size * S)
    try:
        f.set_variation_by_name(weight)
    except (OSError, ValueError):
        pass
    return f


def r(*v):
    return [int(round(x * S)) for x in v]


# Analogue Pocket front, measured from a straight-on product photo, in units
# where the body is 708 wide x 1200 tall (upright, origin top-left).
PK_W, PK_H, PK_CORNER = 708, 1200, 30
PK_GLASS = (6, 8, 702, 639)                    # glass panel
PK_DISPLAY = (76, 78, 624, 568)                # lit area, 548 x 490 (10:9)
PK_DPAD = (148, 805, 167, 57)                  # centre u, v; arm length, arm width
PK_FACE = [(542, 732), (469, 805), (615, 805), (542, 878)]   # diamond, r 34
PK_FACE_R = 34
PK_SMALL = [(288, 1078), (352, 1078), (418, 1078)]          # r 21
PK_SMALL_R = 21
GLASS = 150


def pocket(d, x, y, h=60):
    """Real-proportion Pocket lying on its side: top edge left, bottom edge
    (IR / power LED) facing right, face buttons up, d-pad down."""
    k = h / PK_W
    w = PK_H * k

    def P(u, v):                               # upright (u, v) -> banner (x, y)
        return x + v * k, y + (PK_W - u) * k

    def box(u0, v0, u1, v1):
        (xa, ya), (xb, yb) = P(u0, v0), P(u1, v1)
        return min(xa, xb), min(ya, yb), max(xa, xb), max(ya, yb)

    def circle(u, v, rad, fill):
        cx, cy = P(u, v)
        d.ellipse(r(cx - rad * k, cy - rad * k, cx + rad * k, cy + rad * k), fill=fill)

    d.rounded_rectangle(r(x, y, x + w, y + h), radius=PK_CORNER * k * S, fill=BODY)
    d.rounded_rectangle(r(*box(*PK_GLASS)), radius=PK_CORNER * 0.8 * k * S, fill=GLASS)
    d.rectangle(r(*box(*PK_DISPLAY)), fill=SCREEN)
    cu, cv, arm, wid = PK_DPAD
    for du, dv in ((arm, wid), (wid, arm)):
        d.rounded_rectangle(r(*box(cu - du / 2, cv - dv / 2, cu + du / 2, cv + dv / 2)),
                            radius=6 * k * S, fill=KEY)
    for u, v in PK_FACE:
        circle(u, v, PK_FACE_R, KEY)
    for u, v in PK_SMALL:
        circle(u, v, PK_SMALL_R, KEY)
    # power LED on the bottom edge
    led = (x + w - 1, y + h / 2)
    d.ellipse(r(led[0] - 2.2, led[1] - 2.2, led[0] + 2.2, led[1] + 2.2), fill=255)
    return led


def waves(d, cx, cy, n=3, step=11, span=40):
    for i in range(n):
        rad = 10 + i * step
        shade = 255 - i * 45
        d.arc(r(cx - rad, cy - rad, cx + rad, cy + rad), -span, span,
              fill=shade, width=int(3 * S))


def tv(d, x, y, w=92, h=62):
    d.rounded_rectangle(r(x, y, x + w, y + h), radius=4 * S, fill=BODY)
    d.rectangle(r(x + 5, y + 5, x + w - 5, y + h - 5), fill=SCREEN)
    d.polygon(r(x + w / 2 - 14, y + h + 10, x + w / 2 + 14, y + h + 10,
                x + w / 2 + 5, y + h, x + w / 2 - 5, y + h), fill=KEY)
    # power symbol on the screen
    cx, cy, rad = x + w / 2, y + h / 2, 11
    d.arc(r(cx - rad, cy - rad, cx + rad, cy + rad), -60, 240, fill=EDGE, width=int(3 * S))
    d.line(r(cx, cy - rad - 3, cx, cy - 1), fill=EDGE, width=int(3 * S))


def banner():
    W, H = 521, 165
    im = Image.new("L", (W * S, H * S), BG)
    d = ImageDraw.Draw(im)
    d.text(r(24, 66), "PocketIR", font=font(40), fill=TEXT, anchor="ls")
    d.text(r(25, 90), "UNIVERSAL TV / AV REMOTE", font=font(12, "SemiBold"), fill=SUB, anchor="ls")
    d.text(r(25, 108), "1,000+ DEVICES · LEARNS YOUR REMOTE", font=font(10, "Medium"), fill=SUB - 30, anchor="ls")
    led = pocket(d, 254, 57, h=60)
    waves(d, led[0] + 3, led[1], n=3, step=14, span=40)
    tv(d, 426, 48, w=80, h=54)
    return im.resize((W, H), Image.LANCZOS)


DIGITS = {  # 3x5
    "2": ("###", "..#", "###", "#..", "###"),
    "0": ("###", "#.#", "#.#", "#.#", "###"),
    "3": ("###", "..#", ".##", "..#", "###"),
    "7": ("###", "..#", "..#", ".#.", ".#."),
}


def icon():
    """The author's GitHub avatar (terminal prompt + 2037 in a rounded
    frame), redrawn pixel by pixel at 36x36."""
    N, INK, NUM, FRAME, GLOW = 36, 240, 185, 200, 45
    im = Image.new("L", (N, N), 0)
    px = im.load()
    a, b = 5, 30                                   # frame, 1 px, glow outside
    for i in range(a + 2, b - 1):
        for x, y in ((i, a), (i, b), (a, i), (b, i)):
            px[x, y] = FRAME
        for x, y in ((i, a - 1), (i, b + 1), (a - 1, i), (b + 1, i)):
            px[x, y] = GLOW
    for x, y in ((a + 1, a + 1), (b - 1, a + 1), (a + 1, b - 1), (b - 1, b - 1)):
        px[x, y] = FRAME                           # rounded corners
    for row, off in enumerate((0, 1, 2, 3, 2, 1, 0)):   # chevron, 2-px blocks
        for dx in (0, 1):
            px[13 + off + dx, 10 + row] = INK
    for x in range(19, 23):                        # cursor
        px[x, 16] = INK
    for k, ch in enumerate("2037"):                # 3x5 digits, 1-px gaps
        for y, line in enumerate(DIGITS[ch]):
            for x, c in enumerate(line):
                if c == "#":
                    px[11 + k * 4 + x, 20 + y] = NUM
    return im


def to_apf(im):
    rot = im.rotate(90, expand=True)
    return bytes(b for p in rot.getdata() for b in (255 - p, 0))


def from_apf(data, w, h):
    im = Image.new("L", (h, w))
    im.putdata([255 - v for v in data[0::2]])
    return im.rotate(-90, expand=True)


def main():
    check = "--check" in sys.argv
    jobs = [(banner(), "docs/ui/platform_banner.png", "dist/platforms/_images/pocketir.bin"),
            (icon(), "docs/ui/core_icon.png", "dist/icon.bin")]
    for im, png, binf in jobs:
        if check:
            back = from_apf((ROOT / binf).read_bytes(), *im.size)
            same = list(back.getdata()) == list(Image.open(ROOT / png).getdata())
            print(f"{binf}: {'matches' if same else 'DIFFERS from'} {png}")
            continue
        im.save(ROOT / png)
        (ROOT / binf).write_bytes(to_apf(im))
        assert list(from_apf((ROOT / binf).read_bytes(), *im.size).getdata()) == list(im.getdata())
        print(f"wrote {png} and {binf} ({im.size[0]}x{im.size[1]})")


if __name__ == "__main__":
    main()
