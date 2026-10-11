# Pocket IR Remote — Project Brief

An openFPGA core for the Analogue Pocket that turns the Pocket's built-in infrared LED into a universal TV/AV remote control.

This file is the handoff brief for Claude Code. Put it in the root of the repo (cloned from the openFPGA core template) so it's loaded automatically at the start of every session.

---

## 1. Goal

Build an openFPGA core that:

1. Drives the Pocket's IR transmitter LED with modulated remote-control signals (38 kHz carrier to start).
2. Encodes standard IR protocols, starting with NEC.
3. Maps the Pocket's buttons to remote functions (power, volume, channel, mute, input, d-pad, OK).
4. Shows a simple on-screen UI to pick a device and see which button does what.
5. Later: loads a code database from the SD card, supports more protocols, and possibly "learns" codes using the IR receiver.

---

## 2. Verified hardware facts (from the official core template)

These come from `src/fpga/core/core_top.v` in `open-fpga/core-template`:

| Signal | Direction | Notes |
|---|---|---|
| `port_ir_tx` | output | IR transmitter LED. **Active-high** (Analogue external-hardware docs). The LED runs near its max rated current: **never drive it with DC**, only PWM pulses with duty < 100% (always gate through `ir_carrier.v`). It shares the power LED's lightpipe, so IR comes out where the power LED is (**verified on hardware v0.0.5**: 38 kHz carrier gated at 1 Hz visibly pulses the power LED on a phone camera; the dark window next to it shows nothing). |
| `port_ir_rx` | input | IR receiver circuit output. **Verified on hardware (v0.0.5):** reacts to a TV remote when `port_ir_rx_disable = 0`. Raw vs. demodulated and polarity still **unknown**. Does *not* pick up the Pocket's own LED (no self-echo), so it can't be used as a TX self-test. |
| `port_ir_rx_disable` | output | Set to `1` to power down the receiver. Keep it `1` except while learning. (The v0.10.0 diagnostic build keeps it `0` all the time, M9 step 1.) |
| `clk_74a`, `clk_74b` | input | 74.25 MHz main clocks. Treat as asynchronous to each other. |
| `cont1_key[31:0]` | input | Button bitmap: [0] up, [1] down, [2] left, [3] right, [4] A, [5] B, [6] X, [7] Y, [8] L1, [9] R1, [14] select, [15] start. Synchronous to `clk_74a`. |
| `video_*` | output | Template generates 320×240 @ 60 Hz with a ~12.288 MHz pixel clock from a PLL. |

Analogue's developer docs state that cores have full access to the hardware and I/O wired to the main FPGA, and that the Pocket contains an IR transmitter LED and receiver circuit. The template's own pin list confirms the IR TX line is exposed to user cores.

---

## 3. Known risks and open questions

Resolve these early. Each one can change the plan.

1. **Range (biggest risk). Measured at M3 (v0.0.6, 2026-10-09): Sony STR-DH790 power toggle works up to ~7.5 inches (~19 cm)** with SIRC-15 dev 48 cmd 21 at 40 kHz / 33% duty. The SIRC-12 dev 16 fallback does nothing (expected for this model). Original note: ** The Pocket's IR was designed for short-distance Game Boy Color link features. Analogue's manual says distances between IR devices should be very short. A TV may only respond from a few inches away. Measure this at Milestone 3 before investing in UI and databases.
2. **TX polarity and drive.** Confirm that `port_ir_tx = 1` lights the LED. Confirm whether the LED can be switched cleanly at 38 kHz with ~33% duty cycle.
3. **RX behavior.** Unknown whether `port_ir_rx` gives the raw signal or a demodulated envelope. Only matters for learning mode.
4. **Power.** Keep the LED off when idle, and keep the receiver disabled unless learning.

---

## 4. Environment

