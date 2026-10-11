"""Platform banner (521x165) and core icon (36x36) for the Pocket menu and
the openFPGA Library site.

Draws both in grayscale at 4x and downsamples, then writes:
  docs/ui/platform_banner.png, docs/ui/core_icon.png     previews (upright)
  dist/platforms/_images/pocketir.bin, dist/icon.bin     APF images

APF image format (checked against the core template's own images): 16 bits
per pixel, luminance in the first byte, 0 in the second; pixels stored
row-major from the upright image rotated 90 degrees counter-clockwise.

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


def pocket(d, x, y, w=104, h=60):
    """Pocket lying on its side, bottom edge (IR / power LED) facing right."""
    d.rounded_rectangle(r(x, y, x + w, y + h), radius=7 * S, fill=BODY)
    d.rounded_rectangle(r(x + 6, y + 7, x + 52, y + h - 7), radius=2 * S, fill=SCREEN)
    # d-pad (lower right) and face buttons (upper right), as in the 180-degree grip
    cx, cy = x + 72, y + 42
    d.rectangle(r(cx - 7, cy - 2.5, cx + 7, cy + 2.5), fill=KEY)
    d.rectangle(r(cx - 2.5, cy - 7, cx + 2.5, cy + 7), fill=KEY)
    for bx, by in ((x + 66, y + 14), (x + 76, y + 18), (x + 72, y + 10), (x + 80, y + 9)):
        d.ellipse(r(bx - 3, by - 3, bx + 3, by + 3), fill=KEY)
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
    led = pocket(d, 262, 60, w=92, h=54)
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
    return bytes(b for p in rot.getdata() for b in (p, 0))


def from_apf(data, w, h):
    im = Image.new("L", (h, w))
    im.putdata(data[0::2])
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
