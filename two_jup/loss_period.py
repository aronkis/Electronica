#!/usr/bin/env python3
"""loss_period.py <frames.bin>... [--settle 15] -- is the frame loss PERIODIC, and at what period?

WHY. The steady-state loss looked like isolated random single-frame errors (334 of 397
events were length 1), which reads as marginal SNR. It is not random: across four captures
the errored positions sit at a fixed phase modulo 32, and 89% of inter-error gaps are exact
multiples of 32. 32 is the RX DMA batch depth (-M 32, QPSK_RX_QUEUED=1), so the loss is one
slot of each queued batch.

This tool measures the period WITHOUT needing paired IQ, so an -M sweep is cheap: it works
off frames.bin alone.

METHOD. Frame identity comes from reg_packets (the fabric framesync counter), NOT from
record index -- the host writes several records per fabric frame, so record index would
smear the period. Positions are deduplicated and taken relative to the first steady-state
frame. Counter RESETS split the run into segments, analysed independently, because a reset
makes positions non-comparable across it (a mistake made earlier in this campaign).
Reported: the gap histogram, the best period by mod-consistency, and the phase.
"""
import sys, os, argparse, collections
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_taxonomy import read_frames

DEF_CANDS = [8, 16, 24, 32, 48, 64, 96, 128]
GTHRESH = 0.70


def _verdict(rows):
    """The FUNDAMENTAL rule, in ONE place: the LARGEST candidate period whose multiples
    still capture >=GTHRESH of the gaps. Both the CLI and fundamental() call this, so the
    number sweep_report.py tabulates is by construction the number loss_period.py prints.
    rows = [(P, phase, concentration, gapfrac)]."""
    ok = [r for r in rows if r[3] >= GTHRESH]
    return max(ok, key=lambda r: r[0]) if ok else None


def fundamental(path, settle=15.0, cands=None):
    """Scoring as a callable: -> (P, phase, concentration, gapfrac) or None."""
    cands = cands or DEF_CANDS
    fr = read_frames(path)
    bad = (fr['crc_ok'] == 0)
    t = fr['t_mono_ns'].astype(np.float64)/1e9; t -= t[0]
    pk = fr['reg_packets'].astype('int64')
    keep = t >= settle
    if keep.sum() < 100:
        return None
    pk, bad = pk[keep], bad[keep]
    seg_bounds = [0] + (np.flatnonzero(np.diff(pk) < 0) + 1).tolist() + [len(pk)]
    errs = []
    for s, e in zip(seg_bounds, seg_bounds[1:]):
        if e - s < 50: continue
        p, b = pk[s:e], bad[s:e]
        base = p[0]
        errs += sorted({int(x - base) for x in p[b]})
    errs = sorted(set(errs))
    if len(errs) < 4:
        return None
    gaps = [b - x for x, b in zip(errs, errs[1:]) if b - x > 1]
    rows = []
    for P in cands:
        ph = collections.Counter(x % P for x in errs)
        dom, n = ph.most_common(1)[0]
        gm = sum(1 for g in gaps if g % P == 0)/len(gaps) if gaps else 0
        rows.append((P, dom, n/len(errs), gm))
    return _verdict(rows)


def _cli():
  ap = argparse.ArgumentParser()
  ap.add_argument('frames', nargs='+')
  ap.add_argument('--settle', type=float, default=15.0)
  ap.add_argument('--periods', default='8,16,24,32,48,64,96,128')
  a = ap.parse_args()
  CANDS = [int(x) for x in a.periods.split(',')]

  for path in a.frames:
      fr = read_frames(path)
      bad = (fr['crc_ok'] == 0)
      t = fr['t_mono_ns'].astype(np.float64)/1e9; t -= t[0]
      pk = fr['reg_packets'].astype('int64')
      keep = t >= a.settle
      if keep.sum() < 100:
          print(f"{path}: too few steady-state records"); continue
      pk, bad, t = pk[keep], bad[keep], t[keep]
      # split on counter resets
      seg_bounds = [0] + (np.flatnonzero(np.diff(pk) < 0) + 1).tolist() + [len(pk)]
      errs = []
      for s, e in zip(seg_bounds, seg_bounds[1:]):
          if e - s < 50: continue
          p, b = pk[s:e], bad[s:e]
          base = p[0]
          errs += sorted({int(x - base) for x in p[b]})
      errs = sorted(set(errs))
      if len(errs) < 4:
          print(f"{os.path.basename(os.path.dirname(path)) or path}: only {len(errs)} errors"); continue
      gaps = [b - x for x, b in zip(errs, errs[1:]) if b - x > 1]
      name = os.path.basename(os.path.dirname(path)) or path
      print(f"=== {name} ===  steady-state errors={len(errs)}  gaps={len(gaps)}")
      # FUNDAMENTAL period = the LARGEST P whose multiples still capture most gaps.
      # Scoring on raw concentration is wrong: every gap that is a multiple of 32 is also a
      # multiple of 8 and 16, so small periods always win. The fundamental shows up as the
      # point where gap%P collapses (measured: 95% at P<=32, 27% at P=64 -> fundamental 32).
      rows = []
      for P in CANDS:
          ph = collections.Counter(x % P for x in errs)
          dom, n = ph.most_common(1)[0]
          frac = n/len(errs)
          gm = sum(1 for g in gaps if g % P == 0)/len(gaps) if gaps else 0
          rows.append((P, dom, frac, gm))
          print(f"   P={P:4d}  phase {dom:4d}  concentration {frac:5.1%} "
                f"(chance {1/P:5.1%}, enrich {frac*P:4.1f}x)  gaps multiple-of-P {gm:5.1%}")
      v = _verdict(rows)
      if v:
          P, dom, frac, gm = v
          print(f"   -> FUNDAMENTAL PERIOD {P}, phase {dom}, {frac:.0%} of errors at that "
                f"phase ({frac*P:.1f}x chance), {gm:.0%} of gaps multiples of {P}")
      else:
          print("   -> no period captures >=70% of gaps: loss is NOT periodic")
      h = collections.Counter(gaps)
      print("   gap histogram: " + ", ".join(f"{g}x{n}" for g, n in sorted(h.items())[:12]))


if __name__ == '__main__':
    _cli()
