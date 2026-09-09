#!/usr/bin/env python3
"""score_frames.py -- per-frame CRC verdict for a real-traffic IQ replay.

Parses the sim_byte_iq_perframe outputs (<pfx>_rxw.txt + <pfx>_frames.txt),
reassembles each delivered RX frame (byte_rx_last-delimited runs of 64-bit
words, little-endian bytes -> 1528 B for f1536), and validates it with the
HOST frame contract (host_app_k5/qpsk_frame.c):

    [0..1] magic 'QK'  [2..3] len  [4..7] seq  [8..11] CRC32(zlib poly,
    CRC field zeroed, over header+payload only)

Whitening: capture ran with QPSK_WHITEN unset (bringup_r2r3.sh WHITEN=0),
so no de-whitening is applied.

Capture-frame mapping: frame k of the capture starts at sample k*SPF; the sim
delivers its last word at clk ~= 100 + cadence*(sample_index) + pipeline
latency, so  capframe ~= (clk_last - clk0_offset) / (SPF*cadence)  where
clk0_offset is calibrated from the FIRST CRC-good frame's seq delta vs its
clk (we only need per-frame *relative* indexing; seq gives exact TX ordering).

Usage: score_frames.py PFX [--spf 49332] [--cadence 4] [--sample-offset N]
Emits PFX_verdict.csv (outframe, clk, capframe_est, seq, len, crc_ok) and a
summary with consecutive-failure runs.
"""
import argparse
import sys
import zlib


def load_words(path):
    """[(u64, last, user)] from a _rxw.txt"""
    out = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            w, last, user = ln.split(",")
            out.append((int(w, 16), int(last), int(user)))
    return out


def load_frameclk(path):
    """outframe -> clk of byte_rx_last, from a _frames.txt"""
    m = {}
    with open(path) as f:
        for ln in f:
            if ln.startswith("#") or not ln.strip():
                continue
            p = ln.split()
            m[int(p[0])] = int(p[1])
    return m


def crc32_frame(buf):
    """qpsk_crc32 == zlib.crc32; over header+payload with CRC field zeroed."""
    if len(buf) < 12 or buf[0] != 0x51 or buf[1] != 0x4B:
        return None, None, None
    length = buf[2] | (buf[3] << 8)
    if length > len(buf) - 12:
        return None, None, None
    seq = buf[4] | (buf[5] << 8) | (buf[6] << 16) | (buf[7] << 24)
    crc_rx = buf[8] | (buf[9] << 8) | (buf[10] << 16) | (buf[11] << 24)
    tmp = bytearray(buf[: 12 + length])
    tmp[8:12] = b"\x00\x00\x00\x00"
    ok = zlib.crc32(bytes(tmp)) & 0xFFFFFFFF == crc_rx
    return ok, seq, length


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pfx")
    ap.add_argument("--spf", type=int, default=49332)
    ap.add_argument("--cadence", type=int, default=4)
    ap.add_argument("--sample-offset", type=int, default=0,
                    help="first sample of this slice within the full pair.iq")
    ap.add_argument("--words-per-frame", type=int, default=191)
    a = ap.parse_args()

    words = load_words(a.pfx + "_rxw.txt")
    fclk = load_frameclk(a.pfx + "_frames.txt")

    # split into frames on 'last'
    frames, cur = [], []
    for w, last, user in words:
        cur.append(w)
        if last:
            frames.append(cur)
            cur = []
    if cur:
        print(f"note: {len(cur)} trailing words without last (dropped)")

    rows, nbad = [], 0
    for i, fw in enumerate(frames):
        buf = b"".join(w.to_bytes(8, "little") for w in fw)
        ok, seq, length = crc32_frame(buf)
        short = len(fw) != a.words_per_frame
        good = bool(ok) and not short
        if not good:
            nbad += 1
        clk = fclk.get(i, -1)
        # capture frame index estimate: the last word of capture-frame k is
        # decoded shortly after its final sample k*SPF+SPF-1 enters, i.e.
        # clk ~= 100 + cadence*(off + (k+1)*SPF) + lat  ->  invert w/ floor.
        capf = -1
        if clk >= 0:
            capf = (clk - 100) // (a.cadence * a.spf) - 1 + 0  # coarse
        rows.append((i, clk, capf, seq if seq is not None else -1,
                     length if length is not None else -1,
                     len(fw), int(good)))

    with open(a.pfx + "_verdict.csv", "w") as f:
        f.write("outframe,clk,capframe_est,seq,len,words,crc_ok\n")
        for r in rows:
            f.write(",".join(str(x) for x in r) + "\n")

    # summary + consecutive-fail runs (in delivered-frame order) + seq gaps
    print(f"{a.pfx}: delivered={len(frames)} bad={nbad} good={len(frames)-nbad}")
    runs, run = [], 0
    for r in rows:
        if not r[6]:
            run += 1
        else:
            if run:
                runs.append((r[0] - run, run))
            run = 0
    if run:
        runs.append((len(rows) - run, run))
    if runs:
        print("fail runs (start_outframe,len):", runs)
    # seq continuity across good frames -> undelivered frames
    prev = None
    gaps = []
    for r in rows:
        if r[6]:
            if prev is not None and r[3] != prev + 1:
                gaps.append((prev, r[3], r[3] - prev - 1))
            prev = r[3]
    if gaps:
        print("seq gaps between good frames (prev_seq,next_seq,missing):", gaps)
    return 0


if __name__ == "__main__":
    sys.exit(main())
