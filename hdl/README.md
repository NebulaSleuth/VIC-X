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

## On Artix-7

Not yet built in Vivado (`vivado_xc7.tcl` is ready: out of context, placed
and routed, utilisation per block and timing at a given clock).
`synth_xc7.sh` gives a resource count from Yosys (`synth_xilinx -family
xc7 -abc9`, Yosys 0.66, GHDL 6) for each block, with VRAM outside
(`EXT_VRAM`) as on the MiSTer. The XC7A50T in the Commodore 64 Ultimate has
32,600 LUTs, 65,200 flip-flops, 75 RAMB36 and 120 DSP48; the XC7A100T in the
Commodore 77 has 63,400, 126,800, 135 and 240.

Each feature's cost, measured 2026-11-19 (LUTs count LUT RAM too; the
DMA, XRAM and blitter rows are differences between builds with and
without them, the rest are the blocks' own counts):

| Part | LUTs | Flip-flops | Block RAM | DSP | Build option |
|------|------|------------|-----------|-----|--------------|
| Core: unlock, registers, register space, palette, the two CPU ports, VRAM port and write queue, colour remap, compositing | 2,813 | 1,148 | 1 RAMB36 | 0 | always |
| Layer, each of two (tile and bitmap) | 1,882 | 655 | 0 | 3 | CAP_FEAT bits 0, 1 |
| Sprite engine, 128 entries, 32 a line | 4,254 | 2,920 | 5 RAMB36 + 1 RAMB18 | 0 | CAP_FEAT bit 2 |
| Sprite engine, 64 entries, 16 a line | 2,453 | 1,793 | 3 RAMB18 | 0 | CAP_SPR, CAP_SPRLINE |
| DMA engine and XRAM windows | 1,316 | 758 | 0 | 2 | CAP_FEAT bits 3, 4 |
| Blitter operations (all five) | 521 | 193 | 0 | 2 | CAP_BLIT |

| Build | LUTs | of an XC7A50T | of an XC7A100T |
|-------|------|---------------|----------------|
| Everything (the MiSTer build) | 12,668 | 39% | 20% |
| Everything, sprites 64/16 | 10,936 | 34% | 17% |
| Layers and sprites 64/16, no DMA | 9,323 | 29% | 15% |
| Layers only | 6,499 | 20% | 10% |

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

How far to trust the counts: the layer and sprite blocks come out within
about 100 LUTs from run to run; the top block (`vicx`) swung by a thousand
LUTs between nearly equal designs before this work, and still varies by
a few hundred. The blitter's operations are small (tens of LUTs each);
switching them off one at a time gives differences within that noise.
There is no timing figure: Yosys does not place or route.

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
