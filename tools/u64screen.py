#!/usr/bin/env python3
"""Render an Ultimate 64's text screen to PNG from its memory (REST API).

    python u64screen.py <u64 host> out.png [--text]

Reads the VIC-II registers, $DD00, screen RAM and colour RAM with
/v1/machine:readmem and draws the 40x25 text screen with a 32-pixel border
(hires and extended-colour text; multicolour text is drawn as hires).
It needs no video stream, so it works through a firewall, but it shows
only text mode: bitmaps and sprites are not drawn. --text also prints the
screen as ASCII.

Only side-effect-free addresses are read: never $D019/$D01E/$D01F or the
CIA interrupt registers, whose reads clear state.
"""
import argparse
import os
import sys
import urllib.request

from pngio import write as write_png
from u64grab import PALETTE

HERE = os.path.dirname(os.path.abspath(__file__))
CHARGEN = os.environ.get(
    "VICX_CHARGEN",
    os.path.join(HERE, "..", "..", "vice-vicx", "vice", "data", "C64", "chargen-901225-01.bin"))


def readmem(host, addr, length):
    url = f"http://{host}/v1/machine:readmem?address={addr:04X}&length={length}"
    with urllib.request.urlopen(url, timeout=5) as r:
        data = r.read()
    if len(data) != length:
        raise SystemExit(f"readmem ${addr:04X}: got {len(data)} bytes, wanted {length}")
    return data


def screen_codes_to_ascii(codes):
    out = []
    for c in codes:
        c &= 0x7F
        if c == 0:
            out.append("@")
        elif 1 <= c <= 26:
            out.append(chr(ord("A") + c - 1))
        elif 27 <= c <= 63:
            out.append(chr(c) if c >= 32 else "[\\]^_"[c - 27])
        else:
            out.append(".")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host")
    ap.add_argument("out")
    ap.add_argument("--text", action="store_true")
    a = ap.parse_args()

    vic = readmem(a.host, 0xD011, 8)          # $D011-$D018
    d011, d016, d018 = vic[0], vic[5], vic[7]
    cols = readmem(a.host, 0xD020, 5)         # $D020-$D024
    dd00 = readmem(a.host, 0xDD00, 1)[0]
    bank = (3 - (dd00 & 3)) * 0x4000
    screen = bank + ((d018 >> 4) & 15) * 0x400
    charbase = bank + ((d018 >> 1) & 7) * 0x800
    codes = readmem(a.host, screen, 1000)
    colour = readmem(a.host, 0xD800, 1000)
    if (bank in (0x0000, 0x8000)) and (charbase & 0x3FFF) in (0x1000, 0x1800):
        with open(CHARGEN, "rb") as fh:
            rom = fh.read()
        chars = rom[(charbase & 0x0800):(charbase & 0x0800) + 0x800]
    else:
        chars = readmem(a.host, charbase, 0x800)

    ecm = bool(d011 & 0x40)
    bitmap = bool(d011 & 0x20)
    blank = not (d011 & 0x10)
    W, H, B = 384, 272, 32
    TOP = (H - 200) // 2
    border = PALETTE[cols[0] & 15]
    rows = [[border] * W for _ in range(H)]
    if not blank and not bitmap:
        for cy in range(25):
            for cx in range(40):
                i = cy * 40 + cx
                code = codes[i]
                bg = cols[1] & 15
                if ecm:
                    bg = cols[1 + (code >> 6)] & 15
                    code &= 0x3F
                fg = PALETTE[colour[i] & 15]
                bgc = PALETTE[bg]
                glyph = chars[code * 8:code * 8 + 8]
                for py in range(8):
                    bits = glyph[py]
                    row = rows[TOP + cy * 8 + py]
                    for px in range(8):
                        row[B + cx * 8 + px] = fg if bits & (0x80 >> px) else bgc
    write_png(a.out, W, H, rows)
    mode = "blanked" if blank else "bitmap (not drawn)" if bitmap else "text"
    print(f"{a.out}: screen ${screen:04X}, chars ${charbase:04X}, {mode}")
    if a.text:
        for cy in range(25):
            print(screen_codes_to_ascii(codes[cy * 40:cy * 40 + 40]).rstrip())


if __name__ == "__main__":
    sys.exit(main())
