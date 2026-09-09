#!/usr/bin/env python3
"""sweep_report.py <sweep_dir> -- rank RX configurations from rx_config_sweep.sh.

Joins the three things that have to be weighed together and were previously measured
apart: delivered FER (the campaign metric), daemon CPU, and queued-path occupancy.

METHOD NOTES (the traps this campaign has already fallen into):
  * PER is pooled per CONFIG over its runs via accept_analyze.analyze(), reusing that
    module's wedge-aware live-window logic rather than re-implementing it.
  * The pooled Clopper-Pearson bound treats frames as the unit. Losses here are bursty
    and run-correlated, so the pooled CP is reported as a PRECISION figure only; the
    honest between-config comparison is the PAIRED-BY-CYCLE table, whose unit is the
    RUN. Both are printed; do not quote the CP interval as if n were the frame count.
  * Only cycles where BOTH configs produced a usable run are paired -- a config that
    wedged out of a cycle must not silently borrow another cycle's channel.
"""
import sys, os, csv, collections, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from accept_analyze import analyze, cp_upper
from loss_period import fundamental

if len(sys.argv) < 2:
    sys.exit("usage: sweep_report.py <sweep_dir>")
RUN = sys.argv[1]
rows = list(csv.DictReader(open(os.path.join(RUN, 'results.csv'))))

# ---- per-run PER via the acceptance analyser -------------------------------------
per_run = {}                      # (tag, cycle) -> dict(miss, span, per, wedged)
cfg_of  = {}                      # tag -> (rxq, m)
for r in rows:
    tag, cyc = r['tag'], int(r['cycle'])
    cfg_of[tag] = (r['rxq'], r['m'])
    if r['ok'] != '1':
        continue
    fb = os.path.join(RUN, r['outdir'], 'frames.bin')
    if not os.path.exists(fb):
        continue
    try:
        a = analyze(fb)
    except Exception as e:
        print(f"  (analyse failed {r['outdir']}: {e})"); continue
    if not a.get('usable'):
        continue
    try:
        fnd = fundamental(fb, 15.0, [8, 16, 32, 64, 128])
    except Exception:
        fnd = None
    nbig = int(a['bins'].get('>100', 0))   # bursts of >100 consecutive lost frames
    per_run[(tag, cyc)] = dict(miss=a['miss'], span=a['span'], nbig=nbig,
                               per=100*a['miss']/max(a['span'], 1),
                               wedged=a['wedged'], row=r,
                               period=(fnd[0] if fnd else None),
                               phase=(fnd[1] if fnd else None))

if not per_run:
    sys.exit("no usable runs")

# STATED POLICY, mirroring the wedge policy in accept_analyze: a run containing a burst
# of >100 consecutive lost frames (~1 s of outage) is a LINK DROPOUT event, a different
# failure mode from the periodic per-batch loss being compared here. Measured: exactly 2
# of 22 runs, both ~7.2%, each with 3 such bursts; every other run had none. They are
# excluded from the primary comparison and reported separately -- never silently dropped.
BURSTY = {k: v for k, v in per_run.items() if v['nbig'] > 0}
for k in BURSTY:
    per_run.pop(k)
if BURSTY:
    print("=== EXCLUDED: link-dropout runs (burst >100 consecutive frames) ===")
    for (t, c), v in sorted(BURSTY.items()):
        print(f"  {t}_c{c}: PER={v['per']:.3f}%  {v['nbig']} burst(s) >100 frames "
              f"-- distinct failure mode, excluded from the periodic-loss comparison")
    print()

tags = sorted({t for t, _ in per_run}, key=lambda t: (cfg_of[t][0], int(cfg_of[t][1])))

# ---- pooled per config ------------------------------------------------------------
print("=== RANKED CONFIGURATIONS ===")
print(f"{'cfg':>5} {'RXQ':>3} {'M':>3} {'runs':>4} {'PER%':>7} {'CP95UL':>7} {'gate':>7} "
      f"{'medPER':>7} {'>2%':>4} {'CPU%':>6} {'gaps/cmp':>9} {'backlog/cmp':>11} {'period':>8} {'wedges':>6}")
summary = []
for t in tags:
    rs = [v for (tt, _), v in per_run.items() if tt == t]
    k = sum(v['miss'] for v in rs); n = sum(v['span'] for v in rs)
    per = 100*k/max(n, 1); ub = 100*cp_upper(k, n)
    cpus, dpc, bpc, gpc = [], [], [], []
    for v in rs:
        row = v['row']
        try: cpus.append(float(row['cpu_pct']))
        except (ValueError, KeyError): pass
        try:
            c = float(row['completions'])
            if c > 0:
                dpc.append(float(row['defers'])/c)
                bpc.append(float(row['backlog_sum'])/c)
                gpc.append(float(row.get('engine_gaps', 'nan'))/c)
        except (ValueError, KeyError, ZeroDivisionError): pass
    pers_ = [v['per'] for v in rs]
    med = statistics.median(pers_)
    nbad = sum(1 for x in pers_ if x > 2.0)
    rxq, m = cfg_of[t]
    mean = lambda x: statistics.mean(x) if x else float('nan')
    pds = [v['period'] for v in rs if v['period']]
    # modal period across the config's runs, with the agreement count -- one run's
    # period is noise, the same period in most runs is the tracking claim
    pmode = collections.Counter(pds).most_common(1)[0] if pds else (None, 0)
    summary.append(dict(tag=t, rxq=rxq, m=m, runs=len(rs), per=per, ub=ub, med=med, nbad=nbad,
                        cpu=mean(cpus), dpc=mean(dpc), bpc=mean(bpc), gpc=mean(gpc),
                        period=pmode[0], pn=pmode[1], nper=len(pds),
                        wedges=sum(v['wedged'] for v in rs), k=k, n=n))

