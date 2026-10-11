# M9 plan: learning mode

## Goal
Point any remote at the Pocket, press a button, and the Pocket stores the
signal and can send it again from one of its own buttons. Learned codes are
kept on the SD card.

## What we don't know yet (decides the design)
`port_ir_rx` reacts to a TV remote (v0.0.5), but nothing else is known:

1. **Polarity:** idle high or idle low?
2. **Raw or demodulated:** does it pulse at the carrier (~38 kHz, like the
   Game Boy Color's unfiltered receiver) or give a clean envelope (like a
   TSOP-style receiver)? If raw, we can also learn the carrier frequency.
3. **Fidelity:** how much are marks stretched or shrunk, and is there
   chatter on edges (the FPGA input has no Schmitt trigger)?
4. **Noise:** does room light (lamps, sunlight) produce edges?
5. **Range:** how close the remote has to be.

So step 1 is a measurement, built into the normal core.

## Step 1 (v0.10.0): raw capture into the save file
- `ir/ir_rx_cap.v` records every edge of `port_ir_rx` at clock resolution
  (13.5 ns), with no filtering, as `{level after edge, clocks since the
  previous edge}`.
- A **burst** starts at the first edge and ends after 200 ms without one (or
  3 s, so continuous noise can't block it). A burst with ≥ 20 edges is kept.
- Two buffers of 4096 edges each. A new burst goes into the older buffer, so
  the latest kept burst is never overwritten by noise.
- The buffers and a small header go into the save file after the device
  block. APF writes the file to the SD card on Quit / power-off, so the
  capture reaches the PC with no new hardware.
- While a burst is being recorded, the TX lamp lights (diagnostic only).
- Receiver is **on** in this build (`port_ir_rx_disable = 0`). Later steps
  turn it on only in learning mode.
- PC side: `tools/ir/read_save.py` decodes the capture: idle level, raw or
  demodulated, carrier frequency and duty, mark/space list, and which
  library code (protocol, address, command) the timing matches.

Save file (big-endian words; `data.json` size 0x8040):

| Offset | Words | Content |
|---|---|---|
| 0x0000 | 8 | device save (`lib/dev_save.v`, unchanged) |
| 0x0020 | 8 | capture header (`ir/ir_rx_cap.v`) |
| 0x0040 | 4096 | capture buffer 0 |
| 0x4040 | 4096 | capture buffer 1 |

Hardware test: point the Sony DH790 and Samsung Frame remotes at the
Pocket, tap one known button each (the lamp should flash), then Quit and copy
`Saves/irremote/interface2037.IRRemote/irremote.sav` to the PC.

## Later steps (planned after step 1's data is in)
2. **Receiver front end** (`ir_rx.v`): deglitch, envelope (merge carrier
   pulses if raw), carrier-frequency measurement. Fixed by the step-1 data.
3. **RAW protocol in `ir_engine`:** play a stored list of mark/space
   durations at a given carrier. Simulated against the reference encoder.
4. **Learned-code store:** a "LEARNED" device in the menu with the 12
   functions; each holds one RAW code (mark/space list, carrier, repeat gap).
   Kept in the save file in place of the step-1 capture buffers.
5. **Learn UI:** mockups first (design-review rule), then RTL. Pick a
   function, press the remote's button, see "GOT IT / TRY AGAIN", test-send.
6. Hardware test: learn a remote that isn't in the library, replay it.

## Open decisions for interface2037 (needed by step 4/5, not step 1)
- How learning is entered (a menu item, or a chord).
- One LEARNED device, or several.
- Should a learned code replace a library function on the current device, or
  only live in the LEARNED device?

## Risks
- The receiver may be too slow or too insensitive to capture a remote at
  usable distance. Step 1 measures it.
- A raw receiver picks up ambient light; the front end must reject it.
- Save-file size: 32 KB is far more than needed later (12 RAW codes ≈ 3 KB).
  Assumed fine, because APF already grew the file from 16 to 32 bytes when
  the core asked.
