#!/usr/bin/env python3
"""Live view of an Ultimate 64's screen in a web browser.

    python u64live.py <u64 host> [--http 8064] [--me <this machine's IP>] [--udp 11000]

Starts the Ultimate's VIC video stream to this machine (REST API
/v1/streams/video:start), assembles the frames from the UDP packets and
serves them at http://localhost:<http>/ : a page that shows the newest frame
about 25 times a second, plus /frame.png (one frame) and /status (JSON).
On the page (u64live.html) the keyboard, and a joystick on the arrow keys,
go to the C64 through /v1/machine:input (firmware 3.15+, Ultimate 64
class only), with buttons for reset, the Ultimate menu and RESTORE. The audio stream
comes in on the same UDP port and plays on the page after Sound on.
Stops the stream on exit. Needs Pillow, and inbound UDP on the --udp port
allowed by the firewall. The stream carries the VIC-II's 4-bit colours,
so the page uses the standard C64 palette.
"""
import argparse
import atexit
import io
import json
import queue
import socket
import struct
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image

from u64grab import PALETTE, my_ip_towards, rest

# Ultimate audio stream: 2-byte sequence number, then 192 stereo frames of
# 16-bit little-endian samples, 250 packets a second (48 kHz).
AUDIO_PACKET = 2 + 192 * 4

FLAT_PALETTE = [c for rgba in PALETTE for c in rgba[:3]]

PAGE = Path(__file__).with_name("u64live.html")   # read on each request


class Stream:
    def __init__(self, host, me, port):
        self.host, self.me, self.port = host, me, port
        self.lock = threading.Lock()
        self.png = None
        self.size = (0, 0)
        self.frames = 0
        self.times = []
        self.listeners = []     # one queue.Queue of PCM chunks per /audio client

    def start(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 21)
        self.sock.bind(("0.0.0.0", self.port))
        self.sock.settimeout(1.0)
        rest(self.host, f"/v1/streams/video:start?ip={self.me}:{self.port}")
        # audio on the same port: its packets are 770 bytes, video's 780
        rest(self.host, f"/v1/streams/audio:start?ip={self.me}:{self.port}")
        atexit.register(self.stop)
        threading.Thread(target=self.run, daemon=True).start()

    def stop(self):
        try:
            rest(self.host, "/v1/streams/video:stop")
            rest(self.host, "/v1/streams/audio:stop")
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
            if len(pkt) == AUDIO_PACKET:
                self.audio(pkt[2:])
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

    def audio(self, pcm):
        with self.lock:
            listeners = list(self.listeners)
        for q in listeners:
            if q.qsize() < 50:                 # a stalled client loses audio, not memory
                q.put(pcm)

    def listen(self):
        q = queue.Queue()
        with self.lock:
            self.listeners.append(q)
        return q

    def unlisten(self, q):
        with self.lock:
            self.listeners.remove(q)

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
                self.send(200, "text/html; charset=utf-8", PAGE.read_bytes())
            elif path == "/frame.png":
                with stream.lock:
                    png = stream.png
                if png is None:
                    self.send(204, "image/png", b"")
                else:
                    self.send(200, "image/png", png)
            elif path == "/audio":
                # raw PCM, 16-bit little-endian stereo at 48 kHz, until the client goes
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                q = stream.listen()
                try:
                    while True:
                        try:
                            chunk = q.get(timeout=2)
                        except queue.Empty:
                            continue
                        self.wfile.write(chunk)
                        self.wfile.flush()
                except OSError:
                    pass
                finally:
                    stream.unlisten(q)
            elif path == "/status":
                self.send(200, "application/json", json.dumps(stream.status()).encode())
            else:
                self.send(404, "text/plain", b"not found")

        def do_POST(self):
            path, _, query = self.path.partition("?")
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if path == "/input":
                # keyboard and joystick: firmware 3.15+, Ultimate 64 class only
                code, reply = forward(stream.host, "POST", "/v1/machine:input", body)
            elif path == "/action" and query in ACTIONS:
                code, reply = forward(stream.host, "PUT", ACTIONS[query], None)
            else:
                code, reply = 404, b'{"errors": ["not found"]}'
            self.send(code, "application/json", reply)
    return Handler


ACTIONS = {"do=reset": "/v1/machine:reset", "do=menu": "/v1/machine:menu_button"}


def forward(host, method, route, body):
    """Pass one REST call on to the Ultimate; return (status, JSON body)."""
    req = urllib.request.Request(f"http://{host}{route}", data=body, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read() or json.dumps({"errors": [str(e)]}).encode()
    except OSError as e:
        return 502, json.dumps({"errors": [str(e)]}).encode()


class IPv6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


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
    # Browsers try "localhost" as ::1 first; without a listener there every
    # request waits about 200 ms on Windows, which makes typing crawl.
    try:
        server6 = IPv6Server(("::1", a.http), handler_for(stream))
        threading.Thread(target=server6.serve_forever, daemon=True).start()
    except OSError:
        pass
    print(f"streaming {a.host} -> {stream.me}:{a.udp}; view at http://localhost:{a.http}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stream.stop()


if __name__ == "__main__":
    sys.exit(main())