for s in sorted(summary, key=lambda s: s['med']):
    print(f"{s['tag']:>5} {s['rxq']:>3} {s['m']:>3} {s['runs']:>4} {s['per']:>7.3f} "
          f"{s['ub']:>7.3f} {'PASS' if s['ub']<1.0 else 'NOT MET':>7} "
          f"{s['med']:>7.3f} {str(s['nbad'])+'/'+str(s['runs']):>4} {s['cpu']:>6.1f} {s['gpc']:>9.5f} {s['bpc']:>11.3f} "
          f"{(str(s['period'])+'('+str(s['pn'])+'/'+str(s['nper'])+')') if s['period'] else 'aperiodic':>8} "
          f"{s['wedges']:>6}")
print("\n  medPER = median of the per-run PERs. Large-burst link events hit whichever\n"
      "  config is running, so pooled PER is outlier-dominated; the median is robust\n"
      "  and the paired table is the comparison that controls for drift.")
print("  CP95UL pools frames; losses are bursty and run-correlated, so treat it as a "
      "precision figure.\n  The between-config claim rests on the paired table below "
      "(unit = the run).")

# ---- paired by cycle vs the current default (q32) ---------------------------------
BASE = 'q32' if 'q32' in tags else tags[0]
print(f"\n=== PAIRED BY CYCLE (baseline {BASE}, unit = run) ===")
for t in tags:
    if t == BASE: continue
    cyc = sorted({c for (tt, c) in per_run if tt == t} &
                 {c for (tt, c) in per_run if tt == BASE})
    if not cyc:
        print(f"  {t}: no cycle with both runs usable"); continue
    d = [per_run[(BASE, c)]['per'] - per_run[(t, c)]['per'] for c in cyc]
    wins = sum(1 for x in d if x > 0)
    md = statistics.mean(d)
    sd = statistics.stdev(d) if len(d) > 1 else float('nan')
    print(f"  {t:>5} vs {BASE}: n={len(d)}  median delta {statistics.median(d):+.3f}pp  "
          f"mean {md:+.3f}pp "
          f"(+ = {t} better)  {wins}/{len(d)} cycles favour {t}"
          + (f"  sd {sd:.3f}" if len(d) > 1 else ""))
    print(f"        per-cycle: " + ", ".join(f"c{c}:{per_run[(BASE,c)]['per']:.3f}->"
          f"{per_run[(t,c)]['per']:.3f}" for c in cyc))

# ---- headroom vs race -------------------------------------------------------------
print("\n=== HEADROOM vs RACE (queued configs only) ===")
print("  defers/cmp      = submit slot BUSY (contention). Expected ~0: in steady state")
print("                    the slot is free, so this is not the race that can bite.")
print("  engine_gaps/cmp = transfer ended with the next area NOT yet queued -> the")
print("                    engine had nothing to start. THIS is the race indicator.")
print("  backlog/cmp     = slices undrained at completion, of M (HEADROOM indicator)")
for s in sorted(summary, key=lambda s: int(s['m'])):
    if s['rxq'] != '1':
        continue
    if s['dpc'] != s['dpc']:
        print(f"  {s['tag']:>5} (M={s['m']}): no rxqstat captured"); continue
    frac = s['bpc']/float(s['m'])
    print(f"  {s['tag']:>5} (M={s['m']}): defers/cmp {s['dpc']:.5f}  "
          f"engine_gaps/cmp {s['gpc']:.5f}  "
          f"backlog/cmp {s['bpc']:.2f} = {100*frac:.1f}% of area  "
          f"FER {s['per']:.3f}%")

# ---- cycle effect: are bad runs a CONFIG property or a time-clustered link event? ----
print("\n=== PER BY CYCLE (all configs) -- separates config effects from link events ===")
cycs = sorted({c for _, c in per_run})
print("  cycle " + "".join(f"{t:>9}" for t in tags) + "     worst")
for c in cycs:
    vals = [per_run.get((t, c), {}).get('per') for t in tags]
    cells = "".join((f"{v:>9.3f}" if v is not None else f"{'--':>9}") for v in vals)
    ok = [v for v in vals if v is not None]
    print(f"  {c:>5} {cells}   {max(ok):>7.3f}" if ok else f"  {c:>5} {cells}")
print("  If a cycle's row is bad ACROSS configs, that cycle saw a link event and the")
print("  damage is not attributable to any one configuration.")
