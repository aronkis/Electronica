#!/usr/bin/env python3
"""comb_phase.py FILE.bin --period 32 [--period 16 --period 33 ...]
-- loss-position histogram modulo each requested period, over the live
window (settle 15s, live-window end rule), on the record-position
(reconstructed slot) axis from two_jup/comb/common.py:loss_slot_trains.

For each period P: counts each lost slot's (position - lo) % P (positions are
already relative to the reconstructed slot axis, so this is phase within the
comb), a chi-square uniformity statistic (H0: loss position is uniform over
the P phases) with its p-value (via a bundled regularized-incomplete-gamma
implementation -- no scipy dependency, matching the rest of two_jup/), and
the argmax phase.

Uses the ALL-LOSS train (every lost slot, any run length) by default -- the
comb-phase question is "where in the period does loss cluster", and singles
vs. bursts are a separate axis already covered by comb_census.py's run-length
bins. Pass --singles-only to run the histogram on the singles train instead
(useful cross-check against comb_autocorr.py's singles variant).

Usage: comb_phase.py FILE.bin --period 32 [--period 16 --period 33 ...] [--singles-only]
"""
import argparse
import json
import math
import sys

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from common import loss_slot_trains, read_frames


def _gammainc_lower_reg(a, x, itmax=500, eps=3e-12):
    """Regularized lower incomplete gamma P(a, x), series/continued-fraction
    (Numerical-Recipes style), used for the chi-square CDF (no scipy)."""
    if x <= 0:
        return 0.0
    if x < a + 1.0:
        # series
        ap = a
        summ = 1.0 / a
        delta = summ
        for _ in range(itmax):
            ap += 1.0
            delta *= x / ap
            summ += delta
            if abs(delta) < abs(summ) * eps:
                break
        return summ * math.exp(-x + a * math.log(x) - math.lgamma(a))
    else:
        # continued fraction for Q(a,x), then P = 1-Q
        tiny = 1e-300
        b = x + 1.0 - a
        c = 1.0 / tiny
        d = 1.0 / b
        h = d
        for i in range(1, itmax + 1):
            an = -i * (i - a)
            b += 2.0
            d = an * d + b
            if abs(d) < tiny:
                d = tiny
            c = b + an / c
            if abs(c) < tiny:
                c = tiny
            d = 1.0 / d
            delta = d * c
            h *= delta
            if abs(delta - 1.0) < eps:
                break
        q = math.exp(-x + a * math.log(x) - math.lgamma(a)) * h
        return 1.0 - q


def chisq_pvalue(chi2, dof):
    """Upper-tail p-value for a chi-square statistic (1 - CDF)."""
    if dof <= 0:
        return 1.0
    return 1.0 - _gammainc_lower_reg(dof / 2.0, chi2 / 2.0)


def phase_histogram(fail_train, period):
    n = len(fail_train)
    if n == 0:
        return None
    idx = np.flatnonzero(fail_train)
    if idx.size == 0:
        return dict(period=period, n_events=0, hist=[0] * period,
                    chi2=0.0, dof=period - 1, pvalue=1.0, argmax=0)
    phase = idx % period
    hist = np.bincount(phase, minlength=period).astype(np.int64)
    n_events = int(hist.sum())
    # exposure per phase: how many slot-axis positions map to that phase
    # (uniform to within 1 for any n not a multiple of period), so the null
    # expectation per phase is n_events / period scaled by relative exposure.
    exposure = np.bincount(np.arange(n) % period, minlength=period).astype(np.float64)
    expected = n_events * exposure / exposure.sum()
    with np.errstate(divide="ignore", invalid="ignore"):
        terms = np.where(expected > 0, (hist - expected) ** 2 / expected, 0.0)
    chi2 = float(terms.sum())
    dof = period - 1
    pvalue = chisq_pvalue(chi2, dof)
    return dict(period=period, n_events=n_events, hist=hist.tolist(),
                chi2=chi2, dof=dof, pvalue=pvalue, argmax=int(np.argmax(hist)))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("file", help="frames.bin")
    ap.add_argument("--period", action="append", type=int, required=True,
                     help="period(s) to histogram modulo; repeatable")
    ap.add_argument("--singles-only", action="store_true",
                     help="use the singles-only train instead of all-loss")
    ap.add_argument("--out", help="write the full result as JSON to this path")
    args = ap.parse_args(argv)

    fr = read_frames(args.file)
    lt = loss_slot_trains(fr)
    tag = args.file.split("/")[-2] if "/" in args.file else args.file
    if not lt["usable"]:
        print(f"{tag}: UNUSABLE (live window {lt['live_end']:.0f}s of {lt['dur']:.0f}s"
              f"{', WEDGED' if lt['wedged'] else ''})")
        if args.out:
            with open(args.out, "w") as f:
                json.dump(dict(path=args.file, usable=False, dur=lt["dur"],
                                live_end=lt["live_end"], wedged=lt["wedged"]), f, indent=2)
        return
    train = lt["singles"] if args.singles_only else lt["all_loss"]
    variant = "SINGLES-ONLY" if args.singles_only else "ALL-LOSS"
    print(f"=== {tag}  [{variant}]  slot axis [{lt['lo']}, {lt['hi']}] "
          f"({lt['n_slots']} slots)  events={int(train.sum())} ===")
    print("  [CAVEAT] chi-square p-values assume independent draws; losses inside "
          "a multi-frame run are NOT independent, so p-values here are "
          "anti-conservative (more likely to call NON-UNIFORM than a truly "
          "independent process would) -- treat as a screening signal, not a "
          "calibrated p-value.")
    out_periods = {}
    for p in args.period:
        r = phase_histogram(train, p)
        sig = "NON-UNIFORM" if r["pvalue"] < 0.05 else "uniform"
        print(f"  period={p:3d}  argmax_phase={r['argmax']:3d}  "
              f"chi2={r['chi2']:.2f} dof={r['dof']} p={r['pvalue']:.4g}  [{sig}]")
        print(f"    hist: {r['hist']}")
        out_periods[str(p)] = r
    if args.out:
        result = dict(path=args.file, usable=True, dur=lt["dur"], live_end=lt["live_end"],
                      wedged=lt["wedged"], variant=variant, lo=lt["lo"], hi=lt["hi"],
                      n_slots=lt["n_slots"], n_events=int(train.sum()), periods=out_periods)
        with open(args.out, "w") as f:
            json.dump(result, f, indent=2)


if __name__ == "__main__":
    main(sys.argv[1:])
