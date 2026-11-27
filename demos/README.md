# VIC-X demos

Seven of the eight demos in the spec's demo plan, and one for the wide window. Each (but sixteen, which has no text, and desktop, which shows its redraw rate) shows its frame rate as
"FPS nn": how many times a second the demo draws (over its last 16 frames,
counted with VIC-X's frame counter): 50 on PAL when every frame is drawn,
25 when a frame's work takes longer than a frame.

| Demo | What it shows | Features |
|------|---------------|----------|
| `parallax` | Two 256-colour tile layers scrolling at different speeds behind a normal VIC-II score bar | tile layers, scrolling, mixing, CTRL bit 4 split per raster line |
| `bullets` | 128 sprites: a 32x32 ship and 127 bullets in four rotating spiral arms over a deep-space bitmap, with hit detection | sprite engine, collision groups and hit masks, DMA table updates, bitmap layer |
| `gallery` | 256-colour pictures streamed from XRAM, faded in and out | 8-bit bitmaps, double buffering, background DMA, palette fades |
| `bigworld` | A 320x3198 world (1 MB, six scenes from space to a molten core) scrolling up and down, one new row streamed in per frame, with music for each scene streamed from XRAM | XRAM, a 256-row VRAM ring with a wrapping bitmap base, row DMA, XRAM windows (scene table, 312 KB of SID music), REU DMA (captions) |
| `wide` | The parallax world switching every 5 seconds between the 320x200 window and the whole visible frame; in full-frame mode the text bar moves to the top of the frame | wide window, edges latched per line and per frame, scroll offsets that keep the scene still, a sprite-engine text bar, layer order |
| `sixteen` | A plain C64 multicolour bitmap, alternating between the stock palette and 16 colours picked for the picture | VIC-II colour remap (CTRL bit 3) |
| `blitter` | One scene per optional blitter operation, read from CAP_BLIT: so far expand (a sine scroller of 16x16 letters stamped over a picture with masked expand, and a scrolling text panel, a colour per line, with expand) remap (the picture dimmed to greys through a 256-byte table, with a spotlight in full colour moving over it) scaled copy (one 32x32 ship drawn at any size: a big one zooming and turning like a card, six small ones in orbit sized by depth) and direction (a box panning over the picture that scrolls over itself with the backwards bit, its mirror image, and a rippling reflection drawn upside down through a negative stride), and lists in VRAM (four snakes of 48 balls: one fill and 192 masked copies a frame from one list, started by one DMA_CMD write; the lists sit below a 184-row playfield, hidden by a raster-IRQ split); scenes the build lacks say NOT IN THIS BUILD; a one-minute soundtrack streamed from XRAM plays throughout | blitter expand, masked expand, remap, scaled copy, mirror and backwards, lists in VRAM, signed strides, CAP_BLIT, double-buffered 8-bit bitmap, fonts built from the character ROM at one bit per pixel in XRAM, XRAM windows (96 KB of SID music) |
| `desktop` | A GEOS-style desktop: icons, menus, overlapping windows (notes that type themselves, a photo, the palette, an About box) dragged with a mouse or joystick | a double-buffered 8-bit bitmap redrawn by 2D DMA copies and fills from XRAM (only what changed), VIC-II text in front, sprite pointer, XRAM window (the CPU writes text into the pictures), palette rotation |

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
by `../tools/gen_art.py`, and the desktop (wallpaper, icons, window
frames, menus, pointer) by `../tools/gen_desktop.py`; its photo is the
castle picture again, as `art/desktop_photo.png` (160x100, 160 colours).

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
(`../tools/lzpack.py`); the demo reads it from the drive it was loaded from,
unpacks each block and DMAs it into XRAM, with a progress bar. That works on
any machine with VIC-X and an REU of 2 MB or more: VICE, a MiSTer or an
Ultimate, from a real drive or a disk image. If XRAM already holds the
demo's data (an REU image loaded with it, or an earlier run), it starts at
once.

On a 1541 or 1581 (true drive emulation in VICE, the MiSTer's drives 8 and
9, a real drive) the demos use their own fast loader (`lib/fastload.inc`):
drive code that reads the file's sectors and sends each byte two bits at a
time over CLK and DATA. On anything else (1571, SD2IEC, VICE's virtual
drive) they load through the KERNAL, at about 380 bytes a second. The D64s
are written by `../tools/d64write.py`, with the data file's sectors spaced
for the fast loader (about 122 ms apart); in a D64 written with the
standard interleave the fast loader still works, at half the speed.

| Demo | Disk | Packed data | Fast loader (VICE) | KERNAL |
|------|------|-------------|--------------------|--------|
| `sixteen` | D64 | 14 KB | 10 s | about 40 s |
| `desktop` | D64 | 20 KB | 16 s | about 1 minute |
| `parallax` | D64 | 44 KB | 29 s | about 2 minutes |
| `wide` | D64 | 52 KB | 34 s | about 2.5 minutes |
| `bullets` | D64 | 59 KB | 37 s | about 2.5 minutes |
| `gallery` | D81 | 265 KB | 93 s | about 12 minutes |
| `bigworld` | D81 | 511 KB | about 3.5 minutes | about 23 minutes |

The times are from the demo starting to it running, including unpacking
(1 MB for `bigworld`). `../tests/fastload_check.py` runs a demo from its
disk image in headless VICE and checks what lands in XRAM against its REU
image.

Fast-load cartridges are no way round this: they use the `$DE00-$DFFF` I/O
area, where the REU (that is, XRAM) lives, and most of them only speed up a
1541, not the 1581 that `gallery` and `bigworld` need.

### On a MiSTer: one menu entry per demo

`build.py` also writes `build/<demo>.mgl`, a MiSTer launcher that loads the
C64X core, then `<demo>.reu` into the REU and `<demo>.prg`; the demo finds
its data in XRAM and starts at once. Copy the demo files to
`games/C64X/vicx-demos/` and the `.mgl` files to a folder whose name starts
with `_` (for example `/media/fat/_VIC-X/`): each demo is then one entry in
the MiSTer's main menu.

### On an Ultimate (U64, C64 Ultimate): the demo loads its REU image from USB

On an Ultimate the demo loads `<demo>.reu` itself through the Ultimate
Command Interface (`lib/uci.inc`), straight into the REU: 2 MB in about
0.2 seconds instead of minutes.

1. Copy `build/<demo>.reu` to a USB stick, in the same folder as the demo
   (`build/<demo>.prg`, or its `.d64`/`.d81`).
2. In the Ultimate menu, under C64 and Cartridge Settings, turn the RAM
   Expansion Unit on with an REU Size of 2 MB or more, and set Command
   Interface to Enabled.
3. Run the demo from the file browser.

The demo looks for `<demo>.reu` in the Ultimate's current DOS directory,
then in its home directory. If UCI is off, the file is in neither, or the
load is incomplete, it falls back to loading `<demo>.dat` with the KERNAL.
`tests/hw/run_uci_loader.py` checks both cases on a networked Ultimate
(passed on an Ultimate 64 Elite, firmware 3.15a). Not yet checked: that
the current DOS directory follows the file browser when a program is
started from it (the remote test sets it with CHANGE_DIR).

Without UCI, the file browser's "Load into REU" on `<demo>.reu` does the
same by hand, and REU Preload does it on every power-on; the demo then
finds its signature at `$1FFFF0` and starts at once.

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
- `bigworld`'s music is 312 KB of SID register frames in XRAM (25
  registers a frame, padded to 32 bytes so a frame never crosses an 8 KB
  page): six sections, one for each scene, composed by hand in
  `music/world*.mus` for the TimeWarrior project's SID player and its
  instrument bank (`music/instruments.txt`, `../tools/sound/musfmt.py`).
  `../tools/sound/sidplay.py`, that player in Python, turns each into its
  frames; it matches the 6502 player register for register (checked on
  TimeWarrior's tunes in VICE). Each frame the demo points XRAM window 1
  at the frame's page and copies 25 bytes to the SID; a new scene's section
  starts at the next bar line. On NTSC it plays 20% fast.
  `../tools/sound/render_wav.py` records a stream in VICE, to listen to.
- `blitter`'s soundtrack (`music/blitter.mus`, 32 bars in A minor at
  125 BPM: bouncing octave bass, drums with chord arpeggios between the
  hits, three leads) is rendered the same way to 96 KB and loops. A raster
  IRQ at line 234 plays a frame, so the music keeps time when a scene drops
  to 25 fps; the same IRQ makes the lists scene's split, writing VICX_CTRL
  first so the write lands before line 235.