- **OS:** Windows (PowerShell).
- **Toolchain:** Quartus Prime **Lite 25.1** (`C:\altera_lite\25.1std`) with Cyclone V support. Moved from 18.1 on 2026-10-10 after v0.4.1 built with 25.1 was verified on hardware. `tools\build.ps1` picks the version explicitly (default 25.1; `-Quartus <ver|path>` for another) and ignores PATH. Check that `quartus_sh --version` says **Lite Edition**: the Standard edition asks for a license.
- **Simulation:** Icarus Verilog (and optionally GTKWave for waveforms). Every new module gets a testbench before it goes on hardware.
- **Bitstream:** the Pocket loads a bit-reversed RBF (`.rbf_r`). Follow Analogue's "Packaging a Core" docs; agg23's utilities and other open cores include conversion scripts.
- **Loading on hardware:** copy the packaged core to the SD card (Pocket "USB-Link" mode or card reader). JTAG debugging is optional and needs physical access to the connector on the bottom edge plus a USB-Blaster–compatible cable.
- **Seeing IR:** human eyes can't see the LED. A phone camera (often the front camera) shows IR as a purple-white glow. Use this for first tests.

Claude Code cannot load the core onto the Pocket or watch the LED. The human (interface2037) does hardware tests and reports results back.

---

## 5. Repo setup

