#!/usr/bin/env python3
"""Run uci_probe.s on an Ultimate over the network and report what UCI did.

    python run_uci_probe.py <ultimate host> [--reu FILE] [--dir /Temp] [--png out.png]

Builds the probe, uploads FILE (default: demos/build/bigworld.reu) to the
Ultimate by FTP as <dir>/vxprobe.reu, runs the probe through the REST API
(/v1/runners:run_prg resets the machine first), waits for it to finish,
reads its results from $C000 and compares the REU bytes it fetched with the
file. Needs the Ultimate's FTP and web servers on, Command Interface on and
an REU as large as the file. Exits 0 when the load is proven.
"""
import argparse
import ftplib
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "tools"))
CC65 = Path(os.environ.get("VICX_CC65", r"D:\Repos\TimeWarrior\tools\cc65\bin"))
BUILD = HERE / "build"
NAME = "vxprobe.reu"
STEPS = {2: "IDENTIFY", 3: "GET_PATH", 4: "COPY_HOME_PATH", 5: "CHANGE_DIR",
         6: "OPEN_FILE", 7: "LOAD_REU", 8: "CLOSE_FILE"}


def build(dirname, length):
    BUILD.mkdir(exist_ok=True)
    (BUILD / "probe_cfg.inc").write_text(
        f'.define PROBE_DIR "{dirname}"\n.define PROBE_FILE "{NAME}"\nPROBE_LEN = {length}\n')
    obj, prg = BUILD / "uci_probe.o", BUILD / "uci_probe.prg"
    subprocess.run([CC65 / "ca65", "-I", BUILD, "-o", obj, HERE / "uci_probe.s"], check=True)
    subprocess.run([CC65 / "ld65", "-C", REPO / "demos" / "lib" / "demo.cfg", "-o", prg, obj], check=True)
    return prg.read_bytes()


def upload(host, dirname, data):
    with ftplib.FTP(host, timeout=30) as ftp:
        ftp.login()
        ftp.cwd(dirname)
        from io import BytesIO
        ftp.storbinary(f"STOR {NAME}", BytesIO(data))
        size = ftp.size(NAME)
    if size is not None and size != len(data):
        raise SystemExit(f"upload: {size} bytes on the Ultimate, {len(data)} sent")


def http(host, method, path, body=None):
    req = urllib.request.Request(f"http://{host}{path}", data=body, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/octet-stream")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read()


def readmem(host, addr, length):
    return http(host, "GET", f"/v1/machine:readmem?address={addr:04X}&length={length}")


def cstr(b):
    return b.split(b"\0", 1)[0].decode("latin-1")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host")
    ap.add_argument("--reu", default=str(REPO / "demos" / "build" / "bigworld.reu"))
    ap.add_argument("--dir", default="/Temp")
    ap.add_argument("--png", help="also render the probe's screen to this PNG")
    ap.add_argument("--timeout", type=float, default=60)
    a = ap.parse_args()

    data = Path(a.reu).read_bytes()
    prg = build(a.dir, len(data))
    t = time.time()
    upload(a.host, a.dir, data)
    print(f"uploaded {len(data)} bytes to {a.dir}/{NAME} in {time.time() - t:.1f} s")

    http(a.host, "POST", "/v1/runners:run_prg", prg)
    deadline = time.time() + a.timeout
    while True:
        time.sleep(1)
        try:
            if readmem(a.host, 0xC005, 1)[0] == 0xAA:
                break
        except OSError:
            pass
        if time.time() > deadline:
            print("probe did not finish (see the screen)")
            break
    res = readmem(a.host, 0xC000, 0x600)

    ok = True
    print(f"ID register: ${res[0]:02X} ({'ok' if res[0] == 0xC9 else 'NO UCI'})")
    for n, name in STEPS.items():
        base = 0x100 + n * 0x80
        reply, status = cstr(res[base:base + 0x40]), cstr(res[base + 0x40:base + 0x80])
        err = " [error bit]" if res[8 + n] else ""
        print(f"{n} {name:15} reply {reply!r:40} status {status!r}{err}")
    jiffies = res[2] | res[3] << 8 | res[4] << 16
    print(f"LOAD_REU took {jiffies} jiffies ({jiffies / 60:.2f} s at 60 Hz)")
    for label, off, addr in (("$000000", 0x40, 0), ("$100000", 0x50, 0x100000), ("$1FFFF0", 0x60, 0x1FFFF0)):
        got, want = res[off:off + 16], data[addr:addr + 16]
        same = got == want
        ok &= same
        print(f"REU {label}: {got.hex()} {'matches the file' if same else 'DIFFERS from ' + want.hex()}")
    if a.png:
        import u64screen
        sys.argv = ["u64screen", a.host, a.png]
        u64screen.main()
    with ftplib.FTP(a.host, timeout=30) as ftp:   # /Temp is the Ultimate's RAM
        ftp.login()
        ftp.cwd(a.dir)
        ftp.delete(NAME)
    print("PASS: the REU holds the file" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
