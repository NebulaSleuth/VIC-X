#!/usr/bin/env python3
"""Run a VIC-X demo on a MiSTer with the C64X core and take screenshots.

The demo's REU image (its data, already in XRAM, so the demo skips the disk
load) and its PRG are copied to the MiSTer and started through a launch file
(MGL) that loads the C64X core, then the REU image, then the PRG.  The REU
must be enabled in the core's settings, at least as large as the image.
Screenshots are taken at the given times (seconds after launch) and copied
back to tests/build/mister/demo-<name>-<t>.png.

Usage:  python run_demo.py sixteen --at 15 25
"""

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run_mister as rm  # noqa: E402

DEMOS = HERE.parent.parent / "demos" / "build"
REMOTE = "/media/fat/games/C64X/vicx-demos"


def shot(host, name):
    before = set(rm.ssh(host, f"ls {rm.SHOTS}").split())
    rm.ssh(host, "echo screenshot > /dev/MiSTer_cmd")
    for _ in range(20):
        time.sleep(0.5)
        new = set(rm.ssh(host, f"ls {rm.SHOTS}").split()) - before
        if new:
            time.sleep(0.5)
            local = rm.OUT / name
            rm.OUT.mkdir(parents=True, exist_ok=True)
            rm.scp(f"root@{host}:{rm.SHOTS}/{sorted(new)[-1]}", str(local))
            return local
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default="192.168.1.140")
    ap.add_argument("--at", type=float, nargs="+", default=[15.0],
                    help="seconds from launch to each screenshot")
    ap.add_argument("--no-reu", action="store_true",
                    help="load only the PRG (the demo then loads from disk)")
    ap.add_argument("demo")
    args = ap.parse_args()

    prg, reu = DEMOS / f"{args.demo}.prg", DEMOS / f"{args.demo}.reu"
    rm.ssh(args.host, f"mkdir -p {REMOTE} {rm.SHOTS}")
    rm.scp(str(prg), f"root@{args.host}:{REMOTE}/{prg.name}")
    files = ""
    if not args.no_reu:
        rm.scp(str(reu), f"root@{args.host}:{REMOTE}/{reu.name}")
        files += f'<file delay="2" type="f" index="1" path="vicx-demos/{reu.name}"/>'
    files += f'<file delay="4" type="f" index="1" path="vicx-demos/{prg.name}"/>'
    mgl = f"<mistergamedescription><rbf>_Computer/C64X</rbf>{files}</mistergamedescription>"
    rm.ssh(args.host, f"printf '%s' '{mgl}' > {rm.MGL}; "
                      f"echo 'load_core {rm.MGL}' > /dev/MiSTer_cmd")
    start = time.time()
    for t in sorted(args.at):
        time.sleep(max(0.0, start + t - time.time()))
        local = shot(args.host, f"demo-{args.demo}-{int(t)}.png")
        print(f"{t:6.1f}s  {local if local else 'no screenshot'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
