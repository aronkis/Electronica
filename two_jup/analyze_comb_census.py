#!/usr/bin/env python3
"""analyze_comb_census.py census.csv -- pre-stated verdict on the ROM-air comb census.
PRESENT  if mean biterr rate > 1e5/s  (comb prediction ~2e6/s)
ABSENT   if                 < 1e4/s  (clean anchor ~2.5e3/s)
ANOMALOUS otherwise. Counters are cumulative; wraps/resets (negative deltas) dropped."""
import sys
import numpy as np

# Manual parse: genfromtxt with converters returns a 1-D structured array and
# crashed on first contact with real data (2026-08-24) -- the plan's flagged weak
# point. direct_reg_access prints 0x-prefixed hex; int(s,16) handles it.
rows = []
for ln in open(sys.argv[1]):
    p = ln.strip().split(",")
    if len(p) == 3:
        rows.append((float(p[0]), int(p[1], 16), int(p[2], 16)))
rows = np.array(rows)
t, pk, be = rows[:, 0], rows[:, 1], rows[:, 2]
dt, dpk, dbe = np.diff(t), np.diff(pk), np.diff(be)
ok = (dt > 0) & (dpk >= 0) & (dbe >= 0)
span = t[-1] - t[0]
fps = dpk[ok].sum() / dt[ok].sum()
eps = dbe[ok].sum() / dt[ok].sum()
# time structure: per-sample biterr deltas; a comb single is ~12k errs in one bucket
big = int((dbe[ok] > 5000).sum())
print(f"CENSUS span={span:.1f}s samples={len(t)} framesync={fps:.0f} f/s "
      f"biterr_rate={eps:.3g}/s big_events={big}")
print(f"  denominators: {dpk[ok].sum():.0f} frames, {dbe[ok].sum():.0f} bit errors, "
      f"{dt[ok].sum():.1f} s counted (wrap-dropped: {int((~ok).sum())})")
v = "PRESENT" if eps > 1e5 else ("ABSENT" if eps < 1e4 else "ANOMALOUS")
print(f"COMB_CENSUS_VERDICT={v}")
