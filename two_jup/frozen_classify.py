#!/usr/bin/env python3
"""frozen_classify.py <stallcatch.csv> [--skip-s N] [--forensic] [--label NAME]

FROZEN-class mute classifier for the 13-column stall poller.

PROTOCOL (unchanged from the campaign definition):
  a MUTE  = a window where pkts (0x104) is static for > MUTE_MS
  QUIET   = a mute whose rstcs (0x150) moved: the demod was resetting, not stalled
  then within the rstcs-flat mutes:
    FROZEN  = biterr (0x108) ALSO static  -> Delay14 threshold starvation, the class
              the TMR fix targets
    RUNNING = biterr advancing            -> sustained bad input (channel/SSI), which
              ARQ covers and TMR cannot

CONTAMINATION HANDLING (2026-08-07, and it matters for interpreting the counts):
  These CSVs are collected with stallpoll and lock_watchdog both holding the single
  direct_reg_access address latch, because killing the watchdog leaves the link
  wedged and there is no soak to measure. ~0.07% of rows therefore carry a FOREIGN
  register's value (0xC010180 = adc_forensic 0x15C). A corrupt value inside an
  otherwise-static run makes pkts look like it MOVED, which ENDS a static window
  early -> corrupt rows cause MISSED mutes, not false ones. Conservative for
  detection, but NOT symmetric between arms: an arm whose true count is 0 is far
  more fragile to a missed detection than an arm counting 3. Implausible rows are
  dropped and the drop count reported, so the exposure is visible.

  DO NOT filter against the last ACCEPTED value. That version latched up: one
  spurious LOW read (pkts=2) became the reference, every later valid row looked
  like an impossible jump from 2 and was dropped, and the reference never
  recovered -- 28288 rows silently discarded and a fabricated "7.8% contamination"
  figure (true rate 0.08%). Neighbour agreement carries no state forward.

WARMUP: --skip-s excludes the post-bring-up RF settle (measured: three ~1 s bursts
  at 7.9/9.8/11.6 s after RF enable). Marked and REPORTED, never silently dropped.

FORENSICS: the poller logs 13 columns; the classification needs 4. --forensic dumps
  the full row at each mute's entry and exit and names the columns that moved. That
  is how strobe_forensic (0x184) was caught latching 5->6 at the rate step-down.
"""
import sys, csv, argparse, collections

MUTE_MS     = 25.0      # pkts static longer than this = a mute
RSTCS_GUARD = 100       # rows either side that must be rstcs-flat
NOMINAL_FPS = 1245.44   # 15.36 Msym/s / 12333 sym per frame

COLS = ['t_ns','pkts','rstcs','pdiv_cnt','pdiv_beat','idiv_beat','ip','is',
        'strobe','beat','ta_ops','ta_diag','biterr']
T, PK, RS, BE = 0, 1, 2, 12
# free-running / expected-to-move columns: not interesting when they change
FREE = {'t_ns','pkts','rstcs','biterr','beat'}
FORENSIC = [i for i,c in enumerate(COLS) if c not in FREE]

def load(path):
    rows, bad = [], 0
    with open(path) as f:
        rd = csv.reader(f); next(rd, None)
        for r in rd:
            if len(r) < 13: continue
            try:
                rows.append([int(r[0])] + [int(x, 16) for x in r[1:13]])
            except ValueError:
                bad += 1
    clean, dropped = [], 0
    for i, row in enumerate(rows):
        if 0 < i < len(rows) - 1:
            p, n = rows[i-1][PK], rows[i+1][PK]
            op, on_, span = abs(row[PK]-p), abs(row[PK]-n), abs(n-p)
            if op > 1000 and on_ > 1000 and span < op/4:
                dropped += 1; continue
        clean.append(row)
    return clean, dropped, bad

def classify(rows):
    out, i, n = [], 0, len(rows)
    while i < n - 1:
        j = i
        while j < n - 1 and rows[j+1][PK] == rows[i][PK]:
            j += 1
        dur = (rows[j][T] - rows[i][T]) / 1e6
        if j > i and dur > MUTE_MS:
            lo, hi = max(0, i-RSTCS_GUARD), min(n-1, j+RSTCS_GUARD)
            rst_flat = rows[lo][RS] == rows[hi][RS]
            be_flat  = rows[i][BE] == rows[j][BE]
            cls = 'QUIET' if not rst_flat else ('FROZEN' if be_flat else 'RUNNING')
            out.append((rows[i][T], dur, cls, rows[i], rows[j]))
        i = max(j, i+1)
    return out

