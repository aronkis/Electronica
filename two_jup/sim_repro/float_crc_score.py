#!/usr/bin/env python3
"""float_crc_score.py <decbits.csv> [label]
Independent FLOAT-chain frame verdict: pack float_baseline_f1536 decBits
(first 12224 info bits, MSB-first -- packing derived bit-exactly against the
netlist byte stream, 0 mismatches) into the 1528-byte frame and check the
QK header + zlib CRC32 exactly as the host daemon does. Prints per-capture
totals and the failing frames (index, decoded seq).
"""
import sys, zlib, numpy as np
fl = np.loadtxt(sys.argv[1], delimiter=',', dtype=np.uint8)
lab = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1]
ok = 0; seqs = []; bad = []
for k in range(fl.shape[0]):
    buf = np.packbits(fl[k][:12224]).tobytes()
    good, seq = 0, -1
    if buf[0] == 0x51 and buf[1] == 0x4B:
        L = buf[2] | buf[3] << 8; seq = int.from_bytes(buf[4:8], 'little')
        if L <= len(buf) - 12:
            t = bytearray(buf[:12 + L]); t[8:12] = b'\0' * 4
            good = int((zlib.crc32(bytes(t)) & 0xFFFFFFFF) == int.from_bytes(buf[8:12], 'little'))
    ok += good; seqs.append(seq)
    if not good: bad.append((k, seq))
print(f"FLOAT_CRC {lab}: frames={fl.shape[0]} crc_good={ok} fail={len(bad)} seq_range={min(s for s in seqs if s>=0) if ok else -1}..{max(seqs)} fails={bad[:25]}")
