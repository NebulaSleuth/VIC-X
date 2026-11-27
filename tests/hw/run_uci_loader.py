#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Michael Hartman

"""Test the demos' UCI loader (demos/lib/uci.inc) on an Ultimate.

    python run_uci_loader.py <ultimate host> [--demo bigworld] [--dir /Temp]

Uploads build/<demo>.reu to <dir> by FTP, then runs uci_loader_test.s twice
through the REST API:
  1. from <dir>, where the file is: the loader must report success and the
     demo's signature must be in the REU;
  2. from a directory without the file (<dir>/vxnofile, created by FTP):
     the loader must report failure, so a demo falls back to the KERNAL.
Exits 0 when both behave. Needs FTP, the web server, Command Interface and
an REU of 2 MB or more on the Ultimate.
"""
import argparse
import ftplib
import subprocess
import sys
import time
from io import BytesIO
from pathlib import Path

from run_uci_probe import CC65, HERE, REPO, http, readmem

BUILD = HERE / "build"
EMPTY = "vxnofile"


def build(dirname, demo, sig):
    BUILD.mkdir(exist_ok=True)
    (BUILD / "loader_cfg.inc").write_text(
        f'.define TEST_DIR "{dirname}"\n.define TEST_NAME "{demo}.reu"\n'
        f'.define TEST_SIG "{sig}"\n')
    obj, prg = BUILD / "uci_loader_test.o", BUILD / "uci_loader_test.prg"
    subprocess.run([CC65 / "ca65", "-I", BUILD, "-I", REPO / "demos" / "lib", "-o", obj,
                    HERE / "uci_loader_test.s"], check=True)
    subprocess.run([CC65 / "ld65", "-C", REPO / "demos" / "lib" / "demo.cfg", "-o", prg, obj],
                   check=True)
    return prg.read_bytes()


def run(host, prg, timeout=60):
    http(host, "POST", "/v1/runners:run_prg", prg)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(1)
        try:
            res = readmem(host, 0xC000, 0x20)
        except OSError:
            continue
        if res[0] == 0xAA:
            return res
    raise SystemExit("the test program did not finish")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host")
    ap.add_argument("--demo", default="bigworld")
    ap.add_argument("--dir", default="/Temp")
    a = ap.parse_args()

    data = (REPO / "demos" / "build" / f"{a.demo}.reu").read_bytes()
    sig = data[0x1FFFF0:0x200000]
    with ftplib.FTP(a.host, timeout=30) as ftp:
        ftp.login()
        ftp.cwd(a.dir)
        if EMPTY not in ftp.nlst():
            ftp.mkd(EMPTY)
        ftp.storbinary(f"STOR {a.demo}.reu", BytesIO(data))
    print(f"uploaded {a.demo}.reu ({len(data)} bytes) to {a.dir}")

    ok = True
    for label, d, want_loaded in (("file present", a.dir, True),
                                  ("file missing", f"{a.dir}/{EMPTY}", False)):
        res = run(a.host, build(d, a.demo, sig.decode("ascii")))
        loaded = res[1] == 0
        jiffies = res[2] | res[3] << 8 | res[4] << 16
        sig_there = res[0x10:0x20] == sig
        good = loaded == want_loaded and sig_there == want_loaded
        ok &= good
        print(f"{label:13} ({d}): uci_load {'loaded' if loaded else 'declined'} in "
              f"{jiffies / 60:.2f} s, signature {'in' if sig_there else 'not in'} the REU "
              f"-> {'ok' if good else 'WRONG'}")
    with ftplib.FTP(a.host, timeout=30) as ftp:   # /Temp is the Ultimate's RAM
        ftp.login()
        ftp.cwd(a.dir)
        ftp.delete(f"{a.demo}.reu")
        ftp.rmd(EMPTY)
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
