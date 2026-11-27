#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Michael Hartman

"""Check the demos' fast loader in headless VICE (true drive emulation).

Each demo is started from its disk image with an empty REU; the REU image
VICE writes back at exit is compared with the demo's own .reu (the data the
loader should have put in XRAM), and a screenshot is saved.  The cycle count
at which the demo's signature appeared is not measured: give enough cycles.

Usage:  python fastload_check.py [--ntsc] [--drive 1541|1581|1571] [--cycles N] demo...
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILD = HERE.parent / "demos" / "build"
OUT = HERE / "build" / "fastload"
X64SC = os.environ.get("VICX_X64SC", r"D:\Repos\vice-vicx\vice\build-headless\src\x64sc.exe")
DLLDIR = os.environ.get("VICX_DLLDIR", r"C:\msys64\ucrt64\bin")


def run(demo, drive, ntsc, cycles, disk=None):
    OUT.mkdir(parents=True, exist_ok=True)
    tag = f"{demo}-{drive or 'auto'}{'-ntsc' if ntsc else ''}"
    if disk:
        disk = Path(disk).resolve()
        tag += "-" + disk.stem
    else:
        disk = BUILD / f"{demo}.d64"
        if not disk.exists():
            disk = BUILD / f"{demo}.d81"
    reu = OUT / f"{tag}.reu"
    reu.write_bytes(bytes(2 * 1024 * 1024))
    shot = OUT / f"{tag}.png"
    env = dict(os.environ)
    env["PATH"] = DLLDIR + os.pathsep + env.get("PATH", "")
    data = Path(X64SC).parents[2] / "data"
    cmd = [X64SC, "-default"]
    if ntsc:
        cmd += ["-ntsc"]
    cmd += ["-warp", "-sounddev", "dummy", "-directory", data, "-vicx",
            "-reu", "-reusize", "2048", "-reuimage", reu, "-reuimagerw",
            "-limitcycles", str(cycles), "-exitscreenshot", shot]
    if drive:
        cmd += ["-drive8type", str(drive)]
    labels = {}
    for line in (BUILD / f"{demo}.lbl").read_text().splitlines():
        _, addr, name = line.split()
        labels[name.lstrip(".")] = int(addr, 16)
    mon = OUT / f"{tag}.mon"
    mon.write_text(f"break {labels['ld_go']:x}\nbreak {labels['ld_done']:x}\n")
    cmd += ["-moncommands", mon, "-autostart", disk]
    r = subprocess.run([str(c) for c in cmd], env=env, capture_output=True, text=True, errors="replace",
                       cwd=OUT, timeout=1800, stdin=subprocess.DEVNULL)
    hits = {}
    for line in r.stdout.splitlines():
        if line.startswith(".C:"):
            a = int(line[3:7], 16)
            for k in ("ld_go", "ld_done"):
                if a == labels[k] and k not in hits:
                    hits[k] = int(line.split()[-1])
    if len(hits) == 2:
        clk = 1022727 if ntsc else 985248
        print(f"{tag}: load took {(hits['ld_done'] - hits['ld_go']) / clk:.1f} s")
    want = (BUILD / f"{demo}.reu").read_bytes()
    got = reu.read_bytes()
    bad = [i for i in range(len(want)) if want[i] != got[i]]
    if not bad:
        print(f"{tag}: XRAM matches {demo}.reu   {shot}")
        return True
    print(f"{tag}: {len(bad)} bytes differ, first at ${bad[0]:06X} (got {got[bad[0]]:02X}, "
          f"want {want[bad[0]]:02X}); signature {'there' if got[-16:] == want[-16:] else 'missing'}   {shot}")
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ntsc", action="store_true")
    ap.add_argument("--drive", type=int, default=0, help="drive 8 type (default: VICE's for the image)")
    ap.add_argument("--cycles", type=int, default=40000000)
    ap.add_argument("--disk", help="disk image to start from (default: the demo's)")
    ap.add_argument("demos", nargs="+")
    args = ap.parse_args()
    ok = all([run(d, args.drive, args.ntsc, args.cycles, args.disk) for d in args.demos])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
