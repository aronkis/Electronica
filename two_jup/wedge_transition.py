#!/usr/bin/env python3
"""wedge_transition.py <wtrans.log> -- WHICH SIGNAL MOVES FIRST at the carrier wedge?

The whole point is ordering, not levels. Levels in both stable states are already known:
healthy golden ~99% / cfc_std ~220 / rstcs/s 0, wedged golden 0% / cfc_std ~19000 /
rstcs/s ~2. Retuning the loop changed nothing once it started, so the question is what
DRAGS it there.

Anchor t0 = the first sample where cap_out stops being golden and stays non-golden.
Then, for each signal, find the earliest sample BEFORE t0 at which it had already left
its own pre-transition baseline by a robust margin (median +/- 6*MAD over the quiet
stretch). The signal with the most negative lead time moved first.

MAD not std: the baseline window is short and a single pre-cursor spike would inflate a
std and hide itself.
"""
import sys, re
import numpy as np

GOLD = 0x04922282
if len(sys.argv) < 2:
    sys.exit("usage: wedge_transition.py <wtrans.log>")

t, cap, cfc, rst, adc, be, pk = [], [], [], [], [], [], []
pat = re.compile(r"t=([\d.]+) cap=0x([0-9a-fA-F]+) cfc=0x([0-9a-fA-F]+) rstcs=0x([0-9a-fA-F]+) "
                 r"adc=0x([0-9a-fA-F]+) biterr=0x([0-9a-fA-F]+) pkts=0x([0-9a-fA-F]+)")
for ln in open(sys.argv[1]):
    m = pat.search(ln)
    if not m:
        continue
    t.append(float(m.group(1)))
    cap.append(int(m.group(2), 16)); cfc.append(int(m.group(3), 16))
    rst.append(int(m.group(4), 16)); adc.append(int(m.group(5), 16))
    be.append(int(m.group(6), 16));  pk.append(int(m.group(7), 16))

if len(t) < 50:
    sys.exit(f"only {len(t)} samples -- no transition captured (link may have stayed healthy)")

t = np.array(t) - t[0]
cap = np.array(cap); rst = np.array(rst); adc = np.array(adc)
be = np.array(be, dtype=float); pk = np.array(pk, dtype=float)
sx = lambda u: (int(u) & 0x1FFFFF) - (1 << 21) if (int(u) & 0x1FFFFF) >= (1 << 20) else (int(u) & 0x1FFFFF)
cfc = np.array([sx(v) for v in cfc], dtype=float)

good = (cap == GOLD)
if good.all():
    sys.exit("link stayed golden throughout -- no transition to analyse")
if not good.any():
    sys.exit("link was already wedged at sample 0 -- re-arm and retry")

# t0 = start of the final sustained non-golden run
i = len(good) - 1
while i > 0 and not good[i]:
    i -= 1
t0 = i + 1
print(f"samples={len(t)}  span={t[-1]:.1f}s  rate={len(t)/max(t[-1],1e-9):.0f} Hz")
print(f"transition at sample {t0} (t={t[t0]:.2f}s), {t0} golden samples before it\n")

base = slice(0, max(t0 // 2, 10))          # first half of the quiet stretch
def lead(name, sig, use_diff=False):
    x = np.diff(sig, prepend=sig[0]) if use_diff else sig
    b = x[base]
    med = np.median(b)
    mad = np.median(np.abs(b - med)) or 1e-9
    thr = 6 * mad
    dev = np.abs(x - med) > thr
    pre = np.flatnonzero(dev[:t0])
    if len(pre) == 0:
        print(f"  {name:12s} no pre-transition excursion (>6*MAD)")
        return None
    # earliest excursion that is sustained (>=3 of the next 5 samples also out)
    for j in pre:
        w = dev[j:j+5]
        if w.sum() >= 3:
            print(f"  {name:12s} first sustained excursion at t={t[j]:.2f}s "
                  f"-> lead {t[j]-t[t0]:+.2f}s before the wedge")
            return t[j] - t[t0]
    print(f"  {name:12s} only isolated excursions (no sustained pre-cursor)")
    return None

print("LEAD TIMES (most negative = moved first):")
leads = {
    'cfc':      lead('cfc', cfc),
    'rstcs':    lead('rstcs', rst, use_diff=True),
    'adc':      lead('adc_forensic', adc),
    'biterr/s': lead('biterr rate', be, use_diff=True),
}
ranked = sorted([(v, k) for k, v in leads.items() if v is not None])
print()
if ranked:
    print(f"  >>> FIRST MOVER: {ranked[0][1]}  ({ranked[0][0]:+.2f}s before the wedge)")
    print( "      cfc first   -> loop loses lock on its own (tracking failure)")
    print( "      rstcs first -> something RESETS the carrier; it then cannot reacquire")
    print( "      adc first   -> SSI delivery hiccup upstream of the modem")
else:
    print("  >>> NO pre-cursor found: the wedge is abrupt at this sample rate.")
    print("      That itself is informative -- it argues against a slow drift into")
    print("      instability and for a discrete event. Re-run with a faster sampler")
    print("      or add AGC level to the polled set.")
