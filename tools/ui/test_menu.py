"""Menu vectors for the testbenches (M7 step 5, M9).

* build/ui_expected/menu_page.txt + menu.hex: one menu page (home: RECENT
  DEVICES, LEARN FROM REMOTE, the types; divider, bar, scroll thumb) --
  tb_ui_video writes the page's text slots, sets the menu inputs and compares
  the frame pixel for pixel.
* build/ir_expected/menu_steps.txt: a scripted session, with after every step
  the expected events and page -- for tb_remote.v:
    - M7 route: open, TV, A-Z jump to SAMSUNG, set level, test, choose set 1
    - recent list: open it (cursor on the previous device), test, choose
    - learn: no match, couldn't read, Samsung VOL+ (44 matches), scroll,
      narrow with POWER (28), a button that matches none of them (list kept),
      test, retry, the real Sony capture (10 matches), choose one
    - recent list again, then choose Samsung TV set 1 from it (the testbench
      checks that device afterwards)
  Remote buttons ("BURST") carry the captured intervals; their results come
  from rxcap.identify, the model of lib/ir_match.v.

Line formats (menu_steps.txt):
  header:  nsteps boot_t boot_b boot_s
  step:    key open level test load codes t b s
           [BURST only: n_iv iv0 .. iv(n-1)]
           [open only: bar scroll h0 h1 divider, then 32 slot lines "word len chars..."]

Usage:  python tools/ui/test_menu.py        (prints PASS or FAIL)
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parents[1] / "ir"))
import rxcap  # noqa: E402
import ui_menu as um  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def write_page(fh, m):
    slots, bar, scroll, div = m.page()
    fh.write(f"{15 if bar is None else bar} {1 if scroll else 0} {scroll[0] if scroll else 0} "
             f"{scroll[1] if scroll else 0} {15 if div is None else div}\n")
    for s in (slots + [um.tx.Slot(0, 0)] * 32)[:32]:
        t = s.text[:31]
        fh.write(f"{s.word():x} {len(t)} " + " ".join(f"{ord(c):x}" for c in t) + "\n")


def main():
    types = um.load_types()
    tv = [t for t, _ in types].index("TV")
    rx = [t for t, _ in types].index("RECEIVER")
    sony = (rx, [b for b, _ in types[rx][1]].index("SONY"), 0)
    sam_b = [b for b, _ in types[tv][1]].index("SAMSUNG")
    sam_cs = types[tv][1][sam_b][1][0][1]

    # one page for the video testbench: the home list
    m = um.Menu(types, (tv, sam_b, 0), recent=[(tv, sam_b, 0), sony])
    m.press("CHORD")
    exp = ROOT / "build" / "ui_expected"
    exp.mkdir(parents=True, exist_ok=True)
    with open(exp / "menu_page.txt", "w") as fh:
        write_page(fh, m)
    img = m.render()
    img.save(exp / "menu.png")
    (exp / "menu.hex").write_text(um.tx.rgb_hex(img))

    # remote buttons: intervals as ir_rx_marks.v records them
    cap = rxcap.parse((ROOT / "tools/ir/fixtures/rx_v0.10.0_sony_power.sav").read_bytes())
    hw = [rxcap.cap_intervals(rxcap.mark_starts(b["entries"], b["idle"])) for b in cap["bufs"]]
    bursts = {
        "nec_none": rxcap.edge_intervals("NEC", 0x5A, 0x77),
        "leaders": hw[1],
        "sam_vol": rxcap.edge_intervals("Samsung32", *sam_cs["VOL_UP"][1:3]),
        "sam_pow": rxcap.edge_intervals("Samsung32", *sam_cs["POWER"][1:3], seed=2),
        "sony_hw": hw[0],
    }

    # scripted session; the M7 route is computed with the model so it stays valid
    # when the library changes
    probe = um.Menu(types, sony)
    script = []
    for k in ["CHORD", "DOWN", "DOWN"] + ["DOWN"] * tv + ["OK"]:
        probe.press(k); script.append(k)
    while probe.letter(probe.cur[1]) < "S":
        probe.press("RIGHT"); script.append("RIGHT")
    while probe.cur[1] < sam_b:
        probe.press("DOWN"); script.append("DOWN")
    script += ["LEFT", "RIGHT"] + ["DOWN"] * (sam_b - probe.cur[1])
    script += ["OK", "DOWN", "POWER", "OK",            # set level, set 1, test, choose it
               "CHORD", "BACK", "BACK", "OK", "BACK", "BACK",
               "CHORD", "CHORD",
               # recent list: opens on the previous device (Sony)
               "CHORD", "OK", "POWER", "UP", "DOWN", "OK",
               # learn
               "CHORD", "DOWN", "OK", "UP", "OK",
               "BURST:nec_none", "BURST:leaders", "BURST:sam_vol"] + ["DOWN"] * 10 + [
               "BURST:sam_pow", "BURST:nec_none", "POWER", "BACK", "BURST:sony_hw", "DOWN", "OK",
               "CHORD", "OK", "BACK", "DOWN", "OK", "BACK", "BACK"]
    m = um.Menu(types, sony)
    rec_probe = um.Menu(types, sony)
    for k in script:                                   # where Samsung set 1 ends up in the recent list
        if k.startswith("BURST:"):
            iv = bursts[k[6:]]
            res, lst = rxcap.identify(iv, types, rec_probe.matches if rec_probe.level == um.L_MATCH else None)
            rec_probe.burst(res, lst)
        else:
            rec_probe.press(k)
    script += ["CHORD", "OK"] + ["DOWN"] * rec_probe.recent.index((tv, sam_b, 1)) + ["OK"]

    out = ROOT / "build" / "ir_expected"
    out.mkdir(parents=True, exist_ok=True)
    errors, counts = [], []
    with open(out / "menu_steps.txt", "w") as fh:
        fh.write(f"{len(script)} {sony[0]} {sony[1]} {sony[2]}\n")
        for key in script:
            if key.startswith("BURST:"):
                iv = bursts[key[6:]]
                res, lst = rxcap.identify(iv, types, m.matches if m.level == um.L_MATCH else None)
                ev = m.burst(res, lst)
                counts.append((key[6:], res, len(lst)))
                name = "BURST"
            else:
                ev, name = m.press(key), key
            names = [e[0] for e in ev]
            load = next((e for e in ev if e[0] in ("load", "codes")), None)
            fh.write(f"{name} {int(m.open)} {m.level} {int('test' in names)} "
                     f"{int('load' in names)} {int('codes' in names)} "
                     f"{load[1] if load else 0} {load[2] if load else 0} {load[3] if load else 0}\n")
            if name == "BURST":
                fh.write(f"{len(iv)} " + " ".join(map(str, iv)) + "\n")
            if m.open:
                write_page(fh, m)
    # sanity: the session reaches the screens it is meant to test and ends on Samsung set 1
    if m.open or m.dev != (tv, sam_b, 1):
        errors.append(f"script ended in state open={m.open} dev={m.dev}")
    want = [("nec_none", 1, 0), ("leaders", 2, 0), ("sam_vol", 0, 44), ("sam_pow", 0, 28),
            ("nec_none", 3, 28), ("sony_hw", 0, 10)]
    if counts != want:
        errors.append(f"identify results {counts}, expected {want}")
    if len(m.recent) < 3:
        errors.append(f"recent list {m.recent}")
    if errors:
        print("FAIL test_menu")
        for e in errors:
            print("  " + e)
        sys.exit(1)
    print(f"PASS test_menu ({len(script)} menu steps incl. {len(counts)} remote buttons, 1 page frame -> build/)")


if __name__ == "__main__":
    main()
