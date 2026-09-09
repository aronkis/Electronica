#!/usr/bin/env python3
"""score_tapvs_golden.py -- anchor-free per-frame displacement of a DDR tap capture vs a
netlist-generated golden stream of the same selector (spec §4.2).

Method: take one reference frame R (length P) from the golden stream. For every capture
window W_n = cap[c0 + n*P : c0 + (n+1)*P], circular complex cross-correlation
|ifft(fft(W) * conj(fft(R)))| gives the lag that best matches; the magnitude is invariant to a
fixed phase rotation and gain, so no quadrant search is needed. Rail swap (I<->Q) is a
conjugation, which is NOT rotation-invariant, so both W and its rail-swapped form are tried and
the better one kept. The anchor c0 is chosen so that the MODAL lag over the whole capture is 0:
the majority state is called "aligned", every other state is reported relative to it (§72
convention: aligned 2,722 frames vs displaced 1,452). A window whose normalised peak is below
MINSCORE is 'unmatched' (None), never counted as a state.

Derived unit under §0: run the sel3 positive control and the sel5 negative control before
crediting any number from a new tap.
"""
import argparse, collections, json, sys
import numpy as np

MARK = 0x7FFF
MINSCORE = 0.5
MINRUN = 3          # a state must persist this many frames to count as a divergence

