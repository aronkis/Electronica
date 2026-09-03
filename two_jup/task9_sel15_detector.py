#!/usr/bin/env python3
"""task9_sel15_detector.py -- Rate_Handle FIFO occupancy LEVEL detector (Task 9, sel15).

sel15 bit packing (design doc §3 + 2026-09-02 correction): I[15:8]=beatobsRhCtr (BfGridPace's own
pacer, ignored here), I[7:3]=beatobsPush[4:0], Q[15:11]=beatobsPop[4:0]. Both push/pop are 5-bit
(0-31) counters -- the FIFO's actual depth (design doc "32-deep FIFO"). occupancy = (push-pop) mod
32 is therefore bounded to [0,31]; a rung-scale (thousands-of-symbols) event cannot appear as a
direct mod-32 level difference -- the achievable observable range is "tens of counts", not hundreds.

Primary: a LEVEL comparison (median occupancy, quiet vs displaced reference) that sidesteps needing
a transition to fall inside either window (per the controller's ruling on sel13/14: a re-anchor
event's presence in a window must be evidenced, not assumed).

Secondary: the same tref-indexed windowed-mean-shift TRANSITION detector as sel13, generalized to
the 5-bit push/pop circular fold, in case a window does straddle a genuine step.

Both are indexed by tref (slot==1 sparse positions), with DMA-drop-adjacent pairs excluded by
construction -- the same `clean_pairs` machinery as task9_sel13_detector, reused here (not
reimplemented) since the exclusion rule is selector-agnostic.
"""
import numpy as np
from task9_sel13_detector import clean_pairs, mean_shift_baseline, mean_shift_events, W_DEFAULT

def unpack(a):
    """a: [N,4] int16 decoded-selector array (raw ddrcap2_decode.load() output, NOT decode()'d --
    only I/Q are selector-specific; ch2/ch3 stay the universal anchor). Returns (push, pop)."""
    Iu = a[:, 0].astype(np.uint16)
    Qu = a[:, 1].astype(np.uint16)
    push = (Iu >> 3) & 0x1F
    pop = Qu >> 11
    return push.astype(np.int32), pop.astype(np.int32)

def occupancy(push, pop):
    """(push - pop) mod 32, bounded [0,31]."""
    return np.mod(push - pop, 32)

def clean_occupancy(push, pop, tref):
    """Occupancy sampled only at tref-valid, non-drop-adjacent record positions (reuses
    task9_sel13_detector.clean_pairs' `pos` array -- positions that are the LATER half of a clean,
    modal-cadence tref pair; the first valid position of the stream is not included, matching
    clean_pairs' own definition, which is fine for a level statistic over many samples)."""
    pos, prev_pos, modal = clean_pairs(tref)
    if len(pos) == 0:
        return np.array([]), np.array([]), modal
    occ = occupancy(push[pos], pop[pos])
    return occ, pos, modal

def level_stats(occ):
    if len(occ) == 0:
        return {'median': None, 'mad': None, 'n': 0}
    med = float(np.median(occ))
    mad = float(np.median(np.abs(occ.astype(np.float64) - med)))
    return {'median': med, 'mad': mad, 'n': int(len(occ))}

def level_shift(quiet_occ, displaced_occ, mad_floor=0.5):
    """Compare median occupancy between a quiet reference and a displaced (candidate) sample.
    Returns a dict with both levels, the difference, and whether it clears the quiet-state spread
    (median +/- max(mad_floor, 3*MAD) of the quiet reference)."""
    q = level_stats(quiet_occ)
    d = level_stats(displaced_occ)
    if q['median'] is None or d['median'] is None:
        return {'uninformative': True, 'reason': 'no clean occupancy samples in one or both refs',
                'quiet': q, 'displaced': d}
    diff = d['median'] - q['median']
    spread = max(mad_floor, 3.0 * q['mad'])
    confirmed = abs(diff) > spread
    return {'uninformative': False, 'quiet': q, 'displaced': d, 'diff': diff, 'quiet_spread': spread,
            'confirmed': bool(confirmed)}

def raw_delta_5bit(occ_or_ctr, pos, prev_pos):
    """Signed circular step of a 5-bit (mod-32) field between prev_pos[k] and pos[k] -- same fold
    style as task9_sel13_detector.raw_delta but for a 5-bit field."""
    d = (occ_or_ctr[pos].astype(np.int64) - occ_or_ctr[prev_pos].astype(np.int64) + 16) % 32 - 16
    return d

def transition_score(push, pop, tref, expected_onset_record, total_records, w=W_DEFAULT,
                      quiet_frac=0.20):
    """Secondary: windowed-mean-shift transition detector on occupancy, same statistic family as
    task9_sel13_detector.score_onset_window but for the 5-bit occupancy field."""
    pos, prev_pos, modal = clean_pairs(tref)
    if modal is None or len(pos) == 0:
        return {'uninformative': True, 'reason': 'no clean pairs'}
    occ_full = occupancy(push, pop)
    quiet_n = max(W_DEFAULT + 1, int(len(pos) * quiet_frac))
    quiet_n = min(quiet_n, len(pos))
    base_delta = raw_delta_5bit(occ_full, pos[:quiet_n], prev_pos[:quiet_n])
    # reuse the 11-bit machinery's baseline/rolling-mean helpers (they are field-width agnostic --
    # operate on already-folded deltas)
    med, mad, thresh = mean_shift_baseline(base_delta, w)
    half = int(0.02 * total_records)
    lo, hi = max(0, expected_onset_record - half), min(total_records, expected_onset_record + half)
    win_mask = (pos >= lo) & (pos < hi)
    win_pos = pos[win_mask]
    if len(win_pos) < w + 100:
        return {'uninformative': True, 'reason': f'only {len(win_pos)} clean pairs in search window',
                'search_lo': lo, 'search_hi': hi}
    win_idx_in_pos = np.flatnonzero(win_mask)
    ctx_lo = max(0, win_idx_in_pos[0] - w)
    ctx_hi = min(len(pos), win_idx_in_pos[-1] + 1)
    ctx_delta = raw_delta_5bit(occ_full, pos[ctx_lo:ctx_hi], prev_pos[ctx_lo:ctx_hi])
    ev_rel, rm = mean_shift_events(ctx_delta, med, mad, thresh, w)
    win_events_pos = pos[ctx_lo + ev_rel] if len(ev_rel) else np.array([], dtype=np.int64)
    win_events_pos = win_events_pos[(win_events_pos >= lo) & (win_events_pos < hi)]
    return {'uninformative': False, 'search_lo': lo, 'search_hi': hi, 'baseline_median': med,
            'baseline_mad': mad, 'threshold': thresh, 'window_events': win_events_pos.tolist(),
            'confirmed': bool(len(win_events_pos) > 0)}
