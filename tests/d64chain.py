#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Michael Hartman

"""Print the track/sector chain of each file on a .d64 or .d81 image."""

import sys

SPT64 = [0] + [21] * 17 + [19] * 7 + [18] * 6 + [17] * 10


def offset(kind, t, s):
    if kind == "d81":
        return ((t - 1) * 40 + s) * 256
    return (sum(SPT64[1:t]) + s) * 256


def main(path):
    d = open(path, "rb").read()
    kind = "d81" if path.lower().endswith(".d81") else "d64"
    t, s = (40, 3) if kind == "d81" else (18, 1)
    while t:
        sec = d[offset(kind, t, s):offset(kind, t, s) + 256]
        for e in range(8):
            ent = sec[e * 32:(e + 1) * 32]
            if ent[2]:
                name = ent[5:21].rstrip(b"\xa0").decode("latin-1")
                ft, fs = ent[3], ent[4]
                chain = []
                while ft and len(chain) < 4000:
                    chain.append((ft, fs))
                    o = offset(kind, ft, fs)
                    ft, fs = d[o], d[o + 1]
                steps = [(b[1] - a[1]) for a, b in zip(chain, chain[1:]) if a[0] == b[0]]
                print(f"{name}: {len(chain)} sectors, first {chain[:12]}, same-track steps {sorted(set(steps))[:8]}")
        t, s = sec[0], sec[1]


if __name__ == "__main__":
    main(sys.argv[1])
