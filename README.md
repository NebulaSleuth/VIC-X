# VIC-X

VIC-X (working name) is a graphics and memory extension for FPGA C64s
(Ultimate 64 Elite II, Commodore 64 Ultimate, 64C Ultimate): a 256-colour
palette, two tile/bitmap layers, a 128-sprite engine, 128 KB of VRAM, 16 MB
of XRAM shared with the REU, and a DMA/blitter. A stock program sees no
difference until it unlocks VIC-X.

The spec lives in the Claude Docs document "VIC-X: Graphics and Memory
Extension Spec". This repository holds everything that is not emulator code:

| Path               | Contents |
|--------------------|----------|
| `include/vicx.inc` | ca65 register names, bits, step codes and macros |
| `tests/`           | conformance test programs (ca65) and their runner |
| `tools/`           | developer tools (PNG to tiles/palette converter, later) |
| `hdl/`             | the VHDL block (later) |

The reference model is a VICE fork, `vice-vicx` (branch `vicx`, from VICE
3.10.0), kept next to this repository at `D:\Repos\vice-vicx`.

## Status

Spec steps 1 and 2 are implemented in the fork and covered by the tests.

Step 1:

- unlock: `$56 $58 $21` written consecutively to `$D06F`; `$00` relocks;
  every reset locks; while locked `$D040-$D06F` are stock VIC-II mirrors
- ID `$D040/$D041` = `$56 $58`, VERSION `$D042`, capabilities `$D043-$D047`,
  CTRL `$D048`, IRQ_EN/IRQ_STAT/FRAME `$D049-$D04B`
- VRAM ports 0 and 1 with all 16 step codes, reaching 128 KB of VRAM and the
  register space `$20000-$209FF`
- palette: 256 x 4 bytes at `$20000`; entries 0-15 reset to the C64 palette
- CTRL bit 3: VIC-II colours shown through palette entries 0-15
- snapshot support; `-vicx` / `+vicx` command-line switch (resource `VICXEnable`)

Step 2:

- layer 0 as an 8-bit 320x200 bitmap from VRAM (CTRL bit 0): base, line
  stride and double-width pixels from the layer setup at `$20800`
- the layer fills the VIC-II display window and sits behind the VIC-II; it
  shows through pixels drawn in the `$D021` colour when CTRL bit 4 is set,
  and the border, sprites and other VIC-II pixels stay in front
- bitmap colour 0 is transparent (the `$D021` colour shows through)
- CTRL and the layer setup are latched at the start of each raster line, so
  raster splits work
- CAP_FEAT reports bit 1 (bitmap)

Not yet: 4-bit bitmaps, tiles, layer 1, the layer order register, scrolling
(steps 3 on). Palette changes still take effect per frame, not mid-frame.

Next: spec step 3, tile layers, scrolling and the mixing order.

## Building the fork

In MSYS2 UCRT64 (from cmd.exe, `set MSYSTEM=UCRT64` and `set CHERE_INVOKING=1`):

    C:\msys64\usr\bin\bash.exe -lc "/d/Repos/vice-vicx/vicx-build.sh headless"
    C:\msys64\usr\bin\bash.exe -lc "/d/Repos/vice-vicx/vicx-build.sh gtk"

`headless` builds the binary the tests use (`vice/build-headless/src/x64sc.exe`);
`gtk` builds the normal GTK3 emulator (`vice/build-ucrt64/src/x64sc.exe`). Add
`configure` as a second argument after changing a `Makefile.am`.

Run the GTK build with `-vicx` to enable VIC-X (it then still starts locked).

## Running the tests

Needs Python 3, cc65 (`ca65`, `ld65`) and the headless fork build:

    cd tests
    python run-tests.py            # all tests
    python run-tests.py t05 t06    # tests whose name contains t05 or t06
    python run-tests.py -v         # show VICE's output

Each `tNN_*.s` is one test. It writes its result to VICE's debug cartridge
(`$D7FF`), and VICE exits with that code: 0 = pass, any other value is the
number of the failed check in that file. Header comments say how to run it
(`; RUN:` lines, one per configuration), and can ask for pixel checks on the
exit screenshot (`; PIXEL:`) or a monitor command file (`; MON:`). Tool paths
default to this machine's layout; see `python run-tests.py --help` for the
options and environment variables.

| Test | What it checks |
|------|----------------|
| `t01_locked`       | locked/disabled: mirrors behave as stock, broken unlock sequences fail |
| `t02_stock_unlock` | VIC-X disabled: the full unlock sequence does nothing |
| `t03_unlock`       | unlock, ID, relock, restart rules, no write-through while unlocked |
| `t04_id_caps`      | VERSION, capability registers, CTRL, IRQ_EN, reserved, FRAME |
| `t05_ports`        | port address registers, all step codes both ways, 18-bit wrap, data |
| `t06_reset`        | a machine reset (via the monitor) locks and restores defaults |
| `t07_palette`      | palette reset values and read/write of all 256 entries |
| `t08_remap`        | CTRL bit 3 remaps VIC-II colours (screenshot pixels); stock without VIC-X |
| `t09_snapshot`     | VIC-X state survives a snapshot save and load |
| `t10_bitmap`       | 8-bit bitmap layer: alignment with the display window, VIC-II text in front (8565 and 6569); hidden without VIC-X |
| `t11_split`        | CTRL and layer base changed mid-frame take effect from the next raster line |
| `t12_front`        | border (38 columns), sprites in front; `$D021` changes keep the background transparent |
| `t13_stride`       | bitmap base, stride 0 and double-width pixels |
| `t14_transparent`  | bitmap colour 0 is transparent and shows the VIC-II background |

### Stock compatibility

`stock-compat.py` runs self-checking VIC-II programs from VICE's own
testprogs in an unmodified x64sc 3.10, in the fork with `+vicx`, and in the
fork with `-vicx` (locked), and requires the same exit code and
byte-identical screenshots:

    svn export https://svn.code.sf.net/p/vice-emu/code/testprogs/VICII <dir>/VICII
    python stock-compat.py --testprogs <dir> --stock <unmodified headless x64sc.exe>

The list is in `stock-compat.txt`.
