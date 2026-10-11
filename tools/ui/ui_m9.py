"""M9 screen mockups: Recent devices, Learn from remote, matching devices.

Drawn with the hardware text model (ui_text.py: same fonts, slots, colours)
and the M7 menu geometry (ui_menu.py), with real library content, so the
screens are buildable as drawn. Mockups only: the navigation model and the
RTL constants come after interface2037's review.

Usage:  python tools/ui/ui_m9.py   -> docs/ui/m9_*.png and docs/ui/m9_sheet.png
"""

import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parents[1] / "ir"))
import library as lib  # noqa: E402
import ui_menu as um  # noqa: E402
import ui_text as tx  # noqa: E402
from ui_text import ACC, ACC_DARK, DIM, LABEL, SUB, TITLE  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "ui"
TYPES = um.load_types()


def dev_name(t, b, s):
    """Row text for a device: BRAND MODEL[ & N MORE] (31 chars max, like the set rows)."""
    bname, sets = TYPES[t][1][b]
    base, more = lib.split_model(sets[s][0])
    name = f"{bname} {base}" + (f" & {more} MORE" if more else "")
    return name if len(name) <= 31 else name[:30].rstrip() + "."


def find(tname, bname, model_prefix=""):
    t = [x for x, _ in TYPES].index(tname)
    b = [x for x, _ in TYPES[t][1]].index(bname)
    s = next(i for i, (m, _) in enumerate(TYPES[t][1][b][1]) if m.startswith(model_prefix))
    return t, b, s


def frame(title, crumb, counter=""):
    s = [tx.slot(20, 29, title, font=1, colour=TITLE), tx.slot(20, 47, crumb, colour=SUB)]
    if counter:
        s.append(tx.slot(380, 29, counter, "r", colour=SUB))
    return s


def hints(pairs):
    old = um.HINTS.get("_m9")
    um.HINTS["_m9"] = pairs
    out = um.hint_slots("_m9")
    if old is None:
        del um.HINTS["_m9"]
    return out


def render(slots, bar_row=None, scroll=None, divider=None):
    """divider: list row index whose top edge gets a 1-px line (in the 4-px gap between bars)."""
    img = Image.new("RGB", (um.W, um.H), um.BG_RGB)
    px = img.load()
    for x in range(um.BAR_X0, um.BAR_X1):
        for y in um.SEP_Y:
            px[x, y] = um.BAR_RGB
        if divider is not None:
            px[x, um.ROW_Y0 + divider * um.ROW_H - 14] = um.BAR_RGB
    if bar_row is not None:
        y0 = um.ROW_Y0 + bar_row * um.ROW_H - 12
        for y in range(y0, y0 + 24):
            for x in range(um.BAR_X0, um.BAR_X1):
                px[x, y] = tx.COLOURS[ACC]
    if scroll:
        for y in range(*scroll):
            for x in (um.SCROLL_X, um.SCROLL_X + 1):
                px[x, y] = tx.COLOURS[DIM]
    tx.check_no_overlap(slots)
    return tx.draw(img, slots)


