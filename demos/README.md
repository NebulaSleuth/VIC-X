# VIC-X demos

Five of the six demos in the spec's demo plan, and one for the wide window. Each shows its CPU load as
"CPU nn%": the share of each frame the demo's own code uses (the busiest of
every 16 frames, measured with the raster line), so you can see how little
the CPU has to do while VIC-X does the work.

| Demo | What it shows | Features |
|------|---------------|----------|
| `parallax` | Two 256-colour tile layers scrolling at different speeds behind a normal VIC-II score bar | tile layers, scrolling, mixing, CTRL bit 4 split per raster line |
| `bullets` | 128 sprites: a 32x32 ship and 127 bullets in four rotating spiral arms over a deep-space bitmap, with hit detection | sprite engine, collision groups and hit masks, DMA table updates, bitmap layer |
| `gallery` | 256-colour pictures streamed from XRAM, faded in and out | 8-bit bitmaps, double buffering, background DMA, palette fades |
| `bigworld` | A 320x3198 world (1 MB, six scenes from space to a molten core) scrolling up and down, one new row streamed in per frame | XRAM, a 256-row VRAM ring with a wrapping bitmap base, row DMA, XRAM window (scene table), REU DMA (captions) |
| `wide` | The parallax world switching every 5 seconds between the 320x200 window and the whole visible frame; in full-frame mode the text bar moves to the top of the frame | wide window, edges latched per line and per frame, scroll offsets that keep the scene still, a sprite-engine text bar, layer order |
| `sixteen` | A plain C64 multicolour bitmap, alternating between the stock palette and 16 colours picked for the picture | VIC-II colour remap (CTRL bit 3) |

## Artwork

The landscapes, the ship, the space backdrop, the gallery pictures, the six
Big world scenes and the lighthouse were generated with Google's Nano Banana Pro (`gemini-3-pro-image`) by
`../tools/nanobanana.py`; the originals are in `art/raw/`.
`../tools/prep_art.py` (needs Pillow) turns them into `art/*.png`:

- landscapes are scaled to 512x200, made seamless by appending a mirrored
  copy (the converter stores the mirrored tiles as flipped copies), reduced
  to 96 colours without dithering, and the sky gradient flattened per row,
  so the back layer needs 279 tiles and the front 742 (the limit is 1024)
- the foreground and the ship were drawn on magenta, which becomes
  transparent
- the space backdrop (192 colours) and the gallery pictures (240 colours)
  are dithered

`art/*.png` are committed, so building needs neither the API nor Pillow.
To change a picture, replace it in `art/raw/` (or generate a new one with
`nanobanana.py "prompt" art/raw/name.jpg --aspect 16:9`, with
`GEMINI_API_KEY` set) and build with `--prep`. The bullets are still drawn
by `../tools/gen_art.py`.

Everything goes through `../tools/png2vicx.py`, the same converter you
would use for your own PNGs.
Each demo is a PRG plus an REU image holding its data, since XRAM is the
REU's memory.

## Building

Needs Python 3 and cc65 (set `VICX_CC65` if `ca65`/`ld65` are not in the
default place):

    python build.py                 # everything, into build/
    python build.py gallery         # one demo
    python build.py --check         # also take a headless screenshot of each
    python build.py --prep          # first remake art/*.png from art/raw/
    python build.py --check --ntsc  # screenshots on an NTSC machine

## Disk images: the demos load themselves

`build.py` also makes a disk image per demo, with the demo first (so it
autostarts) and its data file: a D64 (1541) when it fits, a D81 (1581) for
`gallery` and `bigworld`. The data is packed in 8 KB blocks
(`../tools/lzpack.py`); the demo reads it with the KERNAL from the drive it
was loaded from, unpacks each block and DMAs it into XRAM, with a progress
bar. That works on any machine with VIC-X and an REU of 2 MB or more: VICE,
a MiSTer or an Ultimate, from a real drive or a disk image. If XRAM already
holds the demo's data (an REU image loaded with it, or an earlier run), it
starts at once.

