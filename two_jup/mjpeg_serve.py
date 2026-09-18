#!/usr/bin/env python3
"""Turn the incoming RF video stream into something a browser can show in a window.

WHY THIS EXISTS
    The static ffmpeg on these boards has NO ffplay (upstream omits it because
    ffplay needs SDL2, which cannot be linked statically), and its only
    window-capable sink is `xv` -- which fails on BOTH Jupiters with
    "No X-Video adaptors present", because Xorg falls back to the modesetting
    driver and that provides no Xv adaptor. So ffmpeg cannot open a window here
    at all. Chromium can, and it is already installed.

    This decodes the H.264/MPEG-TS arriving over the RF hop and republishes it
    as multipart/x-mixed-replace, which every browser renders natively as live
    video -- no plugin, no player, no extra packages.

WHY NOT `ffmpeg -f mpjpeg -listen 1 http://127.0.0.1:8090`, WHICH NEEDS NO CODE
    `-listen 1` accepts exactly ONE TCP connection for the life of the process.
    Chromium opens a second for /favicon.ico, and every reload opens another, so
    the stream dies the moment you touch the window. This serves any number of
    clients, survives reload, and restarts ffmpeg by itself if the link drops.

DESIGN NOTE -- single-slot frame buffer
    Clients get the LATEST frame, never a queue. A queue would grow without
    bound whenever the browser renders slower than the link delivers, and the
    displayed picture would fall further behind real time forever. Dropping is
    the correct behaviour for live video.
"""
import argparse
import http.server
import socket
import subprocess
import sys
import threading
import time

FFMPEG = "/usr/local/bin/ffmpeg"
SOI = b"\xff\xd8"   # JPEG start-of-image
EOI = b"\xff\xd9"   # JPEG end-of-image


class Latest:
    """One frame slot, guarded by a condition variable."""

    def __init__(self):
        self.buf = None
        self.seq = 0
        self.frames = 0
        self.bytes = 0
        self.cv = threading.Condition()

    def put(self, b):
        with self.cv:
            self.buf = b
            self.seq += 1
            self.frames += 1
            self.bytes += len(b)
            self.cv.notify_all()

    def get(self, last_seq, timeout=15.0):
        """Block until a frame newer than last_seq exists. Returns (buf, seq)."""
        with self.cv:
            if self.seq == last_seq:
                self.cv.wait(timeout)
            return self.buf, self.seq


latest = Latest()
state = {"ff": None, "running": True, "restarts": 0}


def ffmpeg_cmd(args):
    """Decode the RF stream (or a test pattern) into concatenated JPEGs on stdout."""
    if args.test:
        # -re throttles lavfi to real time. Without it the generator free-runs --
        # measured 52 fps for a nominal rate=10 -- which burns a core and makes
        # the fps figures in the log meaningless.
        src = ["-re", "-f", "lavfi", "-i", f"testsrc=size={args.size}:rate={args.fps}"]
    else:
        # nobuffer/low_delay keep latency down; fifo_size absorbs RF bursts, and
        # overrun_nonfatal stops a burst from killing the whole receiver.
        src = ["-fflags", "nobuffer", "-flags", "low_delay",
               "-analyzeduration", "500000", "-probesize", "500000",
               "-f", "mpegts", "-i",
               f"{args.udp}?fifo_size=1000000&overrun_nonfatal=1"]
    return [FFMPEG, "-hide_banner", "-loglevel", "warning", *src,
            "-an", "-c:v", "mjpeg", "-q:v", str(args.q), "-f", "mjpeg", "pipe:1"]


