#!/usr/bin/env python3
"""tick_process.py -- Phase A of the byte/control-plane tick CAMPAIGN.

The interval/phase fingerprint of the air-singles class is set entirely by the
GATED-TICK RENEWAL PROCESS (which frames become events), independent of the DSP
netlist. So the full gate x cadence x MEMORY grid is swept here in pure Python
at 10k-frame scale, and only survivors go to the (expensive) netlist morphology
confirmation.

An EVENT frame = a gated-in tick's frame. Interval = frame gap between
consecutive events. Fingerprint per point:
  - implied event rate (events / frames)
  - interval histogram + modes; is 16 SUPPRESSED relative to 8 and 24?
  - CV of intervals
  - k mod 8 phase: flat (drift) vs concentrated (lock); measured by the
    normalized entropy of the 8-bin histogram AND the within-run phase walk.

Gate MEMORY models (the campaign crux):
  memoryless        : each tick fires iid with prob p
  refractory<D>     : after a fire, the next D ticks are forced OFF
  markov<a><b>      : 2-state {ON,OFF}; in ON fire w.p. pon, OFF fire w.p. poff;
                      P(ON->OFF)=a, P(OFF->ON)=b  (bursty if a,b small)
Cadence: nominal 8.04 frames/tick, multiplicative jitter (0 / 0.02 / 0.05),
Gaussian on each inter-tick gap.
"""
import argparse
import itertools
import math
import statistics as st

import numpy as np

NOMINAL = 8.04     # frames per tick


def gate_series(n, kind, p, rng, D=0, pon=0.9, poff=0.05, a=0.3, b=0.3):
    """Return a boolean fire[] of length n ticks with target ~mean rate p."""
    fire = np.zeros(n, dtype=bool)
    if kind == "memoryless":
        fire = rng.random(n) < p
    elif kind == "refractory":
        dead = 0
        for i in range(n):
            if dead > 0:
                dead -= 1
                continue
            if rng.random() < p:
                fire[i] = True
                dead = D
    elif kind == "markov":
        # calibrate pon/poff so stationary fire-rate ~= p
        # stationary ON frac = b/(a+b)
        onfrac = b / (a + b)
        # choose pon=p_hi, poff=p_lo around p
        state_on = rng.random() < onfrac
        for i in range(n):
            pr = pon if state_on else poff
            fire[i] = rng.random() < pr
            if state_on:
                if rng.random() < a:
                    state_on = False
            else:
                if rng.random() < b:
                    state_on = True
    return fire


def run_point(kind, p, jit, nframes, seed, **kw):
    rng = np.random.default_rng(seed)
    nticks = int(nframes / NOMINAL) + 2
    fire = gate_series(nticks, kind, p, rng, **kw)
    # tick frame positions with jitter on inter-tick gap
    gaps = NOMINAL * (1.0 + jit * rng.standard_normal(nticks))
    tick_frame = np.cumsum(gaps)
    ev_frames = tick_frame[fire]
    ev_k = np.round(ev_frames).astype(int)
    ev_k = ev_k[ev_k < nframes]
    ev_k = np.unique(ev_k)
    return ev_k


def fingerprint(ev_k, nframes):
    if len(ev_k) < 3:
        return dict(rate=len(ev_k) / nframes, n=len(ev_k), cv=float("nan"),
                    modes=[], sup16=float("nan"), phase_entropy=float("nan"),
                    h8=[0] * 8, iv_hist={})
    iv = np.diff(ev_k)
    iv = iv[iv > 0]
    hist = {}
    for x in iv:
        hist[int(x)] = hist.get(int(x), 0) + 1
    cv = float(np.std(iv) / np.mean(iv)) if np.mean(iv) else float("nan")
    c8 = hist.get(8, 0) + hist.get(7, 0) + hist.get(9, 0)
    c16 = hist.get(16, 0) + hist.get(15, 0) + hist.get(17, 0)
    c24 = hist.get(24, 0) + hist.get(23, 0) + hist.get(25, 0)
    # 16-suppression: is the 16-band a local MINIMUM between 8 and 24 bands?
    sup16 = (min(c8, c24) - c16) / max(c8, c24, 1)   # >0 means suppressed
    h8 = [0] * 8
    for k in ev_k:
        h8[int(k) % 8] += 1
    tot = sum(h8)
    ent = -sum((h / tot) * math.log(h / tot + 1e-12) for h in h8 if h) / math.log(8)
    modes = sorted(hist, key=lambda x: -hist[x])[:3]
    return dict(rate=len(ev_k) / nframes, n=len(ev_k), cv=cv, modes=modes,
                c8=c8, c16=c16, c24=c24, sup16=sup16, phase_entropy=ent,
                h8=h8, iv_hist=dict(sorted(hist.items())))


