# Tools

Developer tools for VIC-X. Python 3, standard library only.

| Tool | What it does |
|------|--------------|
| `png2vicx.py` | PNG to VIC-X data: 8- or 4-bit bitmaps, 8x8 or 16x16 tiles with a map, sprite patterns, palettes and palette fade levels |
| `gen_art.py`  | generates the demo artwork as PNGs |
| `pngio.py`    | the PNG reader and writer both use |

## png2vicx

    python png2vicx.py picture.png --mode bitmap8 -o out/picture --palbase 16 --colours 240 --fades 16
    python png2vicx.py level.png --mode tiles8 --tile 8 -o out/level --palbase 16 --colours 96
    python png2vicx.py hero.png --mode sprites4 --sprite 16x16 --bank 3 -o out/hero

- Pixels with alpha below 128 become colour 0, which VIC-X draws as
  transparent. Other colours go into palette entries from `--palbase`
  (8-bit modes) or into one palette bank (`--bank`, 4-bit modes). More
  colours than fit are reduced with a median cut, without dithering.
- Tiles: identical tiles, and tiles that are X/Y-flipped copies of others,
  are stored once; the map (2 bytes per entry) is padded to 32, 64, 128 or
  256 tiles each way. Tile 0 is the empty, transparent tile.
- Output: `.pix`, `.tiles` + `.map`, or `.spr`, plus `.pal` (4 bytes per
  palette entry used, to be copied to `$20000 + 4 * palbase`) and, with
  `--fades N`, `.fades` (N copies of the palette, black to full colour).

Run `python png2vicx.py --help` for all options. `../demos/build.py` shows
how the outputs are packed into an REU image and loaded with DMA.
