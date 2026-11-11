#!/usr/bin/env python3
"""gen_art - generate the demo artwork as PNGs (no outside assets).

  gen_art.py OUTDIR

writes parallax_back.png, parallax_front.png (512x200, seamless left to
right), ship.png (16x16), bullets.png (four 8x8 bullets)
and gallery0-3.png (320x200, at most 255 colours each).
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio  # noqa: E402

CLEAR = (0, 0, 0, 0)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def ramp(stops, n):
    """n colours along a list of (position 0-1, rgb) stops."""
    out = []
    for i in range(n):
        t = i / max(1, n - 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                out.append(lerp(c0, c1, (t - p0) / (p1 - p0) if p1 > p0 else 0))
                break
    return out


def periodic(x, terms, period=512):
    return sum(a * math.sin(2 * math.pi * (k * x / period) + ph) for (a, k, ph) in terms)


# ------------------------------------------------------------------ parallax

def parallax_back(w=512, h=200):
    sky = ramp([(0, (20, 24, 90)), (0.5, (90, 110, 200)), (1, (250, 170, 120))], 40)
    rock = ramp([(0, (60, 50, 90)), (1, (150, 120, 170))], 12)
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            ridge = 120 + periodic(x, [(22, 2, 0.3), (12, 5, 1.1), (6, 11, 2.0)])
            if y < ridge:
                row.append(sky[min(39, y * 40 // 150)] + (255,))
            else:
                depth = min(11, int((y - ridge) / 6))
                row.append(rock[11 - depth] + (255,))
        rows.append(row)
    return rows


def parallax_front(w=512, h=200):
    grass = ramp([(0, (40, 150, 50)), (1, (10, 70, 30))], 16)
    trunk = (90, 60, 30)
    leaf = ramp([(0, (30, 120, 40)), (1, (120, 210, 90))], 8)
    rows = [[CLEAR] * w for _ in range(h)]
    for x in range(w):
        top = 160 + periodic(x, [(10, 3, 0.0), (5, 8, 1.7)])
        for y in range(int(top), h):
            rows[y][x] = grass[min(15, (y - int(top)) // 3)] + (255,)
    for i in range(8):                  # trees, spaced to stay seamless
        cx = i * 64 + 20
        base = int(160 + periodic(cx, [(10, 3, 0.0), (5, 8, 1.7)]))
        for y in range(base - 12, base):
            for x in range(cx - 2, cx + 2):
                rows[y][x % w] = trunk + (255,)
        for y in range(base - 52, base - 10):
            half = (y - (base - 52)) * 14 // 42
            for x in range(cx - half, cx + half + 1):
                shade = leaf[min(7, (x - cx + half) * 8 // (2 * half + 1))]
                rows[y][x % w] = shade + (255,)
    return rows


# ------------------------------------------------------------------ sprites

def ship():
    """The player's ship, 16x16."""
    rows = [[CLEAR] * 16 for _ in range(16)]
    for y in range(16):
        half = y // 2
        for x in range(8 - half, 8 + half):
            rows[y][x] = lerp((80, 200, 255), (20, 60, 160), y / 15) + (255,)
    for x in (7, 8):
        for y in range(3, 9):
            rows[y][x] = (255, 255, 255, 255)
    return rows


def bullets():
    """Four round 8x8 bullets side by side."""
    rows = [[CLEAR] * 32 for _ in range(8)]
    colours = [(255, 80, 80), (255, 220, 60), (120, 255, 120), (230, 120, 255)]
    for i, c in enumerate(colours):
        for y in range(8):
            for x in range(8):
                d = math.hypot(x - 3.5, y - 3.5)
                if d <= 3.6:
                    rows[y][i * 8 + x] = lerp((255, 255, 255), c, min(1, d / 3)) + (255,)
    return rows


# ------------------------------------------------------------------ gallery