| Demo | Disk | Packed data | Load time at standard 1541 speed |
|------|------|-------------|----------------------------------|
| `sixteen` | D64 | 14 KB | about 40 seconds |
| `parallax` | D64 | 44 KB | about 2 minutes (measured in VICE) |
| `wide` | D64 | 52 KB | about 2.5 minutes |
| `bullets` | D64 | 59 KB | about 2.5 minutes |
| `gallery` | D81 | 265 KB | about 12 minutes |
| `bigworld` | D81 | 453 KB | about 20 minutes |

The KERNAL loads about 380 bytes a second from a stock drive. Anything that
speeds up the KERNAL (JiffyDOS, a speeder cartridge, VICE's warp) speeds up
these loads too; a fast loader or the Ultimate's own file access would be
the next step for real hardware.

Fast-load cartridges are no way round this: they use the `$DE00-$DFFF` I/O
area, where the REU (that is, XRAM) lives, and most of them only speed up a
1541, not the 1581 that `gallery` and `bigworld` need.

### On an Ultimate (U64, C64 Ultimate): load the REU image from USB

The Ultimate can put a `.reu` file straight into REU memory, which takes
about a second instead of minutes:

1. Copy `build/<demo>.prg` and `build/<demo>.reu` to a USB stick.
2. In the Ultimate menu, under C64 and Cartridge Settings, turn the RAM
   Expansion Unit on with an REU Size of 2 MB or more.
3. In the file browser, select `<demo>.reu` and choose "Load into REU".
4. Select `<demo>.prg` and run it. It finds its data already in XRAM (the
   signature at `$1FFFF0`) and starts at once.

REU Preload (with REU Preload Image set to the `.reu` file) does step 3 on
every power-on, which suits a machine set up to show one demo.

    D:/Repos/vice-vicx/vice/build-ucrt64/src/x64sc.exe -directory D:/Repos/vice-vicx/vice/data -vicx -reu -reusize 2048 -autostart D:/Repos/VIC-X/demos/build/parallax.d64

## Running

In the GTK build of the VICE fork, from an MSYS2 UCRT64 shell (any folder):

    D:/Repos/vice-vicx/vice/build-ucrt64/src/x64sc.exe -directory D:/Repos/vice-vicx/vice/data -vicx -reu -reusize 2048 -reuimage D:/Repos/VIC-X/demos/build/parallax.reu -autostartprgmode 1 -autostart D:/Repos/VIC-X/demos/build/parallax.prg

Replace both `parallax` with any other demo's name. This loads the data
instantly from the REU image, without the disk. Add `-ntsc` for an NTSC
C64 (about 60 Hz): on a 60 Hz monitor that scrolls more smoothly than PAL's
50 Hz, which VICE has to show unevenly. NTSC frames are shorter, so the same
work shows as a higher CPU percentage (bullets: about 49% PAL, 74% NTSC).

- `-directory` points VICE at its ROMs and keymaps; a build run from its
  build tree does not find them otherwise ("Default keymap not found").
- Use full paths: a relative `-reuimage` path that does not exist is
  reported as "not valid for option `-reuimage`".
- `-autostartprgmode 1` puts the PRG straight into memory; without it VICE
  loads it through an emulated disk drive, which takes a while. Without `-vicx`, or without
the REU, a demo says what is missing and stops.

## Notes

- The gallery keeps its colours in palette entries 16-255. In VICE, layer
  pixels that use entries 0-15 show the stock VIC-II colours unless CTRL
  bit 3 is on (a limitation of the model's 8-bit line buffer; see `VICX.md`
  in the fork).
- `sixteen` alternates whole frames rather than splitting the screen, since
  VICE applies palette changes once per frame. Its stock version is converted
  to the colours VICE 3.10 shows by default, which are not those of every
  real C64 or palette setting.
- `bigworld` has no music yet (the spec's "Big world" also streams music).
- Not built: "Nothing breaks" (needs well-known games and demos;
  `tests/stock-compat.py` covers VICE's own VIC-II test programs meanwhile).
