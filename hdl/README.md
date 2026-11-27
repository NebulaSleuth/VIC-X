# HDL

The VIC-X block in plain VHDL with inferred block RAM and no vendor IP, so
the same files build in Quartus (MiSTer) and Vivado (Artix-7). It is
checked in GHDL against the same behaviour as the VICE fork.

| File | What |
|------|------|
| `vicx.vhd` | the block; its header describes the bus, video, memory and reset interface |
| `vicx_layer.vhd` | one tile or bitmap layer for one line at a time (two in the block) |
| `vicx_sprites.vhd` | the sprite engine: selection, row fetch, line buffers, collisions |
| `tb/tb_vicx_step1.vhd` | step 1 testbench (follows conformance tests t01-t08, then a random stress of both ports) |
| `tb/tb_vicx_step2.vhd` | step 2 testbench: PAL lines of video, every pixel of each frame compared with the spec (t10-t14 cases, raster splits, port traffic) |
| `tb/tb_vicx_step3.vhd` | step 3: both layers in every mode, the order register, border pixels, splits |
| `tb/tb_vicx_step4.vhd` | step 4: sprites over two layers, the order with behind sprites, limits, collision list and IRQ after each frame |
| `tb/tb_vicx_wide.vhd` | the wide window: edges per line and per frame, border pixels as background, sprites and layers from the widened corner |
| `tb/tb_vicx_dma.vhd` | DMA engine testbench: each transfer also run on a reference that follows VICE's `dma_run`, memories compared; also the XRAM window decode |
| `run_sim.sh` | analyse, elaborate and run every testbench in `tb/`; steps 1 and 2 also with external VRAM |
| `sdram-vram-plan.md` | VRAM in the MiSTer's SDRAM: design, bandwidth, status |
| `synth_xc7.sh` | Artix-7 (xc7) resource count for each block with GHDL + Yosys (see "On Artix-7" below) |
| `vivado_xc7.tcl` | the same in Vivado, placed and routed, with timing |
| `vivado_xc7.sh` | the usual Vivado builds, on both Artix-7 parts at 77 MHz |

    C:\msys64\usr\bin\bash.exe -lc "cd /d/Repos/VIC-X && sh hdl/run_sim.sh"

with `MSYSTEM=UCRT64` and `CHERE_INVOKING=1`; needs GHDL 6
(`mingw-w64-ucrt-x86_64-ghdl-llvm`). Prints PASS and exits 0, or lists each
failure and exits 1.

## VRAM inside or outside

With `EXT_VRAM => false` VRAM is block RAM inside the block. With
`EXT_VRAM => true` it is reached through the `vx_*` port, which on the
MiSTer is the VIC-X port of the C64X core's SDRAM controller
(`rtl/sdram_vicx.vhd` there, with its own GHDL testbench in `sim/`). Each
CPU port then keeps a copy of the 8-byte block it points at, fetched ahead;
writes are queued and update the copies. `run_sim.sh` runs the step 1
testbench with external VRAM at C64 speed (an access every 128 clocks,
read-modify-write cycles 32 apart) against a memory that answers after up
to 16 and up to 40 clocks. Deliberately breaking the write snoop or the
stale-fetch discard makes it fail, and so does a memory that takes up to
200 clocks (reads find no data ready: `vx_miss`).

## Putting the block into a core

Two things that are easy to get wrong, each met while wiring the block
into another C64 core:

- **The memory side must not forget a read at reset.** VIC-X still waits
  for a read that was in flight when `reset` came, and throws its data
  away. A memory adapter that is reset together with the block and drops
  the read leaves the `vx_*` port waiting for ever: every later port read
  gets $FF. The step 1 testbench resets the block at twelve distances
  from the start of a fetch; with `-gEXT=true -gDROP=true` its memory
  model forgets such a read and the run fails, as it must (`run_sim.sh`
  checks that it does).
- **`win_hit` and `win_addr` follow `bus_addr` with no register.** Use
  them only while `bus_addr` is the address of the access being made. In
  a core whose CPU steps some time after the bus was sampled, the old
  address is still there in between: a windowed read started then gets
  the last access's byte (seen as code that would not run from a window,
  while single reads worked). The decode into a core's memory map is also
  a long path; registering it by one clock is fine.

## On Artix-7

Built in Vivado 2026.2 (`sh hdl/vivado_xc7.sh`, which runs
`vivado_xc7.tcl`): the block alone, out of context, placed and routed at
77 MHz on speed grade -1, with VRAM outside (`EXT_VRAM`) as on the MiSTer.
Its ports are taken to come from and go to registers in the core around
it, with 2 ns of each clock for the wire. The XC7A50T in the Commodore 64
Ultimate has 32,600 LUTs, 65,200 flip-flops, 75 block RAM tiles and 120
DSP48; the XC7A100T in the Commodore 77 has 63,400, 126,800, 135 and 240.

Measured 2026-11-20 (LUTs count LUT RAM too; block RAM in 36 Kb tiles):

