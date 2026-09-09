#!/usr/bin/env python3
"""dtref_census.py FILE.bin [--i15] -- one-sidedness census of the DDRCAP-v2 `tref`
sidecar (= Peak_Search.timing_Reference, a mod-12333 counter clocked by
Correlator.validOut, i.e. by RECOVERED symbols) against `slot` (a free-running mod-4
LOCAL sample-phase counter). A 4-record group with dtref==0 is a symbol that the
receiver's valid chain failed to deliver; dtref==2 is an extra one. A net imbalance is
a rate offset between the recovered-symbol stream and the local sample clock.

--i15 additionally runs the sel13-only interpolator-underflow (I[15]) strobe census on
the same groups, which localises the imbalance: if I[15] is balanced while tref is
one-sided, the deletion happens DOWNSTREAM of the interpolator strobe.
"""
import sys
import numpy as np

P = 12333


def main(path, i15=False):
    a = np.memmap(path, dtype='<i2', mode='r').reshape(-1, 4)
    c3 = np.array(a[:, 3]).astype(np.uint16)
    slot = (c3 >> 14); side = (c3 & 0x3FFF).astype(np.int64)
    s1 = np.flatnonzero(slot == 1)
    d = np.diff(side[s1]); d = np.where(d < 0, d + P, d)
    n0, n1, n2 = int((d == 0).sum()), int((d == 1).sum()), int((d > 1).sum() - (d > 2).sum())
    nb = int((d > 2).sum())
    span = int(d.sum())
    net = n0 - n2
    print(f"{path}")
    print(f"  records {len(a)}  slot-1 groups {len(s1)}  span {span} sym = {span/P:.1f} frames")
    print(f"  dtref==0 {n0}   ==1 {n1}   ==2 {n2}   >2 {nb} "
          f"(DMA drop bursts, median {np.median(d[d>2]) if nb else 0:.0f} sym)")
    print(f"  net deletions (0s - 2s) = {net}  ->  1 per {span/max(abs(net),1)/P:.2f} frames"
          f"  = {net/span*1e6:.3f} ppm")
    if i15:
        # A DMA burst removes a WHOLE MULTIPLE of 4 records, so record contiguity
        # (rg == 4) alone does NOT exclude a group that straddles a drop -- filtering on
        # it only was what produced the spurious "8,168/8,064" and "511/477" imbalances.
        # A clean interior group additionally needs tref to advance by exactly 1 on BOTH
        # sides.
        I = np.array(a[:, 0]).astype(np.uint16)
        uf = ((I >> 15) & 1).astype(np.int8)
        rg = np.diff(s1)
        i = np.arange(1, len(s1) - 1)
        clean = (rg[i - 1] == 4) & (rg[i] == 4) & (d[i - 1] == 1) & (d[i] == 1)
        gi = s1[i[clean]]
        cnt = uf[gi[:, None] - 1 + np.arange(4)[None, :]].sum(axis=1)
        v, c = np.unique(cnt, return_counts=True)
        h = dict(zip(v.tolist(), c.tolist()))
        z, t = h.get(0, 0), h.get(2, 0)
        sig = np.sqrt(max(z + t, 1))
        print(f"  [sel13] I[15] interpolator strobes per DROP-FREE symbol group "
              f"({int(clean.sum())} groups): {h}")
        print(f"          net(2s-0s) = {t-z:+d}  (random-walk sigma {sig:.0f}) "
              f"= {(t-z)/span*1e6:+.3f} ppm, 1-sigma +-{sig/span*1e6:.3f} ppm")


if __name__ == '__main__':
    main(sys.argv[1], '--i15' in sys.argv)
