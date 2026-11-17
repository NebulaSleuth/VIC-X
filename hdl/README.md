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
4. Done: the sprite engine (CAP_FEAT bit 2, 128 entries, 32 a line). The
   next line is prepared during the current one.
5. Done for the MiSTer (CAP_FEAT bits 3 and 4): the DMA engine reaches C64
   RAM, VRAM and XRAM through the SDRAM port, and holds the CPU through RDY
   while it touches C64 RAM; the XRAM windows make the core send a CPU (or
   REU) access to XRAM. Both need `EXT_VRAM`.

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
