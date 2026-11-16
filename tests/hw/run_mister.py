#!/usr/bin/env python3
"""Run VIC-X conformance tests on a MiSTer with the C64X core.

Each test is assembled with -D HW_RESULT (the harness then shows PASS or
FAIL xx on screen with a green or red border), copied to the MiSTer, and
started through a launch file (MGL) that loads the C64X core fresh and the
PRG into it.  After a few seconds the MiSTer takes a screenshot, which is
copied back and judged by its border colour.  A test's `; PIXEL:` lines
(from its first `; RUN:` block) that fall inside the 320x200 window are
checked on the screenshot too: the MiSTer's screenshot is 382x270 with the
window at (32,34) or (33,34) (the capture moves by a pixel from one
screenshot to the next), one line up from VICE's 384x272 one; each
screenshot is judged at whichever of the two fits better.  Not checked:
border pixels and the top text line, where the harness writes its result.

Needs SSH key access to the MiSTer as root.  Uses Windows' own OpenSSH
client, which takes the key; Git Bash's ssh is refused by this MiSTer.

Usage:  python run_mister.py [--host 192.168.1.140] [test-name-substring ...]
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
REPO = TESTS.parent
sys.path.insert(0, str(TESTS))

SSH = r"C:\Windows\System32\OpenSSH\ssh.exe"
SCP = r"C:\Windows\System32\OpenSSH\scp.exe"
CC65 = Path(r"D:\Repos\TimeWarrior\tools\cc65\bin")
OUT = TESTS / "build" / "mister"
REMOTE_DIR = "/media/fat/games/C64X/vicx-tests"
MGL = "/media/fat/vicx-test.mgl"
SHOTS = "/media/fat/screenshots/C64X"

# tests that run on hardware without VICE's monitor or snapshots
DEFAULT_TESTS = ["t01_locked", "t03_unlock", "t04_id_caps", "t05_ports",
                 "t07_palette", "t08_remap", "t29_palette_split"]


def ssh(host, cmd, check=True):
    r = subprocess.run([SSH, "-o", "BatchMode=yes", f"root@{host}", cmd],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit(f"ssh failed: {cmd}\n{r.stderr}")
    return r.stdout


def scp(src, dst):
    r = subprocess.run([SCP, "-o", "BatchMode=yes", "-q", src, dst],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"scp failed: {src} -> {dst}\n{r.stderr}")


def source(name):
    src = TESTS / f"{name}.s"
    return src if src.exists() else HERE / f"{name}.s"


def assemble(name):
    OUT.mkdir(parents=True, exist_ok=True)
    obj, prg = OUT / f"{name}.o", OUT / f"{name}.prg"
    subprocess.run([str(CC65 / "ca65"), "-D", "HW_RESULT",
                    "-I", str(REPO / "include"), "-I", str(TESTS / "lib"),
                    "-o", str(obj), str(source(name))], check=True)
    subprocess.run([str(CC65 / "ld65"), "-C", str(TESTS / "lib" / "test.cfg"),
                    "-o", str(prg), str(obj)], check=True)
    return prg


def png_border(path):
    """RGB of a pixel in the top-left border of a screenshot."""
    import importlib
    rt = importlib.import_module("run-tests")
    width, height, pixel = rt.png_read(path)
    return pixel(4, 4)


def pixel_checks(name):
    """(x, y, rgb, negate) from the first RUN block, window pixels only."""
    checks, runs = [], 0
    for line in source(name).read_text().splitlines():
        if line.startswith("; RUN:"):
            runs += 1
        elif line.startswith("; PIXEL:") and runs == 1:
            x, y, want = line.split()[2:5]
            x, y = int(x), int(y)
            neg = want.startswith("!")
            want = want.lstrip("!")
            if 32 <= x < 352 and 43 <= y < 235:
                checks.append((x, y - 1, tuple(int(want[i:i + 2], 16) for i in (0, 2, 4)), neg))
    return checks


def check_pixels(name, path, tol=40):
    import importlib
    rt = importlib.import_module("run-tests")
    _, _, pixel = rt.png_read(path)
    border = tuple(pixel(4, 4)[:3])     # the harness's result colour
    best = None
    for dx in (1, 0):
        bad = []
        for x, y, want, neg in pixel_checks(name):
            got = tuple(pixel(x + dx, y)[:3])
            if got == border and not neg:
                continue    # border: the harness gives it its own colour
            close = all(abs(a - b) <= tol for a, b in zip(got, want))
            if close == neg:
                bad.append(f"({x + dx},{y}) {'%02X%02X%02X' % got} {'!' if neg else ''}{'%02X%02X%02X' % want}")
        if best is None or len(bad) < len(best):
            best = bad
    return best


def verdict(rgb):
    r, g, b = rgb[:3]
    if g > r + 40 and g > b:
        return "pass"
    if r > g + 40 and r > b:
        return "FAIL"
    return "?"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default="192.168.1.140")
    ap.add_argument("--wait", type=float, default=9.0,
                    help="seconds from launch to screenshot")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()

    names = DEFAULT_TESTS
    if args.names:
        # conformance tests, and the hardware checks in tests/hw
        sources = sorted(TESTS.glob("t*.s")) + sorted(HERE.glob("*.s"))
        names = [n for n in (p.stem for p in sources)
                 if any(s in n for s in args.names)]

    ssh(args.host, f"mkdir -p {REMOTE_DIR} {SHOTS}")
    results = []
    for name in names:
        prg = assemble(name)
        scp(str(prg), f"root@{args.host}:{REMOTE_DIR}/{prg.name}")
        mgl = ('<mistergamedescription><rbf>_Computer/C64X</rbf>'
               f'<file delay="2" type="f" index="1" path="vicx-tests/{prg.name}"/>'
               '</mistergamedescription>')
        ssh(args.host, f"printf '%s' '{mgl}' > {MGL}; "
                       f"echo 'load_core {MGL}' > /dev/MiSTer_cmd")
        time.sleep(args.wait)
        before = set(ssh(args.host, f"ls {SHOTS}").split())
        ssh(args.host, "echo screenshot > /dev/MiSTer_cmd")
        shot = None
        for _ in range(20):
            time.sleep(0.5)
            new = set(ssh(args.host, f"ls {SHOTS}").split()) - before
            if new:
                shot = sorted(new)[-1]
                break
        if shot is None:
            results.append((name, "no screenshot", None))
            print(f"??    {name}: no screenshot")
            continue
        time.sleep(0.5)
        local = OUT / f"{name}.png"
        scp(f"root@{args.host}:{SHOTS}/{shot}", str(local))
        v = verdict(png_border(local))
        bad = check_pixels(name, local) if v == "pass" else []
        if bad:
            v = "PIXEL"
        results.append((name, v, local))
        print(f"{v:5} {name}   {local}")
        for b in bad[:8]:
            print(f"        pixel {b}")

    passed = sum(1 for _, v, _ in results if v == "pass")
    print(f"\n{passed}/{len(results)} passed (see the screenshots for FAIL codes)")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
