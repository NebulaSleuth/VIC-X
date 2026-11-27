#!/usr/bin/env python3
"""prep_art - turn the generated demo pictures into VIC-X-ready PNGs.

  prep_art.py RAWDIR OUTDIR

Reads the raw pictures (from nanobanana.py) in RAWDIR and writes PNGs sized
and coloured for the demos to OUTDIR, ready for png2vicx.py:

  parallax_back.png   1024x200, 96 colours, no dithering, gradients flattened
                      per row (tile friendly)
  parallax_front.png  1024x200, 96 colours, magenta keyed out (transparent)
  ship.png            32x32, 24 colours, magenta keyed out
  space.png           320x200, 192 colours, dithered
  gallery0-3.png      320x200, 240 colours, dithered
  desktop_photo.png   160x100, 160 colours, dithered (gallery1 again)
  parallax_*_wide.png 1024x272, the landscapes again at full-frame height
  bigworld.png        320 wide, the six world*.jpg stacked top to bottom with
                      48-row blends, 240 colours, dithered; bigworld.json
                      gives the row each scene starts at
  sixteen_stock.bin   a C64 multicolour bitmap of sixteen.jpg in the stock
  sixteen_custom.bin  palette, and in 16 colours chosen for the picture
                      (+ sixteen_custom.pal, and *_preview.png of both)

Landscapes are made seamless by appending a mirrored copy; png2vicx stores
the mirrored tiles as flipped copies, so this costs map space only.
Needs Pillow.
"""

import json
import os
import sys

from PIL import Image


def load(raw, name):
    return Image.open(os.path.join(raw, name)).convert("RGB")


def fit(img, w, h, anchor="centre"):
    """Scale to cover w x h, then crop (anchor: centre or bottom)."""
    s = max(w / img.width, h / img.height)
    img = img.resize((max(w, round(img.width * s)), max(h, round(img.height * s))), Image.LANCZOS)
    x = (img.width - w) // 2
    y = img.height - h if anchor == "bottom" else (img.height - h) // 2
    return img.crop((x, y, x + w, y + h))


def key_magenta(img, cut=40):
    """RGB -> RGBA with the magenta background transparent.

    Spill = how far both red and blue exceed green; magenta has a lot, the
    foreground none.  Pixels with spill above `cut' (the background and the
    edge pixels the JPEG blended into it) become transparent; the rest lose
    their spill, so no pink tint is left along the edges."""
    out = img.convert("RGBA")
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, _ = px[x, y]
            spill = min(r, b) - g
            if spill > cut:
                px[x, y] = (0, 0, 0, 0)
            elif spill > 0:
                px[x, y] = (r - spill, g, b - spill, 255)
    return out


def shrink_rgba(img, w, h):
    """Resize with premultiplied alpha, then make alpha hard (0 or 255)."""
    small = img.convert("RGBa").resize((w, h), Image.BOX).convert("RGBA")
    px = small.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            px[x, y] = (r, g, b, 255) if a >= 128 else (0, 0, 0, 0)
    return small


def quantise(img, colours, dither):
    """Reduce the opaque colours; transparent pixels stay transparent."""
    rgba = img.convert("RGBA")
    alpha = rgba.getchannel("A")
    q = rgba.convert("RGB").quantize(colours, method=Image.Quantize.MEDIANCUT,
                                     dither=Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE)
    out = q.convert("RGBA")
    out.putalpha(alpha.point(lambda a: 255 if a >= 128 else 0))
    return out


