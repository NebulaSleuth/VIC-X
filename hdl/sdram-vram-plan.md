# Plan: VRAM in the MiSTer's SDRAM

Status: plan, nothing built. For the MiSTer build (C64X core,
`D:\Repos\C64X_MiSTer`, branch `vicx`). The spec does not change; the
VHDL block keeps a block-RAM VRAM option for simulation and other boards.

## Why

The step 1 build uses 528 of 553 M10K blocks, 128 of them for VRAM. Moving
VRAM into the SDRAM module frees those 128 and leaves about 150 free for
steps 2-5. The cost is a reworked SDRAM controller and a VIC-X that reads
VRAM ahead of the display instead of pixel by pixel.

## How the core uses SDRAM now

- One 16-bit SDRAM, `rtl/sdram.v` (MiST controller, Till Harbaum), clocked
  by `clk64` = 63.06 MHz PAL (twice `clk_sys`, 31.53 MHz). The PLL
  reconfiguration for NTSC changes only the fractional multiplier, so every
  PLL output scales together.
- Every access is one byte: ACTIVE, then READ or WRITE two clocks later,
  CAS latency 2, auto precharge, no bursts. An access takes 8 clocks.
- Byte address mapping: bank = addr[22:21], row = addr[20:8],
  column = {addr[23], addr[7:0]}, byte lane = addr[24]. So the 16 MB REU at
  `$1000000` is the high byte of every word in the chip.
- A C64 cycle (`sysCycle`, 32 states at `clk_sys`) is 8 slots of 4 states,
  one SDRAM access each:

  | Slot | Owner | Used when |
  |------|-------|-----------|
  | EXT0-3 | `io_cycle`: tape, OSD loading, some cartridges | loading, tape playing |
  | DMA0-3 | `ext_cycle`: REU memory | REU DMA running |
  | EXT4-7 | refresh (1 C64 cycle in 4), else `io_cycle` | refresh; loading |
  | VIC0-3 | VIC-II | always |
  | CPU0-3, CPU4-7, CPU8-B | turbo CPU cycles | turbo on |
  | CPUC-F | CPU | always |

- Address map (bytes): C64 RAM `$0000000-$000FFFF`; cartridge ROM / EasyFlash
  `$0200000-$03FFFFF`; tape `$0400000-`; GeoRAM `$0C00000-$0FFFFFF`; REU
  `$1000000-$1FFFFFF`. `$0100000-$01FFFFF` looks unused: to confirm against
  all of `cartridge.v` before using it.

## The new controller

1. **Word-packed byte lanes.** Byte lane = addr[0], word address =
   addr[24:1]. Every existing user still gives byte addresses and gets
   bytes back, so nothing outside the controller changes, but VRAM gets
   whole 16-bit words. Without this, with the REU on the high lanes, VRAM
   would only have the low lane and half the bandwidth.
2. **Burst length 4 for reads.** In the same 8-clock slot: ACTIVE at 0,
   READ with auto precharge at 2, data at 4-7, which is 8 bytes. Checked
   against MT48LC16M16-class timing at 15.86 ns per clock: tRCD 31.7 ns
   (18-20 needed), tRAS from ACTIVE to precharge 95 ns (42), bank idle by
   clock 8 (tRP 18-20), tRC 127 ns (60). Every slot still opens and closes
   its own row, so slots stay independent. C64 reads take the word they
   need. C64 commands keep their present clocks, so the C64's timing does
   not change.
3. **Writes:** single-word writes as now (DQM picks the byte). VIC-X writes
   1 or 2 bytes per slot.
4. **VIC-X takes idle slots.** Each slot keeps its owner; when the owner
   has no request, a VIC-X request goes in instead. VIC-X region: 128 KB at
   `$0100000` (to confirm above).
5. **Turbo.** With VIC-X fetching, VIC-X goes before the turbo slots
   (CPU0/4/8), so turbo is best effort. MiSTer build only; not a spec
   matter. (The alternative, losing VIC-X fetches to turbo, breaks the
   per-line sprite limits.)

## Bandwidth

Supply, VIC-X slots per PAL line (63 C64 cycles):

