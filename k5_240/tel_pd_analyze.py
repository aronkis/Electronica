#!/usr/bin/env python3
"""Locate tick episodes inside P1C per-symbol PD records.

Checks, per window:
  - tap integrity: symCtr continuity
  - tRef step law: +1 mod 1133 every symbol strobe (ANY violation = direct
    observation of the timing-reference discontinuity inside the PD)
  - inter-sync spacing: 1133 symbols nominal; deviations = TA miss/slip
  - tOff trajectory at each new peak latch; jumps ~32 = the displacement
  - heldTs (peak timestamp, tRefLong domain) deltas vs 1133
"""
import sys
import numpy as np

def analyze(path):
    z = np.load(path)
    tRef = z['tRef'].astype(np.int64)
    tOff = z['tOff'].astype(np.int64)
    sync = z['sync'].astype(bool)
    done = z['done'].astype(bool)
    newPk = z['newPk'].astype(bool)
    heldTs = z['heldTs'].astype(np.int64)
    tRefLong = z['tRefLong'].astype(np.int64)
    symCtr = z['symCtr'].astype(np.int64)
    n = len(tRef)
    print(f'== {path}: {n} symbols ({n/240000:.2f}s) ==')

    # tap integrity
    dsc = np.diff(symCtr) % (1 << 24)
    bad = np.where(dsc != 1)[0]
    print(f'symCtr discontinuities: {len(bad)}' +
          (f' first at rec {bad[0]} (step {dsc[bad[0]]})' if len(bad) else ''))

    # tRef step law
    dtr = np.diff(tRef)
    ok = (dtr == 1) | (dtr == -1132)
    v = np.where(~ok)[0]
    print(f'tRef step violations: {len(v)}')
    for i in v[:20]:
        print(f'  rec {i}: tRef {tRef[i]} -> {tRef[i+1]} (step {dtr[i]:+d}) '
              f'symCtr {symCtr[i]} tRefLong {tRefLong[i]}')

    # tRefLong step law (free-running counter)
    dtl = np.diff(tRefLong)
    vl = np.where(dtl != 1)[0]
    print(f'tRefLong step violations: {len(vl)}')
    for i in vl[:10]:
        print(f'  rec {i}: tRefLong {tRefLong[i]} -> {tRefLong[i+1]} (step {dtl[i]:+d})')

    # inter-sync spacing
    si = np.where(sync)[0]
    ds = np.diff(si)
    odd = np.where(ds != 1133)[0]
    print(f'syncs: {len(si)}, spacing!=1133: {len(odd)}')
    for i in odd[:20]:
        print(f'  sync gap {ds[i]} at rec {si[i]}..{si[i+1]} '
              f'(t={si[i]/240000:.3f}s) tOff there: {tOff[si[i]]}->{tOff[si[i+1]]}')

    # tOff changes (new latched offsets)
    ch = np.where(np.diff(tOff) != 0)[0]
    print(f'tOff changes: {len(ch)}')
    for i in ch[:24]:
        print(f'  rec {i}: tOff {tOff[i]} -> {tOff[i+1]} (t={i/240000:.3f}s) '
              f'tRef {tRef[i]} sync_near={sync[max(0,i-1200):i+1200].sum()}')

    # heldTs frame deltas: distinct consecutive values
    hv = heldTs[np.insert(np.diff(heldTs) != 0, 0, True)]
    dh = np.diff(hv)
    oddh = np.where(dh != 1133)[0]
    print(f'heldTs updates: {len(hv)}, delta!=1133: {len(oddh)}')
    for i in oddh[:24]:
        print(f'  heldTs {hv[i]} -> {hv[i+1]} (delta {dh[i]:+d})')
    print()

for p in sys.argv[1:]:
    analyze(p)