def match_score(fp):
    """Distance to the measured target: rate~0.04, CV~1.5, 16 suppressed
    (sup16>0), phase flat (entropy~1). Lower is better; components reported."""
    if fp["n"] < 10:
        return dict(total=9.9, note="too few events")
    d_rate = abs(fp["rate"] - 0.04) / 0.04
    d_cv = abs(fp["cv"] - 1.5) / 1.5
    d_sup = max(0.0, 0.15 - fp["sup16"]) / 0.15   # want sup16 >= ~0.15
    d_phase = max(0.0, 0.85 - fp["phase_entropy"]) / 0.85  # want flat
    total = d_rate + d_cv + 1.5 * d_sup + d_phase
    return dict(total=total, d_rate=d_rate, d_cv=d_cv, d_sup=d_sup,
                d_phase=d_phase)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nframes", type=int, default=10000)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--csv", default="tick_phaseA.csv")
    args = ap.parse_args()

    memories = [
        ("memoryless", {}),
        ("refractory", dict(D=1)),
        ("refractory", dict(D=2)),
        ("markov", dict(a=0.5, b=0.5)),   # mild
        ("markov", dict(a=0.2, b=0.2)),   # bursty
        ("markov", dict(a=0.15, b=0.05)), # long ON runs, short OFF? tune later
    ]
    ps = [0.2, 0.35, 0.5]
    jits = [0.0, 0.02, 0.05]

    rows = []
    for (kind, kw), p, jit in itertools.product(memories, ps, jits):
        # markov pon/poff scaled around p
        extra = dict(kw)
        if kind == "markov":
            extra.update(pon=min(0.98, p * 2.2), poff=max(0.0, p * 0.25))
        fps = []
        for r in range(args.reps):
            ev = run_point(kind, p, jit, args.nframes, seed=1000 + r,
                           **extra)
            fps.append(fingerprint(ev, args.nframes))
        # average the scalar fields
        agg = dict(kind=kind, kw=str(kw), p=p, jit=jit,
                   rate=np.mean([f["rate"] for f in fps]),
                   cv=np.nanmean([f["cv"] for f in fps]),
                   sup16=np.nanmean([f["sup16"] for f in fps]),
                   phent=np.nanmean([f["phase_entropy"] for f in fps]),
                   c8=np.mean([f["c8"] for f in fps]),
                   c16=np.mean([f["c16"] for f in fps]),
                   c24=np.mean([f["c24"] for f in fps]))
        ms = match_score(fingerprint(run_point(kind, p, jit, args.nframes,
                                                seed=1000, **extra),
                                     args.nframes))
        agg["match"] = ms["total"]
        rows.append(agg)

    rows.sort(key=lambda r: r["match"])
    import csv
    with open(args.csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["kind", "kw", "p", "jit", "rate", "cv", "sup16",
                    "phase_entropy", "c8", "c16", "c24", "match"])
        for r in rows:
            w.writerow([r["kind"], r["kw"], r["p"], r["jit"],
                        f"{r['rate']:.4f}", f"{r['cv']:.2f}",
                        f"{r['sup16']:.2f}", f"{r['phent']:.2f}",
                        f"{r['c8']:.0f}", f"{r['c16']:.0f}", f"{r['c24']:.0f}",
                        f"{r['match']:.2f}"])
    print(f"{'kind':11s} {'kw':12s} {'p':>4s} {'jit':>5s} {'rate':>6s} "
          f"{'CV':>5s} {'sup16':>6s} {'phent':>6s} {'c8':>5s} {'c16':>5s} "
          f"{'c24':>5s} {'match':>6s}")
    for r in rows:
        print(f"{r['kind']:11s} {r['kw']:12s} {r['p']:>4.2f} {r['jit']:>5.2f} "
              f"{r['rate']:>6.4f} {r['cv']:>5.2f} {r['sup16']:>6.2f} "
              f"{r['phent']:>6.2f} {r['c8']:>5.0f} {r['c16']:>5.0f} "
              f"{r['c24']:>5.0f} {r['match']:>6.2f}")


if __name__ == "__main__":
    main()
