#!/usr/bin/env python3
"""accept_analyze.py [--arq] [--burst-times OUT.csv] <frames.bin> [<frames.bin> ...]
-- wedge-aware acceptance analysis.

For each capture: finds the live-link window (clean-rate collapse = a persistent
carrier wedge; the capture harness disables the lock_watchdog, so a mid-capture
wedge stays wedged and is reported separately, not silently averaged in), then
reports on the reliable host_seq-gap metric over the live window:
  PER, burst decomposition, lag-33 singles autocorrelation, CP 95% upper limit.
Pooled CP bound over all live windows at the end.

Wedge policy (stated, not hidden): the <1% goal is assessed on the live-link
windows (representative of watchdog-protected operation); wedge occurrence and
its truncation are reported alongside so nothing is buried.

--burst-times OUT.csv additionally writes ONE ROW PER LOSS RUN (the same runs
the run-length bins count) with its onset host_seq, run length and estimated
onset time on both clocks -- the axis a burst-class question needs and the bins
alone cannot give. Default off; without the flag every printed number and the
returned dict are byte-identical to before, so a like-for-like PER comparison
against an earlier leg is unaffected. See analyze()'s docstring for what
"estimated" means.

RECOVERED LEGS (RXFIX Task 44). If capture_r3.sh recovered a mid-window
collapse (MID_RECOVER=1, default off), it leaves a `recovery.txt` NEXT TO
frames.bin naming the perturbed interval(s). This tool then scores the leg on
its clean live SEGMENTS: every frame inside a perturbed interval is dropped
from BOTH the numerator and the denominator -- the collapse gap is never
counted as loss, and the segment boundary is never diffed across. Zero events
(the ordinary leg, and every leg scored before Task 44) => one segment => the
arithmetic below is unchanged. See ops/recovery_windows.py.
"""
import sys, math
import numpy as np
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from frame_taxonomy import read_frames
from recovery_windows import (keep_mask, load_recovery, segments_from_mask,
                              warn_to_stderr)

def cp_upper(k, n, conf=0.975):
    """Clopper-Pearson 95% two-sided upper limit (beta quantile by bisection)."""
    if n == 0: return 1.0
    if k >= n: return 1.0
    a, b = k + 1, n - k
    def betacf(x, a, b):
        MAXIT, EPS, FPMIN = 300, 3e-12, 1e-300
        qab, qap, qam = a+b, a+1.0, a-1.0
        c, d = 1.0, 1.0 - qab*x/qap
        if abs(d) < FPMIN: d = FPMIN
        d = 1.0/d; h = d
        for m in range(1, MAXIT+1):
            m2 = 2*m
            aa = m*(b-m)*x/((qam+m2)*(a+m2))
            d = 1.0 + aa*d;  d = FPMIN if abs(d) < FPMIN else d
            c = 1.0 + aa/c;  c = FPMIN if abs(c) < FPMIN else c
            d = 1.0/d; h *= d*c
            aa = -(a+m)*(qab+m)*x/((a+m2)*(qap+m2))
            d = 1.0 + aa*d;  d = FPMIN if abs(d) < FPMIN else d
            c = 1.0 + aa/c;  c = FPMIN if abs(c) < FPMIN else c
            d = 1.0/d; de = d*c; h *= de
            if abs(de-1.0) < EPS: break
        return h
    def ibeta(x, aa, bb):
        if x <= 0: return 0.0
        if x >= 1: return 1.0
        lb = math.lgamma(aa+bb) - math.lgamma(aa) - math.lgamma(bb) \
             + aa*math.log(x) + bb*math.log(1.0-x)
        if x < (aa+1.0)/(aa+bb+2.0):
            return math.exp(lb) * betacf(x, aa, bb) / aa
        return 1.0 - math.exp(lb) * betacf(1.0-x, bb, aa) / bb
    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = (lo+hi)/2
        if ibeta(mid, a, b) < conf: lo = mid
        else: hi = mid
    return hi

ARQ_MODE = False   # --arq: seqs sorted+uniqued (ARQ reorders; gaps = unrecovered)

