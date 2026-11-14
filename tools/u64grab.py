#!/usr/bin/env python3
"""Grab one frame from an Ultimate 64's VIC video stream and save it as PNG.

    python u64grab.py <u64 host> out.png [--me <this machine's IP>] [--port 11000]

Starts the stream to this machine through the REST API
(/v1/streams/video:start), assembles one complete frame from the UDP
packets, stops the stream and writes the picture. The stream carries the
VIC-II's 4-bit colour indices (384 pixels a line), so the PNG uses the
standard C64 palette, not the Ultimate's configured one.
"""
import argparse
import socket
import struct
import sys
import time
import urllib.request

from pngio import write as write_png  # tools/pngio.py

PALETTE = [
    (0x00, 0x00, 0x00, 255), (0xFF, 0xFF, 0xFF, 255), (0x9F, 0x4E, 0x44, 255), (0x6A, 0xBF, 0xC6, 255),
    (0xA0, 0x57, 0xA3, 255), (0x5C, 0xAB, 0x5E, 255), (0x50, 0x45, 0x9B, 255), (0xC9, 0xD4, 0x87, 255),
    (0xA1, 0x68, 0x3C, 255), (0x6D, 0x54, 0x12, 255), (0xCB, 0x7E, 0x75, 255), (0x62, 0x62, 0x62, 255),
    (0x89, 0x89, 0x89, 255), (0x9A, 0xE2, 0x9B, 255), (0x88, 0x7E, 0xCB, 255), (0xAD, 0xAD, 0xAD, 255),
]


def rest(host, path):
    req = urllib.request.Request(f"http://{host}{path}", method="PUT")
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read()


def my_ip_towards(host):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((host, 80))
    ip = s.getsockname()[0]
    s.close()
    return ip


def grab(host, me, port, timeout=5.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    sock.settimeout(1.0)
    rest(host, f"/v1/streams/video:start?ip={me}:{port}")
    try:
        lines = {}
        frame = None
        started = False
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                pkt, _ = sock.recvfrom(2048)
            except socket.timeout:
                continue
            if len(pkt) < 12:
                continue
            _seq, fno, line, width, nlines, bpp, _enc = struct.unpack_from("<HHHHBBH", pkt)
            last = bool(line & 0x8000)
            line &= 0x7FFF
            if not started:
                # wait for a frame boundary so the picture is one frame
                if last:
                    started = True
                continue
            if frame is None:
                frame = fno
            if fno != frame:
                continue
            data = pkt[12:]
            bpl = width * bpp // 8
            for i in range(nlines):
                lines[line + i] = (width, data[i * bpl:(i + 1) * bpl])
            if last:
                break
        if not lines:
            raise SystemExit("no video packets received (firewall? wrong --me address?)")
    finally:
        try:
            rest(host, "/v1/streams/video:stop")
        except Exception:
            pass
        sock.close()
    height = max(lines) + 1
    width = max(w for w, _ in lines.values())
    rows = []
    for y in range(height):
        w, d = lines.get(y, (width, bytes(width // 2)))
        row = []
        for b in d:
            row.append(PALETTE[b & 15])
            row.append(PALETTE[b >> 4])
        rows.append(row[:width] + [(0, 0, 0, 255)] * (width - len(row)))
    return width, height, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host")
    ap.add_argument("out")
    ap.add_argument("--me", help="IP the stream is sent to (default: the route to host)")
    ap.add_argument("--port", type=int, default=11000)
    a = ap.parse_args()
    me = a.me or my_ip_towards(a.host)
    w, h, rows = grab(a.host, me, a.port)
    write_png(a.out, w, h, rows)
    print(f"{a.out}: {w}x{h}")


if __name__ == "__main__":
    sys.exit(main())
