#!/usr/bin/env python3
"""render_wav.py - play a SID register stream in VICE and record it.

    python render_wav.py <stream.bin> <seconds> <out.wav>

The stream (32 bytes a frame, the 25 SID registers first, as sidplay.py and
the Big world demo use) goes into an REU image at XRAM 0; streamplay.s plays
it frame by frame in x64sc with VIC-X, and VICE's WAV recorder takes the
sound.  VICE records nothing in warp mode, so this runs in real time.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "demos"))
sys.argv, _args = ["build"], sys.argv
import build  # noqa: E402
sys.argv = _args


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    stream, seconds, out = Path(sys.argv[1]), float(sys.argv[2]), Path(sys.argv[3]).resolve()
    tmp = Path(tempfile.mkdtemp(prefix="streamplay"))
    reu = bytearray(2 * 1024 * 1024)
    data = stream.read_bytes()
    reu[:len(data)] = data[:len(reu)]
    (tmp / "stream.reu").write_bytes(reu)
    cc = Path(build.CC65)
    subprocess.run([cc / "ca65", "-I", REPO / "include", "-I", REPO / "tests" / "lib",
                    "-o", tmp / "sp.o", HERE / "streamplay.s"], check=True)
    subprocess.run([cc / "ld65", "-C", REPO / "tests" / "lib" / "test.cfg",
                    "-o", tmp / "sp.prg", tmp / "sp.o"], check=True)
    env = dict(os.environ)
    env["PATH"] = build.DLLDIR + os.pathsep + env.get("PATH", "")
    data_dir = Path(build.X64SC).parents[2] / "data"
    if out.exists():
        out.unlink()
    cmd = [build.X64SC, "-default", "-sound", "-sounddev", "wav", "-soundarg", out,
           "-soundrate", "44100", "-autostartprgmode", "1", "-directory", data_dir,
           "-vicx", "-reu", "-reusize", "2048", "-reuimage", tmp / "stream.reu",
           "-limitcycles", str(int((seconds + 3) * 985248)), "-autostart", tmp / "sp.prg"]
    subprocess.run([str(c) for c in cmd], env=env, capture_output=True)
    print(f"{out}: {out.stat().st_size} bytes")


if __name__ == "__main__":
    main()