def analyze(path, settle_s=15.0, burst_times=False):
    """burst_times=True additionally returns r['bursts'], one entry per LOSS RUN
    in the live window (the same runs the run-length bins count), each with the
    onset host_seq, run length and an ESTIMATED onset time.

    The time is estimated, not measured: a lost slot has no record of its own, so
    its t_mono_ns / t_real_ns are linearly interpolated against the CLEAN frames'
    (host_seq, timestamp) anchors -- the same construction as
    ops/comb/common.py:interp_t_mono_ns, pinned to it by
    ops/tests/test_accept_burst_times.py. Both t_mono_ns (RX board
    CLOCK_MONOTONIC, safe only within this file) and t_real_ns (wall clock, the
    only axis comparable with a reader CSV or a checker jsonl from another host)
    are emitted; use t_real_ns for any cross-instrument alignment."""
    rec = load_recovery(path)     # {} of events on every leg with no recovery.txt
    warn_to_stderr(rec, prefix=f"{path}: ")
    fr = read_frames(path); clean = fr['crc_ok'] != 0
    tm = fr['t_mono_ns'].astype(np.int64); t0 = tm[0]
    tr = fr['t_real_ns'].astype(np.int64)
    ts = (tm - t0) / 1e9
    dur = float(ts[-1])
    # live-window end: last 1s bucket with clean rate >= 25% of the peak bucket
    nb = max(int(dur) + 1, 1)
    cps = np.zeros(nb)
    for b in range(nb):
        cps[b] = ((clean) & (ts >= b) & (ts < b+1)).sum()
    peak = cps.max() if cps.size else 0
    live_end = dur
    if peak > 0:
        good = np.flatnonzero(cps >= 0.25 * peak)
        live_end = float(good[-1] + 1) if good.size else 0.0
        wedged = live_end < dur - 3.0
        if wedged:
            live_end = max(live_end - 2.0, 0.0)   # guard: exclude the degradation ramp
    else:
        wedged = True; live_end = 0.0
    ci = np.flatnonzero(clean)
    ct = ts[ci]; cseq = fr['host_seq'][ci].astype(np.int64)
    w = (ct >= settle_s) & (ct < live_end)
    if w.sum() < 100:
        return dict(path=path, dur=dur, live_end=live_end, wedged=wedged,
                    usable=False, recovery_events=len(rec['events']),
                    excluded_s=rec['excluded_s'], n_segments=0, n_kept=0)
    wi = np.flatnonzero(w)
    cw = cseq[wi]
    cwm = tm[ci][wi]          # t_mono_ns of each clean in-window frame, cw order
    cwr = tr[ci][wi]          # t_real_ns  of each clean in-window frame, cw order
    if ARQ_MODE:
        cw, uidx = np.unique(cw, return_index=True)   # np.unique returns sorted
        cwm = cwm[uidx]; cwr = cwr[uidx]
    # RECOVERED-LEG SEGMENTATION (Task 44). `rec['events']` is empty on every
    # ordinary leg -> keep is all True -> ONE segment covering the whole window,
    # and every quantity below is computed by exactly the arithmetic that was
    # here before. The exclusion is by t_real_ns because that is the clock
    # capture_r3.sh writes recovery.txt on (the board's own CLOCK_REALTIME).
    keep = keep_mask(cwr, rec['events'])
    segs = segments_from_mask(keep)
    n_kept = int(keep.sum())
    if n_kept < 100:
        return dict(path=path, dur=dur, live_end=live_end, wedged=wedged,
                    usable=False, recovery_events=len(rec['events']),
                    excluded_s=rec['excluded_s'], n_segments=len(segs),
                    n_kept=n_kept)
    cw_kept = cw[keep]
    lo_ = int(cw_kept[0]); hi_ = int(cw_kept[-1])
    # `pres`/`sp` stay on the FULL [lo_, hi_] axis with the perturbed span left
    # as zeros: the singles train keeps its slot phase (so lag-33 still means
    # 33 transmitted frames) and the hole biases the autocorrelation toward
    # zero, which is the conservative direction.
    pres = np.zeros(hi_-lo_+1, dtype=np.int8); pres[cw_kept-lo_] = 1
    sp = np.zeros(hi_-lo_+1)
    span = 0; miss = 0; runs = []; rl_parts = []
    for a, b in segs:
        cs = cw[a:b]
        if cs.size < 2:
            continue            # a 1-frame segment spans nothing and loses nothing
        d = np.diff(cs); lost = d - 1
        span += int(cs[-1] - cs[0]); miss += int(lost[lost > 0].sum())
        rl_parts.append(lost[lost > 0])
        # loss runs WITHIN the segment: the gap across a perturbed interval is
        # never a run, because no diff is ever taken across a segment boundary.
        s_lo = int(cs[0]); s_hi = int(cs[-1])
        s_pres = np.zeros(s_hi-s_lo+1, dtype=np.int8); s_pres[cs-s_lo] = 1
        idx = np.flatnonzero(1-s_pres); i = 0
        while i < len(idx):
            j = i
            while j+1 < len(idx) and idx[j+1] == idx[j]+1: j += 1
            runs.append((idx[i] + (s_lo - lo_), j-i+1)); i = j+1
    rl = np.concatenate(rl_parts) if rl_parts else np.array([], dtype=np.int64)
    bins = {'1': int((rl==1).sum()), '2': int((rl==2).sum()),
            '3-4': int(((rl>=3)&(rl<=4)).sum()), '5-20': int(((rl>=5)&(rl<=20)).sum()),
            '21-100': int(((rl>=21)&(rl<=100)).sum()), '>100': int((rl>100).sum())}
    # lag-33 autocorr over the singles-only train
    for p, l in runs:
        if l == 1: sp[p] = 1
    ac33 = float('nan')
    if sp.sum() > 3 and len(sp) > 40:
        spc = sp - sp.mean(); ac = np.correlate(spc, spc, 'full')[len(spc)-1:]
        ac33 = float(ac[33]/ac[0])
    out = dict(path=path, dur=dur, live_end=live_end, wedged=wedged, usable=True,
               miss=miss, span=span, bins=bins, ac33=ac33,
               recovery_events=len(rec['events']), excluded_s=rec['excluded_s'],
               n_segments=len(segs), n_kept=n_kept)
    if burst_times:
        onsets = np.array([p + lo_ for p, _ in runs], dtype=np.int64)
        lens = np.array([l for _, l in runs], dtype=np.int64)
        if onsets.size:
            # anchors are the clean frames' own (seq, time) pairs; np.interp needs
            # an increasing x, which cw is by construction (host_seq is monotonic
            # over a daemon lifetime; --arq sorts it explicitly).
            bm = np.interp(onsets, cw, cwm.astype(np.float64)).astype(np.int64)
            br = np.interp(onsets, cw, cwr.astype(np.float64)).astype(np.int64)
        else:
            bm = br = np.array([], dtype=np.int64)
        out['bursts'] = [dict(onset_seq=int(s), run_len=int(l),
                              t_s=float((m - t0) / 1e9),
                              t_mono_ns=int(m), t_real_ns=int(r))
                         for s, l, m, r in zip(onsets, lens, bm, br)]
    return out