def reader(args):
    """Run ffmpeg, split its output into JPEGs, publish each one.

    ffmpeg is restarted on exit rather than being fatal: a bring-up, a re-arm or
    a momentary loss of carrier all make the decoder give up, and the window
    should recover on its own instead of needing the whole script re-run.
    """
    while state["running"]:
        cmd = ffmpeg_cmd(args)
        print(f"[reader] starting: {' '.join(cmd)}", flush=True)
        try:
            ff = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=None,
                                  bufsize=0)
        except OSError as e:
            print(f"[reader] cannot exec ffmpeg: {e}", flush=True)
            return
        state["ff"] = ff
        buf = bytearray()
        while state["running"]:
            chunk = ff.stdout.read(65536)
            if not chunk:
                break
            buf += chunk
            # Split on EOI. FF bytes inside entropy-coded data are byte-stuffed
            # as FF00, so a bare FFD9 is always a real end-of-image.
            while True:
                end = buf.find(EOI)
                if end < 0:
                    break
                frame = bytes(buf[:end + 2])
                del buf[:end + 2]
                start = frame.find(SOI)
                if start >= 0:
                    latest.put(frame[start:])
        try:
            ff.kill()
        except Exception:
            pass
        if not state["running"]:
            return
        state["restarts"] += 1
        print(f"[reader] ffmpeg exited (restart #{state['restarts']}); "
              f"retrying in 2s", flush=True)
        time.sleep(2)


PAGE = b"""<!doctype html><meta charset=utf-8><title>Jupiter 148 camera</title>
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden}
  img{width:100%;height:100%;object-fit:contain;display:block}
  #msg{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;
       color:#6d7f8b;font:14px system-ui,sans-serif}
</style>
<div id=msg>waiting for the first frame over the RF hop...</div>
<img id=v src="/stream" onload="document.getElementById('msg').remove()"
     onerror="document.getElementById('msg').textContent='stream ended - reload to retry'">
"""


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # multipart streaming, no keep-alive games

    def log_message(self, *a):
        pass  # the access log would drown the useful output at 10 fps

    def do_GET(self):
        if self.path.startswith("/stream"):
            return self.stream()
        if self.path.startswith("/favicon"):
            self.send_response(204)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def stream(self):
        self.send_response(200)
        self.send_header("Age", "0")
        self.send_header("Cache-Control", "no-cache, private")
        self.send_header("Pragma", "no-cache")
        self.send_header("Content-Type",
                         "multipart/x-mixed-replace; boundary=--jpgboundary")
        self.end_headers()
        seq = 0
        try:
            while True:
                frame, seq = latest.get(seq)
                if frame is None:
                    continue
                self.wfile.write(b"--jpgboundary\r\n")
                self.wfile.write(b"Content-Type: image/jpeg\r\n")
                self.wfile.write(b"Content-Length: %d\r\n\r\n" % len(frame))
                self.wfile.write(frame)
                self.wfile.write(b"\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass  # the window was closed; entirely normal


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True   # so a restart is not blocked by TIME_WAIT


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8090)
    p.add_argument("--bind", default="127.0.0.1",
                   help="127.0.0.1 keeps the stream local to this board")
    p.add_argument("--udp", default="udp://10.66.0.1:5002")
    p.add_argument("--q", type=int, default=6, help="MJPEG quality, 2=best 31=worst")
    p.add_argument("--test", action="store_true",
                   help="ignore the RF link, serve a local test pattern")
    p.add_argument("--size", default="640x480")
    p.add_argument("--fps", type=int, default=10)
    args = p.parse_args()

    t = threading.Thread(target=reader, args=(args,), daemon=True)
    t.start()

    srv = Server((args.bind, args.port), Handler)
    print(f"[serve] http://{args.bind}:{args.port}/  "
          f"({'TEST PATTERN' if args.test else args.udp})", flush=True)

    def stats():
        last = 0
        while True:
            time.sleep(10)
            n = latest.frames
            print(f"[serve] {n - last} frames in 10s "
                  f"({(n - last) / 10:.1f} fps), {latest.bytes / 1024:.0f} KiB total",
                  flush=True)
            last = n
    threading.Thread(target=stats, daemon=True).start()

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        state["running"] = False
        if state["ff"]:
            try:
                state["ff"].kill()
            except Exception:
                pass


if __name__ == "__main__":
    main()
