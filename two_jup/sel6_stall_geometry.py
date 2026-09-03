#!/usr/bin/env python3
"""sel6_stall_geometry.py -- controller analysis (2026-09-02 night): every data-offset transition in a
DDRCAP-v2 sel6 capture is a TRANSMIT STALL: a run of one constant hard-decision symbol from mid-frame to
the frame end (optionally followed by one or more whole frames of the same constant symbol), after which
the payload resumes with its offset changed by -L (mod 12320), L = stall length in symbols.
Per run: start record, frame, position in frame (from the demod mark), length, the offset before/after
(per_frame_offsets), and the predicted new offset (old - L mod 12320). [silicon]"""
import sys, json, numpy as np
from ddrcap2_decode import load, decode
from ddrcap2_beat_analysis import per_frame_offsets, load_map
P = 12320
def main(path, out):
    m = load_map(); a = load(path); d = decode(a)
    sym = ((a[:,0] < 0).astype(np.int8) * 2 + (a[:,1] < 0).astype(np.int8))
    mk = np.flatnonzero(d['mark_demod']); fr = per_frame_offsets(a, d, m); offs = dict(fr)
    ch = np.flatnonzero(np.diff(sym) != 0)
    starts = np.concatenate(([0], ch + 1)); runs = np.diff(np.concatenate(([0], ch + 1, [len(sym)])))
    rows = []
    for s, L in zip(starts[runs > 50], runs[runs > 50]):
        f = int(np.searchsorted(mk, s)) - 1
        if f < 2 or f + 3 >= len(mk): continue
        pos = int(s - mk[f]); full = bool(L >= P - 20)
        before = offs.get(int(mk[f - 1])); after = offs.get(int(mk[f + 2]))
        pred = None if (before is None or full) else (before - int(L)) % P
        rows.append(dict(start=int(s), frame=f, pos_in_frame=pos, length=int(L), full_frame=full,
                         symbol=int(sym[s]), offset_before=before, offset_after=after, predicted_after=pred,
                         pred_error=(None if pred is None or after is None else int(min((after - pred) % P, (pred - after) % P)))))
    res = dict(file=path, n_frames=int(len(mk)), stalls=rows)
    json.dump(res, open(out, 'w'), indent=1)
    for r in rows: print(r)
    return 0
if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