def main(paths, burst_times_csv=None):
    tot_k = tot_n = 0; pers = []; nwedge = 0; brows = []; nrecov = 0; recov_s = 0.0
    print("=== wedge-aware acceptance analysis (live-link windows, settle 15s, wedge-guard 2s) ===")
    for p in paths:
        r = analyze(p, burst_times=bool(burst_times_csv))
        tag = p.split('/')[-2] if '/' in p else p
        # A recovered leg is never silently pooled with clean ones: it says so on
        # its own line, before its PER, and again in the pooled block.
        if r.get('recovery_events'):
            nrecov += 1; recov_s += r.get('excluded_s', 0.0)
            print(f"  {tag}: PERTURBED LEG -- {r['recovery_events']} mid-window recovery "
                  f"interval(s), {r.get('excluded_s', 0.0):.1f}s EXCLUDED from numerator AND "
                  f"denominator; scored on {r.get('n_segments', 0)} clean segment(s)")
            # A recovered leg MUST split into >= 2 segments. One segment means the
            # perturbed interval never intersected the scored window, and the
            # dangerous way that happens is silent: if the post-recovery buckets
            # do not reach 25% of the pre-collapse peak, live_window()'s rule puts
            # live_end at or before the collapse and the RECOVERED TAIL -- the
            # whole point of recovering -- is discarded before this exclusion ever
            # runs, leaving a plausible PER measured on the pre-collapse segment
            # alone. (The benign cause is a recovery before the 15 s settle.)
            if r.get('n_segments', 0) < 2:
                print(f"  {tag}: *** CHECK: recovery.txt names {r['recovery_events']} "
                      f"interval(s) but only {r.get('n_segments', 0)} scored segment "
                      f"survived (live_end={r.get('live_end', 0):.0f}s of "
                      f"{r.get('dur', 0):.0f}s). Either the recovery was before the 15 s "
                      f"settle, or the live-window rule truncated at/before the collapse "
                      f"and the recovered tail was DROPPED. Do not read this PER as the "
                      f"recovered leg's until you know which.")
        for b in r.get('bursts', []):
            brows.append((p, b['onset_seq'], b['run_len'], b['t_s'],
                          b['t_mono_ns'], b['t_real_ns']))
        if not r['usable']:
            nwedge += r['wedged']
            print(f"  {tag}: UNUSABLE (live window {r['live_end']:.0f}s of {r['dur']:.0f}s"
                  f"{', WEDGED' if r['wedged'] else ''})")
            continue
        per = 100*r['miss']/max(r['span'], 1); pers.append(per)
        ub = 100*cp_upper(r['miss'], r['span'])
        tot_k += r['miss']; tot_n += r['span']; nwedge += r['wedged']
        print(f"  {tag}: live {r['live_end']:.0f}s/{r['dur']:.0f}s"
              f"{' [WEDGE truncated]' if r['wedged'] else ''}  "
              f"PER={per:.3f}% ({r['miss']}/{r['span']})  CP95UL={ub:.3f}%  "
              f"lag33={r['ac33']:.3f}  bins={r['bins']}")
    if tot_n:
        ub_all = 100*cp_upper(tot_k, tot_n)
        print(f"\n  POOLED live-window: PER={100*tot_k/tot_n:.3f}% ({tot_k}/{tot_n})"
              f"  CP95UL={ub_all:.3f}%")
        if pers:
            print(f"  per-run spread: {min(pers):.3f}%..{max(pers):.3f}%")
        print(f"  wedges during captures: {nwedge} (real events; auto-recovered in "
              f"normal ops by lock_watchdog, disabled during captures)")
        if nrecov:
            print(f"  PERTURBED legs in this pool: {nrecov} (harness-recovered mid-window "
                  f"collapse, {recov_s:.1f}s excluded in total). Their clean segments are "
                  f"pooled here; the perturbed intervals are in neither k nor n.")
        print(f"  GATE (<1% at CP95 upper limit, live-link): "
              f"{'PASS' if ub_all < 1.0 else 'NOT MET'}")
    if burst_times_csv is not None:
        with open(burst_times_csv, 'w') as f:
            f.write("path,onset_seq,run_len,t_s,t_mono_ns,t_real_ns\n")
            for row in brows:
                f.write("%s,%d,%d,%.6f,%d,%d\n" % row)
        print(f"  burst times: {len(brows)} loss runs -> {burst_times_csv}"
              f"  (onset times INTERPOLATED from clean-frame anchors; "
              f"t_real_ns is the only cross-host-comparable axis)")

if __name__ == '__main__':
    args = sys.argv[1:]
    if args and args[0] == '--arq':
        ARQ_MODE = True
        args = args[1:]
        print("(ARQ mode: sorted-unique seqs; PER = frames never delivered by any copy)")
    bt = None
    if '--burst-times' in args:
        i = args.index('--burst-times')
        if i + 1 >= len(args):
            sys.exit("--burst-times needs a CSV output path")
        bt = args[i + 1]
        args = args[:i] + args[i + 2:]
    main(args, burst_times_csv=bt)
