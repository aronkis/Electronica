#!/usr/bin/env python3
"""Capture the USB webcam ON THE BOARD, with the Python standard library only.

WHY THIS EXISTS
  stream_webcam.sh captures on WSL because the boards have no media stack at
  all: no ffmpeg, no ffplay, no gstreamer, no v4l2-ctl. The 146 board also has
  no default route and no working DNS, so `apt install ffmpeg` cannot fetch
  anything. Nothing can be installed -- so nothing is used. This module talks
  to V4L2 directly through ioctls and needs only python3 (3.13.5 is present).

WHY NO ENCODER IS NEEDED
  The Logitech C270 (046d:0825) produces Motion-JPEG *in hardware* -- format[1]
  MJPG is flagged COMPRESSED by the driver. Every frame the kernel hands us is
  already a complete JPEG. So the board never has to encode, which is the one
  thing it has no software for and not much CPU for either.

WHY mmap AND NOT read()
  VIDIOC_QUERYCAP on this board reports STREAMING=True but READWRITE=False, so
  a plain read() on /dev/video0 returns EINVAL. Frames must be pulled with the
  REQBUFS/QBUF/DQBUF mmap streaming API. That is most of the code below.

MODES
  --stats [SEC]      prove the camera works; measure real frame size and fps
  --http PORT        serve MJPEG over HTTP; view in ANY browser, no player
  --udp HOST:PORT    datagram the frames (this is the RF tun0 hop path)
  --file OUT.mjpg    record to a file

Sizes/rates come from the driver's own enumeration; 320x240 is the default
because it is the only setting that comfortably fits the ~2 Mbit/s the RF hop
sustains (see the bandwidth note under --stats).
"""

import ctypes
import errno
import fcntl
import mmap
import os
import select
import socket
import struct
import sys
import threading
import time

# ---------------------------------------------------------------- V4L2 ABI --
# Encoded by hand because there is no python-v4l2 module on the board and no
# way to install one. Numbers are _IOC(dir,'V',nr,size) for a 64-bit kernel;
# the struct sizes are the aarch64 ones (v4l2_buffer is 88 bytes, not 68).
VIDIOC_QUERYCAP   = 0x80685600  # _IOR ('V',  0, v4l2_capability[104])
VIDIOC_S_FMT      = 0xC0D05605  # _IOWR('V',  5, v4l2_format[208])
VIDIOC_REQBUFS    = 0xC0145608  # _IOWR('V',  8, v4l2_requestbuffers[20])
VIDIOC_QUERYBUF   = 0xC0585609  # _IOWR('V',  9, v4l2_buffer[88])
VIDIOC_QBUF       = 0xC058560F  # _IOWR('V', 15, v4l2_buffer[88])
VIDIOC_DQBUF      = 0xC0585611  # _IOWR('V', 17, v4l2_buffer[88])
VIDIOC_STREAMON   = 0x40045612  # _IOW ('V', 18, int)
VIDIOC_STREAMOFF  = 0x40045613  # _IOW ('V', 19, int)
VIDIOC_S_PARM     = 0xC0CC5616  # _IOWR('V', 22, v4l2_streamparm[204])

BUF_TYPE_CAPTURE = 1
MEMORY_MMAP      = 1
FIELD_NONE       = 1
BUF_FLAG_ERROR   = 0x0040
CAP_TIMEPERFRAME = 0x1000

V4L2_BUFFER_SIZE = 88


def fourcc(s):
    return s[0] | (s[1] << 8) | (s[2] << 16) | (s[3] << 24)


PIX_MJPG = fourcc(b"MJPG")


