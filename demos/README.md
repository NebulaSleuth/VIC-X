# VIC-X demos

Three of the six demos in the spec's demo plan. Each shows its CPU load as
"CPU nn%": the share of each frame the demo's own code uses (the busiest of
every 16 frames, measured with the raster line), so you can see how little
the CPU has to do while VIC-X does the work.

| Demo | What it shows | Features |
|------|---------------|----------|
| `parallax` | Two 256-colour tile layers scrolling at different speeds behind a normal VIC-II score bar | tile layers, scrolling, mixing, CTRL bit 4 split per raster line |
| `bullets` | 128 sprites: a 32x32 ship and 127 bullets in four rotating spiral arms over a deep-space bitmap, with hit detection | sprite engine, collision groups and hit masks, DMA table updates, bitmap layer |
| `gallery` | 256-colour pictures streamed from XRAM, faded in and out | 8-bit bitmaps, double buffering, background DMA, palette fades |

## Artwork

The landscapes, the ship, the space backdrop and the four gallery pictures
were generated with Google's Nano Banana Pro (`gemini-3-pro-image`) by
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

## Running

In the GTK build of the VICE fork, from an MSYS2 UCRT64 shell (any folder):

    D:/Repos/vice-vicx/vice/build-ucrt64/src/x64sc.exe -directory D:/Repos/vice-vicx/vice/data -vicx -reu -reusize 2048 -reuimage D:/Repos/VIC-X/demos/build/parallax.reu -autostartprgmode 1 -autostart D:/Repos/VIC-X/demos/build/parallax.prg

Replace both `parallax` with `bullets` or `gallery`. Add `-ntsc` for an NTSC
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
- Not built yet: "Big world" (XRAM windows and REU streaming), "Any sixteen
  colours" (needs a classic picture and a stock game) and "Nothing breaks"
  (needs well-known games and demos; `tests/stock-compat.py` covers VICE's
  own VIC-II test programs meanwhile).
