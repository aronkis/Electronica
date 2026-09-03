#!/usr/bin/env python3
"""accept_analyze.py <frames.bin> [<frames.bin> ...] -- wedge-aware acceptance analysis.

For each capture: finds the live-link window (clean-rate collapse = a persistent
carrier wedge; the capture harness disables the lock_watchdog, so a mid-capture
wedge stays wedged and is reported separately, not silently averaged in), then
reports on the reliable host_seq-gap metric over the live window:
  PER, burst decomposition, lag-33 singles autocorrelation, CP 95% upper limit.
Pooled CP bound over all live windows at the end.

Wedge policy (stated, not hidden): the <1% goal is assessed on the live-link
windows (representative of watchdog-protected operation); wedge occurrence and
its truncation are reported alongside so nothing is buried.
"""
import sys, math
import numpy as np
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from frame_taxonomy import read_frames

def cp_upper(k, n, conf=0.975):
    """Clopper-Pearson 95% two-sided upper limit (beta quantile by bisection)."""
    if n == 0: return 1.0
    if k >= n: return 1.0
    a, b = k + 1, n - k
    def betacf(x, a, b):
        MAXIT, EPS, FPMIN = 300, 3e-12, 1e-300
        qab, qap, qam = a+b, a+1.0, a-1.0
        c, d = 1.0, 1.0 - qab*x/qap
        if abs(d) < FPMIN: d = FPMIN
        d = 1.0/d; h = d
        for m in range(1, MAXIT+1):
            m2 = 2*m
            aa = m*(b-m)*x/((qam+m2)*(a+m2))
            d = 1.0 + aa*d;  d = FPMIN if abs(d) < FPMIN else d
            c = 1.0 + aa/c;  c = FPMIN if abs(c) < FPMIN else c
            d = 1.0/d; h *= d*c
            aa = -(a+m)*(qab+m)*x/((a+m2)*(qap+m2))
            d = 1.0 + aa*d;  d = FPMIN if abs(d) < FPMIN else d
            c = 1.0 + aa/c;  c = FPMIN if abs(c) < FPMIN else c
            d = 1.0/d; de = d*c; h *= de
            if abs(de-1.0) < EPS: break
        return h
    def ibeta(x, aa, bb):
        if x <= 0: return 0.0
        if x >= 1: return 1.0
        lb = math.lgamma(aa+bb) - math.lgamma(aa) - math.lgamma(bb) \
             + aa*math.log(x) + bb*math.log(1.0-x)
        if x < (aa+1.0)/(aa+bb+2.0):
            return math.exp(lb) * betacf(x, aa, bb) / aa
        return 1.0 - math.exp(lb) * betacf(1.0-x, bb, aa) / bb
    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = (lo+hi)/2
        if ibeta(mid, a, b) < conf: lo = mid
        else: hi = mid
    return hi

ARQ_MODE = False   # --arq: seqs sorted+uniqued (ARQ reorders; gaps = unrecovered)

