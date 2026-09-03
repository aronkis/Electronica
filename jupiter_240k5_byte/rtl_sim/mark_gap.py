#!/usr/bin/env python3
"""Demod-marker cadence check for a TX-kick .bin: total records, marker count, and
constancy of np.diff(marker_index) -- the witness for "RX marker cadence unmoved"
(prediction A requires this; Sec.76's `ss` case was caught perturbing exactly this).
Usage: mark_gap.py FILE.bin"""
import sys
import numpy as np

MARK = 0x7FFF

def main():
    path = sys.argv[1]
    a = np.fromfile(path, dtype='<i2')
    a = a[:(len(a)//4)*4].reshape(-1, 4)
    mk = np.flatnonzero(a[:, 2] == MARK)
    print(f"{path}: {len(a):,} records, {len(mk):,} demod markers")
    if len(mk) < 2:
        print("TOO FEW MARKERS"); return
    d = np.diff(mk)
    uniq, counts = np.unique(d, return_counts=True)
    print(f"  marker gaps: min={d.min()} max={d.max()} unique_values={len(uniq)}")
    for u, c in sorted(zip(uniq, counts), key=lambda x: -x[1])[:6]:
        print(f"    gap={u}: {c} occurrences")
    print(f"  CONSTANT CADENCE: {'YES' if len(uniq)==1 else 'NO'}")

if __name__ == '__main__':
    main()
