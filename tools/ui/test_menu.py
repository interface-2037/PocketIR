"""Menu vectors for the testbenches (M7 step 5).

* build/ui_expected/menu_page.txt + menu.hex: one menu page (TV brands,
  cursor on SAMSUNG, scroll thumb shown) -- tb_ui_video writes the page's text
  slots, sets the menu inputs and compares the frame pixel for pixel.
* build/ir_expected/menu_steps.txt: a scripted navigation (open, TV, A-Z jump
  to SAMSUNG, set level, test, choose set 1, reopen, back out) with, after
  every key, the expected events and page -- for tb_remote.v.

Usage:  python tools/ui/test_menu.py        (prints PASS or FAIL)
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import ui_menu as um  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def write_page(fh, m):
    slots, bar, scroll = m.page()
    fh.write(f"{bar} {1 if scroll else 0} {scroll[0] if scroll else 0} {scroll[1] if scroll else 0}\n")
    for s in (slots + [um.tx.Slot(0, 0)] * 32)[:32]:
        t = s.text[:31]
        fh.write(f"{s.word():x} {len(t)} " + " ".join(f"{ord(c):x}" for c in t) + "\n")


def main():
    types = um.load_types()
    tv = [t for t, _ in types].index("TV")
    rx = [t for t, _ in types].index("RECEIVER")
    sony = (rx, [b for b, _ in types[rx][1]].index("SONY"), 0)
    sam_b = [b for b, _ in types[tv][1]].index("SAMSUNG")

    # one page for the video testbench
    m = um.Menu(types, (tv, sam_b, 0))
    m.press("CHORD")
    m.press("OK")                                   # TV -> brands, cursor on SAMSUNG
    exp = ROOT / "build" / "ui_expected"
    exp.mkdir(parents=True, exist_ok=True)
    with open(exp / "menu_page.txt", "w") as fh:
        write_page(fh, m)
    img = m.render()
    img.save(exp / "menu.png")
    (exp / "menu.hex").write_text(um.tx.rgb_hex(img))

    # scripted navigation for the remote testbench
    # open (cursor on RECEIVER), up to TV, into brands, A-Z jumps to the S block,
    # then step to SAMSUNG; computed with the model so the script stays valid
    # when the library changes
    probe = um.Menu(types, sony)
    script = []
    for k in ["CHORD", "UP", "OK"]:
        probe.press(k); script.append(k)
    while probe.letter(probe.cur[1]) < "S":
        probe.press("RIGHT"); script.append("RIGHT")
    while probe.cur[1] < sam_b:
        probe.press("DOWN"); script.append("DOWN")
    script += ["LEFT", "RIGHT"] + ["DOWN"] * (sam_b - probe.cur[1])
    script += ["OK", "DOWN", "POWER", "OK",            # set level, set 1, test, choose it
               "CHORD", "BACK", "BACK", "OK", "BACK", "BACK",
               "CHORD", "CHORD"]
    m = um.Menu(types, sony)
    out = ROOT / "build" / "ir_expected"
    out.mkdir(parents=True, exist_ok=True)
    errors = []
    with open(out / "menu_steps.txt", "w") as fh:
        fh.write(f"{len(script)} {sony[0]} {sony[1]} {sony[2]}\n")
        for key in script:
            ev = m.press(key)
            names = [e[0] for e in ev]
            load = next((e for e in ev if e[0] in ("load", "codes")), None)
            fh.write(f"{key} {int(m.open)} {m.level} {int('test' in names)} "
                     f"{int('load' in names)} {int('codes' in names)} "
                     f"{load[1] if load else 0} {load[2] if load else 0} {load[3] if load else 0}\n")
            if m.open:
                write_page(fh, m)
    # sanity: the script must reach SAMSUNG and end with the Samsung set 1 chosen, menu closed
    if m.open or m.dev != (tv, sam_b, 1):
        errors.append(f"script ended in state open={m.open} dev={m.dev}")
    if errors:
        print("FAIL test_menu")
        for e in errors:
            print("  " + e)
        sys.exit(1)
    print(f"PASS test_menu ({len(script)} menu steps, 1 page frame -> build/)")


if __name__ == "__main__":
    main()