def list_page(title, crumb, rows, cur, top, hint, divider=None):
    """rows: [(name, detail)]; same row geometry and colours as the M7 menu."""
    n = len(rows)
    s = frame(title, crumb, f"{cur + 1} / {n}")
    for r in range(um.ROWS):
        k, y = top + r, um.ROW_Y0 + r * um.ROW_H
        name, det = rows[k] if k < n else ("", "")
        on = k == cur
        s.append(tx.slot(28, y, name, colour=ACC_DARK if on else LABEL))
        s.append(tx.slot(372, y, det, "r", colour=ACC_DARK if on else DIM))
    scroll = None
    if n > um.ROWS:
        scroll = (um.SCROLL_Y0 + um.SCROLL_LEN * top // n,
                  um.SCROLL_Y0 + um.SCROLL_LEN * min(n, top + um.ROWS) // n)
    vis = divider - top if divider is not None and 0 < divider - top < um.ROWS else None
    return render(s + hints(hint), cur - top, scroll, vis)


# ---------------------------------------------------------------- screens
def home(recent_n, cur=0):
    rows = [("RECENT DEVICES", f"{recent_n} DEVICES"), ("LEARN FROM REMOTE", "")]
    rows += [(t, um.sets_word(sum(len(s) for _, s in br))) for t, br in TYPES]
    return list_page("CHOOSE DEVICE", "RECENT, LEARN, OR BY TYPE", rows, cur, 0,
                     um.HINTS["nav"], divider=2)


def recent(devs, cur=1):
    rows = [(dev_name(*d), TYPES[d[0]][0]) for d in devs]
    return list_page("RECENT DEVICES", "MOST RECENT FIRST", rows, cur, 0,
                     [("POWER", "TEST"), ("ENTER", "USE"), ("BACK", "UP")])


def learn(result=()):
    """Instructions centred in the list area, LISTENING..., then the last try's result."""
    s = frame("LEARN FROM REMOTE", "FIND YOUR DEVICE BY ITS REMOTE")
    for i, ln in enumerate(INSTR):
        s.append(tx.slot(200, um.ROW_Y0 + (i + 1) * um.ROW_H, ln, "m", colour=LABEL))
    s.append(tx.slot(200, um.ROW_Y0 + 5 * um.ROW_H, "LISTENING...", "m", font=1, colour=ACC))
    for i, ln in enumerate(result):
        s.append(tx.slot(200, um.ROW_Y0 + (6 + i) * um.ROW_H + 6, ln, "m", colour=TITLE if i == 0 else SUB))
    return render(s + hints([("BACK", "CANCEL")]))


INSTR = ["POINT THE REMOTE AT THE POCKET'S", "BOTTOM EDGE, 1 TO 3 INCHES AWAY,", "AND TAP ONE BUTTON."]


def matches_for(codes):
    """Menu entries whose code set contains every (proto, D, F) in codes."""
    out = []
    for t, (tname, brands) in enumerate(TYPES):
        for b, (bname, sets) in enumerate(brands):
            for s, (model, cs) in enumerate(sets):
                have = {(p, d, f) for p, d, f, _ in cs.values()}
                if all(c in have for c in codes):
                    out.append((t, b, s))
    return out


def matches(found, crumb, cur=0):
    rows = [(dev_name(*d), TYPES[d[0]][0]) for d in found]
    title = f"{len(found)} MATCH" + ("" if len(found) == 1 else "ES")
    return list_page(title, crumb, rows, cur, 0,
                     [("POWER", "TEST"), ("ENTER", "USE"), ("BACK", "RETRY")])


def main():
    sam = find("TV", "SAMSUNG", "BN59-01180A")
    sony = find("RECEIVER", "SONY", "STR-DH790")
    lg = find("TV", "LG")
    roku = find("STREAMING", "ROKU")
    recents = [sam, sony, lg, roku, find("SOUNDBAR", "VIZIO")]
    cs = TYPES[sam[0]][1][sam[1]][1][sam[2]][1]
    vol = cs["VOL_UP"][:3]
    pwr = cs["POWER"][:3]
    one = matches_for([vol])
    two = matches_for([vol, pwr])
    screens = [
        ("home", home(len(recents))),
        ("recent", recent(recents)),
        ("learn_listen", learn()),
        ("learn_unread", learn(["COULDN'T READ THAT", "MOVE THE REMOTE CLOSER"])),
        ("learn_unknown", learn(["NO MATCH IN THE LIBRARY", "TRY ANOTHER BUTTON"])),
        ("matches_one", matches(one, "SAMSUNG32 07 07: TAP ANOTHER TO NARROW")),
        ("matches_two", matches(two, "2 BUTTONS: TAP ANOTHER TO NARROW")),
    ]
    sheet = Image.new("RGB", (2 * um.W + 30, 4 * um.H + 50), (12, 12, 14))
    for i, (name, img) in enumerate(screens):
        img.save(OUT / f"m9_{name}.png")
        img.resize((um.W * 4, um.H * 4), Image.NEAREST).save(OUT / f"m9_{name}_panel.png")
        sheet.paste(img, (10 + (i % 2) * (um.W + 10), 10 + (i // 2) * (um.H + 10)))
    sheet.save(OUT / "m9_sheet.png")
    print(f"{len(screens)} screens -> docs/ui/m9_*.png; matches: VOL_UP {len(one)}, +POWER {len(two)}")


if __name__ == "__main__":
    main()