| Build | LUTs (of which RAM) | Flip-flops | Block RAM | DSP | XC7A50T | XC7A100T | Slack at 77 MHz |
|-------|---------------------|------------|-----------|-----|---------|----------|-----------------|
| Everything (the MiSTer build) | 9,550 (188) | 5,872 | 15 | 10 | 29% | 15% | +0.05 ns (50T), +0.19 ns (100T) |
| Everything, sprites 64/16 | 8,531 (276) | 4,675 | 9 | 10 | 26% | 13% | +0.03 ns |
| Layers and sprites 64/16, no DMA | 6,801 (250) | 3,798 | 8.5 | 6 | 21% | 11% | +0.52 ns |
| Layers only | 5,311 (84) | 2,212 | 4.5 | 6 | 16% | 8% | +0.71 ns |

Each part's cost, from the differences between those builds:

| Part | LUTs | Flip-flops | Block RAM | DSP | Build option |
|------|------|------------|-----------|-----|--------------|
| Core: unlock, registers, register space, palette, the two CPU ports, VRAM port and write queue, colour remap, compositing | about 1,600 | 1,060 | 2.5 | 0 | always |
| Layer, each of two (tile and bitmap) | about 1,830 | 574 | 1 | 3 | CAP_FEAT bits 0, 1 |
| Sprite engine, 64 entries, 16 a line | 1,490 | 1,586 | 4 | 0 | CAP_FEAT bit 2, CAP_SPR, CAP_SPRLINE |
| Sprite engine, 128 entries, 32 a line: more than 64/16 | 1,019 | 1,197 | 6 | 0 | |
| DMA engine, XRAM windows and the blitter's operations | 1,730 | 877 | 0.5 | 4 | CAP_FEAT bits 3, 4, CAP_BLIT |

Vivado's own per-block report (`util_hier.txt`) moves logic across block
edges as it optimises, by several hundred LUTs between builds of the same
block, so the table takes whole-build differences instead. The full build
on the 50T meets 77 MHz with little to spare; inside a whole C64 Ultimate
design, placed among the rest, it may need another stage or two (the
worst paths left are the sprite engine's draw step and the DMA's store,
`paths_reg.txt` lists them).

For 77 MHz (the first route came out at 57 MHz, with the CPU's and the
DMA's work for a clock chained into one 23-LUT path):

- The register copies (layer setups, order, wide window, DMA list
  address) follow a register-space store a clock later, so the store and
  the decoder behind them are no longer one path.
- Where the DMA's source and destination go (C64 RAM, VRAM, the register
  space, the palette, XRAM) is worked out when it moves to them, a clock
  before the byte step uses it.
