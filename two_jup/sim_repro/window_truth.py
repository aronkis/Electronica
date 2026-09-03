#!/usr/bin/env python3
"""window_truth.py <capture_dir>... -- hardware ground truth inside each capture window.

For each r3cap capture dir with frames.bin + regs_cap.txt: locate the capture
window via the CAP_START/CAP_END reg_packets bracket, list every crc-fail
record and every missing host_seq in the window, size the holes, and flag
burst-class holes (>20 frames) for the E4 search. Output: one block per dir.
"""
import sys, re, numpy as np
sys.path.insert(0, '/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup')
from frame_taxonomy import read_frames

for d in sys.argv[1:]:
    d = d.rstrip('/')
    try:
        fr = read_frames(d + '/frames.bin')
        txt = open(d + '/regs_cap.txt', errors='replace').read()
        p0 = int(re.search(r'CAP_START.*?pkts=0x([0-9A-Fa-f]+)', txt).group(1), 16)
        p1 = int(re.search(r'CAP_END.*?pkts=0x([0-9A-Fa-f]+)', txt).group(1), 16)
    except Exception as e:
        print(f"WINDOW {d} ERROR {e}"); continue
    pk = fr['reg_packets'].astype(np.int64)
    m = (pk >= p0) & (pk <= p1)
    idx = np.where(m)[0]
    if idx.size == 0:
        print(f"WINDOW {d} pkts={p0:#x}..{p1:#x} NO_RECORDS_IN_WINDOW"); continue
    i0, i1 = max(idx[0] - 3, 0), min(idx[-1] + 3, len(fr) - 1)
    w = fr[i0:i1 + 1]
    good = w[w['crc_ok'] == 1]
    gs = good['host_seq'].astype(np.int64)
    if gs.size == 0:
        print(f"WINDOW {d} pkts={p0:#x}..{p1:#x} records={idx.size} NO_GOOD_FRAMES crc0_records={int((w['crc_ok']==0).sum())}"); continue
    lo, hi = gs.min(), gs.max()
    missing = np.setdiff1d(np.arange(lo, hi + 1), np.unique(gs))
    # group missing into holes
    holes = []
    if missing.size:
        st = missing[0]; prev = missing[0]
        for s in missing[1:]:
            if s != prev + 1:
                holes.append((int(st), int(prev - st + 1))); st = s
            prev = s
        holes.append((int(st), int(prev - st + 1)))
    crc0 = np.where(w['crc_ok'] == 0)[0]
    bursts = [h for h in holes if h[1] > 20]
    print(f"WINDOW {d} pkts={p0:#x}..{p1:#x} ({p1-p0} pkts) records={idx.size} "
          f"seq={lo}..{hi} good={gs.size} crc0_records={crc0.size} holes={len(holes)} "
          f"lost_frames={int(missing.size)} bursts={len(bursts)}")
    for h in holes[:40]:
        print(f"  hole seq={h[0]} k={h[1]}")
    for j in crc0[:40]:
        r = w[j]
        print(f"  crc0 file_idx={i0+j} hdr_seq={r['host_seq']} pkts={int(r['reg_packets']):#x} "
              f"biterr={r['reg_biterr']} prev={w[j-1]['host_seq'] if j>0 else -1} "
              f"next={w[j+1]['host_seq'] if j+1<len(w) else -1}")
