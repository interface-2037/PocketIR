"""Decode irremote.sav: the saved device (lib/dev_save.v) and, from v0.10.0,
the receiver capture that follows it (ir/ir_rx_cap.v, analysed by rxcap.py).

Usage:  python tools/ir/read_save.py [path/to/irremote.sav]
"""

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import library as lib  # noqa: E402
import rxcap  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
path = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "irremote.sav")
data = path.read_bytes()
print(f"{path}: {len(data)} bytes: " + " ".join(f"{x:02x}" for x in data[:32]) + (" ..." if len(data) > 32 else ""))
w = struct.unpack(f">{len(data) // 4}I", data[: len(data) // 4 * 4])

image = bytes(int(x, 16) for x in (ROOT / "src/fpga/core/lib/ir_lib.hex").read_text().split())
import zlib  # noqa: E402
lib_id = zlib.crc32(image)
types = lib.read_library(image)

if len(w) >= 4:
    t, b, s = (w[2] >> 16) & 0xFF, w[2] & 0xFFFF, w[3] & 0xFFFF
    ok = w[0] == 0x49525331 and w[1] == lib_id
    print(f"magic {'ok' if w[0] == 0x49525331 else 'BAD'}, library id {'ok' if w[1] == lib_id else 'BAD'}"
          f" (file {w[1]:08x}, this build {lib_id:08x})")
    try:
        tname, brands = types[t]
        bname, sets = brands[b]
        print(f"device {t}/{b}/{s}: {tname} / {bname} / {sets[s][0]}{'' if ok else '  (ignored: invalid)'}")
    except IndexError:
        print(f"device {t}/{b}/{s}: out of range")
if len(w) >= 8:
    print(f"diagnostics: reset exits {w[4] >> 24}, reset enters {(w[4] >> 16) & 0xFF}, "
          f"all-completes {(w[4] >> 8) & 0xFF}, boots {w[4] & 0xFF}")
    print(f"             slot writes {w[5] >> 16} (while running {w[5] & 0xFFFF}), reads before this one {w[7] >> 16}")
    print(f"             at the last boot: word 2 {w[6]:08x}, valid {(w[7] >> 2) & 1}, fresh {(w[7] >> 1) & 1}; booted {w[7] & 1}")

print()
for line in rxcap.report(rxcap.parse(data), types):
    print(line)
