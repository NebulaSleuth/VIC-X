#!/usr/bin/env python3
"""Debug the fast loader: a test build of a demo (FL_RAWTEST) puts its data
file into XRAM exactly as it arrives; the XRAM VICE writes back is compared
with the .dat file, and the bit errors are listed.

Usage:  python fastload_raw.py [--ntsc] [--drive N] [--cycles N] demo
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEMOS = HERE.parent / "demos"
BUILD = DEMOS / "build"
OUT = HERE / "build" / "fastload"
CC65 = Path(os.environ.get("VICX_CC65", r"D:\Repos\TimeWarrior\tools\cc65\bin"))
C1541 = os.environ.get("VICX_C1541", r"D:\Repos\vice-vicx\vice\build-headless\src\c1541.exe")
X64SC = os.environ.get("VICX_X64SC", r"D:\Repos\vice-vicx\vice\build-headless\src\x64sc.exe")
DLLDIR = os.environ.get("VICX_DLLDIR", r"C:\msys64\ucrt64\bin")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ntsc", action="store_true")
    ap.add_argument("--drive", type=int, default=0)
    ap.add_argument("--cycles", type=int, default=30000000)
    ap.add_argument("demo")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PATH"] = DLLDIR + os.pathsep + env.get("PATH", "")
    obj, prg = OUT / f"{a.demo}-raw.o", OUT / f"{a.demo}-raw.prg"
    subprocess.run([str(CC65 / "ca65"), "-D", "FL_RAWTEST"] + (["-D", "FL_BLANKTEST"] if os.environ.get("FL_BLANK") else []) + [ "-I", str(HERE.parent / "include"),
                    "-I", str(DEMOS / "lib"), "-I", str(BUILD / a.demo), "-o", str(obj),
                    str(DEMOS / f"{a.demo}.s")], check=True)
    subprocess.run([str(CC65 / "ld65"), "-C", str(DEMOS / "lib" / "demo.cfg"), "-o", str(prg), str(obj)],
                   check=True)
    dat = BUILD / f"{a.demo}.dat"
    kind = "d64" if (BUILD / f"{a.demo}.d64").exists() else "d81"
    disk = OUT / f"{a.demo}-raw.{kind}"
    disk.unlink(missing_ok=True)
    subprocess.run([C1541, "-format", f"vic-x {a.demo},vx", kind, str(disk), "-write", str(prg), a.demo,
                    "-write", str(dat), f"{a.demo}.dat,s"], env=env, check=True, capture_output=True)
    reu = OUT / f"{a.demo}-raw.reu"
    reu.write_bytes(bytes(2 * 1024 * 1024))
    data = Path(X64SC).parents[2] / "data"
    cmd = [X64SC, "-default"] + (["-ntsc"] if a.ntsc else []) + [
        "-warp", "-sounddev", "dummy", "-directory", str(data), "-vicx", "-reu", "-reusize", "2048",
        "-reuimage", str(reu), "-reuimagerw", "-limitcycles", str(a.cycles),
        "-exitscreenshot", str(OUT / f"{a.demo}-raw.png")]
    if a.drive:
        cmd += ["-drive8type", str(a.drive)]
    cmd += ["-autostart", str(disk)]
    subprocess.run(cmd, env=env, capture_output=True, cwd=OUT, timeout=1800)
    want = dat.read_bytes()
    got = reu.read_bytes()
    n = 0
    while n < len(want) and got[n] == want[n]:
        n += 1
    blocks = 0
    while blocks * 1024 < len(got) and any(got[blocks * 1024:(blocks + 1) * 1024]):
        blocks += 1
    print(f"{a.demo}: {blocks} 1 KB blocks arrived; first {n} bytes right")
    shown = 0
    for i in range(min(len(want), blocks * 1024)):
        if got[i] != want[i]:
            x = got[i] ^ want[i]
            print(f"  ${i:05X} (sector {i // 254} byte {i % 254}): got {got[i]:08b} want {want[i]:08b} "
                  f"pairs wrong {[p for p in range(4) if (x >> (2 * p)) & 3]}")
            shown += 1
            if shown >= 20:
                break
    return 0


if __name__ == "__main__":
    sys.exit(main())