1. Clone `https://github.com/open-fpga/core-template` as this repo.
2. Clone `https://github.com/agg23/analogue-pocket-utils` next to it as reference (do not vendor the whole thing; copy only what's needed, with attribution).
3. Fill in the core JSON files (`core.json`, `video.json`, `input.json`, `data.json`, etc.) with a placeholder author/name, e.g. `interface2037.IRRemote`.

### Code layout (current)

```
src/fpga/core/
  core_top.v            # template top; wires the modules below
  ir/
    ir_engine.v         # microcoded protocol engine + carrier (M6)
    ir_proto.hex/.vh    # protocol microcode, generated by tools/ir/ircompile.py
    ir_remote.v         # buttons -> function -> engine; chord, repeat / button-switch rules
    ir_rx_cap.v         # M9 step 1: raw receiver edge capture, read out through the save file
  lib/
    ir_lib.hex/.vh      # code library ROM (tools/ir/library.py, format in docs/codes-format.md)
    dev_ctrl.v          # library reader: LOAD device, CODES, menu PAGE text, A-Z JUMP
    menu.v              # device menu navigation (model: tools/ui/ui_menu.py)
    dev_save.v          # current device <-> nonvolatile save slot (data.json slot 0, irremote.sav; file = device block + capture)
  ui/
    ui_video.v          # 400x360 video: RLE picture ROM + palette + highlights + menu background
    ui_text.v           # runtime text layer (32 slots, Inter fonts)
    ui_rle.hex/.vh, ui_palette.hex   # generated by tools/ui/ui_rom.py
    font_*.bin, text_*.hex, ui_text.vh, ui_menu.vh   # tools/ui/ui_text.py, ui_menu.py
tools/
  build.ps1, package_core.py        # Quartus build + SD-card package
  ir/  irproto.py (protocols + reference encoder), ircompile.py, library.py, test_*.py, measure/,
       read_save.py (decode irremote.sav), rxcap.py (receiver capture analysis + protocol decoder)
  ui/  ui_hires.py (design), ui_rom.py (export + video mode), ui_text.py, ui_menu.py (menu model), test_menu.py
sim/
  run.ps1               # runs tools/**/test_*.py, then every tb_*.v
  tb_ir_engine.v, tb_remote.v (menu + library + buttons + save), tb_dev_save.v, tb_ui_video.v, tb_rx_cap.v
```

---

## 6. Milestones

Work **one milestone at a time**. Don't start the next until the human confirms the current one works on hardware.

### M0 — Build the untouched template
- Compile the template as-is, package it, load it on the Pocket.
- **Done when:** the template's gray screen shows on the Pocket.

### M1 — Prove we control the LED
- Blink the LED ~1 Hz from a counter on `clk_74a`, but **as an envelope gating the 38 kHz carrier** (never DC, see section 2). Keep `port_ir_rx_disable = 1`. (M1 and M2 were merged after the DC-drive warning was found.)
- **Done when:** the LED visibly blinks through a phone camera. This confirms polarity.

### M2 — 38 kHz carrier
- `ir_carrier.v`: parameterized carrier generator from 74.25 MHz.
  - Period ≈ 74,250,000 / 38,000 ≈ **1954 cycles**.
  - Duty cycle ~33% (≈ 651 cycles high). Make frequency and duty parameters so 36 kHz and 40 kHz are easy later.
- Gate it with a 1 Hz on/off envelope for testing.
- Testbench checks period and duty cycle.
- **Done when:** simulation passes and the camera shows the LED pulsing.

### M3 — NEC encoder + range test (go/no-go)
- `ir_nec_tx.v`: input `{address[7:0], command[7:0]}` plus a `send` strobe; output an envelope (1 = carrier on).
  - Leader: 9 ms mark, 4.5 ms space.
  - 32 bits, LSB first: address, ~address, command, ~command.
  - Bit 0: 562.5 µs mark + 562.5 µs space. Bit 1: 562.5 µs mark + 1687.5 µs space.
  - Trailing 562.5 µs mark.
  - While held: repeat frame (9 ms mark, 2.25 ms space, 562.5 µs mark) every ~108 ms from the start of the previous frame.
  - Support extended NEC (16-bit address, no inverted address byte) via a parameter or input.
- `port_ir_tx = envelope & carrier`.
- Testbench decodes the output back to address/command and checks timings within tolerance.
- Hard-code one known code for a TV the human owns (human supplies the code; NEC TV codes are widely documented).
- **Done when:** the TV responds. **Measure the maximum working distance and report it.** If range is only inches, stop and decide with the human whether to continue, accept short range, or add an external emitter via the link port.

### Grip and button-layout rule (decided at M4, 2026-10-09)
- The IR leaves through the power LED at the **bottom edge**, so interface2037 holds the Pocket **rotated 180°**: screen toward him, upside down, d-pad under his right thumb, face buttons on the left.
- `video.json` uses `"rotation": 180` so the picture reads correctly in that grip. Draw UI in normal framebuffer coordinates.
- Map the d-pad, face buttons and shoulders **by position in that grip**, not by printed label. Start/Select stay by label.
- Current map (`ir/ir_code_rom.v`): Start power, Select mute, L1 (right) vol+, R1 (left) vol−, d-pad flipped for menu nav, Y Enter, X BACK, B AMP MENU, A Options. Use the DH790 remote's names (**AMP MENU**, **BACK**) in any on-screen legend.

### M4 — Button mapping for one device
- `button_edge.v`: synchronize and edge-detect `cont1_key`.
- Map buttons → codes for one device: e.g. Start = power, L1/R1 = volume, up/down = channel, Select = mute, d-pad + A = navigation/OK, B = back.
- Holding a button sends NEC repeat frames.
- **Done when:** the TV can be operated from the Pocket.

### M5 — On-screen UI
- 8×8 or 8×16 font ROM and a text overlay on the existing 320×240 video timing.
- Screens: device name, button legend, a "sending…" indicator.
- Note: crossing from `clk_74a` (input/IR) to the 12.288 MHz video clock needs proper synchronization.
- **Done when:** the UI shows the current device and button map, and highlights while sending.

### M5 implementation notes: done on hardware at v0.4.1 (2026-10-09)
- Video is **400×360 @ 60 Hz** (v0.4.0, 9.324 MHz, 420×370 total): exactly 4× into the 1600×1440 panel, so it fills the screen with square pixels. `video.json` is 10:9, rotation 180.
- **Hardware finding (pixel-clock limit):** video corrupts above a pixel clock of roughly 25 MHz: striped flat colours, streaks, broken lines. Clean: 9.3 MHz (400×360) and 24.6 MHz (640×480). Corrupted: 29.2 MHz (720×648), and 29.9, 35.9 and 41 MHz (800×720).
  - It isn't the picture: a procedural test pattern with no ROM also corrupted.
  - It isn't the rotation: rotation 0 was worse.
  - It isn't the scaler clock phase: 45°, 90° and 135° gave the same corruption, and 180° went black (branch `test/800x720-pattern`).
  - Analogue documents ~50 MHz, but keep the pixel clock **≤ 25 MHz**. 800×720 (≥ 28 MHz at 47 Hz) is therefore not usable.
- The background must stay flat. A 1-level gradient banded visibly on the panel.
- Picture pipeline: edit `tools/ui/ui_hires.py` (the design), then run `python tools/ui/ui_rom.py [W H]`. It also sets the timing in `ui_rle.vh`, `video.json` and the PLL. That regenerates `src/fpga/core/ui/ui_rle.hex`, `ui_palette.hex` and `ui_rle.vh` (RLE ROM + 256-colour palette + per-pixel highlight regions), plus `build/ui_expected/` for `sim/tb_ui_video.v`. Rebuild afterwards.
- Highlight regions: key bit k → k+1 (k ≤ 9), Select 11, Start 12, TX lamp 13 (see `core_top.v` and `ui_rom.py`; keep them in sync with `ir_code_rom.v`).
- Design review loop: render mockups and critique them before touching RTL (interface2037's request).

### Universal-remote plan (decided 2026-10-10, replaces the original M6–M8)
Goal: the whole code library lives inside the core (on-chip memory), with no SDRAM and no runtime SD loading.

Measured with `tools/ir/measure/measure_*.py` (clone the databases first, then run with `python -I`), 12 functions, deduplicated, stored as parameters:
- **Flipper-IRDB curated AV folders** (CC0 public domain): 1,087 devices, 918 code sets, about **78 KB**. This is the chosen source.
- **IRDB:** about 40 KB more. Its licence requires opening an issue on its repo, including its notice, and supplying units on request, so add it only if interface2037 agrees.
- Flipper's `_Converted_` folder is mostly raw captures, probably includes IRDB, and is not CC0-clean. Leave it out.

Design constraints:
- **12 functions per device:** POWER, VOL_UP, VOL_DOWN, MUTE, UP, DOWN, LEFT, RIGHT, OK, BACK, MENU, INPUT.
- **Codes are parameters, not timings:** protocol id + address + command, with a per-button override when a button uses a different protocol or address. The Sony DH790 needs this: menu keys are at address 176, BACK/OPTIONS are 20-bit at address 272.
- **Memory budget (on-chip ≈ 385 KB):** UI background ~40 KB + fonts ~20 KB + library ~80–120 KB.
- **Video stays at 400×360,** with the pixel clock ≤ 25 MHz (see the M5 notes).

### M6 — Protocol engine (microcoded) + protocol compiler: done (v0.5.1, 2026-10-10)
- `ir/ir_engine.v` turns {protocol id, address, command} into an envelope and carrier from a protocol microcode ROM. One engine covers all protocols.
- `tools/ir/irproto.py` defines the protocols (Mark/Space/Send/GapTo, pulse-code or Manchester bits, repeat frames, min frames). It is also the reference encoder used as the test oracle. `ircompile.py` turns it into microcode; the format is documented there.
- Protocols: SIRC12/15/20, NEC, NECext, Samsung32, RC5, RC5X, RC6, Kaseikyo, RCA, Pioneer. The microcode is 193 words.
- **Conventions:**
  - Timing, field packing, bit order, stop bits, repeat codes and silences follow **Flipper Zero's encoders**, because the library comes from Flipper-IRDB.
  - All times run on a **4 µs tick** (297 clocks at 74.25 MHz).
  - Carrier duty is 50 % everywhere (better range).
  - The toggle bit flips per press and starts at 0.
  - Kaseikyo's checksum bytes are packed on the PC (`Protocol.pack`), so the library must store the **packed** D/F words for Kaseikyo.
  - Protocol ids (`PROTO_ORDER`) are append-only, because they end up in the library.
- Verified:
  - 65 simulated cases across all protocols match the reference cycle for cycle (`tb_ir_engine`).
  - The reference matches published codes: LG `0x20DF10EF`, Samsung `0xE0E040BF`, Philips RC5 `0x300C`.
  - On hardware, all 12 STR-DH790 buttons work through the engine.
  - Only SIRC has been tested on a real device so far. The other protocols get real-world tests in M7.
  - **Samsung32 verified on Samsung The Frame TV** (v0.7.0, 2026-10-10): all 12 functions from the library's Samsung TV set 0 (BN59-01180A).
- Not done: the **RAW** protocol (stored timing lists) moves to M7/M9, where raw library entries and learned codes need it.

### M7 — Built-in code library + device menu
- A PC tool converts Flipper-IRDB (curated AV) into one compact ROM image: brand table, device types, code sets, and overrides.
- On-Pocket menu: brand → device type → code set, so a set can be tried with POWER (classic universal-remote setup).
- The selected device is remembered across sessions (save data slot).
- **Done when:** a second real device is found in the menu and controlled.
- **Status (2026-10-10):**
  - v0.8.0: the menu works on hardware; the Samsung Frame was found and controlled through it.
  - v0.9.2: the chosen device is remembered across Quit / restart and power-off.
  - Implementation:
    - `lib/menu.v` navigates; `lib/dev_ctrl.v` reads the library.
    - `lib/dev_save.v` handles the save slot: 32 bytes = magic, library CRC, device, 4 diagnostic words. `python tools/ir/read_save.py <file>` decodes it.
    - Save-slot facts verified on hardware are in `pocket-learnings.md` (section 4).
  - Runtime labels (old M8) were merged into M7 and are done too.

### M8 — Runtime labels on the fixed background: merged into M7, done
- The background picture keeps the layout and buttons but drops the labels. A text layer draws the device name and the 12 labels at runtime from the library. Missing functions are dimmed.
- **Done when:** labels change with the selected device, with mockups reviewed first (design-review rule).
- **Status:** done.
  - Mockups were approved before the RTL.
  - Labels change with the device on hardware (v0.7.0 Sony / Samsung, v0.8.0 menu choice).
  - Dimmed labels for missing functions pass in simulation but haven't been seen on hardware yet: both tested devices have all 12 functions. To check, pick a code set marked "N KEYS" in the menu.

### M9 — Learning mode
- Enable the receiver and capture `port_ir_rx` mark/space timings. Store them as RAW codes, assign them to buttons, and save them to SD.
- Plan and steps: `docs/m9-plan.md`. Whether the receiver output is raw or demodulated, and its polarity, are still unknown, so step 1 measures them.
- **Step 1 (v0.10.0, built 2026-10-10, not yet tested on hardware):**
  - `ir/ir_rx_cap.v` records every `port_ir_rx` edge (13.5 ns resolution, no filtering) into two 4096-edge buffers.
  - The buffers are appended to `irremote.sav` (file size 0x8040), so APF writes them to the SD card on Quit.
  - The receiver is on all the time in this build, and the TX lamp lights while a burst is being recorded.
  - `python tools/ir/read_save.py <file>` reports the idle level, raw vs demodulated, carrier, mark/space timing, the decoded protocol and code, and the matching library entries.
- **Done when:** a remote the Pocket has never seen can be captured and replayed.

### M10 (optional) — External emitter
- Drive an IR LED through the link port for room-range control. This needs a small hardware add-on.

---

## 7. Working rules for Claude Code

- **Don't modify Analogue's APF framework files** (the `apf/` folder and bridge command handler) unless explicitly asked. All new logic goes in new modules wired into `core_top.v`.
- **Simulate first.** Every module has a testbench in `sim/` that runs with Icarus Verilog and prints PASS/FAIL. Run it before asking the human to test on hardware.
- **Parameters, not magic numbers.** Derive all timings from a `CLK_HZ` parameter (74,250,000).
- **Clock domains:** IR and input logic run on `clk_74a`. Anything crossing into the video clock is synchronized.
- **Keep it buildable.** After each change, the Quartus build must succeed. Report timing warnings.
- **Small steps.** At the end of each milestone, summarize what changed, what to test on hardware, and what result to report back.
- **Ask before large refactors** or before adding new dependencies.

---

## 8. References

- openFPGA developer docs: https://www.analogue.co/developer/docs/overview
- External hardware (IR, link port, cartridge): https://www.analogue.co/developer/docs/external-hardware
- Core template: https://github.com/open-fpga/core-template
- agg23 utilities and wiki: https://github.com/agg23/analogue-pocket-utils
- Analogue Pocket user guide (IR range note): analogue.co support pages

---

## 9. First prompt to give Claude Code

> Read CLAUDE.md. Start with Milestone M0: check the template builds with Quartus on this machine, tell me the exact build and packaging steps, and list anything I need to install. Then prepare M1 (the slow IR blink) but don't move past it until I confirm it works on the Pocket.
