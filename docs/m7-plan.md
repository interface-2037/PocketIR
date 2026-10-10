# M7 plan: built-in code library, device menu, runtime labels

Decided 2026-10-10: the runtime labels (old M8) merge into M7; the menu opens
with **Select + Start together**. Test device: **Samsung The Frame TV**
(Samsung32, device address 7) next to the Sony STR-DH790 (SIRC).

## Goal
Pick any device from a library built into the core, see its name and button
labels on screen, and control it. The choice is remembered across power-offs.

## 1. Library builder (PC, `tools/ir/library.py`)
- Source: Flipper-IRDB curated AV folders (CC0): TVs, receivers, soundbars,
  projectors, streaming, cable boxes, Blu-ray/DVD, …
- Map each file's signals to the 12 functions (POWER, VOL+, VOL-, MUTE, UP,
  DOWN, LEFT, RIGHT, OK, BACK, MENU, INPUT) with the measured name rules.
  Keep the database's own label text per button (e.g. SOURCE, HOME, RETURN),
  shortened to ≤ 9 characters for the screen.
- Protocol names → engine ids (`ircompile.PROTO_ORDER`). Kaseikyo is stored
  packed (`Protocol.pack`). Signals in unsupported protocols or raw form are
  dropped (RAW comes with learning, M9).
- Deduplicate identical code sets; group by device type → brand → code sets
  (each listing the remote/model names it covers).
- Add the hand-verified **Sony STR-DH790** set (with its by-position grip
  mapping and AMP MENU/BACK names), so nothing regresses.
- Output: `src/fpga/core/lib/ir_lib.hex` + `ir_lib.vh`, a coverage report, and
  `docs/codes-format.md` (the binary format).

## 2. Library format (on-chip ROM, ~80–120 KB)
- Type table → brand table (name, list of code sets) → code set:
  {default protocol, address, 12-bit "present" mask, per button: command or an
  override {protocol, address, command}, label index}.
- Shared string table (brand names, labels), deduplicated.
- A small reader in the clk_74a domain fetches what the menu or a button press
  needs. ROM latency doesn't matter at these speeds.

## 3. Button behaviour changes (`ir_remote.v`)
- Codes come from the library entry of the **current device**, not
  `ir_code_rom.v` (retired).
- Start / Select wait ~150 ms for the other one: both → open the menu (send
  nothing); one alone → send Power / Mute as now (held → repeats).
- Functions a device lacks do nothing (and are dimmed on screen).

## 4. Menu (`menu.v`, clk_74a domain)
- Screens: **type → brand → code set**. D-pad moves, Enter (Y) selects,
  BACK (X) goes up a level, Select + Start closes.
- On the code-set screen, a **TEST** action sends that set's POWER so you can
  find the one your device answers to (classic universal-remote setup);
  Enter keeps it.
- Long lists scroll (brands sorted A–Z).

## 5. Screen (`ui/`)
- **Design first** (design-review rule): render mockups of the main screen and
  the three menu screens in `tools/ui/`, critique, and get interface2037's OK before
  any RTL.
- Background picture: the Pocket layout **without** text.
- Text layer: a pre-rendered Inter bitmap font (crisp at 400×360, ~10 px and
  ~15 px sizes, a few grey levels for smooth edges) drawn from a small
  character buffer that the menu / current device fills. Highlights stay as now.
- Main screen: device name + the 12 labels from the library; missing
  functions dimmed.

## 6. Remembering the device
- A nonvolatile data slot in `data.json` holds the current device id; the core
  reads it at start-up and writes it when the choice changes (APF saves it
  back to the SD card on exit). Details to confirm from Analogue's docs.

## Verification
- Python: builder unit checks (Samsung TV set = Samsung32 addr 7 with the
  known power/volume commands; Sony set equals today's `ir_code_rom.v`), size
  and coverage report.
- Simulation: library reader + menu navigation testbench; `tb_ir_remote` for
  the Start/Select chord timing; `tb_ui_video` extended for the text layer
  (frames compared with the Python mockup pixel for pixel).
- Hardware:
  1. Sony still works, labels unchanged.
  2. Open the menu, pick TV → Samsung, find the set that powers The Frame,
     select it: name and labels change, volume/mute/menu/source work.
  3. Power-cycle the Pocket: Samsung is still selected.

## Steps
1. Library builder + format doc + coverage report (Python only).
2. Screen mockups (main + menu) → interface2037's review.
3. Text layer + font in `ui_video` (sim against mockups).
4. Library ROM + reader; `ir_remote` reads the current device; chord logic.
5. Menu controller + screens.
6. Nonvolatile device memory.
7. Build, hardware test with The Frame.

## Risks
- Function-name mapping quality varies across the database (coverage report).
- The Frame's power key toggles Art Mode/TV; full off may need a long press.
- Memory: picture (~40 KB) + fonts + library must stay well under 385 KB.