def load(path):
    a = np.fromfile(path, dtype='<i2')
    return a[:(len(a) // 4) * 4].reshape(-1, 4)

def period_from_markers(gold):
    m = np.flatnonzero(gold[:, 3] == MARK)
    if len(m) < 3:
        m = np.flatnonzero(gold[:, 2] == MARK)
    if len(m) < 3:
        return None
    d = np.diff(m)
    vals, cnts = np.unique(d, return_counts=True)
    return int(vals[cnts.argmax()])

def _cx(a):
    return a[:, 0].astype(np.float64) + 1j * a[:, 1].astype(np.float64)

def _best_lag(w, R_fft, R_norm, P):
    """Return (lag, score, swapped) for window w (complex, length P)."""
    best = (0, -1.0, 0)
    for swapped, ww in ((0, w), (1, np.conj(w) * 1j)):     # rail swap == multiply conj by j
        n = np.linalg.norm(ww)
        if n == 0:
            continue
        xc = np.abs(np.fft.ifft(np.fft.fft(ww) * R_fft))
        k = int(np.argmax(xc))
        s = float(xc[k] / (n * R_norm))
        if s > best[1]:
            best = (k, s, swapped)
    return best

def frame_starts(cap, P, max_frames=None):
    """Frame boundaries for the capture. REVISION (see module docstring §note): a blind n*P
    grid from record 0 accumulates drift against a handful of irregular demod-marker spacings
    (most captures are >=98% exactly P, but the rest are not exact multiples of P), which sprays
    the correlation across many spurious lag states. When the capture carries its own demod
    markers (column 2) with a stable majority spacing, anchor each frame to the nearest real
    marker near the expected position and only blind-step where no marker is found nearby --
    this is still anchor-free (no marker/frame IDENTITY correspondence to the golden stream is
    assumed, only local spacing). Synthetic captures in the test suite never populate column 2,
    so they always take the blind-grid path unchanged.
    """
    mk = np.flatnonzero(cap[:, 2] == MARK)
    if len(mk) >= 3:
        d = np.diff(mk)
        vals, cnts = np.unique(d, return_counts=True)
        modal_d = int(vals[cnts.argmax()])
        modal_frac = float(cnts.max()) / len(d)
        if modal_frac >= 0.5 and abs(modal_d - P) <= max(2, P // 1000):
            radius = max(4, P // 20)
            starts = [int(mk[0])]
            cur = int(mk[0])
            n = len(mk)
            limit = len(cap) - P
            while cur + P <= limit:
                target = cur + P
                if max_frames and len(starts) >= max_frames:
                    break
                j = np.searchsorted(mk, target)
                cands = []
                if j < n: cands.append(int(mk[j]))
                if j > 0: cands.append(int(mk[j - 1]))
                best = min(cands, key=lambda x: abs(x - target)) if cands else None
                cur = best if (best is not None and abs(best - target) <= radius) else target
                starts.append(cur)
            return starts
    nfr = (len(cap) - P) // P
    if max_frames:
        nfr = min(nfr, max_frames)
    return [n * P for n in range(nfr)]

def score(cap, gold, period, max_frames=None):
    P = int(period)
    gm = np.flatnonzero(gold[:, 3] == MARK)
    r0 = int(gm[min(2, len(gm) - 1)]) if len(gm) else 0
    R = _cx(gold[r0:r0 + P])
    R_fft = np.conj(np.fft.fft(R)); R_norm = np.linalg.norm(R)
    c = _cx(cap)
    starts = frame_starts(cap, P, max_frames)
    nfr = len(starts)
    lags, scores, swaps = [], [], []
    for n in range(nfr):
        s0 = starts[n]
        k, s, sw = _best_lag(c[s0:s0 + P], R_fft, R_norm, P)
        lags.append(k if s >= MINSCORE else None); scores.append(s); swaps.append(sw)
    placed = [k for k in lags if k is not None]
    if not placed:
        return {'period': P, 'frames': nfr, 'modal_offset': None, 'states': {}, 'first_divergence_frame': None,
                'first_divergence_record': None, 'offset_after': None, 'kind': None, 'unmatched': nfr, 'rows': []}
    modal = collections.Counter(placed).most_common(1)[0][0]
    rel = [None if k is None else (k - modal) % P for k in lags]
    rel = [None if k is None else (k - P if k > P // 2 else k) for k in rel]   # signed, |offset| <= P/2
    states = collections.Counter(k for k in rel if k is not None)
    first_f = first_r = after = kind = None
    n = 0
    while n < len(rel):
        if rel[n] is not None and rel[n] != 0:
            run = [rel[m] for m in range(n, min(n + MINRUN, len(rel))) if rel[m] is not None]
            if len(run) == MINRUN:
                first_f = n; first_r = starts[n]
                if len(set(run)) == 1:
                    after = run[0]; kind = 'jump'
                else:
                    d = np.diff(run)
                    kind = 'walk' if (np.all(d > 0) or np.all(d < 0)) else 'jump'
                    j = n
                    while j + 1 < len(rel) and rel[j + 1] is not None and rel[j + 1] != rel[j]:
                        j += 1
                    after = rel[j]
                break
        n += 1
    rows = [(i, rel[i], swaps[i], round(scores[i], 4)) for i in range(nfr)]
    return {'period': P, 'frames': nfr, 'modal_offset': 0, 'states': {int(k): int(v) for k, v in states.items()},
            'first_divergence_frame': first_f, 'first_divergence_record': first_r, 'offset_after': after,
            'kind': kind, 'unmatched': sum(1 for k in lags if k is None), 'rows': rows}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('capture'); ap.add_argument('golden')
    ap.add_argument('--period', type=int); ap.add_argument('--max-frames', type=int); ap.add_argument('--out')
    a = ap.parse_args()
    cap, gold = load(a.capture), load(a.golden)
    P = a.period or period_from_markers(gold)
    if not P:
        print('no period: golden has no markers and --period not given'); return 2
    r = score(cap, gold, P, a.max_frames)
    rows = r.pop('rows')
    print(f"period {P}: {r['frames']} frames, unmatched {r['unmatched']}, states {dict(sorted(r['states'].items(), key=lambda kv: -kv[1])[:8])}")
    print(f"first divergence: frame {r['first_divergence_frame']} record {r['first_divergence_record']} offset_after {r['offset_after']} kind {r['kind']}")
    if a.out:
        with open(a.out + '.json', 'w') as f: json.dump(r, f, indent=1)
        with open(a.out + '.csv', 'w') as f:
            f.write('frame,offset,swap,score\n')
            for i, o, sw, s in rows: f.write(f"{i},{'' if o is None else o},{sw},{s}\n")
    return 0

if __name__ == '__main__':
    sys.exit(main())