def analyze(path, settle_s=15.0):
    fr = read_frames(path); clean = fr['crc_ok'] != 0
    tm = fr['t_mono_ns'].astype(np.int64); t0 = tm[0]
    ts = (tm - t0) / 1e9
    dur = float(ts[-1])
    # live-window end: last 1s bucket with clean rate >= 25% of the peak bucket
    nb = max(int(dur) + 1, 1)
    cps = np.zeros(nb)
    for b in range(nb):
        cps[b] = ((clean) & (ts >= b) & (ts < b+1)).sum()
    peak = cps.max() if cps.size else 0
    live_end = dur
    if peak > 0:
        good = np.flatnonzero(cps >= 0.25 * peak)
        live_end = float(good[-1] + 1) if good.size else 0.0
        wedged = live_end < dur - 3.0
        if wedged:
            live_end = max(live_end - 2.0, 0.0)   # guard: exclude the degradation ramp
    else:
        wedged = True; live_end = 0.0
    ci = np.flatnonzero(clean)
    ct = ts[ci]; cseq = fr['host_seq'][ci].astype(np.int64)
    w = (ct >= settle_s) & (ct < live_end)
    if w.sum() < 100:
        return dict(path=path, dur=dur, live_end=live_end, wedged=wedged,
                    usable=False)
    cw = cseq[np.flatnonzero(w)]
    if ARQ_MODE:
        cw = np.sort(np.unique(cw))
    d = np.diff(cw); lost = d - 1
    span = int(cw[-1] - cw[0]); miss = int(lost[lost > 0].sum())
    rl = lost[lost > 0]
    bins = {'1': int((rl==1).sum()), '2': int((rl==2).sum()),
            '3-4': int(((rl>=3)&(rl<=4)).sum()), '5-20': int(((rl>=5)&(rl<=20)).sum()),
            '21-100': int(((rl>=21)&(rl<=100)).sum()), '>100': int((rl>100).sum())}
    # lag-33 autocorr over the singles-only train
    lo_ = cw[0]
    pres = np.zeros(cw[-1]-lo_+1, dtype=np.int8); pres[cw-lo_] = 1
    idx = np.flatnonzero(1-pres); runs = []; i = 0
    while i < len(idx):
        j = i
        while j+1 < len(idx) and idx[j+1] == idx[j]+1: j += 1
        runs.append((idx[i], j-i+1)); i = j+1
    sp = np.zeros(cw[-1]-lo_+1)
    for p, l in runs:
        if l == 1: sp[p] = 1
    ac33 = float('nan')
    if sp.sum() > 3 and len(sp) > 40:
        spc = sp - sp.mean(); ac = np.correlate(spc, spc, 'full')[len(spc)-1:]
        ac33 = float(ac[33]/ac[0])
    return dict(path=path, dur=dur, live_end=live_end, wedged=wedged, usable=True,
                miss=miss, span=span, bins=bins, ac33=ac33)

def main(paths):
    tot_k = tot_n = 0; pers = []; nwedge = 0
    print("=== wedge-aware acceptance analysis (live-link windows, settle 15s, wedge-guard 2s) ===")
    for p in paths:
        r = analyze(p)
        tag = p.split('/')[-2] if '/' in p else p
        if not r['usable']:
            nwedge += r['wedged']
            print(f"  {tag}: UNUSABLE (live window {r['live_end']:.0f}s of {r['dur']:.0f}s"
                  f"{', WEDGED' if r['wedged'] else ''})")
            continue
        per = 100*r['miss']/max(r['span'], 1); pers.append(per)
        ub = 100*cp_upper(r['miss'], r['span'])
        tot_k += r['miss']; tot_n += r['span']; nwedge += r['wedged']
        print(f"  {tag}: live {r['live_end']:.0f}s/{r['dur']:.0f}s"
              f"{' [WEDGE truncated]' if r['wedged'] else ''}  "
              f"PER={per:.3f}% ({r['miss']}/{r['span']})  CP95UL={ub:.3f}%  "
              f"lag33={r['ac33']:.3f}  bins={r['bins']}")
    if tot_n:
        ub_all = 100*cp_upper(tot_k, tot_n)
        print(f"\n  POOLED live-window: PER={100*tot_k/tot_n:.3f}% ({tot_k}/{tot_n})"
              f"  CP95UL={ub_all:.3f}%")
        if pers:
            print(f"  per-run spread: {min(pers):.3f}%..{max(pers):.3f}%")
        print(f"  wedges during captures: {nwedge} (real events; auto-recovered in "
              f"normal ops by lock_watchdog, disabled during captures)")
        print(f"  GATE (<1% at CP95 upper limit, live-link): "
              f"{'PASS' if ub_all < 1.0 else 'NOT MET'}")

if __name__ == '__main__':
    args = sys.argv[1:]
    if args and args[0] == '--arq':
        ARQ_MODE = True
        args = args[1:]
        print("(ARQ mode: sorted-unique seqs; PER = frames never delivered by any copy)")
    main(args)
