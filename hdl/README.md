# HDL

The VIC-X block in plain VHDL with inferred block RAM and no vendor IP, so
the same files build in Quartus (MiSTer) and Vivado (Artix-7). It is
checked in GHDL against the same behaviour as the VICE fork.

| File | What |
|------|------|
| `vicx.vhd` | the block; its header describes the bus, video and reset interface |
| `tb/tb_vicx_step1.vhd` | step 1 testbench (follows conformance tests t01-t08) |
| `run_sim.sh` | analyse, elaborate and run every testbench in `tb/` |

    C:\msys64\usr\bin\bash.exe -lc "cd /d/Repos/VIC-X && sh hdl/run_sim.sh"

with `MSYSTEM=UCRT64` and `CHERE_INVOKING=1`; needs GHDL 6
(`mingw-w64-ucrt-x86_64-ghdl-llvm`). Prints PASS and exits 0, or lists each
failure and exits 1.

## Steps

1. Done: unlock, ID and capability registers, the two ports and VRAM, the
   register space, palette, VIC-II colour remapping, frame counter, IRQ.
   Synthesises for the MiSTer's Cyclone V with Quartus 17.0.2: 128 KB VRAM
   and the register space as block RAM, 804 registers.
2. Bitmap layer.
3. Tile layers, scrolling, mixing order.
4. Sprite engine.
5. DMA engine and XRAM windows.

The MiSTer core it goes into is the `vicx` branch of `D:\Repos\C64X_MiSTer`
(the MiSTer C64 core with drive 9 removed to make room for the VRAM).
