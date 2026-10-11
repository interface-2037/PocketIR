# M9 plan: identify a remote, recent devices

## Decisions (interface2037, 2026-10-11)
- **Learning identifies, it doesn't record.** A button captured from a remote
  is matched against the built-in library. The screen lists the matching
  devices and the user picks one to switch to. No raw codes, no replay.
- **Learning starts from a menu item.**
- **Recent devices:** the last 20 devices used, kept in the save file.

## Step 1 result (v0.10.0, hardware, 2026-10-11)
Raw capture of a Sony STR-DH790 remote (`tools/ir/fixtures/rx_v0.10.0_sony_power.sav`):
- `port_ir_rx` idles **high**, is active **low**, and passes the **raw carrier** (40.6 kHz).
- It only shows the **start of each mark**: 2–10 carrier pulses (~50–300 µs),
  then nothing. Mark lengths are lost; mark starts are accurate to ~±30 µs.
- Range: about 3 in.
- Matching start-to-start intervals against every library code
  (`tools/ir/rxcap.py`, `match_library`) found exactly SIRC15 48/21 (POWER),
  i.e. the STR-DH790 and 9 other Sony sets sharing that code, in 0.1 s of Python.

## Design
1. **Receiver front end** (`ir/ir_rx_marks.v`). The receiver is powered only
   while the learn screen is open. A mark start = an active edge after ≥ 250 µs
   of idle. Start-to-start intervals in 4 µs ticks (16 bits, saturating) go into
   a 256-entry buffer; a burst ends after 200 ms of silence. `ir_rx_cap` keeps
   recording raw edges into the save file during learning, so a failed match
   can be diagnosed on the PC.
2. **Matcher** (`lib/ir_match.v`). Walks every menu entry and code in the
   library ROM. For each code, a microcode walker (`ir/ir_synth.v`: the same
   protocol microcode as `ir_engine`, but no real-time output) produces the
   mark-start intervals of the code's first frame, and they're compared with
   the capture at every frame start. Same rules as `rxcap.py`: tolerance
   max(160 µs, 1/16 of the interval); the frame must be followed by a ≥ 4 ms gap
   or the end of the capture. Biphase protocols are tried with toggle 0 and 1.
   - Result: a bitmap of matching menu entries (880). Another button press on the
     remote ANDs into it (narrows the list).
   - `ir_synth` is a separate module, not a refactor of the hardware-proven
     `ir_engine`; a testbench checks it against the reference encoder.
   - Estimated scan time: well under 100 ms.
   - Outcomes: matches → list; a frame-like burst (≥ 8 marks) with no match →
     "NO MATCH IN THE LIBRARY"; anything shorter → "COULDN'T READ THAT".
3. **Recent list** (`lib/recent.v`). 20 × {type, brand, set}. The current
   device moves to the front whenever it changes (menu, learn, recent list, boot).
   Stored in the save file and cleared when the library id changes.
4. **Menu.** Level 0 gets RECENT DEVICES and LEARN FROM REMOTE above the types,
   with a divider line. New screens: recent list, learn (listening + result),
   matches list (POWER TEST, ENTER USE, BACK RETRY). Reference model in
   `tools/ui/ui_menu.py`, checked by `tb_remote`; `dev_ctrl` draws the pages.
5. **Save file:** device block 0x0000, receiver capture 0x0020, recent list
   0x8040 (header + 20 words); size 0x80A0.

Mockups: `docs/ui/m9_*.png` (`tools/ui/ui_m9.py`).

## Steps
1. Done: v0.10.0 raw capture, receiver measured, Python matcher proven on it.
2. Mockups and interface2037's review. **← now**
3. `ir_rx_marks` + `ir_synth` + `ir_match`, simulated against `rxcap.py`.
4. `recent.v` + save layout, simulated.
5. Menu model, then `menu.v` / `dev_ctrl.v` / `ui_video` divider, simulated
   against the model. Starts after the `menu.v` timing fix (separate task) lands.
6. Build v0.11.0. Hardware test: identify the Sony and Samsung remotes, pick
   the match, check the recent list survives a restart.

## Risks
- Range is ~3 in, so the instructions say "1 to 3 inches".
- SIRC's last bit can't be measured (no stop mark); both variants can match,
  but the library usually has only one.
- Remotes using a protocol we don't have (12 supported) can't be identified.
