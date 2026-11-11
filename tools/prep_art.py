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

Landscapes are made seamless by appending a mirrored copy; png2vicx stores
the mirrored tiles as flipped copies, so this costs map space only.
Needs Pillow.
"""

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


def key_magenta(img):
    """RGB -> RGBA with the magenta background transparent."""
    out = img.convert("RGBA")
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, _ = px[x, y]
            if r > 170 and b > 170 and g < 110:
                px[x, y] = (0, 0, 0, 0)
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
    """Snap pixels close to their row's median colour onto it.  Removes the
    small noise in gradients that would make every tile unique."""
    img = img.convert("RGB")
    px = img.load()
    w, h = img.size
    for y in range(h):
        row = [px[x, y] for x in range(w)]
        med = tuple(sorted(c[k] for c in row)[w // 2] for k in range(3))
        for x in range(w):
            if sum(abs(row[x][k] - med[k]) for k in range(3)) <= threshold:
                px[x, y] = med
    return img


def mirror_wrap(img):
    out = Image.new(img.mode, (img.width * 2, img.height))
    out.paste(img, (0, 0))
    out.paste(img.transpose(Image.FLIP_LEFT_RIGHT), (img.width, 0))
    return out


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

    save(quantise(fit(load(raw, "space.jpg"), 320, 200), 192, True), "space.png")
    for i in range(4):
        save(quantise(fit(load(raw, f"gallery{i}.jpg"), 320, 200), 240, True), f"gallery{i}.png")


if __name__ == "__main__":
    main()
