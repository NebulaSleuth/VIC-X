# Plan: VRAM in the MiSTer's SDRAM

Status: built and running on the MiSTer; VRAM is in SDRAM. For the MiSTer build (C64X core,
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
2. **The core's own accesses are unchanged**: burst length 1, the same
   commands on the same clocks. A first idea, burst length 4 for every
   read, does not work: the core takes read data on a rising edge about
   5 ns after the chip's data hold time, which works only because the bus
   floats afterwards and keeps its value. With bursts the next word would
   be on the bus by then.
3. **A VIC-X read is four single-word READs** on consecutive clocks in the
   open row, then PRECHARGE: ACTIVE at e1, READ at e3-e6, PRECHARGE at e7,
   8 bytes per 8-clock slot. Each word is taken on the falling edge of clk,
   in the middle of its valid window. At 15.86 ns per clock: tRCD 31.7 ns
   (18-20 needed), tRAS 95 ns (42), tRP 31.7 ns before the next slot (18-20),
   tRC 127 ns (60).
4. **Writes:** single-word writes as now (DQM picks the byte). VIC-X writes
   1 or 2 bytes per slot.
5. **VIC-X takes idle slots.** The core marks each slot's start and the
   slots VIC-X may use. When such a slot starts with no owner request and
   no refresh, a VIC-X request takes it. VIC-X region: 128 KB at
   `$0100000`. Checked: cartridge RAM is `$0010000-$001FFFF`, cartridge ROM
   `$0200000-$03FFFFF`, GeoRAM `$0C00000-$0FFFFFF`, the erase at start covers
   `$0000000-$001FFFF`.
6. **Which slots.** Only slots whose owners always start their request in
   the slot's first state: the REU slot (DMA0) and the turbo CPU slots
   (CPU0/4/8). The EXT slots are left out for now: the EasyFlash's flash
   (`am29f040.sv`) can raise its request in the middle of an io slot. The
   controller has a `conflict` flag that goes high if an owner request ever
   starts during a VIC-X access.
7. **Turbo.** Turbo CPU cycles are owners, so with turbo on VIC-X loses
   those slots. Planned for the fetcher (step 2): with VIC-X fetching, VIC-X
   goes before turbo, so turbo is best effort. MiSTer build only; not a
   spec matter.

## Bandwidth

Supply, VIC-X slots per PAL line (63 C64 cycles), with the slots above:

| Situation | Free slots per C64 cycle | Slots per line | Bytes per line |
|-----------|--------------------------|----------------|----------------|
| no REU DMA, turbo off | DMA0, CPU0/4/8: 4 | 252 | 2016 |
| REU DMA running | 3 | 189 | 1512 |
| later, with the EXT slots too | up to 5.75 | 362 | 2900 |

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
pixel depth. With the four slots the worst case is just at the limit (252
against about 254), and over it during REU DMA. Normal content (one bitmap
layer plus 32 16-pixel sprites, about 130 slots) fits with room to spare.
The rest of each line, and the lines outside the display, go to DMA.

Ways to more room, in order: the EXT slots once the flash's request timing
is handled; then the same slot grid at twice the clock (126 MHz, one more
PLL output that scales with the NTSC switch), which doubles the supply but
adds timing risk on the MiSTer's SDRAM board.

Other option considered: the HPS DDR3 (`DDRAM_*`, already used by the
drive). Plenty of bandwidth and no change to the C64's controller, but its
latency is not fixed (Linux on the ARM and the drive share it), so per-line
deadlines could be missed. Kept as a fallback.

## Status

- Done: `rtl/sdram_vicx.vhd` in the C64X core (replaces `sdram.v`), with
  `sim/` (GHDL): a chip model with timing checks and data valid windows,
  and a testbench of random traffic from every owner plus a VIC-X client.
  It passes with 0-9 ns of extra read data delay (board and pins) and
  fails, as it should, from 11 ns; the limit worked out is about 10.5 ns.
- Done: `vicx.vhd` with `EXT_VRAM`: port read-ahead, write queue, snooping
  (see `hdl/README.md`); the C64X core uses it. Block RAM 401 of 553 (was
  528), logic 62%, timing met.
- On the MiSTer (2026-11-15): step 1 tests as before, `tests/hw/ram_check`,
  `reu_check` (16 MB) and `vram_check` (all 128 KB both ways, step-640 reads
  four cycles apart, write then read on the other port) pass.
- 2026-11-17: a build whose placement moved the VIC-X read capture read
  wrong data (the four word registers sampled the pins directly; only one
  could be the pin's input register). Now one register (`fq`) samples the
  pins on every falling edge and is the fast input register in every
  build; VIC-X words and the core's own reads are taken from it.
- Not yet: EasyFlash cartridges; turbo (VIC-X would lose the turbo slots);
  the conflict flag and vx_miss are not visible on the hardware.

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

1. (Done) Controller in VHDL with word-packed lanes, VIC-X reads of 8
   bytes and the idle-slot arbiter. GHDL testbench with a timing-checking SDRAM model (our own;
   the vendor models' licences are unclear). It checks that C64 slots issue
   the same commands on the same clocks as before, and that VIC-X reads
   keep tRCD/tRAS/tRP/tRC.
2. `vicx.vhd`: memory interface, port read-ahead with write snooping, write
   queue. The step 1 testbench runs against a memory model with random
   latency, so read-ahead is tested.
3. Build, compare block RAM and timing, run `tests/hw/run_mister.py` on the
   MiSTer, plus a REU program and an EasyFlash cartridge to check the
   core's own memory users still work.
4. Then step 2's layer fetcher on the same interface.

Checked: the free region at `$0100000`, and no core user reads 16 bits or
depends on the old byte-lane order (all use the 8-bit `dout`).