| Situation | Free slots per C64 cycle | Slots per line | Bytes per line |
|-----------|--------------------------|----------------|----------------|
| nothing loading, no REU DMA, turbo off | CPU0/4/8, EXT0-3, EXT4-7 3 times in 4: 5.75 | 362 | 2900 |
| REU DMA running | 4.75 | 299 | 2390 |
| guaranteed (CPU0/4/8 only) | 3 | 189 | 1510 |

NTSC lines have 65 cycles, slightly more.

Demand: one slot per 8 aligned bytes. Worst cases with the window widened
to the full visible width (about 384 pixels):

| Source | Fetch per line | Slots |
|--------|----------------|-------|
| tile layer, 8x8 tiles, 4- or 8-bit | 49 map entries (98 B) + 49 tile rows | 63 |
| tile layer, 16x16, 8-bit | 25 entries + 25 rows of 16 B | 58 |
| bitmap, 8-bit | 384 B | 49 |
| two layers, worst | | 126 |
| sprites, 640 pixels 8-bit, 32 sprites unaligned | | about 112 |
| CPU port accesses, read-ahead and writes | 1 per 4 cycles typical | about 16 |
| total, worst | | about 254 |

So: 8x8 tile rows are what cost the most, one slot per 8 bytes whatever the
pixel depth. The worst case fits when nothing is loading, REU DMA included,
but not in the guaranteed 3 slots alone. Normal content (one bitmap layer
plus 32 16-pixel sprites, about 130 slots) fits even in those. The rest of
each line, and the lines outside the display, go to DMA.

If this proves too tight, the next step is the same slot grid at twice the
clock (126 MHz, one more PLL output that scales with the NTSC switch):
CAS latency 3, two BL4 reads per slot to different banks, double the supply.
Faster, but more timing risk on the MiSTer's SDRAM board.

Other option considered: the HPS DDR3 (`DDRAM_*`, already used by the
drive). Plenty of bandwidth and no change to the C64's controller, but its
latency is not fixed (Linux on the ARM and the drive share it), so per-line
deadlines could be missed. Kept as a fallback.

## Changes to VIC-X (`hdl/vicx.vhd`)

- VRAM behind a request interface: 8-byte aligned reads, 1-2 byte writes,
  with an acknowledge. A generic picks block RAM (simulation, other boards)
  or the external port (MiSTer).
- **Port read-ahead.** The CPU takes read data 3 clocks after CYCLE_CPUC,
  too soon for SDRAM, so each port keeps the byte at its address fetched
  ahead (as on VERA's data ports). Refetch after an address write or a
  step. Any VRAM write (CPU port, DMA) that hits a port's address updates
  its fetched byte, so reads behave exactly as now and no spec change is
  needed. The shortest gap between two port accesses is one C64 cycle (the
  extra write of a read-modify-write instruction), and port requests come
  first, so the byte is ready in time.
- Writes go through a short queue.
- Step 2 onward: layers and sprites read the next line during the current
  one into line buffers, so a whole line time is available. Line buffers,
  double buffered, about 2 blocks per layer and 2-4 for sprites.
- The register space (palette, sprite table, layer setup, collision list)
  stays in block RAM: the palette is read every pixel.

Block RAM after the move: about 400 of 553 used.

## Order of work

1. Controller in VHDL with word-packed lanes, BL4 reads and the idle-slot
   arbiter. GHDL testbench with a timing-checking SDRAM model (our own;
   the vendor models' licences are unclear). It checks that C64 slots issue
   the same commands on the same clocks as now, and that VIC-X bursts keep
   tRCD/tRAS/tRP/tRC.
2. `vicx.vhd`: memory interface, port read-ahead with write snooping, write
   queue. The step 1 testbench runs against a memory model with random
   latency, so read-ahead is tested.
3. Build, compare block RAM and timing, run `tests/hw/run_mister.py` on the
   MiSTer, plus a REU program and an EasyFlash cartridge to check the
   core's own memory users still work.
4. Then step 2's layer fetcher on the same interface.

To check first: the free region at `$0100000` (all of `cartridge.v`, tape
size limit), and that no core user relies on the old byte-lane order (a
16-bit read somewhere).
