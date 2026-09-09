#!/usr/bin/env python3
"""[sim] COMB32 SRO scorer v2 -- adds the valid-chain symbol census (the sim analogue
of tx_sel8_desk/dtref_census.py) and lag-1..128 loss autocorrelation.
Usage: score_sro2.py <golden_prefix> <prefix> [...]"""
import sys
from collections import Counter
import numpy as np
P = 49332; SYM = 12333
FC = ('f push pop occS occE anom mumin mumax und ss cfc cs pd corr pa con dem '
      'dtref0 dtref2 dtrefB '
      # ---- T0a (2026-09-04) appended true-tap columns ----
      'occTS occTE occTmin occTmax rhPopEmpty rhPushFull pdPof pdPopEmpty '
      'pdOccMin pdOccMax').split()
MC = ('sidx ss cfc cs pd corr pa con dem push pop occ '
      'occTrue mPE mPF mPDPF mPDPE pdOcc').split()
RING_FULL = 32          # Compare_To_Constant1_block.v:36  (6-bit occupancy)
PD_FULL   = 12333       # Compare_To_Constant1.v:36        (14-bit occupancy)

def deliv(p):
    return [(int(a), int(b), c, int(d)) for a, b, c, d in
            (l.split(',') for l in open(p + '_deliv.txt'))]

def cols(p, suf, names):
    """Tolerates the pre-2026-09-04 9-column _frames.txt (no valid-chain census)."""
    try:
        a = np.loadtxt(p + suf, delimiter=',', dtype=np.int64, ndmin=2)
    except Exception:
        return None, None
    if a.shape[1] < len(names):
        return {n: a[:, i] for i, n in enumerate(names[:a.shape[1]])}, a
    return {n: a[:, i] for i, n in enumerate(names)}, a

def autocorr(x, maxlag):
    x = x.astype(float) - x.mean()
    if x.std() == 0 or len(x) <= maxlag: return {}
    den = (x * x).sum()
    return {L: float((x[:-L] * x[L:]).sum() / den) for L in range(1, maxlag + 1)}

def perm_null(x, maxlag, n=200, seed=0):
    rng = np.random.default_rng(seed); best = []
    for _ in range(n):
        y = rng.permutation(x); a = autocorr(y, maxlag)
        best.append(max(a.values()) if a else 0.0)
    return float(np.percentile(best, 95))