def mandelbrot(w=320, h=200):
    pal = ramp([(0, (0, 7, 100)), (0.16, (32, 107, 203)), (0.42, (237, 255, 255)),
                (0.64, (255, 170, 0)), (0.86, (0, 2, 0)), (1, (0, 7, 100))], 254)
    rows = []
    for py in range(h):
        row = []
        for px in range(w):
            x0 = -2.2 + px * 3.0 / w
            y0 = -1.0 + py * 2.0 / h
            x = y = 0.0
            i = 0
            while x * x + y * y < 16 and i < 96:
                x, y = x * x - y * y + x0, 2 * x * y + y0
                i += 1
            if i >= 96:
                row.append((0, 0, 0, 255))
            else:
                mu = i + 1 - math.log(math.log(math.sqrt(x * x + y * y)) / math.log(2)) / math.log(2)
                row.append(pal[int(mu * 6) % 254] + (255,))
        rows.append(row)
    return rows


def plasma(w=320, h=200):
    pal = ramp([(0, (40, 0, 80)), (0.25, (220, 40, 120)), (0.5, (255, 220, 80)),
                (0.75, (40, 200, 200)), (1, (40, 0, 80))], 255)
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            v = (math.sin(x / 23) + math.sin(y / 17) + math.sin((x + y) / 31)
                 + math.sin(math.hypot(x - 160, y - 100) / 13))
            row.append(pal[int((v + 4) / 8 * 254) % 255] + (255,))
        rows.append(row)
    return rows


def sunset(w=320, h=200):
    sky = ramp([(0, (30, 10, 70)), (0.6, (230, 80, 60)), (1, (255, 200, 90))], 100)
    sea = ramp([(0, (255, 170, 90)), (1, (10, 20, 60))], 100)
    sun = ramp([(0, (255, 255, 200)), (1, (255, 190, 80))], 40)
    horizon = 120
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            if y < horizon:
                d = math.hypot(x - 160, y - 100)
                c = sun[min(39, int(d))] if d < 34 else sky[y * 99 // horizon]
            else:
                ripple = (y - horizon) / (h - horizon)
                c = sea[min(99, int(ripple * 99))]
                if abs(x - 160) < 34 * (1 - ripple) and (y // 3) % 2 == 0:
                    c = sun[20]
            row.append(c + (255,))
        rows.append(row)
    return rows


def wheel(w=320, h=200):
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            dx, dy = x - 160, y - 100
            r = math.hypot(dx, dy)
            if r > 95:
                v = ((x // 20) + (y // 20)) % 2
                row.append(((40, 40, 50) if v else (25, 25, 32)) + (255,))
                continue
            hue = (math.atan2(dy, dx) / (2 * math.pi)) % 1
            sat = min(1, r / 95)
            hi = int(hue * 6)
            f = hue * 6 - hi
            q, t = 1 - f, f
            rgb = [(1, t, 0), (q, 1, 0), (0, 1, t), (0, q, 1), (t, 0, 1), (1, 0, q)][hi % 6]
            # quantise to 21 hues x 12 saturations = 252 colours
            hue_q = round(hue * 21) / 21
            hi = int(hue_q * 6) % 6
            f = hue_q * 6 - int(hue_q * 6)
            q, t = 1 - f, f
            rgb = [(1, t, 0), (q, 1, 0), (0, 1, t), (0, q, 1), (t, 0, 1), (1, 0, q)][hi]
            s = round(sat * 11) / 11
            row.append(tuple(round(255 * (1 - s + s * c)) for c in rgb) + (255,))
        rows.append(row)
    return rows


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    jobs = [("parallax_back", parallax_back, 512, 200), ("parallax_front", parallax_front, 512, 200),
            ("ship", ship, 16, 16), ("bullets", bullets, 32, 8), ("gallery0", mandelbrot, 320, 200),
            ("gallery1", plasma, 320, 200), ("gallery2", sunset, 320, 200),
            ("gallery3", wheel, 320, 200)]
    for name, fn, w, h in jobs:
        path = os.path.join(out, name + ".png")
        pngio.write(path, w, h, fn())
        print("wrote", path)


if __name__ == "__main__":
    main()
