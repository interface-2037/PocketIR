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
| `port_ir_rx_disable` | output | Set to `1` to power down the receiver. Keep it `1` until the learning feature exists. |
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
- **Toolchain:** Intel Quartus Prime Lite with Cyclone V device support (free). Use the Quartus version the core template README specifies.
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

### Suggested layout for new code

```
src/fpga/core/
  core_top.v            # existing; wire new modules in here
  ir/
    ir_carrier.v        # carrier generator (clock-enable based)
    ir_nec_tx.v         # NEC encoder state machine
    ir_tx_mux.v         # carrier AND envelope -> port_ir_tx
    ir_code_rom.v       # hard-coded codes (early milestones)
  ui/
    font_rom.v
    text_overlay.v
  input/
    button_edge.v       # debounce/edge detect on cont1_key
sim/
  tb_ir_carrier.v
  tb_ir_nec_tx.v
  ...
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

### M5 implementation notes (v0.2.0)
- Video is now **640×480 @ 60 Hz**. The PLL outputs 0/1 were retuned to 24.576 MHz, with 800×512 total timing. `video.json` is 640×480, rotation 180.
- Picture pipeline: edit `tools/ui/ui_hires.py` (the design), then run `python tools/ui/ui_rom.py`. That regenerates `src/fpga/core/ui/ui_rle.hex`, `ui_palette.hex` and `ui_rle.vh` (RLE ROM + 256-colour palette + per-pixel highlight regions), plus `build/ui_expected/` for `sim/tb_ui_video.v`. Rebuild afterwards.
- Highlight regions: key bit k → k+1 (k ≤ 9), Select 11, Start 12, TX lamp 13 (see `core_top.v` and `ui_rom.py`; keep them in sync with `ir_code_rom.v`).
- Design review loop: render mockups and critique them before touching RTL (interface2037's request).

### M6 — Multiple devices and protocols
- Device selection menu (e.g. hold a button combo to open it).
- Add protocols, each a separate encoder module behind a common interface:
  - Samsung (38 kHz, NEC-like with 4.5 ms/4.5 ms leader)
  - Sony SIRC (40 kHz, 12/15/20-bit)
  - Philips RC5 (36 kHz, Manchester) and RC6
- Carrier frequency comes from the selected protocol.

### M7 — Code database from SD card
- Define a simple binary file format for device/code tables (document it in `docs/codes-format.md`).
- Load it through an openFPGA data slot into on-chip memory or PSRAM.
- Provide a small script (Python) that converts a human-readable list into that binary file.

### M8 (stretch) — Learning mode
- Enable the receiver, capture `port_ir_rx` timings, and store/replay raw codes.
- First investigate what `port_ir_rx` actually outputs (see Risks).

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