def flatten_rows(img, threshold=30):
    """Snap pixels close to their row's main colour onto it.  Removes the
    small noise in gradients that would make every tile unique.

    The main colour is the median of the row's largest group of alike
    pixels, not of the whole row: where two areas share a row about half
    and half, the median of all pixels is a colour between the two, and a
    row snapped to that shows as a line through the picture."""
    img = img.convert("RGB")
    px = img.load()
    w, h = img.size
    for y in range(h):
        row = [px[x, y] for x in range(w)]
        bins = {}
        for c in row:
            bins.setdefault((c[0] >> 4, c[1] >> 4, c[2] >> 4), []).append(c)
        top = max(bins.values(), key=len)
        mid = tuple(sorted(c[k] for c in top)[len(top) // 2] for k in range(3))
        group = [c for c in row if sum(abs(c[k] - mid[k]) for k in range(3)) <= threshold]
        if not group:               # a small threshold can leave nothing near the median: keep the row
            continue
        med = tuple(sorted(c[k] for c in group)[len(group) // 2] for k in range(3))
        for x in range(w):
            if sum(abs(row[x][k] - med[k]) for k in range(3)) <= threshold:
                px[x, y] = med
    return img


def mirror_wrap(img):
    out = Image.new(img.mode, (img.width * 2, img.height))
    out.paste(img, (0, 0))
    out.paste(img.transpose(Image.FLIP_LEFT_RIGHT), (img.width, 0))
    return out


# The C64 colours as VICE 3.10 shows them by default (its internal palette,
# measured from a screenshot of colour bars 0-15).  Real machines and other
# palette settings differ.
C64_PALETTE = [
    (0, 0, 0), (255, 255, 255), (175, 60, 88), (126, 243, 214),
    (170, 64, 245), (98, 213, 50), (44, 61, 236), (255, 255, 70),
    (183, 99, 30), (119, 83, 0), (238, 123, 149), (98, 98, 98),
    (148, 148, 148), (183, 255, 134), (115, 133, 255), (205, 205, 205),
]


def big_world(raw, names, width=320, fade=48):
    """Stack tall pictures into one strip, blending each join over `fade' rows."""
    parts = []
    for n in names:
        im = load(raw, n)
        parts.append(im.resize((width, round(im.height * width / im.width)), Image.LANCZOS))
    height = sum(p.height for p in parts) - fade * (len(parts) - 1)
    strip = Image.new("RGB", (width, height))
    starts, y = [], 0
    for i, p in enumerate(parts):
        if i == 0:
            strip.paste(p, (0, 0))
        else:
            y -= fade
            for r in range(fade):         # blend the overlap row by row
                t = (r + 0.5) / fade
                a = strip.crop((0, y + r, width, y + r + 1))
                b = p.crop((0, r, width, r + 1))
                strip.paste(Image.blend(a, b, t), (0, y + r))
            strip.paste(p.crop((0, fade, width, p.height)), (0, y + fade))
        starts.append(y)
        y += p.height
    return strip, starts


def c64_multicolour(img, palette):
    """160x200 multicolour bitmap: per 4x8 cell the background colour plus
    three of its own; Floyd-Steinberg within those choices.  Returns
    (bitmap 8000, screen 1000, colour 1000, background) and a preview."""
    small = fit(img, 320, 200).resize((160, 200), Image.LANCZOS)
    src = [[list(small.getpixel((x, y))) for x in range(160)] for y in range(200)]

    def nearest(c, choices):
        return min(choices, key=lambda i: sum((c[k] - palette[i][k]) ** 2 for k in range(3)))

    everything = list(range(len(palette)))
    # distance of every pixel to every colour, and each pixel's nearest colour
    dist = [[[sum((c[k] - palette[i][k]) ** 2 for k in range(3)) for i in everything]
             for c in row] for row in src]
    near = [[min(everything, key=lambda i: d[i]) for d in row] for row in dist]

    def cell_choice(cx, cy, bg):
        hist = [0] * len(palette)
        for y in range(cy * 8, cy * 8 + 8):
            for x in range(cx * 4, cx * 4 + 4):
                hist[near[y][x]] += 1
        hist[bg] = -1
        return sorted(everything, key=lambda i: -hist[i])[:3]

    # the background is shared by every cell: try each colour, keep the best
    best = None
    for bg in everything:
        err = 0
        for cy in range(25):
            for cx in range(40):
                choices = [bg] + cell_choice(cx, cy, bg)
                for y in range(cy * 8, cy * 8 + 8):
                    for x in range(cx * 4, cx * 4 + 4):
                        err += min(dist[y][x][i] for i in choices)
        if best is None or err < best[0]:
            best = (err, bg)
    bg = best[1]
    cells = {(cx, cy): cell_choice(cx, cy, bg) for cy in range(25) for cx in range(40)}

    out = [[0] * 160 for _ in range(200)]
    for y in range(200):
        for x in range(160):
            cell = cells[(x // 4, y // 8)]
            choices = [bg] + cell
            c = src[y][x]
            i = nearest(c, choices)
            out[y][x] = choices.index(i)
            err = [c[k] - palette[i][k] for k in range(3)]
            for dx, dy, w in ((1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)):
                if 0 <= x + dx < 160 and y + dy < 200:
                    for k in range(3):
                        src[y + dy][x + dx][k] += err[k] * w / 16

    bitmap, screen, colour = bytearray(), bytearray(), bytearray()
    for cy in range(25):
        for cx in range(40):
            c1, c2, c3 = cells[(cx, cy)]
            screen.append((c1 << 4) | c2)
            colour.append(c3)
            for y in range(cy * 8, cy * 8 + 8):
                b = 0
                for x in range(cx * 4, cx * 4 + 4):
                    b = (b << 2) | out[y][x]
                bitmap.append(b)
    preview = Image.new("RGB", (320, 200))
    for y in range(200):
        for x in range(160):
            cell = cells[(x // 4, y // 8)]
            rgb = palette[([bg] + cell)[out[y][x]]]
            preview.putpixel((2 * x, y), rgb)
            preview.putpixel((2 * x + 1, y), rgb)
    return bytes(bitmap) + bytes(screen) + bytes(colour) + bytes([bg]), preview


def main():
    raw, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)

    def save(img, name):
        path = os.path.join(out, name)
        img.save(path)
        print("wrote", path, img.size)

    back = fit(load(raw, "parallax_back.jpg"), 512, 200, "bottom")
    save(mirror_wrap(quantise(flatten_rows(back), 96, False)), "parallax_back.png")

    front = key_magenta(load(raw, "parallax_front.jpg"))
    s = 512 / front.width
    front = shrink_rgba(front, 512, round(front.height * s))
    front = front.crop((0, front.height - 200, 512, front.height))
    save(mirror_wrap(quantise(front, 96, False)), "parallax_front.png")

    ship = key_magenta(load(raw, "ship.jpg"))
    bbox = ship.getchannel("A").getbbox()
    ship = ship.crop(bbox)
    side = max(ship.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(ship, ((side - ship.width) // 2, (side - ship.height) // 2))
    save(quantise(shrink_rgba(square, 32, 32), 24, False), "ship.png")

    # the landscapes again, tall enough to fill a widened window
    back = fit(load(raw, "parallax_back.jpg"), 512, 272, "bottom")
    save(mirror_wrap(quantise(flatten_rows(back), 96, False)), "parallax_back_wide.png")
    front = key_magenta(load(raw, "parallax_front.jpg"))
    s = 272 / front.height
    front = shrink_rgba(front, round(front.width * s), 272)
    # Both crop edges must fall in open sky: mirror_wrap reflects each edge onto
    # itself, so a tree cut there becomes a trunkless tree split at the tip.
    x = 12
    front = front.crop((x, 0, x + 512, 272))
    save(mirror_wrap(quantise(front, 96, False)), "parallax_front_wide.png")

    save(quantise(fit(load(raw, "space.jpg"), 320, 200), 192, True), "space.png")

    world, starts = big_world(raw, [f"world{i}.jpg" for i in range(6)])
    save(quantise(world, 240, True), "bigworld.png")
    with open(os.path.join(out, "bigworld.json"), "w") as fh:
        json.dump({"rows": world.height, "starts": starts}, fh)

    sixteen = load(raw, "sixteen.jpg")
    data, preview = c64_multicolour(sixteen, C64_PALETTE)
    open(os.path.join(out, "sixteen_stock.bin"), "wb").write(data)
    save(preview, "sixteen_stock_preview.png")
    pal = fit(sixteen, 160, 200).quantize(16, method=Image.Quantize.MEDIANCUT).getpalette()[:48]
    custom = [tuple(pal[i:i + 3]) for i in range(0, 48, 3)]
    custom.sort(key=lambda c: sum(c))   # darkest first: colour 0 is the border
    data, preview = c64_multicolour(sixteen, custom)
    open(os.path.join(out, "sixteen_custom.bin"), "wb").write(data)
    open(os.path.join(out, "sixteen_custom.pal"), "wb").write(bytes(v for c in custom for v in (*c, 0)))
    save(preview, "sixteen_custom_preview.png")
    for i in range(4):
        save(quantise(fit(load(raw, f"gallery{i}.jpg"), 320, 200), 240, True), f"gallery{i}.png")
    # the desktop demo's photo window
    save(quantise(fit(load(raw, "gallery1.jpg"), 160, 100), 160, True), "desktop_photo.png")


if __name__ == "__main__":
    main()
