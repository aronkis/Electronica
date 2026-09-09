#!/usr/bin/env python3
"""ddrcap2_decode.py -- DDRCAP-v2 record decoder (spec sec 2).
ch2 = {mark_demod, mark_fec, timingOffset[13:0]}, ch3 = {slot[1:0], side[13:0]}.
--v1compat writes [I, Q, 0x7FFF|0, 0x7FFF|0] so the v1 scorers run unchanged."""
import argparse, sys
import numpy as np

SLOTS = ('heldts_lo', 'tref', 'runmax_hi', 'corrthr_hi')

def load(path):
    a = np.fromfile(path, dtype='<i2')
    return a[:(len(a) // 4) * 4].reshape(-1, 4)

def decode(a):
    c2 = a[:, 2].astype(np.uint16); c3 = a[:, 3].astype(np.uint16)
    d = {'I': a[:, 0], 'Q': a[:, 1],
         'mark_demod': (c2 >> 15) & 1 == 1, 'mark_fec': (c2 >> 14) & 1 == 1,
         'toff': c2 & 0x3FFF, 'slot': (c3 >> 14).astype(np.uint8), 'side': c3 & 0x3FFF}
    for k, name in enumerate(SLOTS):
        v = np.full(len(a), -1, dtype=np.int32)
        m = d['slot'] == k
        v[m] = d['side'][m]
        d[name] = v
    return d

def v1compat(a):
    d = decode(a)
    o = np.zeros_like(a)
    o[:, 0] = a[:, 0]; o[:, 1] = a[:, 1]
    o[:, 2] = np.where(d['mark_demod'], 0x7FFF, 0).astype(np.int16)
    o[:, 3] = np.where(d['mark_fec'], 0x7FFF, 0).astype(np.int16)
    return o

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('src'); ap.add_argument('--v1compat'); ap.add_argument('--summary', action='store_true')
    x = ap.parse_args(); a = load(x.src)
    if x.v1compat:
        v1compat(a).astype('<i2').tofile(x.v1compat); print(f"wrote {len(a)} v1-compat records")
    if x.summary or not x.v1compat:
        d = decode(a); t = d['toff']
        vals, cnts = np.unique(t, return_counts=True)
        print(f"records {len(a)}  demod_marks {int(d['mark_demod'].sum())}  tx_marks {int(d['mark_fec'].sum())}")
        print(f"toff min {int(t.min())} max {int(t.max())} mode {int(vals[cnts.argmax()])} ({cnts.max()/len(t):.3f})  distinct {len(vals)}")
        print(f"slot histogram {np.bincount(d['slot'], minlength=4).tolist()}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
