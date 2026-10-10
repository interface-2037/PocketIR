"""Export the M5 UI as FPGA ROM data and set the video mode.

Renders the mockup (ui_hires.py) idle, once per pressed button, and with the
TX lamp lit. Every pixel that changes when a button is pressed belongs to that
button's *region*; its pressed colour is stored as the pixel's *lit* colour.
All colours share one 256-entry palette. The frame is then run-length encoded
in raster order (active pixels only).

Outputs (src/fpga/core/ui/):
  ui_rle.hex      one 28-bit word per run: {len-1[7:0], region[3:0], lit[7:0], idle[7:0]}
  ui_palette.hex  256 x 24-bit RGB
  ui_rle.vh       UI_RLE_WORDS + video timing (active, totals, porches, pixel Hz)
Also points video.json (width/height) and the PLL (outputs 0/1, 90 deg phase)
at the chosen mode, so RTL, testbench, JSON and clock always agree.
Outputs (build/ui_expected/, for the testbench):
  idle.hex, enter.hex   expected 24-bit pixels, raster order

Region ids: Pocket key bit k -> k+1 for k <= 9, Select(14) -> 11, Start(15) -> 12,
TX lamp -> 13. Function -> key bit matches src/fpga/core/ir/ir_code_rom.v.

Usage:  python tools/ui/ui_rom.py [WIDTH HEIGHT]     (default 800 720; 10:9 layout)
"""

import re
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import ui_hires  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
W, H = 800, 720
FPS = 60
H_BLANK, V_BLANK = 20, 10      # minimal blanking: HS at x=3, DE from x=10, 6 lines before

KEY_BIT = {"POWER": 15, "MUTE": 14, "VOL+": 8, "VOL-": 9, "UP": 1, "DOWN": 0,
           "LEFT": 3, "RIGHT": 2, "ENTER": 7, "BACK": 6, "AMP MENU": 5, "OPTIONS": 4}
TX_REGION = 13


def region_of_bit(k):
    return k + 1 if k <= 9 else {14: 11, 15: 12}[k]


def build():
    idle = ui_hires.render(W, H, None, tx=False)
    ip = idle.load()
    region = [[0] * W for _ in range(H)]
    lit_rgb = [[None] * W for _ in range(H)]
    shared = []

    def claim(img, rid):
        p = img.load()
        for y in range(H):
            for x in range(W):
                if p[x, y] != ip[x, y]:
                    if region[y][x] not in (0, rid):
                        # an anti-aliased edge pixel shared by two neighbours
                        # (e.g. d-pad arm corners at small sizes): a pixel
                        # holds one lit colour, so the first region keeps it
                        shared.append((x, y))
                        continue
                    region[y][x] = rid
                    lit_rgb[y][x] = p[x, y]

    for func, bit in KEY_BIT.items():
        claim(ui_hires.render(W, H, func, tx=False), region_of_bit(bit))
    claim(ui_hires.render(W, H, None, tx=True), TX_REGION)
    if shared:
        print(f"note: {len(shared)} edge pixel(s) shared between highlight regions, kept by the first")

    # one shared palette: quantise idle + all-lit composite together
    lit_img = idle.copy()
    lp = lit_img.load()
    for y in range(H):
        for x in range(W):
            if lit_rgb[y][x]:
                lp[x, y] = lit_rgb[y][x]
    mosaic = Image.new("RGB", (W, 2 * H))
    mosaic.paste(idle, (0, 0))
    mosaic.paste(lit_img, (0, H))
    q = mosaic.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    pal = q.getpalette()[:768]
    pal += [0] * (768 - len(pal))
    qp = q.load()
    idle_idx = [[qp[x, y] for x in range(W)] for y in range(H)]
    lit_idx = [[qp[x, y + H] for x in range(W)] for y in range(H)]

    # run-length encode
    words = []
    run_key, run_len = None, 0
    for y in range(H):
        for x in range(W):
            r = region[y][x]
            key = (idle_idx[y][x], lit_idx[y][x] if r else idle_idx[y][x], r)
            if key == run_key and run_len < 256:
                run_len += 1
            else:
                if run_key is not None:
                    words.append((run_len, *run_key))
                run_key, run_len = key, 1
    words.append((run_len, *run_key))
    return pal, words, idle_idx, lit_idx, region


