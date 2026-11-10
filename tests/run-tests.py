#!/usr/bin/env python3
"""Build and run the VIC-X conformance tests headless in the VICE fork.

Each tests/tNN_*.s file is assembled with ca65/ld65 into a PRG and run in
x64sc with VICE's debug cartridge: the program writes its result to $D7FF and
VICE exits with that value (0 = pass, otherwise the number of the failing
check).

Directives in a test's header comments:

    ; RUN: <x64sc options>          one run; repeat the line for more runs
    ; MON: <file>                   monitor command file for the runs (-moncommands)
    ; PIXEL: <x> <y> <RRGGBB>       after the preceding RUN, the exit screenshot
    ; PIXEL: <x> <y> !<RRGGBB>      pixel must (or must not) have this colour
    ; EXIT: cycle-limit             after the preceding RUN: the run is expected
                                    to end at the cycle limit (result on screen)

In RUN options, {build} is replaced by the build directory (VICE also runs
with that as its working directory) and {tests} by this directory.  A RUN that has its own -autostart
(for example a snapshot saved by an earlier run) does not get the PRG.

Usage:  python run-tests.py [options] [test-name-substring ...]

Paths default to this machine's layout and can be changed with options or
environment variables (VICX_X64SC, VICX_CC65, VICX_DLLDIR).
"""

import argparse
import os
import re
import struct
import subprocess
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent

DEFAULT_X64SC = os.environ.get(
    "VICX_X64SC", r"D:\Repos\vice-vicx\vice\build-headless\src\x64sc.exe")
DEFAULT_CC65 = os.environ.get("VICX_CC65", r"D:\Repos\TimeWarrior\tools\cc65\bin")
DEFAULT_DLLDIR = os.environ.get("VICX_DLLDIR", r"C:\msys64\ucrt64\bin")

BASE_ARGS = [
    "-default",            # factory settings, ignore vicerc
    "-debugcart",          # result register at $D7FF
    "-warp",
    "-sounddev", "dummy",
    "-autostartprgmode", "1",   # inject the PRG into RAM, then RUN
]


# --------------------------------------------------------------------------
# minimal PNG reader (8-bit RGB, RGBA or palette; what VICE writes)

