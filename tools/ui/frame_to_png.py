"""Convert a captured simulation frame (one RRGGBB hex per active pixel, raster
order, from sim/tb_ui_video.v) to a PNG.

Usage:  python tools/ui/frame_to_png.py sim/out/ui_frame_enter.hex out.png [width]
"""

import sys

from PIL import Image


def main(src, dst, width=800):
    px = [int(line, 16) for line in open(src) if line.strip()]
    height = len(px) // width
    img = Image.new("RGB", (width, height))
    img.putdata([((p >> 16) & 255, (p >> 8) & 255, p & 255) for p in px[: width * height]])
    img.save(dst)
    print(f"{dst}: {width}x{height}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 800)
