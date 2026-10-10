# M6 plan: microcoded IR protocol engine

## Goal
Replace the Sony-only `ir_sirc_tx.v` with one engine that can send any supported
protocol from **parameters** (protocol id, address, command, toggle). That is
what lets M7 fit a whole code library (~80–120 KB) inside the FPGA.

## Architecture

```
ir_code_rom (per button)            protocol microcode ROM (from PC compiler)
  {proto_id, address, command} ──►  ir_engine.v ──► envelope ──► ir_carrier ──► port_ir_tx
                                       ▲  carrier kHz/duty also set by the microcode
                     key held / tap ───┘  (repeat rules live in the microcode too)
```

### Engine state
- **Timing:** `unit_us` (protocol time unit) and a frame timer (time since frame start).
- **Bit encoding:** how a 0 and a 1 are sent, either pulse-distance/width (`mark0, space0, mark1, space1`) or bi-phase/Manchester (RC5/RC6, with polarity).
- **Fields:** D (address, up to 32 bits), F (command, up to 32 bits), T (toggle, flips once per press), and an XOR accumulator for checksums (Kaseikyo).
- **Frame counter:** compared with a minimum frame count (SIRC needs at least 3).

### Microcode (16-bit words, sketch)
| Op | Meaning |
|---|---|
| `CARRIER k` | carrier table entry (36 / 38 / 40 / 56 kHz, duty) |
| `UNIT n` | time unit in µs |
| `MARK n` / `SPACE n` | carrier on / off for n units |
| `BITS kind, m0, s0, m1, s1` | set the bit encoding |
| `SEND src, lsb, count, flags` | send `count` bits of D/F/T/const/XOR, LSB- or MSB-first, optionally inverted |
| `XOR src, lsb, count` | accumulate a checksum |
| `GAPTO n` | wait until n units after frame start (fixed frame period) |
| `REPEAT` | marks the start of the repeat section |
| `MINFRAMES n` | send at least n frames per tap |
| `END` | if the key is held, or fewer than the minimum frames have been sent, go to `REPEAT`; otherwise stop |
| `RAW ptr, len` | play a stored timing list (RAW protocol, learned codes) |

### PC side (`tools/ir/`)
- `protocols.py`: protocol definitions in a small Python DSL that mirrors the ops above. Covers SIRC12/15/20, NEC, NECext, Samsung32, RC5, RC5X, RC6, Kaseikyo, RCA and Pioneer.
- `irref.py`: a reference encoder that turns a definition plus parameters into a mark/space list. This is the test oracle.
- `ircompile.py`: compiles definitions into `src/fpga/core/ir/ir_proto.hex` plus an entry table (`ir_proto.vh`).
- Parameter conventions (how Flipper's `address`/`command` bytes map to D/F) are checked against Flipper's published protocol documentation. We only read it to match conventions and don't copy its code.

## Verification
1. **Reference vs. known-good:** the Python SIRC output must match the old `ir_sirc_tx` envelopes exactly (that encoder is proven on hardware: 0x540C, 0xA81). Each other protocol is checked against published timing examples.
2. **Engine vs. reference:** `sim/tb_ir_engine.v` runs every protocol with random parameters, plus tap and hold, and the decoded mark/space durations must match the Python vectors exactly.
3. **Regression:** `tb_ir_remote.v` (all 12 Sony buttons, hold, button switching) must pass unchanged with the engine swapped in.
4. **Hardware:** v0.5.0. All 12 STR-DH790 buttons work as before, with the same range.

## Steps
1. DSL + reference encoder for SIRC, and prove it matches `ir_sirc_tx`.
2. Compiler + `ir_engine.v` + `tb_ir_engine` for SIRC.
3. Swap the engine into `ir_remote.v` (the code ROM becomes {proto, addr, cmd}). `tb_ir_remote` passes. Build v0.5.0 for a hardware check.
4. Add NEC/NECext and Samsung32, then RC5/RC5X/RC6, then Kaseikyo/RCA/Pioneer/RAW, each with test vectors.
5. Retire `ir_sirc_tx.v`, `ir_blink.v` and `ir_diag.v` (M1–M3 scaffolding) once nothing uses them.

## Risks
- **Protocol details:** Kaseikyo's vendor and checksum bytes, RC6's double-width trailer bit, and RC5X's extra field. Mitigation: a test vector per protocol and per edge case.
- **Database conventions:** how Flipper stores its parameters may differ from my field definitions. Mitigation: decode a few real devices on hardware early in M7.
- **Engine timing at 74.25 MHz:** fine. One instruction every few µs is ample, since the shortest pulse is about 400 µs.