- A DMA read from the palette waits out a clock in which the CPU accesses
  VIC-X (rather than taking the CPU's store as it happens), and the byte
  is used a clock after it is read.
- The frontmost layer or sprite pixel goes into a register before the
  palette RAM. A pixel lasts four clocks or more (four on the MiSTer, about
  ten at 77 MHz), so this costs no delay; `pix_ce` must now come no more
  often than every fourth clock.

`synth_xc7.sh` gives Yosys's count for each block (`synth_xilinx -family
xc7 -abc9`, Yosys 0.66, GHDL 6), with no placement or timing. Before the
timing work it counted 12,668 LUTs for everything, 10,936 with sprites
64/16, 9,323 with no DMA and 6,499 for the layers alone; Yosys maps less
tightly than Vivado, by about a quarter here.

The same full build measured 22,229 LUTs before this work (Yosys, same
flow); in Quartus (Cyclone V, the block alone) it went from 16,047 ALUTs
and 8,721 registers to 11,378 and 7,795. What changed, each checked with
`run_sim.sh`:

- DMA descriptors are read from the register space as each starts (28
  bytes, about 30 clocks), not kept in five copies in flip-flops; the
  next-descriptor byte is read when a descriptor ends.
- One register-space snoop for the CPU's, the DMA's and the sprites' stores
  (they take turns), not three.
- The VRAM write queue, the sprites' selection list and row buffers, and
  palette entries 0-15 are in LUT RAM. The palette's first-access copy of
  the stock palette takes 16 clocks instead of one; until an entry is
  copied it reads as stock (unless stored since), so it reads the same.
- The DMA's per-pixel `x * X step` is an accumulator, and a row's start is
  worked out over three clocks instead of two chained multiplies in one
  (for timing; about 150 ALUTs more, 2 DSPs fewer).
- The sprite row offset is a shift (the row length is a power of two).

Tried and taken back: shifts for the layers' map-width multiply, and a
narrower row gather in the layer, both cost LUTs (267 and 229 a layer)
where the DSP multiply and the original gather did not.

The blitter's operations are small (tens of LUTs each); switching them
off one at a time gives differences within the run-to-run noise.

The sprite engine's size is a build option (CAP_SPR 128 or 64 entries,
CAP_SPRLINE 32 or 16 a line; the capability registers report it). Almost
all of the difference is sprites a line (the selection lists, the collision
masks and the line buffers' mask bits are that wide); the table size is
mostly block RAM. With 64 entries the table's higher entries are ignored
(they are still stored in the register space). `run_sim.sh` runs the
sprite testbench at 64/16 too.

The register space, the palette (`pal_r/g/b`) and each layer's line
buffer (`pbuf`) are written in the template GHDL's synthesis needs to infer
RAM (one write enable, an unconditional read). Written otherwise (writes
split by a case, two write enables with different data, a read replaced by
a constant past the end) GHDL builds them from about 35,000 flip-flops and
their read muxes, where Quartus still infers RAM; Quartus's result is the
same either way (checked 2026-11-19: the same 15 RAMs, 128,384 bits).

## Steps

1. Done: unlock, ID and capability registers, the two ports and VRAM, the
   register space, palette, VIC-II colour remapping, frame counter, IRQ.
2. Done: bitmap layers (CAP_FEAT bit 1). The core gives the block three
   more VIC-II flags per pixel: drawn from `$D021`, in the 320x200 window,
   border.
3. Done: tile layers, layer 1 and the layer order (CAP_FEAT bit 0). Each
   layer fetches its line from the line's own start, when its setup is
   latched (as the spec says), into a decoded line buffer the display reads
   behind the fetch; the window's left edge comes about 16 C64 cycles later.
4. Done: the sprite engine (CAP_FEAT bit 2, 128 entries, 32 a line, or as
   set by CAP_SPR and CAP_SPRLINE: 64 and 16 are also built and tested). The
   next line is prepared during the current one.
5. Done for the MiSTer (CAP_FEAT bits 3 and 4): the DMA engine reaches C64
   RAM, VRAM and XRAM through the SDRAM port, and holds the CPU through RDY
   while it touches C64 RAM; the XRAM windows make the core send a CPU (or
   REU) access to XRAM. Both need `EXT_VRAM`.

Blitter options (spec: optional per target, CAP_BLIT at `$D05B`): the
`CAP_BLIT` generic picks them. Done: expand and masked expand (bit 0),
remap (bit 1: the table is loaded into a 256-byte block RAM as the
descriptor starts), scaled copy (bit 2), mirror and backwards (bit 3);
strides are signed; lists in VRAM (bit 4: each entry fetched through the
read cache into a fifth descriptor slot). `tb_vicx_dma` checks them all
against VICE's `dma_run`.

Wide window: done. The block counts pixels from the line's start and
learns where the 320x200 area begins from the VIC-II, so the edges can move
out by up to 32 pixels each side, 35 lines up and 37 down (VICE's PAL
visible frame).

On the MiSTer (2026-11-15/16, CAP_FEAT $1F, 83% of the logic, 431 of 553
block RAMs, timing met): t01-t28 as far as they run on hardware pass (t04
only differs in CAP_XRAM, which is 16 with the REU on), and all six demos
run: sixteen, gallery, parallax, bullets, bigworld and wide
(`tests/hw/run_demo.py`).

Known limits on the MiSTer, all from SDRAM bandwidth (one 8-byte block per
free slot, 4 slots a C64 cycle, 3 while the REU's DMA runs):

- While REU DMA runs, two 8x8 8-bit tile layers, or the heaviest sprite
  line (640 8-bit pixels) over two layers, can miss pixels (drawn
  transparent, `lay_late`). Without REU DMA they fit.
- The DMA engine waits while a layer or the sprite engine fetches its
  line, so it cannot make them late; it runs in the rest of each line
  and in the border. Measured (`tests/hw/dma_bench.s`, 2026-11-17, before
  that change): 64,000 bytes XRAM to VRAM in 191 raster lines (about
  5.2 MB/s), a fill in 127 lines (7.9 MB/s), 217 lines with an 8-bit
  bitmap layer on; with the wait, 229 lines with the layer on (a fill
  148) and the same as before with it off; since VIC-X reads take a
  clock more (the two-stage pin capture, 2026-11-18), 253 lines with the
  layer on (a fill 164). Copies are under the spec's 8 MB/s target: each 8
  bytes take one read slot and four one-word write slots.
- Collisions are checked one pair a clock as each line shows. A heap of
  sprites with hundreds of pairs at a pixel falls behind, so the list can
  hold other pairs than VICE's; the count (127) and the full flag agree.
- Without XRAM (REU off) the windows take no accesses, where VICE reads
  `$FF` there.
- Turbo: VIC-X's slots are the turbo CPU slots; with turbo on, VIC-X gets
  only what turbo leaves.

The MiSTer core it goes into is the `vicx` branch of `D:\Repos\C64X_MiSTer`
(the MiSTer C64 core; drive 9 was removed while VRAM was block RAM, and is
back since VRAM moved to SDRAM). Its 1541 reads D64 tracks that the
MiSTer's main program places in DDR3, so it needs a Main_MiSTer from May
2026 or later; with an older one `.d64` images show no files (`.d81` work).
