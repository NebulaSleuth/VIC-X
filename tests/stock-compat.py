#!/usr/bin/env python3
"""Check that VIC-X leaves stock VIC-II behaviour unchanged.

Runs the self-checking VICE testprogs listed in stock-compat.txt in up to
three configurations and compares them:

    stock    an unmodified x64sc 3.10 build (optional, --stock)
    off      the VIC-X fork with VIC-X disabled (+vicx)
    locked   the VIC-X fork with VIC-X enabled but locked (-vicx)

Each run must reach the same debug-cart exit code, and the exit screenshots
must be byte-identical across the configurations.

Get the test programs first (needs Subversion; MSYS2 has it in /usr/bin):
    svn export https://svn.code.sf.net/p/vice-emu/code/testprogs/VICII <dir>/VICII

Usage:  python stock-compat.py --testprogs <dir> [--stock <x64sc.exe>]
"""

import argparse
import hashlib
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_X64SC = os.environ.get(
    "VICX_X64SC", r"D:\Repos\vice-vicx\vice\build-headless\src\x64sc.exe")
DEFAULT_DLLDIR = os.environ.get("VICX_DLLDIR", r"C:\msys64\ucrt64\bin")


def run(exe, data, prg, cycles, extra, shot, env):
    cmd = [str(exe), "-default", "-seed", "1", "-debugcart", "-warp",
           "-sounddev", "dummy", "-autostartprgmode", "1",
           "-limitcycles", str(cycles), "-directory", str(data),
           "-exitscreenshot", str(shot)] + extra + ["-autostart", str(prg)]
    if shot.exists():
        shot.unlink()
    try:
        p = subprocess.run(cmd, env=env, capture_output=True, text=True,
                           errors="replace", timeout=600)
        code = p.returncode
    except subprocess.TimeoutExpired:
        code = "timeout"
    digest = hashlib.sha1(shot.read_bytes()).hexdigest()[:12] if shot.exists() else "-"
    return code, digest


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--testprogs", required=True, help="root of the VICE testprogs checkout")
    ap.add_argument("--x64sc", default=DEFAULT_X64SC, help="headless x64sc from the VIC-X fork")
    ap.add_argument("--stock", default=None, help="unmodified headless x64sc for comparison")
    ap.add_argument("--dlldir", default=DEFAULT_DLLDIR)
    ap.add_argument("--data", default=None, help="VICE data directory")
    opts = ap.parse_args()

    x64sc = Path(opts.x64sc)
    data = Path(opts.data) if opts.data else x64sc.parents[2] / "data"
    root = Path(opts.testprogs)
    outdir = HERE / "build" / "stock-compat"
    outdir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PATH"] = opts.dlldir + os.pathsep + env.get("PATH", "")

    configs = []
    if opts.stock:
        configs.append(("stock", Path(opts.stock), []))
    configs.append(("off", x64sc, ["+vicx"]))
    configs.append(("locked", x64sc, ["-vicx"]))

    bad = total = 0
    for line in (HERE / "stock-compat.txt").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = [f.strip() for f in line.split(",")]
        directory, prog, _kind, cycles = fields[:4]
        prg = root / directory / prog
        name = (directory + prog).replace("/", "_")
        results = []
        for cname, exe, extra in configs:
            shot = outdir / f"{name}-{cname}.png"
            results.append((cname,) + run(exe, data, prg, cycles, extra, shot, env))
        total += 1
        codes = {r[1] for r in results}
        shots = {r[2] for r in results}
        ok = codes == {0} and len(shots) == 1 and "-" not in shots
        same = len(codes) == 1 and len(shots) == 1
        if not ok:
            bad += 1
        status = "pass " if ok else ("SAME " if same else "DIFF ")
        detail = "  ".join(f"{c}: exit {e} shot {h}" for c, e, h in results)
        print(f"{status} {directory}{prog}\n        {detail}")
    print(f"\n{total - bad}/{total} programs passed in every configuration "
          "with identical screenshots")
    print("(SAME = failed identically in every configuration, i.e. not caused by VIC-X)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