def set_video_mode():
    """Point video.json and the PLL at W x H @ FPS; return (.vh timing text, Hz)."""
    h_total, v_total = W + H_BLANK, H + V_BLANK
    hz = h_total * v_total * FPS
    phase_ps = round(1e12 / hz / 4)                  # 90 degrees
    mhz = f"{hz / 1e6:.6f}"

    vj = ROOT / "video.json"
    t = vj.read_text()
    t = re.sub(r'"width": \d+', f'"width": {W}', t)
    t = re.sub(r'"height": \d+', f'"height": {H}', t)
    vj.write_text(t)

    pll = ROOT / "src" / "fpga" / "core" / "mf_pllbase" / "mf_pllbase_0002.v"
    t = pll.read_text()
    t = re.sub(r'\.output_clock_frequency([01])\("[0-9.]+ MHz"\)',
               lambda m: f'.output_clock_frequency{m.group(1)}("{mhz} MHz")', t)
    t = re.sub(r'\.phase_shift1\("\d+ ps"\)', f'.phase_shift1("{phase_ps} ps")', t)
    pll.write_text(t)

    ip = ROOT / "src" / "fpga" / "core" / "mf_pllbase.v"      # IP-editor record only
    t = ip.read_text()
    t = re.sub(r'(gui_output_clock_frequency[01]" value=")[0-9.]+',
               lambda m: m.group(1) + f"{hz / 1e6:g}", t)
    t = re.sub(r'(gui_phase_shift1" value=")\d+', lambda m: m.group(1) + str(phase_ps), t)
    ip.write_text(t)

    vh = (f"localparam UI_H_ACTIVE = {W};\n"
          f"localparam UI_V_ACTIVE = {H};\n"
          f"localparam UI_H_TOTAL  = {h_total};\n"
          f"localparam UI_V_TOTAL  = {v_total};\n"
          f"localparam UI_H_BPORCH = 10;\n"
          f"localparam UI_V_BPORCH = 6;\n"
          f"localparam UI_PIXEL_HZ = {hz};   // {FPS} Hz; PLL 90 deg = {phase_ps} ps\n")
    return vh, hz


def main():
    global W, H
    if len(sys.argv) == 3:
        W, H = int(sys.argv[1]), int(sys.argv[2])
    timing, hz = set_video_mode()
    pal, words, idle_idx, lit_idx, region = build()
    out = ROOT / "src" / "fpga" / "core" / "ui"
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "ui_rle.hex", "w") as f:
        for n, idle, lit, r in words:
            f.write(f"{((n - 1) << 20) | (r << 16) | (lit << 8) | idle:07X}\n")
    with open(out / "ui_palette.hex", "w") as f:
        for i in range(256):
            f.write(f"{pal[3 * i]:02X}{pal[3 * i + 1]:02X}{pal[3 * i + 2]:02X}\n")
    (out / "ui_rle.vh").write_text(
        "// generated by tools/ui/ui_rom.py -- do not edit\n"
        f"localparam UI_RLE_WORDS = {len(words)};\n" + timing)

    # expected frames for the testbench: idle, and ENTER pressed + TX lit
    exp = ROOT / "build" / "ui_expected"
    exp.mkdir(parents=True, exist_ok=True)
    enter_r = region_of_bit(KEY_BIT["ENTER"])
    for name, active in [("idle", ()), ("enter", (enter_r, TX_REGION))]:
        with open(exp / f"{name}.hex", "w") as f:
            img = Image.new("RGB", (W, H))
            px = img.load()
            for y in range(H):
                for x in range(W):
                    i = lit_idx[y][x] if region[y][x] in active else idle_idx[y][x]
                    rgb = (pal[3 * i], pal[3 * i + 1], pal[3 * i + 2])
                    px[x, y] = rgb
                    f.write(f"{rgb[0]:02X}{rgb[1]:02X}{rgb[2]:02X}\n")
            img.save(exp / f"{name}.png")
    bits = len(words) * 28
    print(f"{W}x{H} @ {FPS} Hz, pixel clock {hz / 1e6:.4f} MHz: {len(words)} runs, "
          f"{bits / 1000:.0f} kbit RLE + 6 kbit palette -> {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
