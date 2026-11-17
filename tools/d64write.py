#!/usr/bin/env python3
"""d64write - write a 1541 disk image (.d64) with a chosen interleave per file.

The demos' data file is read by the fast loader (demos/lib/fastload.inc),
which reads a sector, sends it to the C64, then asks for the next; the
standard interleave (10) makes the drive miss that sector and wait a whole
turn of the disk, so the data file gets a wider interleave.

write(path, disk_name, disk_id, files): files are (name, kind, data,
interleave) with kind "prg" or "seq"; interleave is a number of sectors, or
a time in ms ("124ms": the sectors that pass in that time on each track,
which has 17-21 sectors a turn at 300 rpm).  Names are PETSCII as given
(upper case ASCII letters show as upper case on the C64).  Files are placed
from track 17 down to 1, then 19 up to 35, the way CBM DOS does.
"""

import sys

SPT = [0] + [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5
TRACKS = 35
DIR_TRACK = 18


def offset(t, s):
    return (sum(SPT[1:t]) + s) * 256


def write(path, disk_name, disk_id, files):
    img = bytearray(sum(SPT[1:]) * 256)
    used = {t: set() for t in range(1, TRACKS + 1)}
    used[DIR_TRACK] |= {0, 1}
    order = list(range(17, 0, -1)) + list(range(19, TRACKS + 1))
    entries = []
    for name, kind, data, inter in files:
        nsec = max(1, (len(data) + 253) // 254)
        chain = []
        ti = 0
        s = 0
        for _ in range(nsec):
            while len(used[order[ti]]) >= SPT[order[ti]]:
                ti += 1
                s = 0
                if ti >= len(order):
                    raise ValueError("disk full")
            t = order[ti]
            if chain and chain[-1][0] == t:
                step = inter
                if isinstance(inter, str):           # a time: whole sectors
                    ms = float(inter.rstrip("ms"))
                    step = -(-int(ms * SPT[t]) // 200)
                s = (chain[-1][1] + step) % SPT[t]
            while s in used[t]:
                s = (s + 1) % SPT[t]
            used[t].add(s)
            chain.append((t, s))
        for k, (t, s) in enumerate(chain):
            part = data[k * 254:(k + 1) * 254]
            o = offset(t, s)
            if k + 1 < len(chain):
                img[o], img[o + 1] = chain[k + 1]
            else:
                img[o], img[o + 1] = 0, len(part) + 1
            img[o + 2:o + 2 + len(part)] = part
        entries.append((name, {"prg": 0x82, "seq": 0x81}[kind], chain[0], nsec))

    # directory, from 18/1
    if len(entries) > 8:
        raise ValueError("more than 8 files")
    o = offset(DIR_TRACK, 1)
    img[o], img[o + 1] = 0, 0xFF
    for k, (name, typ, (t, s), nsec) in enumerate(entries):
        e = o + 32 * k
        img[e + 2] = typ
        img[e + 3], img[e + 4] = t, s
        nm = name.encode("ascii")[:16].ljust(16, b"\xa0")
        img[e + 5:e + 21] = nm
        img[e + 30], img[e + 31] = nsec & 0xFF, nsec >> 8

    # BAM at 18/0
    o = offset(DIR_TRACK, 0)
    img[o:o + 4] = bytes((DIR_TRACK, 1, 0x41, 0))
    for t in range(1, TRACKS + 1):
        free = [s for s in range(SPT[t]) if s not in used[t]]
        bits = sum(1 << s for s in free)
        img[o + 4 * t:o + 4 * t + 4] = bytes((len(free), bits & 0xFF, (bits >> 8) & 0xFF, bits >> 16))
    img[o + 0x90:o + 0xAB] = b"\xa0" * 0x1B
    img[o + 0x90:o + 0x90 + 16] = disk_name.encode("ascii")[:16].ljust(16, b"\xa0")
    img[o + 0xA2:o + 0xA4] = disk_id.encode("ascii")[:2]
    img[o + 0xA5:o + 0xA7] = b"2A"
    with open(path, "wb") as f:
        f.write(img)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit("usage: d64write.py out.d64 'NAME' ID file.prg:NAME:prg:10 ...")
    fl = []
    for spec in sys.argv[4:]:
        fn, nm, kind, inter = spec.rsplit(":", 3)
        fl.append((nm, kind, open(fn, "rb").read(), inter if inter.endswith("ms") else int(inter)))
    write(sys.argv[1], sys.argv[2], sys.argv[3], fl)