def main():
    gp = sys.argv[1]
    key = Counter((n, h) for _, n, h, _ in deliv(gp)).most_common(1)[0][0]
    print(f'golden (nwords,hash) = {key}\n')
    for p in sys.argv[1:]:
        d = deliv(p)
        if not d:
            print(f'== {p}: NO FRAMES DELIVERED\n'); continue
        s = np.array([x[0] for x in d]); sp = np.median(np.diff(s))
        idx = np.rint((s - s[0]) / sp).astype(int)
        st = np.zeros(idx[-1] + 1, dtype=np.int8)
        for k, (_, n, h, u) in zip(idx, d): st[k] = 1 if (n, h) == key else 2
        w0, w1 = 3, len(st) - 1
        sc = st[w0:w1]
        ok = int((sc == 1).sum()); cor = int((sc == 2).sum()); mis = int((sc == 0).sum())
        lost = (sc != 1).astype(float)
        F, _ = cols(p, '_frames.txt', FC)
        M, Ma = cols(p, '_marks.txt', MC)
        haveChain = F is not None and 'corr' in F
        haveMarks = M is not None and 'corr' in M
        print(f'== {p}: slots={len(st)} scored={len(sc)} OK={ok} CORRUPT={cor} MISSING={mis} '
              f'loss={100.0*(cor+mis)/max(1,len(sc)):.2f}%')
        li = np.nonzero(lost)[0] + w0
        print(f'   lost idx: {list(li[:30])}{" ..." if len(li) > 30 else ""}')
        if len(li) > 1: print(f'   loss spacings: {list(np.diff(li)[:30])}')
        ac = autocorr(lost, min(128, len(lost) // 3))
        if ac:
            top = sorted(ac.items(), key=lambda kv: -kv[1])[:6]
            print('   loss autocorr top6: ' + ', '.join(f'{L}:{v:+.3f}' for L, v in top))
            print(f'   permutation null p95 = {perm_null(lost, min(128, len(lost)//3)):+.3f}'
                  f'   |  lag32={ac.get(32, 0):+.3f} lag64={ac.get(64, 0):+.3f} lag8={ac.get(8, 0):+.3f}')
        # ---- valid-chain census over the interior frames (mark-to-mark) ----
        if not haveChain:
            print('   (legacy 9-column _frames.txt: no valid-chain / tref census)\n'); continue
        m0, m1 = 3, (len(M['sidx']) - 1 if haveMarks else 0)
        if haveMarks and m1 > m0:
            print('   valid-chain per mark (nominal 12333): ' + '  '.join(
                f'{k}={int(np.median(M[k][m0:m1]))}/{int(M[k][m0:m1].min())}..{int(M[k][m0:m1].max())}'
                for k in ('ss', 'cfc', 'cs', 'pd', 'corr', 'con', 'dem')))
            for k in ('ss', 'cfc', 'cs', 'pd', 'corr'):
                dele = int((SYM - M[k][m0:m1]).clip(0, None).sum())
                ins = int((M[k][m0:m1] - SYM).clip(0, None).sum())
                if dele or ins:
                    print(f'     {k}: deletions={dele} insertions={ins} over {m1-m0} marks'
                          f'  -> 1 per {(m1-m0)/max(1,abs(dele-ins)):.2f} frames')
        # ---- valid-chain census in LOCAL SAMPLE TIME (the correct dtref analogue) ----
        # each _frames.txt row is one 49332-input-sample bucket = one nominal local
        # frame, so (12333 - corr) is the net symbol deficit the receiver's valid
        # chain delivered against the local clock over that frame -- exactly what
        # dtref_census.py measures on silicon by diffing tref against the local slot.
        print('   valid-chain census in LOCAL time (per 49332-sample frame, nominal 12333):')
        for k in ('ss', 'cfc', 'cs', 'pd', 'corr'):
            v = F[k][w0:w1]
            dele = int((SYM - v).clip(0, None).sum()); ins = int((v - SYM).clip(0, None).sum())
            net = dele - ins
            print(f'     {k}: local deficit={dele} surplus={ins} net={net}'
                  + (f' -> 1 per {len(sc)/abs(net):.2f} frames = {-net/(len(sc)*SYM)*1e6:+.3f} ppm'
                     if net else ' (balanced)'))
        # interpolator strobe (FIFO push) census, the I[15] analogue
        pv = F['push'][w0:w1]
        pd_ = int((SYM - pv).clip(0, None).sum()); pi_ = int((pv - SYM).clip(0, None).sum())
        print(f'     [push=interpolator strobe] deficit={pd_} surplus={pi_} net={pd_-pi_}')
        d0 = int(F['dtref0'][w0:w1].sum()); d2 = int(F['dtref2'][w0:w1].sum())
        print(f'   (event-indexed tref census dtref==0 {d0} ==2 {d2} -- self-referential '
              f'by construction, tref advances on every Correlator.validOut; kept only as a check)')
        # ---- FIFO: legacy pointer metric, kept only for comparison ----
        occ = F['occE']
        steps = np.nonzero(np.diff(occ[w0:w1]))[0] + w0
        edge = np.nonzero((occ[w0:w1] == 0) | (occ[w0:w1] == 31))[0] + w0
        print(f'   [legacy pointer metric, CANNOT tell 0 from 32] occ {occ[w0]} -> {occ[w1-1]}, '
              f'{len(steps)} steps'
              + (f', mean spacing {np.diff(steps).mean():.2f}' if len(steps) > 1 else '')
              + f'; frames at a pointer edge (0 or 31): {len(edge)}'
              + (f', first at f={edge[0]}' if len(edge) else ''))
        print(f'   excess pushes (legacy, push.sum - 12333*n) = '
              f'{int(F["push"][w0:w1].sum() - SYM * len(sc))}')
        exc = int(F['push'][w0:w1].sum() - F['pop'][w0:w1].sum())
        print(f'   exc = pushes - pops over window = {exc}   '
              f'(predicted 12333*s*{len(sc)} entries of net drift)')
        print(f'   strobe anomalies/frame: mean={F["anom"][w0:w1].mean():.1f}')
        true_taps(F, M, w0, w1, sc, li)
        print()

def true_taps(F, M, w0, w1, sc, li):
    """T0a: the TRUE guarded-ring taps and the phase-lock score."""
    if 'occTE' not in F:
        print('   (no true-tap columns in _frames.txt: pre-T0a run)'); return
    oS, oE = F['occTS'][w0:w1], F['occTE'][w0:w1]
    oMin, oMax = F['occTmin'][w0:w1], F['occTmax'][w0:w1]
    pe, pf = F['rhPopEmpty'][w0:w1], F['rhPushFull'][w0:w1]
    pdpf, pdpe = F['pdPof'][w0:w1], F['pdPopEmpty'][w0:w1]
    pdMin, pdMax = F['pdOccMin'][w0:w1], F['pdOccMax'][w0:w1]
    n = len(oE)
    print(f'   TRUE ring occupancy (0..{RING_FULL}): {oS[0]} -> {oE[-1]}, '
          f'per-frame min/max envelope {int(oMin.min())}..{int(oMax.max())}')
    # tap self-check: dOcc over a frame must equal validated pushes - pops
    docc = oE - oS
    dpp = F['push'][w0:w1] - F['pop'][w0:w1]
    # occTS/occTE are the first/last sampled values inside the frame, so the
    # identity holds up to the boundary beat's own push/pop: |dev| <= 1.
    dev = np.abs(docc - dpp)
    bad = int((dev > 1).sum())
    print(f'   TAP SELF-CHECK  (occTE-occTS == pushes-pops, +/-1 boundary beat): '
          f'{"PASS" if bad == 0 else f"FAIL on {bad}/{n} frames"} (max dev {int(dev.max())})')
    # first edge of each kind, on the per-frame ENVELOPE (a momentary touch counts)
    def first(mask, label):
        ix = np.nonzero(mask)[0]
        return (f'{label} first at f={int(ix[0]) + w0}, {len(ix)} frames' if len(ix)
                else f'{label} never')
    print('   ring edges: ' + first(oMin == 0, 'EMPTY(0)') + ' | '
          + first(oMax >= RING_FULL, f'FULL({RING_FULL})'))
    print(f'   PD FIFO occupancy envelope {int(pdMin.min())}..{int(pdMax.max())} '
          f'(full mark {PD_FULL}): ' + first(pdMin == 0, 'EMPTY(0)') + ' | '
          + first(pdMax >= PD_FULL, f'FULL({PD_FULL})'))
    ev = {'pop_on_empty': pe, 'push_on_full': pf, 'pdPof': pdpf, 'pd_pop_on_empty': pdpe}
    for k, v in ev.items():
        nz = np.nonzero(v)[0]
        print(f'     {k}: total={int(v.sum())} frames_with_event={len(nz)}'
              + (f' first f={int(nz[0]) + w0} at frames {[int(i) + w0 for i in nz[:12]]}'
                 if len(nz) else ''))
    # ---- phase-lock score: nearest event of each kind to each lost frame ----
    if not len(li):
        print('   phase-lock: no lost frames'); return
    print(f'   phase lock ({len(li)} lost/corrupt frames, gate = >=80% within +/-1 frame):')
    for k, v in ev.items():
        ef = np.nonzero(v)[0] + w0
        if not len(ef):
            print(f'     {k}: NO EVENTS -> 0.0% within +/-1'); continue
        d = np.array([int(ef[np.argmin(np.abs(ef - L))] - L) for L in li])
        frac = float((np.abs(d) <= 1).mean())
        # best constant offset (diagnostic only, never the gate)
        offs, cnt = np.unique(d, return_counts=True)
        bo = int(offs[np.argmax(cnt)]); bf = float(cnt.max()) / len(d)
        # reciprocal: fraction of EVENT frames that have a loss within +/-1
        d2 = np.array([int(li[np.argmin(np.abs(li - E))] - E) for E in ef])
        rfrac = float((np.abs(d2) <= 1).mean())
        print(f'     {k}: within +/-1 = {frac*100:.1f}% ({int((np.abs(d)<=1).sum())}/{len(d)})'
              f'   nearest-offset median={int(np.median(d))} '
              f'mode={bo} ({bf*100:.1f}% of losses)  offsets={list(d[:20])}')
        print(f'        reciprocal (events with a loss within +/-1): '
              f'{rfrac*100:.1f}% ({int((np.abs(d2)<=1).sum())}/{len(d2)} events)')
        # DIAGNOSTIC ONLY, never the gate: the two series are indexed in
        # different frame spaces (events in input-sample frames, losses in
        # delivered-frame slots, offset by the receiver pipeline latency).
        best = max(((float(np.mean([np.min(np.abs(ef + o - L)) <= 1 for L in li])), o)
                    for o in range(-6, 7)))
        print(f'        [diagnostic] best constant alignment offset {best[1]:+d}: '
              f'{best[0]*100:.1f}% of losses within +/-1')

if __name__ == '__main__':
    main()
