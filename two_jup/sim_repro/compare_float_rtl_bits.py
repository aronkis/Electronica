#!/usr/bin/env python3
"""compare_float_rtl_bits.py <float_decbits.csv> <rtl_fec.txt> [maxshift]

Float-vs-RTL equivalence at the FEC-decoded info-bit level, frame by frame.
  float_decbits.csv : uint8 matrix nF x INFO from float_baseline_f1536(...,'keepbits',true)
  rtl_fec.txt       : "bit,start" lines from Vwrap_byte_taps(_mu) (one per FEC-decoded bit)
RTL frames are split on start==1. Frame k of each stream is matched by content:
for every float frame, find the RTL frame with the minimum Hamming distance
(searching all RTL frames), so misalignment or dropped frames cannot fake a
mismatch. Reports per-frame min distance and the equal-frame count.
"""
import sys, numpy as np
fl = np.loadtxt(sys.argv[1], delimiter=',', dtype=np.uint8)
bits, starts = [], []
for ln in open(sys.argv[2]):
    b, s = ln.strip().split(',')
    bits.append(int(b)); starts.append(int(s))
bits = np.array(bits, dtype=np.uint8); starts = np.array(starts)
idx = np.where(starts == 1)[0]
INFO = fl.shape[1]
rtl = [bits[i:i + INFO] for i in idx if i + INFO <= len(bits)]
rtl = [f for f in rtl if len(f) == INFO]
R = np.array(rtl, dtype=np.uint8)
print(f"float frames={fl.shape[0]} INFO={INFO}; rtl fec frames={len(rtl)} (starts={len(idx)})")
eq = 0; rows = []
for k in range(fl.shape[0]):
    d = np.count_nonzero(R != fl[k], axis=1) if len(R) else np.array([INFO])
    j = int(d.argmin()); rows.append((k, j, int(d[j])))
    eq += d[j] == 0
print(f"EQUAL_FRAMES {eq}/{fl.shape[0]}  (float frame -> best RTL frame, hamming)")
bad = [r for r in rows if r[2] > 0]
print("mismatching float frames (k, rtl_j, hamming):", bad[:30], "... total", len(bad))
# the inverse: RTL frames with no float twin
seen = set(r[1] for r in rows if r[2] == 0)
print(f"RTL frames without an exact float twin: {len(R) - len(seen)} of {len(R)}")