class V4L2Camera:
    """Minimal MJPEG capture over the V4L2 mmap streaming API."""

    def __init__(self, dev="/dev/video0", width=320, height=240, fps=10, nbufs=4):
        self.dev, self.width, self.height = dev, width, height
        self.fps, self.nbufs = fps, nbufs
        self.fd = None
        self.bufs = []          # list of (mmap object, length)
        self.streaming = False

    # -- setup -------------------------------------------------------------
    def open(self):
        self.fd = os.open(self.dev, os.O_RDWR | os.O_NONBLOCK)

        cap = bytearray(104)
        fcntl.ioctl(self.fd, VIDIOC_QUERYCAP, cap)
        devcaps = struct.unpack_from("<I", cap, 88)[0]
        if not devcaps & 0x04000000:
            raise RuntimeError(f"{self.dev} cannot stream (devcaps=0x{devcaps:08x})")

        self._set_format()
        self._set_fps()
        self._request_buffers()
        self._queue_all()
        fcntl.ioctl(self.fd, VIDIOC_STREAMON, struct.pack("<i", BUF_TYPE_CAPTURE))
        self.streaming = True
        return self

    def _set_format(self):
        # v4l2_format: type at 0, then the pix union at offset 8.
        f = bytearray(208)
        struct.pack_into("<I", f, 0, BUF_TYPE_CAPTURE)
        struct.pack_into("<IIII", f, 8, self.width, self.height, PIX_MJPG, FIELD_NONE)
        fcntl.ioctl(self.fd, VIDIOC_S_FMT, f)
        # The driver rewrites the struct with what it ACTUALLY granted. Trust
        # that, not what we asked for -- silently getting a different size is
        # how you end up debugging a "corrupt" stream that is really fine.
        w, h, pf = struct.unpack_from("<III", f, 8)
        self.width, self.height = w, h
        if pf != PIX_MJPG:
            raise RuntimeError(
                f"driver refused MJPG and gave '{pf.to_bytes(4,'little').decode()}' instead"
            )

    def _set_fps(self):
        if not self.fps:
            return
        p = bytearray(204)
        struct.pack_into("<I", p, 0, BUF_TYPE_CAPTURE)
        # v4l2_captureparm starts at 4; timeperframe (num,den) at 12.
        struct.pack_into("<II", p, 12, 1, int(self.fps))
        try:
            fcntl.ioctl(self.fd, VIDIOC_S_PARM, p)
            capability, = struct.unpack_from("<I", p, 4)
            num, den = struct.unpack_from("<II", p, 12)
            if capability & CAP_TIMEPERFRAME and num:
                self.fps = den / num
        except OSError:
            pass  # rate control is optional; the encoder-side cap still applies

    def _request_buffers(self):
        r = bytearray(20)
        struct.pack_into("<III", r, 0, self.nbufs, BUF_TYPE_CAPTURE, MEMORY_MMAP)
        fcntl.ioctl(self.fd, VIDIOC_REQBUFS, r)
        granted = struct.unpack_from("<I", r, 0)[0]
        if granted < 2:
            raise RuntimeError(f"driver granted only {granted} buffers")
        self.nbufs = granted

        for i in range(self.nbufs):
            b = bytearray(V4L2_BUFFER_SIZE)
            struct.pack_into("<II", b, 0, i, BUF_TYPE_CAPTURE)
            struct.pack_into("<I", b, 60, MEMORY_MMAP)
            fcntl.ioctl(self.fd, VIDIOC_QUERYBUF, b)
            offset, = struct.unpack_from("<I", b, 64)   # m.offset
            length, = struct.unpack_from("<I", b, 72)
            mm = mmap.mmap(self.fd, length, mmap.MAP_SHARED,
                           mmap.PROT_READ | mmap.PROT_WRITE, offset=offset)
            self.bufs.append((mm, length))

    def _queue_all(self):
        for i in range(self.nbufs):
            self._qbuf(i)

    def _qbuf(self, index):
        b = bytearray(V4L2_BUFFER_SIZE)
        struct.pack_into("<II", b, 0, index, BUF_TYPE_CAPTURE)
        struct.pack_into("<I", b, 60, MEMORY_MMAP)
        fcntl.ioctl(self.fd, VIDIOC_QBUF, b)

    # -- capture -----------------------------------------------------------
    def frames(self, timeout=5.0):
        """Yield complete JPEG frames as bytes until the caller stops asking."""
        while True:
            r, _, _ = select.select([self.fd], [], [], timeout)
            if not r:
                raise TimeoutError(
                    f"no frame for {timeout}s -- camera stopped producing "
                    "(USB dropout, or another process grabbed the device)"
                )
            b = bytearray(V4L2_BUFFER_SIZE)
            struct.pack_into("<I", b, 4, BUF_TYPE_CAPTURE)
            struct.pack_into("<I", b, 60, MEMORY_MMAP)
            try:
                fcntl.ioctl(self.fd, VIDIOC_DQBUF, b)
            except OSError as e:
                if e.errno == errno.EAGAIN:
                    continue
                raise
            index, = struct.unpack_from("<I", b, 0)
            bytesused, = struct.unpack_from("<I", b, 8)
            flags, = struct.unpack_from("<I", b, 12)

            data = None
            if not flags & BUF_FLAG_ERROR and bytesused:
                mm = self.bufs[index][0]
                # Copy out BEFORE re-queueing: once queued the driver owns the
                # buffer again and will overwrite it under us.
                data = mm[:bytesused]
            self._qbuf(index)
            if data:
                yield bytes(data)

    def close(self):
        if self.fd is None:
            return
        try:
            if self.streaming:
                fcntl.ioctl(self.fd, VIDIOC_STREAMOFF,
                            struct.pack("<i", BUF_TYPE_CAPTURE))
        except OSError:
            pass
        for mm, _ in self.bufs:
            mm.close()
        self.bufs.clear()
        os.close(self.fd)
        self.fd = None

    def __enter__(self):
        return self.open()

    def __exit__(self, *exc):
        self.close()


