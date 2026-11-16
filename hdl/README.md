# HDL

The VIC-X block in plain VHDL with inferred block RAM and no vendor IP, so
the same files build in Quartus (MiSTer) and Vivado (Artix-7). It is
checked in GHDL against the same behaviour as the VICE fork.

| File | What |
|------|------|
| `vicx.vhd` | the block; its header describes the bus, video and reset interface |
| `tb/tb_vicx_step1.vhd` | step 1 testbench (follows conformance tests t01-t08, then a random stress of both ports) |
| `run_sim.sh` | analyse, elaborate and run every testbench in `tb/`; step 1 also with external VRAM |
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
stale-fetch discard makes it fail, and so does a memory slower than about
120 clocks (reads find no data ready: `vx_miss`).

## Steps

1. Done: unlock, ID and capability registers, the two ports and VRAM, the
   register space, palette, VIC-II colour remapping, frame counter, IRQ.
   Synthesises for the MiSTer's Cyclone V with Quartus 17.0.2. Runs on the
   MiSTer in the C64X core, first with VRAM in block RAM, now in SDRAM.
2. Bitmap layer.
3. Tile layers, scrolling, mixing order.
4. Sprite engine.
5. DMA engine and XRAM windows.

The MiSTer core it goes into is the `vicx` branch of `D:\Repos\C64X_MiSTer`
(the MiSTer C64 core with drive 9 removed to make room for the VRAM).
