#!/usr/bin/env python3
"""Live view of an Ultimate 64's screen in a web browser.

    python u64live.py <u64 host> [--http 8064] [--me <this machine's IP>] [--udp 11000]

Starts the Ultimate's VIC video stream to this machine (REST API
/v1/streams/video:start), assembles the frames from the UDP packets and
serves them at http://localhost:<http>/ : a page that shows the newest frame
about 25 times a second, plus /frame.png (one frame) and /status (JSON).
Stops the stream on exit. Needs Pillow, and inbound UDP on the --udp port
allowed by the firewall. The stream carries the VIC-II's 4-bit colours,
so the page uses the standard C64 palette.
"""
import argparse
import atexit
import io
import json
import socket
import struct
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image

from u64grab import PALETTE, my_ip_towards, rest

FLAT_PALETTE = [c for rgba in PALETTE for c in rgba[:3]]

PAGE = b"""<!doctype html>
<html><head><meta charset="utf-8"><title>Ultimate 64 live</title>
<style>
 html,body{margin:0;height:100%;background:#111;color:#bbb;font:13px system-ui,sans-serif}
 body{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px}
 img{image-rendering:pixelated;width:min(96vw,calc(88vh*384/272));aspect-ratio:384/272;background:#000}
</style></head><body>
<img id="f" alt="Ultimate 64 screen">
<div id="s">connecting</div>
<script>
const img = document.getElementById('f'), s = document.getElementById('s');
let last = null;
async function frame() {
  try {
    const r = await fetch('/frame.png?' + Date.now());
    if (r.status === 200) {
      const u = URL.createObjectURL(await r.blob());
      img.onload = () => { if (last) URL.revokeObjectURL(last); last = u; };
      img.src = u;
    }
  } catch (e) {}
  setTimeout(frame, 40);
}
async function status() {
  try {
    const j = await (await fetch('/status')).json();
    s.textContent = j.frames ? `${j.host} - ${j.fps.toFixed(1)} frames/s - ${j.width}x${j.height}`
                             : `${j.host} - waiting for the video stream (firewall?)`;
  } catch (e) { s.textContent = 'viewer stopped'; }
  setTimeout(status, 1000);
}
frame(); status();
</script></body></html>
"""


class Stream:
    def __init__(self, host, me, port):
        self.host, self.me, self.port = host, me, port
        self.lock = threading.Lock()
        self.png = None
        self.size = (0, 0)
        self.frames = 0
        self.times = []

    def start(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 21)
        self.sock.bind(("0.0.0.0", self.port))
        self.sock.settimeout(1.0)
        rest(self.host, f"/v1/streams/video:start?ip={self.me}:{self.port}")
        atexit.register(self.stop)
        threading.Thread(target=self.run, daemon=True).start()

    def stop(self):
        try:
            rest(self.host, "/v1/streams/video:stop")
        except Exception:
            pass

    def run(self):
        lines = {}
        frame = None
        width = 384
        while True:
            try:
                pkt, _ = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            if len(pkt) < 12:
                continue
            _seq, fno, line, w, nlines, bpp, _enc = struct.unpack_from("<HHHHBBH", pkt)
            last = bool(line & 0x8000)
            line &= 0x7FFF
            if fno != frame:
                lines = {}
                frame = fno
            width = w
            bpl = w * bpp // 8
            data = pkt[12:]
            for i in range(nlines):
                lines[line + i] = data[i * bpl:(i + 1) * bpl]
            if last:
                self.publish(lines, width, line + nlines)
                lines = {}
                frame = None

    def publish(self, lines, width, height):
        if len(lines) < height * 3 // 4:          # too many packets lost: skip it
            return
        raw = bytearray(width * height)
        for y, d in lines.items():
            if y >= height:
                continue
            o = y * width
            for x, b in enumerate(d):
                raw[o + 2 * x] = b & 15
                raw[o + 2 * x + 1] = b >> 4
        img = Image.frombytes("P", (width, height), bytes(raw))
        img.putpalette(FLAT_PALETTE)
        buf = io.BytesIO()
        img.save(buf, "PNG", compress_level=1)
        now = time.time()
        with self.lock:
            self.png = buf.getvalue()
            self.size = (width, height)
            self.frames += 1
            self.times = [t for t in self.times if now - t < 2] + [now]

    def status(self):
        with self.lock:
            fps = (len(self.times) - 1) / max(self.times[-1] - self.times[0], 1e-6) if len(self.times) > 1 else 0
            return {"host": self.host, "frames": self.frames, "fps": fps,
                    "width": self.size[0], "height": self.size[1]}


def handler_for(stream):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, kind, body):
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/":
                self.send(200, "text/html; charset=utf-8", PAGE)
            elif path == "/frame.png":
                with stream.lock:
                    png = stream.png
                if png is None:
                    self.send(204, "image/png", b"")
                else:
                    self.send(200, "image/png", png)
            elif path == "/status":
                self.send(200, "application/json", json.dumps(stream.status()).encode())
            else:
                self.send(404, "text/plain", b"not found")
    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host")
    ap.add_argument("--http", type=int, default=8064)
    ap.add_argument("--me", help="IP the stream is sent to (default: the route to host)")
    ap.add_argument("--udp", type=int, default=11000)
    a = ap.parse_args()
    stream = Stream(a.host, a.me or my_ip_towards(a.host), a.udp)
    stream.start()
    server = ThreadingHTTPServer(("127.0.0.1", a.http), handler_for(stream))
    print(f"streaming {a.host} -> {stream.me}:{a.udp}; view at http://localhost:{a.http}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stream.stop()


if __name__ == "__main__":
    sys.exit(main())
