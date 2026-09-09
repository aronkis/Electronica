#!/usr/bin/env python3
"""ddr_to_iq.py -- cut [I,Q] out of DDR 4-word records into the interleaved int16 IQ file
float_baseline_f1536.m reads. --start/--count are in RECORDS (one record = one sample)."""
import argparse, numpy as np
ap = argparse.ArgumentParser(); ap.add_argument('src'); ap.add_argument('dst')
ap.add_argument('--start', type=int, default=0); ap.add_argument('--count', type=int, default=None)
a = ap.parse_args()
r = np.fromfile(a.src, dtype='<i2'); r = r[:(len(r) // 4) * 4].reshape(-1, 4)
end = len(r) if a.count is None else a.start + a.count
r[a.start:end, :2].astype('<i2').tofile(a.dst)
print(f"wrote {end - a.start} samples from record {a.start}")
