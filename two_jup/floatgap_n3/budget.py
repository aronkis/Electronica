#!/usr/bin/env python3
"""N3 budget aggregation: ladder_all.csv -> per-stage quadrature margin budget."""
import csv, math, statistics as st
from collections import defaultdict

rows = list(csv.DictReader(open('ladder_all.csv')))
runs = defaultdict(dict)   # (capture,off) -> rung -> medEVM
for r in rows:
    runs[(r['capture'], r['off'])][r['rung']] = float(r['medEVM'])

order = ['float','agc','rrc','ss','cfc','cs','pa','con']
stages = order[1:]
contrib = defaultdict(list)   # rung -> list of signed quadrature contributions
totals = []
print(f"{'run':28s} " + " ".join(f"{r:>7s}" for r in order))
for k, d in sorted(runs.items()):
    print(f"{k[0]+'_o'+k[1]:28s} " + " ".join(
        f"{d.get(r,float('nan')):7.3f}" for r in order))
    prev = d.get('float')
    for rg in stages:
        cur = d.get(rg)
        if cur is None or prev is None or math.isnan(cur):
            contrib[rg].append(float('nan')); continue
        q = cur*cur - prev*prev
        contrib[rg].append(math.copysign(math.sqrt(abs(q)), q))
        prev = cur
    if 'con' in d and 'float' in d:
        q = d['con']**2 - d['float']**2
        totals.append(math.copysign(math.sqrt(abs(q)), q))

print("\nPer-stage signed quadrature contribution (EVM pp), per run + median:")
med = {}
for rg in stages:
    v = [x for x in contrib[rg] if not math.isnan(x)]
    med[rg] = st.median(v) if v else float('nan')
    print(f"  {rg:4s} " + " ".join(f"{x:7.3f}" for x in contrib[rg]) +
          f"   median {med[rg]:7.3f}")
tot = st.median(totals) if totals else float('nan')
print(f"\nTotal fixed-vs-float gap (con vs float, quadrature, median): {tot:.3f} pp")
s = sum(max(m,0.0)**2 for m in med.values())
print(f"Quadrature sum of positive stage medians: {math.sqrt(s):.3f} pp")
