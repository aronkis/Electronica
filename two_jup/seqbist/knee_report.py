#!/usr/bin/env python3
"""knee_report.py -- summarise SEQ-BIST legs on the saturation axis.

For each run dir: achieved TGEN emission rate (chk_last_seq delta / window), the
0x104 air rate, the filler fraction, and the gap1/gap2 split that says WHICH loss
mechanism is in play:
  gap2-dominant  -> over-supply: the generator offered more than the chain could take
                    and whole frames were dropped, losing seq numbers. Self-inflicted.
  gap1-dominant  -> single-slot losses = the candidate fabric loss.
A gap is USABLE as the mission gap when emitted is >= 4 % below the 0x104 rate.
"""
import json, sys, os

def one(d):
    # DRY runs write into the SAME two_jup/comb/runs/ tree as real legs (seqbist_run.sh
    # honours OUT/TS identically in both modes), so a desk test lands beside silicon data
    # and will silently appear in a results table. Refuse them here rather than let a
    # [sim] artefact be quoted as [silicon]. Caught 2026-09-04 when three DRY 12 s
    # gapsweep dirs showed up in this report next to the real 120 s legs.
    try:
        meta = open(os.path.join(d, "meta.txt")).read()
    except OSError:
        meta = ""
    if "dry=1" in meta:
        return "DRY"
    rp = os.path.join(d, "readings.jsonl")
    if not os.path.exists(rp):
        return "NOREAD"
    rows = [json.loads(l) for l in open(rp) if l.strip()]
    if len(rows) < 2:
        return None
    a, b = rows[0], rows[-1]
    dt = b["ts_mono"] - a["ts_mono"]
    g = lambda k: b[k] - a[k]
    em, air, ev = g("chk_last_seq"), g("reg_0x104"), g("chk_gap_events")
    gap = ""
    try:
        for ln in open(os.path.join(d, "meta.txt")):
            if ln.startswith("fill="):
                gap = ln.split("gap=")[1].split()[0]
    except OSError:
        pass
    r_em, r_air = em / dt, air / dt
    under = 100.0 * (1 - r_em / r_air) if r_air else 0.0
    g1, g2, g3 = g("chk_gap1"), g("chk_gap2"), g("chk_gap3plus")
    fam = "gap1" if g1 > g2 else ("gap2" if g2 > g1 else "mixed")
    return dict(dir=os.path.basename(d), gap=gap, dt=dt, r_em=r_em, r_air=r_air,
                under=under, ev=ev, lost=g("chk_lost_slots"),
                pct=100.0 * ev / em if em else 0.0, g1=g1, g2=g2, g3=g3, fam=fam,
                usable=under >= 4.0)

print(f"{'gap':>7} {'emit/s':>8} {'air/s':>8} {'under%':>7} {'loss%':>8} "
      f"{'gap1':>5} {'gap2':>5} {'g3+':>4} {'family':>7} {'usable':>7}  dir")
for d in sys.argv[1:]:
    r = one(d)
    if r == "DRY":
        print(f"(DRY desk run -- SKIPPED, not silicon) {os.path.basename(d)}"); continue
    if r == "NOREAD":
        print(f"(no readings.jsonl -- aborted/refused leg) {os.path.basename(d)}"); continue
    if not r:
        print(f"(too few readings) {d}"); continue
    print(f"{r['gap']:>7} {r['r_em']:8.1f} {r['r_air']:8.1f} {r['under']:7.2f} "
          f"{r['pct']:8.4f} {r['g1']:5d} {r['g2']:5d} {r['g3']:4d} {r['fam']:>7} "
          f"{str(r['usable']):>7}  {r['dir']}")