# ------------------------------------------------------------------ modes --
def mode_stats(cam, seconds):
    """Measure the camera, charging UVC start-up to its own line.

    Time-to-first-frame and steady-state rate are completely different faults
    and must not be averaged together: a UVC camera can idle for seconds
    before the first buffer completes, and folding that into the mean makes a
    perfectly healthy 10 fps stream read as 0.3 fps.
    """
    print(f"capturing {cam.width}x{cam.height} MJPG for {seconds}s ...", flush=True)
    t0 = time.monotonic()
    n = total = biggest = 0
    t_first = None
    t_steady = 0.0
    steady_n = steady_bytes = 0

    for jpg in cam.frames(timeout=10.0):
        now = time.monotonic()
        n += 1
        total += len(jpg)
        biggest = max(biggest, len(jpg))
        if not jpg.startswith(b"\xff\xd8"):
            print(f"  WARNING frame {n} is not a JPEG (starts {jpg[:4].hex()})")
        if t_first is None:
            t_first = now - t0
            t_steady = now          # steady-state clock starts at frame 1
        else:
            steady_n += 1
            steady_bytes += len(jpg)
        if now - t0 >= seconds:
            break

    el = time.monotonic() - t0
    if not n:
        print("NO FRAMES -- camera opened but produced nothing")
        return 1
    span = time.monotonic() - t_steady
    fps = steady_n / span if steady_n and span > 0 else 0.0
    avg = total / n
    mbit = steady_bytes * 8 / span / 1e6 if steady_n and span > 0 else 0.0
    print(f"  first frame: {t_first*1000:.0f} ms after STREAMON")
    print(f"  frames    : {n} in {el:.1f}s  = {fps:.1f} fps steady-state")
    print(f"  frame size: avg {avg/1024:.1f} KiB, max {biggest/1024:.1f} KiB")
    print(f"  bitrate   : {mbit:.2f} Mbit/s")
    if steady_n == 0:
        print("  -> only ONE frame arrived; the camera is not streaming freely")
        return 1
    # The RF hop sustains roughly 2 Mbit/s (stream_webcam.sh keeps H.264 at
    # 400k for margin). Say plainly whether this setting fits.
    if mbit > 1.6:
        print(f"  -> TOO FAT for the RF hop (~2 Mbit/s). Drop --fps or --size.")
    else:
        print(f"  -> fits the RF hop with margin.")
    return 0


def mode_file(cam, path):
    print(f"recording to {path} (Ctrl-C to stop)", flush=True)
    n = 0
    with open(path, "wb") as fh:
        try:
            for jpg in cam.frames():
                fh.write(jpg)
                n += 1
                if n % 30 == 0:
                    print(f"\r  {n} frames", end="", flush=True)
        except KeyboardInterrupt:
            pass
    print(f"\nwrote {n} frames to {path}")
    return 0


