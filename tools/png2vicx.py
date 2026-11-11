#!/usr/bin/env python3
"""png2vicx - convert a PNG into VIC-X bitmaps, tiles, sprites and palettes.

Pixels with alpha below 128 become colour 0, which VIC-X draws as
transparent.  The other colours go into palette entries from --palbase
upwards; with more colours than --colours, a median cut reduces them.

Modes and output files (prefix from -o):
  bitmap8   PREFIX.pix   one byte per pixel, rows top to bottom
  bitmap4   PREFIX.pix   two pixels per byte, high nibble left; --bank
  tiles8    PREFIX.tiles + PREFIX.map   8x8 or 16x16 tiles (--tile),
  tiles4    duplicates (also X/Y-flipped ones) merged; the map is 2 bytes
            per entry, padded to 32/64/128/256 tiles; tile 0 is transparent
  sprites8  PREFIX.spr   frames of --sprite WxH, left to right, top to bottom
  sprites4  PREFIX.spr   the same at 4 bits per pixel; --bank

Always:     PREFIX.pal   4 bytes (R, G, B, 0) per entry used, starting at
                         palette entry --palbase: copy it to $20000 + 4 *
                         palbase
With --fades N: PREFIX.fades  N copies of PREFIX.pal from black (level 0)
                         to full colour (level N-1)

In 4-bit modes the colours go into one palette bank: entries bank * 16 + 1
to bank * 16 + 15 (--palbase and --colours are set from --bank).
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio  # noqa: E402


# ------------------------------------------------------------------ colours

def median_cut(colours, n):
    """colours: {rgb: count}.  Returns up to n representative colours."""
    boxes = [list(colours.items())]
    while len(boxes) < n:
        # split the box with the widest channel range (weighted by size)
        best, best_score, best_ch = None, -1, 0
        for i, box in enumerate(boxes):
            if len(box) < 2:
                continue
            for ch in range(3):
                vals = [c[0][ch] for c in box]
                score = (max(vals) - min(vals)) * len(box)
                if score > best_score:
                    best, best_score, best_ch = i, score, ch
        if best is None:
            break
        box = sorted(boxes.pop(best), key=lambda c: c[0][best_ch])
        total = sum(c[1] for c in box)
        acc, cut = 0, 1
        for j, c in enumerate(box):
            acc += c[1]
            if acc >= total / 2:
                cut = max(1, min(len(box) - 1, j + 1))
                break
        boxes += [box[:cut], box[cut:]]
    out = []
    for box in boxes:
        total = sum(c[1] for c in box)
        out.append(tuple(round(sum(c[0][ch] * c[1] for c in box) / total) for ch in range(3)))
    return out


def build_palette(rows, ncolours):
    counts = {}
    for row in rows:
        for (r, g, b, a) in row:
            if a >= 128:
                counts[(r, g, b)] = counts.get((r, g, b), 0) + 1
    if len(counts) <= ncolours:
        pal = sorted(counts)
    else:
        pal = median_cut(counts, ncolours)
        print(f"  {len(counts)} colours reduced to {len(pal)}", file=sys.stderr)
    return pal


def index_image(rows, pal, base):
    cache = {}
    exact = {c: i for i, c in enumerate(pal)}

    def nearest(c):
        if c in exact:
            return exact[c]
        if c not in cache:
            cache[c] = min(range(len(pal)),
                           key=lambda i: sum((c[k] - pal[i][k]) ** 2 for k in range(3)))
        return cache[c]

    return [[0 if a < 128 else base + nearest((r, g, b)) for (r, g, b, a) in row] for row in rows]


def pal_bytes(pal, level=1.0):
    out = bytearray()
    for (r, g, b) in pal:
        out += bytes((round(r * level), round(g * level), round(b * level), 0))
    return out


# ------------------------------------------------------------------ packing

def pack4(values, bank):
    """values: palette indices (0 or bank*16+n) -> nibbles, high nibble left."""
    out = bytearray()
    for i in range(0, len(values), 2):
        a, b = values[i], values[i + 1]
        out.append(((a & 15) << 4) | (b & 15))
    return out


def map_size(n):
    for s in (32, 64, 128, 256):
        if n <= s:
            return s
    raise SystemExit(f"map of {n} tiles is wider than 256")


def tiles(img, w, h, ts, bpp4, bank):
    if w % ts or h % ts:
        raise SystemExit(f"image size {w}x{h} is not a multiple of the tile size {ts}")
    tw, th = w // ts, h // ts
    mw, mh = map_size(tw), map_size(th)
    found = {}                  # pixels -> (tile number, flags)
    data = []
    blank = tuple([0] * (ts * ts))
    found[blank] = (0, 0)
    data.append(blank)
    tmap = [[0] * mw for _ in range(mh)]
    for ty in range(th):
        for tx in range(tw):
            px = [img[ty * ts + y][tx * ts + x] for y in range(ts) for x in range(ts)]
            key = tuple(px)
            if key not in found:
                rows = [px[y * ts:(y + 1) * ts] for y in range(ts)]
                variants = {
                    0x0400: tuple(v for r in rows for v in reversed(r)),
                    0x0800: tuple(v for r in reversed(rows) for v in r),
                    0x0C00: tuple(v for r in reversed(rows) for v in reversed(r)),
                }
                hit = None
                for flags, var in variants.items():
                    if var in found and found[var][1] == 0:
                        hit = (found[var][0], flags)
                        break
                if hit is None:
                    hit = (len(data), 0)
                    data.append(key)
                found[key] = hit
            num, flags = found[key]
            tmap[ty][tx] = num | flags | ((bank << 12) if bpp4 else 0)
    if len(data) > 1024:
        raise SystemExit(f"{len(data)} tiles: more than 1024")
    tbytes = bytearray()
    for t in data:
        tbytes += pack4(t, bank) if bpp4 else bytes(t)
    mbytes = bytearray()
    for row in tmap:
        for e in row:
            mbytes += bytes((e & 0xFF, e >> 8))
    return tbytes, mbytes, len(data), mw, mh


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("png")
    ap.add_argument("-o", "--out", required=True, help="output prefix")
    ap.add_argument("--mode", required=True,
                    choices=["bitmap8", "bitmap4", "tiles8", "tiles4", "sprites8", "sprites4"])
    ap.add_argument("--tile", type=int, default=8, choices=[8, 16])
    ap.add_argument("--sprite", default="16x16", help="sprite frame size, WxH (8, 16, 32 or 64 each)")
    ap.add_argument("--palbase", type=int, default=16, help="first palette entry (8-bit modes)")
    ap.add_argument("--colours", type=int, default=None, help="colours to use (8-bit modes)")
    ap.add_argument("--bank", type=int, default=1, help="palette bank (4-bit modes)")
    ap.add_argument("--fades", type=int, default=0, help="also write N palette fade levels")
    args = ap.parse_args()

    w, h, rows = pngio.read(args.png)
    bpp4 = args.mode.endswith("4")
    if bpp4:
        if not 1 <= args.bank <= 15:
            raise SystemExit("--bank must be 1-15 (bank 0 holds the VIC-II colours)")
        base, ncol = args.bank * 16 + 1, 15
    else:
        base = args.palbase
        ncol = args.colours if args.colours else 256 - base
        if base < 1 or base + ncol > 256:
            raise SystemExit("palette range must lie within entries 1-255")
    pal = build_palette(rows, ncol)
    img = index_image(rows, pal, base)
    flat = [v for row in img for v in row]

    info = [f"{args.png}: {w}x{h}, {len(pal)} colours at palette entry {base}"]
    if args.mode.startswith("bitmap"):
        data = pack4(flat, args.bank) if bpp4 else bytes(flat)
        open(args.out + ".pix", "wb").write(data)
        info.append(f"{len(data)} bytes of pixels")
    elif args.mode.startswith("tiles"):
        tb, mb, n, mw, mh = tiles(img, w, h, args.tile, bpp4, args.bank)
        open(args.out + ".tiles", "wb").write(tb)
        open(args.out + ".map", "wb").write(mb)
        info.append(f"{n} tiles ({len(tb)} bytes), map {mw}x{mh} ({len(mb)} bytes)")
    else:
        sw, sh = (int(v) for v in args.sprite.lower().split("x"))
        if sw not in (8, 16, 32, 64) or sh not in (8, 16, 32, 64):
            raise SystemExit("sprite sizes are 8, 16, 32 or 64")
        out = bytearray()
        frames = 0
        for fy in range(h // sh):
            for fx in range(w // sw):
                px = [img[fy * sh + y][fx * sw + x] for y in range(sh) for x in range(sw)]
                out += pack4(px, args.bank) if bpp4 else bytes(px)
                frames += 1
        open(args.out + ".spr", "wb").write(out)
        info.append(f"{frames} frames of {sw}x{sh} ({len(out)} bytes)")

    open(args.out + ".pal", "wb").write(pal_bytes(pal))
    if args.fades:
        fades = bytearray()
        for k in range(args.fades):
            fades += pal_bytes(pal, k / (args.fades - 1))
        open(args.out + ".fades", "wb").write(fades)
        info.append(f"{args.fades} fade levels")
    print(", ".join(info))


if __name__ == "__main__":
    main()