- `desktop`: move the pointer with a 1351 mouse in either port (on the
  MiSTer, set Pot 1/2 or Pot 3/4 to Mouse; until the mouse moves, the demo
  reads both ports in turn) or a joystick in port 2; the left button or
  fire clicks. Double-click an icon to open its window (Trash closes them
  all), drag a window by its title bar, click the box at the left of the
  title to close it, click a window to bring it to the front, click a menu
  title and then an item (View changes the wallpaper). An Amiga mouse does
  not work: it needs a 1351 adapter. A test build
  (`VICX_DEMO_DEFS=DESK_TEST python build.py desktop`) plays a script that
  does all of this, for checking it in headless VICE. The desktop, the
  windows and the menus are pictures in XRAM; a change marks a rectangle
  dirty, and each frame the hidden buffer's dirty rectangle is redrawn
  (desktop, then the windows from the back, clipped) and shown at the next
  frame, so nothing half-drawn is ever seen. On a MiSTer core from before 2026-11-17, DMA during the display
  made the bitmap layer miss fetches (black lines); build with
  `VICX_DEMO_DEFS=BORDER_BLIT` for such a core, and the blitter only runs
  while the beam is outside the display window. Where the front window
  covers the dirty rectangle, nothing under it is drawn. The menu bar shows the redraw rate
  ("50 fps" when every redraw is shown the next frame,
  "--" while nothing changes). The buttons and the mouse are
  read while the CPU waits for the frame or the blitter, so short clicks
  count and the 1351's 6-bit counters do not wrap between reads; two mouse
  counts move the pointer one pixel. Its program is longer than the others, so it moves the loader's
  buffer (`LD_IN`) up to `$3800`; `lib/demo.inc` stops the link if a
  program reaches `LD_IN`. `tests/fastload_check.py` reports XRAM
  differences for it, because the demo writes its text into XRAM after
  loading; stopped at `ld_done`, XRAM matches `desktop.reu`.
- Not built: "Nothing breaks" (needs well-known games and demos;
  `tests/stock-compat.py` covers VICE's own VIC-II test programs meanwhile).