def mode_udp(cam, host, port, src=None):
    """Send each JPEG as its own datagram, length-prefixed and fragmented.

    A 320x240 JPEG is ~8-15 KiB, well over the 1516-byte tun0 MTU, so it must
    be chopped. Each chunk carries (frame_seq, chunk_idx, chunk_count) so the
    receiver can drop a frame that lost a piece instead of feeding a decoder
    a truncated JPEG -- a half frame is what makes a viewer wedge rather than
    just flicker.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if src:
        s.bind((src, 0))
    dst = (host, port)
    PAYLOAD = 1400          # under the 1516 tun0 MTU with room for headers
    seq, sent = 0, 0
    print(f"sending MJPEG to {host}:{port} (Ctrl-C to stop)", flush=True)
    try:
        for jpg in cam.frames():
            chunks = [jpg[i:i + PAYLOAD] for i in range(0, len(jpg), PAYLOAD)]
            for i, c in enumerate(chunks):
                hdr = struct.pack("<IHH", seq, i, len(chunks))
                try:
                    s.sendto(hdr + c, dst)
                    sent += 1
                except OSError:
                    pass    # a full socket buffer must not kill the stream
            seq += 1
            if seq % 30 == 0:
                print(f"\r  {seq} frames / {sent} datagrams", end="", flush=True)
    except KeyboardInterrupt:
        pass
    print(f"\nsent {seq} frames / {sent} datagrams")
    return 0


def mode_http(cam, port):
    """Serve multipart/x-mixed-replace: any browser plays this with no plugin.

    Capture runs in one thread into a single latest-frame slot. Slow clients
    therefore drop frames instead of applying backpressure to the camera --
    with a queue, one stalled browser would stall the capture for everyone.
    """
    latest = {"jpg": None, "seq": 0}
    cond = threading.Condition()
    stop = threading.Event()

    def grab():
        try:
            for jpg in cam.frames():
                with cond:
                    latest["jpg"] = jpg
                    latest["seq"] += 1
                    cond.notify_all()
                if stop.is_set():
                    break
        except Exception as e:
            print(f"\ncapture thread died: {e}", file=sys.stderr)
            with cond:
                latest["jpg"] = None
                cond.notify_all()

    threading.Thread(target=grab, daemon=True).start()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(8)

    PAGE = (
        b"<!doctype html><title>146 webcam</title>"
        b"<style>body{margin:0;background:#111;display:grid;place-items:center;"
        b"height:100vh}img{max-width:100%;image-rendering:pixelated}</style>"
        b"<img src='/stream.mjpg'>"
    )

    def serve(conn):
        try:
            conn.settimeout(10)
            req = conn.recv(2048).split(b"\r\n")[0]
            path = req.split(b" ")[1] if len(req.split(b" ")) > 1 else b"/"
            if path != b"/stream.mjpg":
                conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n"
                             b"Content-Length: %d\r\n\r\n%s" % (len(PAGE), PAGE))
                return
            conn.sendall(b"HTTP/1.0 200 OK\r\n"
                         b"Cache-Control: no-store\r\n"
                         b"Content-Type: multipart/x-mixed-replace; boundary=f\r\n\r\n")
            conn.settimeout(None)
            last = 0
            while not stop.is_set():
                with cond:
                    cond.wait_for(lambda: latest["seq"] != last, timeout=5)
                    jpg, last = latest["jpg"], latest["seq"]
                if jpg is None:
                    break
                conn.sendall(b"--f\r\nContent-Type: image/jpeg\r\n"
                             b"Content-Length: %d\r\n\r\n" % len(jpg))
                conn.sendall(jpg)
                conn.sendall(b"\r\n")
        except (OSError, socket.timeout):
            pass        # a browser closing mid-stream is normal, not an error
        finally:
            conn.close()

    addrs = []
    try:
        out = os.popen("ip -4 -o addr show scope global").read()
        addrs = [ln.split()[3].split("/")[0] for ln in out.strip().splitlines()]
    except Exception:
        pass
    print(f"MJPEG server on port {port} -- open one of:")
    for a in addrs or ["<board-ip>"]:
        print(f"    http://{a}:{port}/")
    print("Ctrl-C to stop", flush=True)

    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=serve, args=(conn,), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        srv.close()
    return 0


def main(argv):
    import argparse
    p = argparse.ArgumentParser(
        description="On-board webcam capture (stdlib only, no ffmpeg needed)")
    p.add_argument("--dev", default="/dev/video0")
    p.add_argument("--size", default="320x240",
                   help="WxH; the C270 offers 160x120 .. 1280x960 in MJPG")
    p.add_argument("--fps", type=float, default=10,
                   help="0 = let the camera pick its native rate")
    p.add_argument("--stats", nargs="?", type=float, const=5, metavar="SEC")
    p.add_argument("--http", type=int, metavar="PORT")
    p.add_argument("--udp", metavar="HOST:PORT")
    p.add_argument("--src", metavar="IP", help="bind source IP (e.g. tun0 10.66.0.1)")
    p.add_argument("--file", metavar="OUT.mjpg")
    a = p.parse_args(argv)

    w, _, h = a.size.partition("x")
    cam = V4L2Camera(a.dev, int(w), int(h), a.fps)
    try:
        cam.open()
    except OSError as e:
        if e.errno == errno.EBUSY:
            sys.exit(f"{a.dev} is busy -- another capture is already running")
        if e.errno == errno.ENOENT:
            sys.exit(f"{a.dev} does not exist -- is the camera plugged into this board?")
        sys.exit(f"cannot open {a.dev}: {e}")

    print(f"{a.dev}: {cam.width}x{cam.height} MJPG @ {cam.fps:g} fps, "
          f"{cam.nbufs} buffers", flush=True)
    try:
        if a.http:
            return mode_http(cam, a.http)
        if a.udp:
            host, _, port = a.udp.partition(":")
            return mode_udp(cam, host, int(port or 5000), a.src)
        if a.file:
            return mode_file(cam, a.file)
        return mode_stats(cam, a.stats or 5)
    finally:
        cam.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
