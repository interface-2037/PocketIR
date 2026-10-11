# IR code library format (`IRL1`)

Built by `tools/ir/library.py` into `src/fpga/core/lib/ir_lib.hex` (one byte
per line), read on the Pocket from on-chip ROM. `library.read_library()` is
the reference reader; `tools/ir/test_library.py` checks the committed ROM.

All integers are little-endian. Offsets are byte offsets from the start of
the ROM. Strings are uppercase ASCII, zero-terminated, stored once.

## Header (32 bytes, offset 0)
| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `IRL1` |
| 4 | 2 | number of device types |
| 6 | 2 | number of labels |
| 8 | 4 | offset of the type table |
| 12 | 4 | offset of the label table |
| 16 | 4 | total ROM size in bytes |
| 20 | 4 | first 8 hex digits of the Flipper-IRDB commit it was built from |
| 24 | 4 | offset of the constant-string table (one u32 string offset per entry of `library.CONSTS`: `REMOTE `, `VOLUME DOWN`, `VOLUME UP`, `NAVIGATE`, `MENU`, `INPUT`, `OK`, `BACK`, `POWER`, `MUTE`, ` `, then the menu strings; see `library.CONSTS`; append only) |
| 28 | 4 | reserved (0) |

## Type table: one 12-byte entry per device type (menu order)
| Size | Field |
|---|---|
| 4 | offset of the type name string (e.g. `TV`) |
| 4 | offset of this type's brand table |
| 2 | number of brands |
| 2 | total code sets of this type (all brands; the menu shows "332 SETS") |

## Brand table: one 12-byte entry per brand (A–Z)
| Size | Field |
|---|---|
| 4 | offset of the brand name string |
| 4 | offset of the brand's code-set list |
| 2 | number of code sets |
| 2 | reserved |

## Code-set list: one 8-byte entry per menu item (most complete set first)
| Size | Field |
|---|---|
| 4 | offset of the code set |
| 2 | offset of the display name (remote/model, e.g. `BN59-01180A`) |
| 2 | number of other remotes that share this code set (menu shows "& N MORE") |

## Label table: one 4-byte string offset per label id
Labels are the names shown on screen (`POWER`, `VOL +`, `SOURCE`, `HOME`,
`AMP MENU`, …), at most 9 characters.

## Code set (4-byte aligned; shared by every menu item that uses it)
| Size | Field |
|---|---|
| 1 | default protocol id (`ircompile.PROTO_ORDER`) |
| 1 | number of functions present |
| 2 | present mask: bit i = function i |
| 4 | default D word (address, as `ir_engine.v` sends it) |

Then, for each present function in order, 4 bytes:

| Size | Field |
|---|---|
| 2 | F word (command) low 16 bits |
| 1 | label id |
| 1 | flags: bit 0 = override follows |

If the override flag is set, 12 more bytes follow: protocol id (1), 3 reserved,
D word (4), F word (4). They replace the defaults for this function.

Functions (bit order): 0 POWER, 1 VOL_UP, 2 VOL_DOWN, 3 MUTE, 4 UP, 5 DOWN,
6 LEFT, 7 RIGHT, 8 OK, 9 BACK, 10 MENU, 11 INPUT. The 12th slot is the
"extra" key: INPUT/SOURCE for most devices, OPTIONS on the verified Sony set.

D and F are the engine's packed fields (`irproto.Protocol.pack`); for every
protocol except Kaseikyo they equal Flipper's address and command.
