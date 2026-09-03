#!/usr/bin/env python3
"""§45 discriminator: did the DATA move, or did the RX MARKER move?

Requires a TXMARK image (§58): ch2 = RX demod marker, ch3 = TX frame marker
(Transmitter_txFrameStart). Pre-registration in §58 -- read it before reading
any output here.

Per frame:
  S = TX marker position minus RX marker position, in beats
  D = data displacement vs the RX marker (the existing §31 measurement)

  DATA moved   -> S stays at its quiet value S0 while D goes to a rung
  MARKER moved -> S shifts by exactly D on those same frames
  neither      -> S shifts by an amount unrelated to D; §45 is not answered

Usage: s45_discriminate.py <capture.bin> [skew]
"""
import os, sys, collections
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MARK = 0x7FFF

def main():
    path = sys.argv[1]; skew = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    a = np.fromfile(path, dtype='<i2'); a = a[:(len(a)//4)*4].reshape(-1, 4)
    m = {}
    for l in open(os.path.join(HERE, 'offsetmap', 'tap3_word_to_offset.tsv')):
        if l.startswith('#'):
            continue
        w, o = l.split(); m[int(w, 16)] = int(o)
    span = max(m.values()) + 1
    rx = np.flatnonzero(a[:, 2] == MARK)
    tx = np.flatnonzero(a[:, 3] == MARK)
    print(f"{len(a):,} beats | RX markers {len(rx):,} | TX markers {len(tx):,}")
    if len(tx) == 0:
        print("NO TX MARKERS -- this is not a TXMARK image. No §45 conclusion."); return 2
    coincident = len(np.intersect1d(rx, tx))
    print(f"  markers at the SAME beat: {coincident} of {min(len(rx),len(tx))}")
    if coincident > 0.5 * min(len(rx), len(tx)):
        print("  *** markers are still coincident -- the retarget did not take.")
        print("  *** Per §58 no §45 conclusion may be drawn from this capture."); return 3
    sign = ((a[:, 0] < 0).astype(np.uint32) << 1) | (a[:, 1] < 0).astype(np.uint32)
    rows = []
    for i in rx:
        s = i + skew
        if s + 16 > len(a):
            break
        w = 0
        for k in range(16):
            w |= int(sign[s+k]) << (30 - 2*k)
        D = m.get(w)
        j = np.searchsorted(tx, i)
        cands = [tx[k] for k in (j-1, j) if 0 <= k < len(tx)]
        if not cands:
            continue
        S = int(min(cands, key=lambda t: abs(t - i)) - i)
        rows.append((D, S))
    byD = collections.defaultdict(list)
    for D, S in rows:
        byD[D].append(S)
    print(f"\n  {'displacement D':>16}  {'frames':>7}  {'S (median)':>11}  {'S spread':>9}")
    base = None
    for D in sorted(byD, key=lambda x: (x is None, x)):
        v = np.array(byD[D]); med = int(np.median(v))
        if D == 0:
            base = med
        print(f"  {str(D):>16}  {len(v):7d}  {med:11d}  {int(v.max()-v.min()):9d}")
    if base is None:
        print("\n  no aligned frames -- cannot establish S0"); return 4
    print(f"\n  S0 (quiet) = {base}")
    for D in sorted(k for k in byD if k not in (None, 0)):
        med = int(np.median(byD[D])); shift = med - base
        verdict = ("DATA moved (S unchanged)" if abs(shift) < 16 else
                   "MARKER moved (S shifted by D)" if abs(abs(shift) - D) < 16 else
                   f"NEITHER: S shifted {shift:+d}, unrelated to D={D}")
        print(f"  D={D:5d}: S={med} (shift {shift:+d})  ->  {verdict}")
    return 0

sys.exit(main())
