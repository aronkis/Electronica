#!/usr/bin/env python3
"""target_fingerprint.py -- re-derive the MEASURED air-singles fingerprint with
ONE consistent interval/collapse/binning scorer, so the sim campaign is matched
against a number computed by the same code (advisor gate #2/#3).

Uses frame_taxonomy.read_frames (the canonical framelog parser). Frame identity
from reg_packets (fabric framesync counter), counter-reset segmented (same
convention as loss_period.py). An EVENT = a maximal run of consecutive-position
CRC-fail frames (collapse = adjacent-position merge). Interval = start-to-start
gap between consecutive events (frame units). Reports, over all segments pooled:
  rate, single:double:longer, interval histogram, CV, k mod 8 of event starts,
  and the 8/16/24 band test (is 16 a local MIN vs 8 and 24?).

Same collapse+interval+binning is reused by score_sim() so sim and hardware are
scored identically.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from frame_taxonomy import read_frames


def events_from_positions(bad_pos):
    """bad_pos: sorted unique integer frame positions of CRC fails within a
    segment. Collapse adjacent into events; return event start list + sizes."""
    ev = []
    for k in bad_pos:
        if ev and k == ev[-1][-1] + 1:
            ev[-1].append(k)
        else:
            ev.append([k])
    return ev


def fingerprint(seg_events, seg_bad_positions, nframes, label):
    starts = []
    sizes = []
    for evlist in seg_events:
        for e in evlist:
            starts.append(e[0])
            sizes.append(len(e))
    singles = sum(1 for s in sizes if s == 1)
    doubles = sum(1 for s in sizes if s == 2)
    longer = sum(1 for s in sizes if s > 2)
    # intervals are within-segment start-to-start
    iv = []
    for evlist in seg_events:
        st = [e[0] for e in evlist]
        iv += [b - a for a, b in zip(st, st[1:])]
    hist = {}
    for x in iv:
        hist[x] = hist.get(x, 0) + 1
    cv = float(np.std(iv) / np.mean(iv)) if len(iv) >= 2 and np.mean(iv) else float("nan")
    c8 = sum(hist.get(x, 0) for x in (7, 8, 9))
    c16 = sum(hist.get(x, 0) for x in (15, 16, 17))
    c24 = sum(hist.get(x, 0) for x in (23, 24, 25))
    sup16 = (min(c8, c24) - c16) / max(c8, c24, 1)
    mod8 = [0] * 8
    for s in starts:
        mod8[s % 8] += 1
    nbad = sum(sizes)
    print(f"== {label}: frames={nframes} bad={nbad} ({100*nbad/max(nframes,1):.2f}%) "
          f"events={len(sizes)} S:D:L={singles}:{doubles}:{longer} "
          f"(double_frac={doubles/max(len(sizes),1):.2f})")
    print(f"   CV={cv:.2f}  bands c8={c8} c16={c16} c24={c24}  sup16={sup16:+.2f} "
          f"({'16 SUPPRESSED' if c16 < c8 and c16 < c24 else '16 not a local min'})")
    print(f"   interval hist: {dict(sorted(hist.items()))}")
    print(f"   k mod 8 (event starts): {mod8}")
    return dict(label=label, nframes=nframes, nbad=nbad, nev=len(sizes),
                singles=singles, doubles=doubles, longer=longer, cv=cv,
                c8=c8, c16=c16, c24=c24, sup16=sup16, mod8=mod8, iv=iv)


def score_hw(path, settle=15.0, label=None):
    fr = read_frames(path)
    bad = (fr["crc_ok"] == 0)
    t = fr["t_mono_ns"].astype(np.float64) / 1e9
    t -= t[0]
    pk = fr["reg_packets"].astype("int64")
    keep = t >= settle
    pk, bad = pk[keep], bad[keep]
    seg_bounds = [0] + (np.flatnonzero(np.diff(pk) < 0) + 1).tolist() + [len(pk)]
    seg_events, seg_bad, nframes = [], [], 0
    for s, e in zip(seg_bounds, seg_bounds[1:]):
        if e - s < 50:
            continue
        p, b = pk[s:e], bad[s:e]
        base = int(p[0])
        span = int(p[-1]) - base + 1
        nframes += span
        badpos = sorted({int(x - base) for x in p[b]})
        seg_bad.append(badpos)
        seg_events.append(events_from_positions(badpos))
    return fingerprint(seg_events, seg_bad, nframes,
                       label or os.path.basename(os.path.dirname(path)))


def score_sim_ev(ev_k, nframes, label):
    """ev_k: sorted event frame positions from a sim (single segment)."""
    ev = events_from_positions(sorted(set(int(x) for x in ev_k)))
    return fingerprint([ev], [ev_k], nframes, label)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        score_hw(p)
