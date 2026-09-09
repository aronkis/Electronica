#!/usr/bin/env python3
"""Per-frame offset sequence (frame_index offset) for a kick .bin, tap3 map, skew 1.
load_map()/MARK copied verbatim from t6_score_large.py (NOT imported: that module's
bottom-level `sys.exit(main())` runs on import). Usage: kick_seq.py FILE.bin [skew=1]"""
import os, sys
import numpy as np

TWOJUP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'two_jup')
MARK = 0x7FFF

def load_map(name):
    m = {}
    for l in open(os.path.join(TWOJUP, 'offsetmap', name)):
        if l.startswith('#'):
            continue
        w, o = l.split()
        m[int(w, 16)] = int(o)
    return m

def main():
    path = sys.argv[1]; skew = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    a = np.fromfile(path, dtype='<i2')
    a = a[:(len(a)//4)*4].reshape(-1, 4)
    m = load_map('tap3_word_to_offset.tsv')
    mk = np.flatnonzero(a[:, 2] == MARK)
    sign = ((a[:, 0] < 0).astype(np.uint32) << 1) | (a[:, 1] < 0).astype(np.uint32)
    for fi, i in enumerate(mk):
        s = i + skew
        if s + 16 > len(a):
            break
        w = 0
        for k in range(16):
            w |= int(sign[s+k]) << (30 - 2*k)
        print(fi, m.get(w, None))

if __name__ == '__main__':
    main()
