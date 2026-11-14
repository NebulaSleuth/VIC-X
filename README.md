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
| `include/vicxlib.inc` | ca65 helper macros: ports, palette, layers, sprites, DMA |
| `tests/`           | conformance test programs (ca65) and their runner |
| `demos/`           | demos from the spec's demo plan (see `demos/README.md`) |
| `tools/`           | developer tools: PNG converter, demo art generator |
| `hdl/`             | the VHDL block (later) |

The reference model is a VICE fork, `vice-vicx` (branch `vicx`, from VICE
3.10.0), kept next to this repository at `D:\Repos\vice-vicx`.

## Status

Spec steps 1 to 5 are implemented in the fork and covered by the tests;
step 6 has its first three demos.

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

Step 3:

- layers 0 and 1, each a tile layer (4- or 8-bit, 8x8 or 16x16 tiles, maps
  of 32-256 tiles each way, flip X/Y, palette banks) or a bitmap (4- or
  8-bit); tile layers scroll with 12-bit scroll X/Y that wrap around the map
- 4-bit pixels use palette entry bank x 16 + n; colour 0 is transparent in
  every mode
- the layer order register at `$20840`: a 2-bit priority per source, higher
  in front, ties in the order VIC-II, layer 0, layer 1; latched per line
- the border stays on top of every order
- CAP_FEAT reports tiles and bitmaps ($03)

Step 4:

- the sprite engine (CTRL bit 2): 128 entries latched each frame, 8-64
  pixels each way, 4- or 8-bit pixels, flips, double width, X/Y in
  display-window pixels wrapping at 1024; lower entries in front; the behind
  bit puts a sprite one step back in the layer order
- per-line limits of 32 sprites and 640 pixels; the overflow flag at `$20841`
- collisions by group mask into the list at `$20900`, IRQ_STAT bit 0
- IRQ_STAT bit 2 at the start of each frame; IRQ_STAT AND IRQ_EN drives the
  CPU's IRQ line
- CAP_SPR $80, CAP_SPRLINE $20, CAP_FEAT $07

Wide window (added after step 4):

- `$20842-$20845` move the display window's edges into the border, up to
  the visible frame; layers and sprites fill it and (0,0) is its corner
- left and right are latched per line, top and bottom per frame
- in the widened part, border pixels are background (transparent with CTRL
  bit 4); over the 320x200 area the border stays on top

Step 5:

- XRAM is the REU's memory (run VICE with `-reu -reusize 16384` for 16 MB);
  CAP_XRAM reports its size in MB
- two 8 KB CPU windows (`$D054-$D059`) at `$2000`-`$A000` or `$E000`, over
  RAM and ROM whatever `$01` says; code runs from them
- the DMA engine (`$D05A`, descriptors at `$20880`): copy, fill and masked
  copy between C64 RAM, VRAM and the register space, and XRAM, straight or
  2D, chained; background transfers keep DMA_CMD busy, transfers touching
  C64 RAM halt the CPU; IRQ_STAT bit 1 when a chain ends
- CAP_FEAT $1F

Palette changes still take effect per frame, not mid-frame.

Step 6 (first part):

- demos `parallax`, `bullets`, `gallery`, `bigworld`, `wide` and `sixteen`, built
  from generated art through the PNG converter (`demos/`, `tools/`)
- sprite hit masks (entry +7 bits 0-3), added when the bullet storm showed
  that shared group bits cannot keep bullets from colliding with each other

Next: "Nothing breaks" (needs well-known games and demos), music for Big
world, and running the tests on FPGA simulation and hardware.

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
| `t04_id_caps`      | VERSION, capability registers, CTRL, IRQ_EN/IRQ_STAT, reserved, FRAME |
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
| `t15_tiles8`       | 8-bit 8x8 tiles: map entries, flips, tile numbers above 255, map wrap |
| `t16_tiles4`       | layer 1 alone: 4-bit 16x16 tiles, palette banks, a 64-tile-wide map |
| `t17_scroll`       | tile scroll X/Y wrapping around the map in both directions |
| `t18_bitmap4`      | 4-bit bitmap with a palette bank; scroll ignored |
| `t19_order`        | layer order register in four raster bands; border on top |
| `t20_scroll_double` | with double-width pixels, scroll X counts layer pixels |
| `t21_sprites`      | sprite sizes, 4/8-bit pixels, banks, flips, double width, wrap, on bit |
| `t22_sprite_order` | lower entries in front, the behind bit, sprites in the layer order |
| `t23_sprite_limits` | 32 sprites and 640 pixels per line, overflow flag |
| `t24_collisions`   | collision list, group masks, transparency, IRQ_STAT bit 0 and the CPU IRQ |
| `t25_wide`         | full-size wide window: layer and sprite in the border, origin, border on top over 320x200 |
| `t26_wide_split`   | partly widened window, left edge split per line, top edge, layer in front |
| `t27_windows`      | XRAM windows: CAP_XRAM, paging, REU sharing, priority over ROM, slot rules, code in a window |
| `t28_dma`          | DMA: fill, copy, masked 2D, chains, busy, IRQ bit, register space, start while busy, length 0 |

### On an Ultimate over the network

`tests/hw/` runs programs on a real Ultimate (U64, C64 Ultimate) through
its REST API and FTP server, with no one at the machine. They need no
VIC-X: they test what the demos use from the Ultimate itself.

    python tests/hw/run_uci_probe.py <host>     # UCI commands, LOAD_REU of 2 MB
    python tests/hw/run_uci_loader.py <host>    # the demos' loader, lib/uci.inc

`tools/u64live.py <host>` shows the Ultimate's screen live at
http://localhost:8064/ from its video stream. `tools/u64screen.py <host> out.png` draws the Ultimate's text screen from
its memory; `tools/u64grab.py <host> out.png` grabs a frame from its video
stream (inbound UDP port 11000 must be open in the firewall).

### Stock compatibility

`stock-compat.py` runs self-checking VIC-II programs from VICE's own
testprogs in an unmodified x64sc 3.10, in the fork with `+vicx`, and in the
fork with `-vicx` (locked), and requires the same exit code and
byte-identical screenshots:

    svn export https://svn.code.sf.net/p/vice-emu/code/testprogs/VICII <dir>/VICII
    python stock-compat.py --testprogs <dir> --stock <unmodified headless x64sc.exe>

The list is in `stock-compat.txt`.