def png_read(path):
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")
    pos, idat, plte = 8, b"", None
    width = height = depth = ctype = None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif kind == b"PLTE":
            plte = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if depth != 8 or ctype not in (2, 3, 6):
        raise ValueError(f"unsupported PNG (depth {depth}, type {ctype})")
    bpp = {2: 3, 3: 1, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = width * bpp
    rows, prev = [], bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
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
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        rows.append(bytes(line))
        prev = line

    def pixel(x, y):
        row = rows[y]
        if ctype == 3:
            return plte[row[x]]
        return tuple(row[x * bpp:x * bpp + 3])

    return width, height, pixel


# --------------------------------------------------------------------------

def parse_test(path):
    runs, mon = [], None
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*;\s*(RUN|MON|PIXEL|EXIT):\s*(.*?)\s*$", line)
        if not m:
            continue
        kind, arg = m.groups()
        if kind == "RUN":
            runs.append({"args": arg.split(), "pixels": [], "cyclelimit": False})
        elif kind == "EXIT":
            if not runs or arg != "cycle-limit":
                raise ValueError(f"{path.name}: bad EXIT line")
            runs[-1]["cyclelimit"] = True
        elif kind == "MON":
            mon = path.parent / arg
        elif kind == "PIXEL":
            if not runs:
                raise ValueError(f"{path.name}: PIXEL before any RUN")
            x, y, col = arg.split()
            neg = col.startswith("!")
            col = col.lstrip("!")
            rgb = tuple(int(col[i:i + 2], 16) for i in (0, 2, 4))
            runs[-1]["pixels"].append((int(x), int(y), rgb, neg))
    if not runs:
        runs.append({"args": ["-vicx"], "pixels": [], "cyclelimit": False})
    return runs, mon


def build(src, outdir, cc65):
    obj = outdir / (src.stem + ".o")
    prg = outdir / (src.stem + ".prg")
    ca65 = str(Path(cc65) / "ca65")
    ld65 = str(Path(cc65) / "ld65")
    subprocess.run([ca65, "-I", str(REPO / "include"), "-I", str(HERE / "lib"),
                    "-o", str(obj), str(src)], check=True)
    subprocess.run([ld65, "-C", str(HERE / "lib" / "test.cfg"),
                    "-o", str(prg), str(obj)], check=True)
    return prg


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("filters", nargs="*", help="only run tests whose name contains one of these")
    ap.add_argument("--x64sc", default=DEFAULT_X64SC, help="headless x64sc from the fork")
    ap.add_argument("--cc65", default=DEFAULT_CC65, help="directory with ca65 and ld65")
    ap.add_argument("--dlldir", default=DEFAULT_DLLDIR, help="directory with the MSYS2 UCRT64 DLLs")
    ap.add_argument("--data", default=None, help="VICE data directory (default: next to the source tree)")
    ap.add_argument("--cycles", default="40000000", help="cycle limit per run")
    ap.add_argument("-v", "--verbose", action="store_true", help="show VICE output")
    opts = ap.parse_args()

    x64sc = Path(opts.x64sc)
    data = Path(opts.data) if opts.data else x64sc.parents[2] / "data"
    outdir = HERE / "build"
    outdir.mkdir(exist_ok=True)
    env = dict(os.environ)
    env["PATH"] = opts.dlldir + os.pathsep + env.get("PATH", "")

    tests = sorted(HERE.glob("t[0-9][0-9]_*.s"))
    if opts.filters:
        tests = [t for t in tests if any(f in t.stem for f in opts.filters)]

    total = failed = 0
    for src in tests:
        runs, mon = parse_test(src)
        prg = build(src, outdir, opts.cc65)
        for n, run in enumerate(runs, 1):
            total += 1
            label = f"{src.stem} [{' '.join(run['args'])}]"
            shot = outdir / f"{src.stem}-{n}.png"
            if shot.exists():
                shot.unlink()
            cmd = [str(x64sc)] + BASE_ARGS + ["-limitcycles", opts.cycles,
                                              "-directory", str(data)]
            if run["pixels"]:
                cmd += ["-exitscreenshot", str(shot)]
            if mon:
                cmd += ["-moncommands", str(mon)]
            args = [a.replace("{build}", str(outdir)).replace("{tests}", str(HERE))
                    for a in run["args"]]
            cmd += args
            if "-autostart" not in args:
                cmd += ["-autostart", str(prg)]
            try:
                p = subprocess.run(cmd, env=env, capture_output=True, text=True,
                                   errors="replace", timeout=120, cwd=outdir)
                code, out = p.returncode, p.stdout + p.stderr
            except subprocess.TimeoutExpired:
                code, out = None, "timeout"
            problems = []
            if run["cyclelimit"]:
                if "cycle limit reached" not in out:
                    problems.append(f"expected to run into the cycle limit, exit {code}")
            elif code != 0:
                if code is None:
                    problems.append("timed out")
                elif "cycle limit reached" in out:
                    problems.append("cycle limit reached (no result written)")
                else:
                    problems.append(f"check {code} failed")
            for (x, y, rgb, neg) in run["pixels"]:
                if not shot.exists():
                    problems.append("no screenshot")
                    break
                _, _, pixel = png_read(shot)
                got = pixel(x, y)
                ok = (got != rgb) if neg else (got == rgb)
                if not ok:
                    want = ("not " if neg else "") + "%02X%02X%02X" % rgb
                    problems.append(f"pixel {x},{y} is %02X%02X%02X, want {want}" % got)
            if problems:
                failed += 1
                print(f"FAIL  {label}: " + "; ".join(problems))
                if opts.verbose:
                    print(out)
            else:
                print(f"pass  {label}")
                if opts.verbose:
                    print(out)
    print(f"\n{total - failed}/{total} runs passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