ap = argparse.ArgumentParser()
ap.add_argument('csv'); ap.add_argument('--label', default='')
ap.add_argument('--skip-s', type=float, default=0.0)
ap.add_argument('--episode-gap', type=float, default=5.0,
                help='merge same-class mutes closer than this many seconds into ONE episode. '
                     'A single physical stall fragments into many sub-events when pkts briefly '
                     'advances mid-stall: block03 logged 17 FROZEN that are really 2 episodes '
                     '(8 within +1822-1825s, 9 within +1987-1990s). Raw event counts overstate '
                     'stall COUNT by ~an order of magnitude and are not comparable across arms.')
ap.add_argument('--forensic', action='store_true',
                help='dump all 13 columns at each mute boundary and name what moved')
a = ap.parse_args()

rows, dropped, unparsed = load(a.csv)
excl = 0
if a.skip_s > 0 and rows:
    t0 = rows[0][T]
    pre = [r for r in rows if (r[T]-t0)/1e9 < a.skip_s]
    excl = len(classify(pre)) if len(pre) > 2 else 0
    rows = [r for r in rows if (r[T]-t0)/1e9 >= a.skip_s]
if len(rows) < 100:
    print(f"{a.csv}: only {len(rows)} usable rows"); sys.exit(1)

hours = (rows[-1][T]-rows[0][T]) / 3.6e12
ev = classify(rows)
c = collections.Counter(e[2] for e in ev)

def episodes(evts, gap):
    out = []
    for e in evts:
        if out and e[2] == out[-1][-1][2] and (e[0] - out[-1][-1][0])/1e9 <= gap:
            out[-1].append(e)
        else:
            out.append([e])
    return out
eps = episodes(ev, a.episode_gap)
ce = collections.Counter(g[0][2] for g in eps)

print(f"=== FROZEN-class classification{' — '+a.label if a.label else ''} ===")
print(f"  rows      {len(rows)} usable ({dropped} implausible dropped = "
      f"{100*dropped/max(1,len(rows)+dropped):.3f}%, {unparsed} unparsable)")
print(f"  observed  {hours:.2f} h" +
      (f"   [first {a.skip_s:.0f}s RF-warmup EXCLUDED: {a.skip_s/3600:.3f} h, "
       f"{excl} event(s) dropped]" if a.skip_s > 0 else ""))
print(f"  mutes (>{MUTE_MS:.0f} ms): {len(ev)}")
print(f"  {'class':<8} {'events':>7} {'ev/hr':>7}   {'EPISODES':>9} {'ep/hr':>7}"
      f"   (episodes merge same-class mutes <{a.episode_gap:.0f}s apart)")
for k in ('FROZEN','RUNNING','QUIET'):
    print(f"    {k:<8} {c[k]:7d} {c[k]/hours if hours else 0:7.2f}   "
          f"{ce[k]:9d} {ce[k]/hours if hours else 0:7.2f}")

if a.forensic and ev:
    print("\n  FORENSIC — columns that MOVED across each mute "
          "(free-running t_ns/pkts/rstcs/biterr/beat omitted):")
    moved_hist = collections.Counter()
    for t, dur, cls, r0, r1 in ev:
        ch = [(COLS[i], r0[i], r1[i]) for i in FORENSIC if r0[i] != r1[i]]
        for name,_,_ in ch: moved_hist[name] += 1
        if cls == 'FROZEN':
            off = (t-rows[0][T])/1e9
            desc = ', '.join(f"{n} {hex(x)}->{hex(y)}" for n,x,y in ch) or 'nothing moved'
            print(f"    FROZEN +{off:8.1f}s {dur:7.1f}ms  {desc}")
    print("  how often each forensic column moved across a mute (any class):")
    if moved_hist:
        for n, k in moved_hist.most_common():
            print(f"    {n:<11} {k:4d} / {len(ev)} mutes")
    else:
        print("    none — every forensic column was static across every mute")
    print("  static-value census (a column constant all run tells you the block's state):")
    for i in FORENSIC:
        vals = {r[i] for r in rows}
        if len(vals) == 1:
            print(f"    {COLS[i]:<11} constant at {hex(vals.pop())}")
        else:
            print(f"    {COLS[i]:<11} {len(vals)} distinct values")
