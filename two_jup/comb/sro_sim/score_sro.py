#!/usr/bin/env python3
"""[sim] COMB32 SRO scorer. Usage: score_sro.py <golden_prefix> <prefix> [...]"""
import sys, numpy as np
P = 49332

def deliv(pfx):
    a = []
    for ln in open(pfx + '_deliv.txt'):
        s, n, h, u = ln.split(',')
        a.append((int(s), int(n), h, int(u)))
    return a

def frames(pfx):
    return np.loadtxt(pfx + '_frames.txt', delimiter=',', dtype=np.int64, ndmin=2)

def anom(pfx):
    try:
        return np.loadtxt(pfx + '_anom.txt', delimiter=',', dtype=np.int64, ndmin=2)
    except Exception:
        return np.zeros((0, 3), dtype=np.int64)

def golden_key(pfx):
    from collections import Counter
    d = deliv(pfx)
    return Counter((n, h) for _, n, h, _ in d).most_common(1)[0][0]

def autocorr(x, maxlag=64):
    x = x.astype(float) - x.mean()
    if x.std() == 0:
        return {}
    den = (x * x).sum()
    return {L: float((x[:-L] * x[L:]).sum() / den) for L in range(1, maxlag + 1)}

def main():
    gp = sys.argv[1]
    key = golden_key(gp)
    print(f'golden (nwords,hash) = {key}\n')
    for pfx in sys.argv[1:]:
        d = deliv(pfx)
        if not d:
            print(f'{pfx}: NO FRAMES DELIVERED'); continue
        s = np.array([x[0] for x in d])
        dd = np.diff(s)
        sp = np.median(dd)
        # air-frame index of each delivered frame, referenced to the first
        idx = np.rint((s - s[0]) / sp).astype(int)
        nslots = idx[-1] + 1
        status = np.full(nslots, 0, dtype=np.int8)   # 0 = MISSING
        for k, (_, n, h, u) in zip(idx, d):
            status[k] = 1 if (n, h) == key else 2    # 1 = OK, 2 = CORRUPT
        # skip a 3-frame warm-up at each end
        w0, w1 = 3, nslots - 1
        st = status[w0:w1]
        miss = int((st == 0).sum()); corr = int((st == 2).sum()); ok = int((st == 1).sum())
        lost = (st != 1).astype(float)
        ac = autocorr(lost, 64)
        top = sorted(ac.items(), key=lambda kv: -kv[1])[:5]
        F = frames(pfx)
        occ = F[:, 4]
        dpush = F[:, 1]
        occstep = np.nonzero(np.diff(occ[w0:w1]))[0] + w0
        an = anom(pfx)
        anpf = F[:, 5]
        lostidx = np.nonzero(lost)[0] + w0
        # coincidence: lost frame within +-1 of an occupancy step
        coinc = sum(1 for L in lostidx if np.any(np.abs(occstep - L) <= 1))
        print(f'== {pfx}: slots={nslots} scored={len(st)} OK={ok} CORRUPT={corr} MISSING={miss} '
              f'loss={100.0*(miss+corr)/max(1,len(st)):.2f}%')
        print(f'   lost frame indices: {list(lostidx[:40])}{" ..." if len(lostidx)>40 else ""}')
        if len(lostidx) > 1:
            print(f'   loss spacings: {list(np.diff(lostidx)[:40])}')
        print(f'   loss autocorr top5: ' + ', '.join(f'{L}:{v:+.3f}' for L, v in top))
        print(f'   pushes/frame: min={dpush[w0:w1].min()} max={dpush[w0:w1].max()} '
              f'sum-12333*n={int(dpush[w0:w1].sum()-12333*len(st))}')
        print(f'   occupancy: start={occ[w0]} end={occ[w1-1]} steps at {list(occstep[:20])} (n={len(occstep)})')
        print(f'   strobe-interval anomalies: total={len(an)} per-frame mean={anpf[w0:w1].mean():.1f} '
              f'min={anpf[w0:w1].min()} max={anpf[w0:w1].max()}')
        print(f'   lost-frame / occ-step coincidence: {coinc}/{len(lostidx)}\n')

if __name__ == '__main__':
    main()
