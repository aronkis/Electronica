#!/usr/bin/env python3
"""[sim] Task 6 (T2) epoch/divergence scorer for the SRO harness _ep.txt trace.

Usage: score_t6_ep.py <golden_prefix> <prefix> [...]

For each leg it prints
  * the divergence D = nCorr - nPop (valids in flight through the Preamble_Detector
    realignment FIFO = the phase between Peak_Search's epoch space and
    Timing_Adjust's).  Constant D  <=>  the two epoch spaces stay aligned.
  * every D excursion, with the pop_on_empty event that caused it,
  * a per-event timeline (event -> +6 frames) of the SyncPulse rows: taRef/accoff,
    the Peak_Search timingOffset, D, and the demod frame-mark anomaly, and
  * which delivered frame died.
"""
import sys
import numpy as np
from collections import Counter

P = 49332
SYM = 12333
EPC = ('kind sidx f nCorr nPop D pdOcc psTref taRef taAcc psToff newpk armed '
       'sdcAct rhPhase nPE txFS').split()
MC = ('sidx ss cfc cs pd corr pa con dem push pop occ occTrue mPE mPF mPDPF '
      'mPDPE pdOcc').split()


def load(p, suf, names):
    try:
        a = np.loadtxt(p + suf, delimiter=',', dtype=np.int64, ndmin=2)
    except Exception:
        return None
    if a.size == 0:
        return None
    return {n: a[:, i] for i, n in enumerate(names) if i < a.shape[1]}


def lost_slots(p, key):
    rows = [l.split(',') for l in open(p + '_deliv.txt')]
    if not rows:
        return np.array([]), 0.0
    s = np.array([int(r[0]) for r in rows])
    sp = np.median(np.diff(s)) if len(s) > 1 else P
    idx = np.rint((s - s[0]) / sp).astype(int)
    st = np.zeros(idx[-1] + 1, dtype=np.int8)
    for k, r in zip(idx, rows):
        st[k] = 1 if (r[1], r[2]) == key else 2
    li = np.nonzero(st[3:len(st) - 1] != 1)[0] + 3
    return li, s[0] / P          # slot index, and the slot->input-frame offset


def golden_key(p):
    rows = [l.split(',') for l in open(p + '_deliv.txt')]
    return Counter((r[1], r[2]) for r in rows).most_common(1)[0][0]


def mark_anoms(p):
    """Frame-start anomalies: demod marks whose spacing or symbol count is off."""
    M = load(p, '_marks.txt', MC)
    if M is None:
        return []
    s = M['sidx']
    if len(s) < 5:
        return []
    d = np.diff(s)
    med = P            # the KNOWN frame period; an empirical median would move
                       # under it on a badly broken leg and hide the anomalies
    out = []
    for i in np.nonzero(d != med)[0]:
        out.append((float(s[i + 1]) / P, int(d[i] - med), int(M['corr'][i + 1]) - SYM))
    return out


def main():
    key = golden_key(sys.argv[1])
    for p in sys.argv[1:]:
        E = load(p, '_ep.txt', EPC)
        print(f'== {p}')
        if E is None:
            print('   no _ep.txt (pre-T2 run)\n'); continue
        li, off = lost_slots(p, key)
        lostf = set(int(round(x + off)) for x in li)      # in input-frame units
        ev = np.nonzero(E['kind'] == 0)[0]
        sy = np.nonzero(E['kind'] == 1)[0]
        D = E['D']
        # steady-state D: the mode over SyncPulse rows after acquisition
        Ds = D[sy][5:] if len(sy) > 5 else D[sy]
        if len(Ds) == 0:
            print('   no SyncPulse rows\n'); continue
        d0 = int(Counter(Ds.tolist()).most_common(1)[0][0])
        exc = np.nonzero(Ds != d0)[0]
        print(f'   rows: {len(E["kind"])}  pop_on_empty={len(ev)}  SyncPulse={len(sy)}  '
              f'toffLatch={int((E["kind"]==2).sum())}')
        print(f'   DIVERGENCE D = nCorr-nPop (PD FIFO occupancy): steady {d0}, '
              f'excursions on {len(exc)}/{len(Ds)} SyncPulse epochs '
              f'(values {sorted(set(Ds.tolist()))})')
        print(f'   EPOCH ALIGNMENT: {"HELD (D constant)" if len(exc)==0 else "BROKEN"}')
        am = mark_anoms(p)
        print(f'   demod frame-mark anomalies: {len(am)}'
              + (f'  first 8 (frame, d_sidx, d_symbols): '
                 f'{[(round(a,2), b, c) for a, b, c in am[:8]]}' if am else ''))
        print(f'   lost/corrupt delivered frames: {len(li)} '
              f'(input-frame units {sorted(lostf)[:12]}{" ..." if len(lostf) > 12 else ""})')
        # per-event timeline
        for k, e in enumerate(ev[:6]):
            f0 = int(E['f'][e])
            print(f'   --- pop_on_empty #{k+1} at f={f0} sidx={int(E["sidx"][e])} '
                  f'(D just after: {int(E["D"][e])}, rhPhase={int(E["rhPhase"][e])}) ---')
            sel = [i for i in sy if f0 - 1 <= E['f'][i] <= f0 + 6]
            print('        f    taRef  accoff  psToff    D   armed  sdcAct   marker')
            for i in sel:
                f = int(E['f'][i])
                tag = []
                if f in lostf:
                    tag.append('LOST')
                for a, b, c in am:
                    if int(a) == f:
                        tag.append(f'MARK{b:+d}smp/{c:+d}sym')
                print(f'     {f:6d} {int(E["taRef"][i]):7d} {int(E["taAcc"][i]):7d} '
                      f'{int(E["psToff"][i]):7d} {int(E["D"][i]):5d} '
                      f'{int(E["armed"][i]):6d} {int(E["sdcAct"][i]):7d}   '
                      + ' '.join(tag))
        print()


if __name__ == '__main__':
    main()
