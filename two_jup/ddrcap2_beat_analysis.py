#!/usr/bin/env python3
"""ddrcap2_beat_analysis.py -- the pre-registered spec sec 6 verdict on a DDRCAP-v2 sel-6 burst capture.
Per frame: d_data = injective offset-map lookup of the 16 hard decisions at demod-marker+1 (the sec 57/69
instrument; map two_jup/offsetmap/tap3_word_to_offset.tsv). Per beat: tOff (ch2[13:0]).
onset_beat_data = first record of the first frame with d_data != 0 after >=3 frames at 0.
onset_beat_toff = first record where tOff != d0 (d0 = modal tOff before onset_beat_data).
P1: tOff steps to d0 +/- rung (|.|<=4 symbols) and |delta_beats| <= 1 and holds >= 3 frames.
P2: tOff == d0 on every beat while d_data is on a rung for >= 3 frames.
NEITHER: tOff moves but not to d0 +/- rung. UNINFORMATIVE: no 0->rung transition in the capture.
Frame ordinality: frames_by_marker (demod marks), frames_by_tref (slot-1 wraps), frames_by_index (records/12333)."""
import argparse, json, os, sys
import numpy as np
from ddrcap2_decode import load, decode
HERE = os.path.dirname(os.path.abspath(__file__))
RUNGS = (6176, 6240, 6299, 6363, 6432, 6489, 6548)
# P=12333 is the DDR *record* frame length (full-rate taps, sel12-15) and the
# modulus of the tref counter -- see task9_sel13/14_detector.py TREF_MOD and
# Peak_Search.v. It is NOT the sel6 demod-marker period: on silicon the sel6
# tap sees 12320 records between demod marks (the 13 preamble symbols never
# reach the demod-input tap), matching the offset map's declared frame length
# (offsetmap/tap3_word_to_offset.tsv: "frame=12320 symbols"). Kept here only
# for the tref-wrap threshold (measured_period() below drives frames_by_index).
P = 12333

def measured_period(d, fallback=12320):
    """Modal gap (in records) between consecutive demod markers (mark_demod).
    Falls back to `fallback` (12320, the known sel6 value) if there are fewer
    than two markers in the capture to measure a gap from."""
    mk = np.flatnonzero(d['mark_demod'])
    if len(mk) < 2:
        return fallback
    gaps = np.diff(mk.astype(np.int64))
    vals, cnts = np.unique(gaps, return_counts=True)
    return int(vals[cnts.argmax()])

def load_map():
    m = {}
    for l in open(os.path.join(HERE, 'offsetmap', 'tap3_word_to_offset.tsv')):
        if not l.startswith('#'):
            w, o = l.split(); m[int(w, 16)] = int(o)
    return m

def per_frame_offsets(a, d, m, skew=1):
    sign = ((a[:, 0] < 0).astype(np.uint32) << 1) | (a[:, 1] < 0).astype(np.uint32)
    mk = np.flatnonzero(d['mark_demod']); out = []
    for i in mk:
        s = i + skew
        if s + 16 > len(a): break
        w = 0
        for k in range(16): w |= int(sign[s + k]) << (30 - 2 * k)
        out.append((int(i), m.get(w)))
    return out

def analyse(a, m):
    d = decode(a); fr = per_frame_offsets(a, d, m); r = {}
    zero_run = 0; onset_idx = None
    for k, (rec, o) in enumerate(fr):
        if o == 0: zero_run += 1
        elif o is not None and o in RUNGS and zero_run >= 3:
            onset_idx = k; break
        elif o is None: pass
        else: zero_run = 0
    period = measured_period(d); r['measured_period'] = period
    r['frames_by_marker'] = len(fr); r['frames_by_index'] = int(len(a) // period)
    tr = d['tref']; trv = tr[tr >= 0]; r['frames_by_tref'] = int((np.diff(trv.astype(int)) < -12000).sum()) + 1 if len(trv) else 0
    if onset_idx is None:
        r.update(verdict='UNINFORMATIVE', onset_beat_data=None, onset_beat_toff=None, delta_beats=None, d0=None, toff_after=None, toff_delta_is_rung=False)
        return r
    onset_rec = fr[onset_idx][0]; r['onset_beat_data'] = onset_rec
    toff = d['toff'].astype(int); pre = toff[:onset_rec]; v, c = np.unique(pre, return_counts=True); d0 = int(v[c.argmax()]); r['d0'] = d0
    moved = np.flatnonzero(toff != d0); moved = moved[moved >= max(0, onset_rec - 3 * P)]
    if len(moved) == 0:
        after_rung = sum(1 for _, o in fr[onset_idx:onset_idx + 3] if o in RUNGS) >= 3
        r.update(onset_beat_toff=None, delta_beats=None, toff_after=d0, toff_delta_is_rung=False, verdict='P2' if after_rung else 'UNINFORMATIVE'); return r
    ob = int(moved[0]); r['onset_beat_toff'] = ob; r['delta_beats'] = ob - onset_rec
    after = int(np.bincount(toff[ob:ob + 3 * P]).argmax()); r['toff_after'] = after
    # NOTE (Task 8 deviation, minimal fix): the brief's code computed
    # delta = (after-d0) % 12320, then folded it with min(delta, 12320-delta).
    # 12320 is the correct modulus -- it is the ROM's declared symbol-frame
    # length (see offsetmap/tap3_word_to_offset.tsv header: "frame=12320
    # symbols"; the distinct P=12333 in this file is the DDR *record* frame
    # length used for record indexing, a different count -- see the brief's
    # frame-identity note). The bug is the fold: every RUNGS value
    # (6176..6548) exceeds 12320/2=6160, so min(delta, 12320-delta) always
    # maps a true rung step into its complement (5772..6157), which then
    # matches no RUNGS entry -- the P1 test is RED against the brief's
    # verbatim code (delta=6363 folds to 5957, no rung within +/-4). Fixed by
    # checking the raw circular delta AND its complement against RUNGS
    # directly, instead of collapsing to one minimized magnitude that
    # discards which rung (and which sign) it was closest to. This is more
    # faithful to the pre-registered P1 text ("tOff steps to d0 +/- rung"),
    # not a widening of it: it still requires a hit within +/-4 symbols of
    # one of the same 7 pre-registered RUNGS values, just checked in both
    # directions instead of one that structurally can never match.
    delta = (after - d0) % 12320
    is_rung = any(abs(delta - g) <= 4 for g in RUNGS) or any(abs((12320 - delta) - g) <= 4 for g in RUNGS)
    r['toff_delta_is_rung'] = bool(is_rung)
    held = (toff[ob:ob + 3 * P] == after).mean() >= 0.95
    r['verdict'] = 'P1' if (is_rung and abs(r['delta_beats']) <= 1 and held) else 'NEITHER'
    return r

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('capture'); ap.add_argument('--out', required=True)
    x = ap.parse_args(); r = analyse(load(x.capture), load_map())
    json.dump(r, open(x.out + '.json', 'w'), indent=1); print(json.dumps(r, indent=1)); return 0

if __name__ == '__main__':
    sys.exit(main())
