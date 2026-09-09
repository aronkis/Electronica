#!/usr/bin/env python3
"""zero_rate_metric.py <dir-or-csv...> [--skip-s N] -- ZERO-RATE TIME FRACTION.

WHY THIS REPLACES MUTE/FROZEN COUNTS AS THE PRIMARY METRIC
  A "mute" is pkts static for >25 ms, so mute COUNT is a quantised, threshold-sensitive
  proxy for the same underlying quantity this measures directly: how much of the time the
  link was fully stopped. Measured on the 2026-08-07 rotation, mute count is a near-perfect
  function of zero-rate time (zero% 0.38 -> 106 mutes, 0.25 -> 82, 0.02 -> 1), which means
  the counts carried no information the fraction does not.

  Worse, counts are BADLY behaved as a statistic:
    - one physical stall fragments into many "events" whenever pkts briefly advances
      (block03: 17 FROZEN that are two bursts), so counts overstate stall number ~10x
    - a 25 ms threshold makes the count discontinuous in the underlying physics
    - block-to-block variance was 20x, so n=3-4 per arm could not resolve an image effect
  The time fraction is continuous, threshold-free, and directly comparable across arms of
  unequal length. Use it as the headline; keep FROZEN/RUNNING for CLASSIFYING what kind of
  stoppage it was, which the fraction cannot tell you.

DEFINITIONS (deliberately explicit, because the earlier metrics hid their assumptions)
  interval        one poller sample gap, ~35 ms
  reset interval  pkts DECREASED -> the watchdog's 0x000 zeroed the counter. Counted and
                  reported separately, EXCLUDED from both numerator and denominator: we
                  cannot tell from the counter alone whether the link was dead across it.
  zero interval   pkts did not advance -> link produced no framesync for that gap
  zero_frac       sum(dt of zero intervals) / sum(dt of non-reset intervals), TIME-weighted
                  rather than interval-counted, since sample gaps vary 33-41 ms.
"""
import sys, os, csv, glob, argparse, statistics

def analyse(path, skip_s):
    rows = []
    with open(path) as fh:
        rd = csv.reader(fh); next(rd, None)
        for r in rd:
            if len(r) >= 13:
                try: rows.append((int(r[0]), int(r[1], 16)))
                except ValueError: pass
    if len(rows) < 100: return None
    if skip_s > 0:
        t0 = rows[0][0]
        rows = [r for r in rows if (r[0]-t0)/1e9 >= skip_s]
        if len(rows) < 100: return None
    zero_t = valid_t = reset_t = 0.0
    resets = 0
    rates = []
    for (t0, p0), (t1, p1) in zip(rows, rows[1:]):
        dt = (t1 - t0) / 1e9
        if dt <= 0 or dt > 1.0:      # a >1 s gap means the poller itself stalled
            continue
        if p1 < p0:
            resets += 1; reset_t += dt; continue
        valid_t += dt
        if p1 == p0:
            zero_t += dt
        else:
            r = (p1-p0)/dt
            if r <= 3000: rates.append(r)
    hrs = (rows[-1][0]-rows[0][0]) / 3.6e12
    return dict(hours=hrs, zero_frac=zero_t/valid_t if valid_t else float('nan'),
                zero_s=zero_t, valid_s=valid_t, resets=resets, reset_hr=resets/hrs if hrs else 0,
                med_fps=statistics.median(rates) if rates else 0)

ap = argparse.ArgumentParser()
ap.add_argument('paths', nargs='+')
ap.add_argument('--skip-s', type=float, default=60.0)
a = ap.parse_args()

files = []
for p in a.paths:
    files += sorted(glob.glob(os.path.join(p, 'block*.csv'))) if os.path.isdir(p) else [p]

res = []
print(f"{'block':<28}{'hrs':>5}{'zero_frac%':>11}{'zero_s':>9}{'rst/hr':>8}{'med f/s':>9}")
for f in files:
    r = analyse(f, a.skip_s)
    if not r: continue
    name = os.path.basename(f)[:-4]
    res.append((name, r))
    print(f"{name:<28}{r['hours']:5.2f}{100*r['zero_frac']:11.4f}{r['zero_s']:9.1f}"
          f"{r['reset_hr']:8.1f}{r['med_fps']:9.0f}")

def arm(n):
    n = n.lower()
    if 'unfixed' in n: return 'unfixed'
    if 'tmronly' in n: return 'tmronly'
    if 'tmr' in n:     return 'tmr'
    return '?'

groups = {}
for n, r in res: groups.setdefault(arm(n), []).append((n, r))
print("\nBY ARM (time-weighted pooled, and per-block spread):")
for k, v in sorted(groups.items()):
    zs = sum(x[1]['zero_s'] for x in v); vs = sum(x[1]['valid_s'] for x in v)
    fr = [100*x[1]['zero_frac'] for x in v]
    print(f"  {k:<9} n={len(v)}  pooled {100*zs/vs:.4f}%   per-block "
          f"[{', '.join(f'{x:.3f}' for x in fr)}]  median {statistics.median(fr):.4f}%")

# NON-OVERLAPPING adjacent pairs. Using every consecutive pair would put each block in
# TWO deltas with opposite signs -- the deltas are then correlated by construction and a
# paired t-test on them reports an n that does not exist. (Done wrongly first time: 7
# overlapping pairs gave t=-2.64, p~0.04; the 3 independent pairs give t=-1.89, p~0.20.)
print("\nADJACENT PAIRS (non-overlapping, same channel window):")
d = []
i = 0
while i < len(res)-1:
    a1, a2 = arm(res[i][0]), arm(res[i+1][0])
    if a1 == a2 or '?' in (a1, a2):
        i += 1; continue
    f1, f2 = 100*res[i][1]['zero_frac'], 100*res[i+1][1]['zero_frac']
    fix = f1 if a1 != 'unfixed' else f2
    unf = f2 if a1 != 'unfixed' else f1
    d.append(unf - fix)
    print(f"  {res[i][0]:<26}{f1:8.4f}%   vs {res[i+1][0]:<26}{f2:8.4f}%   "
          f"delta {unf-fix:+8.4f} (positive = fixed better)")
    i += 2          # consume BOTH blocks -- no reuse
if d:
    print(f"\n  pairs favouring the FIXED arm: {sum(1 for x in d if x>0)}/{len(d)}   "
          f"mean paired delta {statistics.mean(d):+.4f} points")
    if len(d) > 1:
        sd = statistics.stdev(d)
        print(f"  sd {sd:.4f}" + (f"   paired t {statistics.mean(d)/(sd/len(d)**0.5):+.2f} on {len(d)-1} df"
              if sd > 0 else ""))
    print("  NOTE: with block-to-block zero_frac spanning ~20x, a handful of pairs cannot")
    print("        resolve an image effect. Treat the sign, not the magnitude, as the signal.")
