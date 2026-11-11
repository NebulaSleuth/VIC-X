"""pngio - minimal PNG reading and writing with the standard library only.

read(path) -> (width, height, rows), where rows[y][x] is an (r, g, b, a)
tuple.  Reads 8-bit greyscale, grey+alpha, RGB, RGBA and palette images
(palette also at 1, 2 and 4 bits, with tRNS transparency); not interlaced.

write(path, width, height, rows) writes 8-bit RGBA.
"""

import struct
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _unfilter(raw, width, height, bpp, rowbytes):
    rows, prev, pos = [], bytearray(rowbytes), 0
    for _ in range(height):
        f = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + rowbytes])
        pos += 1 + rowbytes
        for i in range(rowbytes):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 0xFF
            elif f == 2:
                line[i] = (line[i] + b) & 0xFF
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 0xFF
            elif f != 0:
                raise ValueError(f"bad PNG filter {f}")
        rows.append(bytes(line))
        prev = line
    return rows


def read(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:8] != SIGNATURE:
        raise ValueError(f"{path}: not a PNG file")
    pos, idat, plte, trns = 8, b"", None, None
    width = height = depth = ctype = interlace = None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            plte = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if interlace:
        raise ValueError(f"{path}: interlaced PNGs are not supported")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype)
    if channels is None or (ctype != 3 and depth != 8) or (ctype == 3 and depth not in (1, 2, 4, 8)):
        raise ValueError(f"{path}: unsupported PNG (depth {depth}, colour type {ctype})")
    bits = depth * channels
    rowbytes = (width * bits + 7) // 8
    raw = zlib.decompress(idat)
    lines = _unfilter(raw, width, height, max(1, bits // 8), rowbytes)

    out = []
    for line in lines:
        row = []
        for x in range(width):
            if ctype == 3:
                if depth == 8:
                    i = line[x]
                else:
                    per = 8 // depth
                    i = (line[x // per] >> (8 - depth * (x % per + 1))) & ((1 << depth) - 1)
                r, g, b = plte[i]
                a = trns[i] if trns is not None and i < len(trns) else 255
            elif ctype == 0:
                r = g = b = line[x]
                a = 255
            elif ctype == 4:
                r = g = b = line[x * 2]
                a = line[x * 2 + 1]
            elif ctype == 2:
                r, g, b = line[x * 3:x * 3 + 3]
                a = 255
            else:
                r, g, b, a = line[x * 4:x * 4 + 4]
            row.append((r, g, b, a))
        out.append(row)
    return width, height, out


def write(path, width, height, rows):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for (r, g, b, a) in rows[y]:
            raw += bytes((r, g, b, a))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    png = SIGNATURE
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)
