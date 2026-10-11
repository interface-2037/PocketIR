# IR Remote for Analogue Pocket

An openFPGA core that turns the Analogue Pocket's built-in infrared LED into a universal TV/AV remote.

- **Built-in code library:** about 1,000 TVs, soundbars, receivers and projectors from [Flipper-IRDB](https://github.com/Lucaslhm/Flipper-IRDB) (CC0). Pick brand → device type → code set from the menu, and test each set with POWER.
- **Learn from remote:** point your original remote at the Pocket and press a button. The core lists the library devices that match.
- **Recent devices:** the last 20 devices you used, one menu away.
- **Protocols:** NEC, NECext, Samsung32, Sony SIRC 12/15/20, RC5, RC5X, RC6, Kaseikyo, RCA, Pioneer.
- The selected device is remembered across restarts.

## Range: hold it close

The Pocket's IR LED was designed for short-range Game Boy link features. Expect it to work from **a few inches to about 20 cm (8 in)** from the TV or receiver's IR window. This is a hardware limit, not a bug.

## How to hold it

IR leaves through the **power LED on the bottom edge**, so hold the Pocket **upside down** (rotated 180°) and point the bottom edge at the device. The picture is rotated to read correctly in this grip.

| Button (printed label) | Function |
|---|---|
| Start | Power |
| Select | Mute |
| L | Volume + |
| R | Volume − |
| D-pad | Up / Down / Left / Right (as seen in the upside-down grip) |
| Y | OK |
| X | Back |
| B | Menu |
| A | Input |
| **Start + Select** together | Open the device menu |

Holding a button repeats it. Labels on screen change with the selected device, and functions a device lacks are dimmed.

## Install

1. Download the latest `interface2037.IRRemote_*.zip` from [Releases](../../releases).
2. Unzip it and copy the `Cores` and `Platforms` folders to the root of your Pocket's SD card (merge with the existing folders).
3. On the Pocket, open **openFPGA → IR Remote**.

Needs Pocket firmware 1.1 or later.

## Building from source

- Quartus Prime Lite 25.1 (Cyclone V): `tools\build.ps1`
- Package for the SD card: `python tools/package_core.py`
- Simulation (Icarus Verilog): `sim\run.ps1`

See [CLAUDE.md](CLAUDE.md) for the design notes and milestone history.

## Credits and license

- Based on the [openFPGA core template](https://github.com/open-fpga/core-template) by Analogue.
- IR codes from [Flipper-IRDB](https://github.com/Lucaslhm/Flipper-IRDB) (CC0 1.0, public domain).
- This core is licensed under the [GNU GPL v3.0](LICENSE).

## Legal

Analogue's Development program was created to further video game hardware preservation with FPGA technology. Analogue Developers have access to Analogue Pocket I/O's so Developers can utilize cartridge adapters or interface with other pieces of original or bespoke hardware to support legacy media. Analogue does not support or endorse the unauthorized use or distribution of material protected by copyright or other intellectual property rights.
