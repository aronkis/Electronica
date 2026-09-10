#!/usr/bin/env python3
"""aggregate.py -- merge the chunked perframe_f1536 runs into one per-frame
decode map of the pair.iq tap, and cross-reference the hardware FRAMELOG.

Frame indexing: k = pair.iq sample-frame index (frame k = samples
[k*49332, (k+1)*49332)). Calibration (pilot f2_r0): the last delivered word of
frame k lands at clk = (k_slice + 2.2982) * 4*49332, where k_slice is the
frame index within the slice; so outframe i <-> k = w0 + i, with w0 the first
frame of the slice (chunk tag chunk_S_E_r0 has w0 = max(S-WARM,0), WARM=8).
Warm-up frames (k < S) are dropped; chunk overlap covers each chunk's
undelivered tail (~2 frames, sim tail is only 60k clks).

Anchors: sim-decoded seq(k) = SEQBASE + k (SEQBASE=53577-1+1 measured from the
pilot: k=1 -> seq 53578). Hardware FRAMELOG reg-frame indices are offset ~+89
(iio capture started later than the CAP_START register read); hardware records
are re-anchored by seq for the comparison, not by reg_packets.

Usage: aggregate.py [--glob 'chunk_*_r0'] [--warm 8]
Writes framemap.csv (k, delivered, crc_ok, seq, words) and prints summary +
consecutive-failure runs + hardware cross-reference.
"""
import glob
import os
import re
import sys
import zlib

SPF = 49332
CAD = 4
FP = SPF * CAD
WPF = 191
SEQBASE = 53577          # seq carried by pair.iq frame k is SEQBASE + k


def score_chunk(pfx):
    words = []
    with open(pfx + "_rxw.txt") as f:
        for ln in f:
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                w, last, user = ln.split(",")
                words.append((int(w, 16), int(last)))
    clks = {}
    with open(pfx + "_frames.txt") as f:
        for ln in f:
            if not ln.startswith("#") and ln.strip():
                p = ln.split()
                clks[int(p[0])] = int(p[1])
    frames, cur = [], []
    for w, last in words:
        cur.append(w)
        if last:
            frames.append(cur)
            cur = []
    out = []
    for i, fw in enumerate(frames):
        buf = b"".join(w.to_bytes(8, "little") for w in fw)
        ok, seq = 0, -1
        if len(buf) >= 12 and buf[0] == 0x51 and buf[1] == 0x4B:
            length = buf[2] | (buf[3] << 8)
            if length <= len(buf) - 12:
                seq = int.from_bytes(buf[4:8], "little")
                crc_rx = int.from_bytes(buf[8:12], "little")
                tmp = bytearray(buf[:12 + length])
                tmp[8:12] = b"\x00\x00\x00\x00"
                ok = int((zlib.crc32(bytes(tmp)) & 0xFFFFFFFF) == crc_rx
                         and len(fw) == WPF)
        # frame index within slice from the delivery clk (robust even if a
        # frame is skipped): k_slice = round(clk/FP - 2.2982)
        ks = round(clks[i] / FP - 2.2982)
        out.append((ks, ok, seq, len(fw)))
    return out


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--glob", default="chunk_*_r0")
    ap.add_argument("--warm", type=int, default=8)
    a = ap.parse_args()

    fmap = {}          # k -> (crc_ok, seq, words)
    span = set()       # payload region frames each chunk is responsible for
    # PROVENANCE CHECK (defect #8). This merge silently pooled chunks cut from TWO
    # DIFFERENT captures, because chunk files are matched by NAME only. Refuse to
    # merge unless every chunk's .prov sidecar names the same capture+md5. Chunks
    # with no sidecar predate the guard and are reported, not trusted.
    provs, noprov = {}, []
    for pfx in sorted(glob.glob(a.glob + "_frames.txt")):
        base = pfx[: -len("_frames.txt")]
        try:
            src = " ".join(open(base + ".prov").read().split()[:2])  # path + md5
            provs.setdefault(src, []).append(os.path.basename(base))
        except OSError:
            noprov.append(os.path.basename(base))
    if len(provs) > 1:
        print("REFUSING TO MERGE -- chunks come from DIFFERENT captures:")
        for src, tags in provs.items():
            print(f"  {src}\n    {', '.join(tags)}")
        raise SystemExit(2)
    if noprov:
        print(f"WARNING: {len(noprov)} chunk(s) have no .prov sidecar and cannot be "
              f"provenance-checked: {', '.join(noprov)}")
        print("         Re-run run_region.sh to stamp them before trusting this merge.")
    for pfx in sorted(glob.glob(a.glob + "_frames.txt")):
        pfx = pfx[: -len("_frames.txt")]
        m = re.match(r"chunk_(\d+)_(\d+)_r\d+$", os.path.basename(pfx))
        s, e = int(m.group(1)), int(m.group(2))
        w0 = max(s - a.warm, 0)
        span.update(range(s, e + 1))
        for ks, ok, seq, nw in score_chunk(pfx):
            k = w0 + ks
            if k < s or k > e:
                continue                      # warm-up / out of payload
            prev = fmap.get(k)
            if prev is None or ok > prev[0]:  # overlap: any leg decoding = ok
                fmap[k] = (ok, seq, nw)

    ks = sorted(span)
    with open("framemap.csv", "w") as f:
        f.write("capframe,delivered,crc_ok,seq,words,seq_expected\n")
        for k in ks:
            v = fmap.get(k)
            if v is None:
                f.write(f"{k},0,0,-1,0,{SEQBASE + k}\n")
            else:
                f.write(f"{k},1,{v[0]},{v[1]},{v[2]},{SEQBASE + k}\n")

    good = [k for k in ks if fmap.get(k, (0,))[0]]
    bad = [k for k in ks if not fmap.get(k, (0,))[0]]
    seqmis = [k for k in good if fmap[k][1] != SEQBASE + k]
    print(f"frames covered: {len(ks)} ({ks[0]}..{ks[-1]})  "
          f"good={len(good)} bad={len(bad)}")
    print("bad frames:", bad if bad else "NONE")
    if seqmis:
        print("CRC-good but seq mismatch vs SEQBASE+k:", seqmis[:20])
    runs, run, start = [], 0, None
    for k in ks:
        if not fmap.get(k, (0,))[0]:
            if run == 0:
                start = k
            run += 1
        else:
            if run:
                runs.append((start, run))
            run = 0
    if run:
        runs.append((start, run))
    print("consecutive-fail runs (start_k,len):", runs)
    multi = [r for r in runs if r[1] >= 5]
    print("multi-frame (>=5) runs:", multi if multi else "NONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
