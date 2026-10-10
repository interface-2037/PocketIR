"""Package the core for the Analogue Pocket SD card.

Reads the Quartus .rbf, reverses the bit order of every byte (the Pocket loads
.rbf_r files), and builds the SD-card folder layout under build/sdcard/:

    Cores/<AUTHOR>.<CORE>/   bitstream.rbf_r, *.json, info.txt, icon.bin
    Platforms/<platform>.json
    Platforms/_images/<platform>.bin

Copy the contents of build/sdcard/ to the root of the SD card.

Usage:  python tools/package_core.py [--rbf PATH]
"""

import argparse
import json
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE_JSONS = ["core.json", "audio.json", "data.json", "input.json",
              "interact.json", "variants.json", "video.json"]

# Lookup table: byte -> same byte with bit order reversed.
REVERSE = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rbf", type=Path,
                    default=ROOT / "src/fpga/output_files/ap_core.rbf")
    args = ap.parse_args()

    if not args.rbf.is_file():
        print(f"ERROR: bitstream not found: {args.rbf}  (run the Quartus build first)")
        return 1

    meta = json.loads((ROOT / "core.json").read_text())["core"]["metadata"]
    core_id = f"{meta['author']}.{meta['shortname']}"   # folder must match author.shortname
    platform = meta["platform_ids"][0]

    out = ROOT / "build" / "sdcard"
    if out.exists():
        shutil.rmtree(out)
    core_dir = out / "Cores" / core_id
    img_dir = out / "Platforms" / "_images"
    core_dir.mkdir(parents=True)
    img_dir.mkdir(parents=True)

    (core_dir / "bitstream.rbf_r").write_bytes(args.rbf.read_bytes().translate(REVERSE))
    for name in CORE_JSONS + ["info.txt"]:
        shutil.copy2(ROOT / name, core_dir / name)
    shutil.copy2(ROOT / "dist/icon.bin", core_dir / "icon.bin")
    shutil.copy2(ROOT / f"dist/platforms/{platform}.json", out / "Platforms" / f"{platform}.json")
    shutil.copy2(ROOT / f"dist/platforms/_images/{platform}.bin", img_dir / f"{platform}.bin")

    zip_path = ROOT / "build" / f"{core_id}_{meta['version']}_{meta['date_release']}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(out.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(out))

    print(f"Packaged {core_id} v{meta['version']} from {args.rbf.name}")
    print(f"  SD-card folder: {out}")
    print(f"  Zip:            {zip_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
