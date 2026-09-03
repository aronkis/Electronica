#!/usr/bin/env python3
"""task9_sel13_detector.py -- tref-indexed interpolator-phase discontinuity detector (Task 9, sel13).

Per TASK9_PREREG.md (as amended -- see the "detector revision" note in the report): operates only
on "clean" consecutive tref pairs (tref valid on both sides, delta == modal cadence, i.e. no
DMA-drop-coincident pair is ever scored). tref is sparse (present only at slot==1, ~1 in 4 records
on these enb-domain taps), so a "clean pair" is a pair of CONSECUTIVE valid-tref record positions,
one symbol apart in the un-dropped stream.

Revision from the originally pre-registered per-pair magnitude threshold: on real silicon the
per-symbol raw_delta of the 11-bit countReg accumulator has a heavy-tailed background (~6% of
symbols show a jump >64 counts even far from any predicted onset -- ordinary timing-loop tracking
jitter, ~253-count std, that is genuinely part of normal interpolator operation, not drop artifact
and not anomalous). A single-pair threshold detector cannot separate an injected discontinuity from
this background (its own positive control, run against real quiet-stretch data, failed: an injected
step was swamped by background events, see report). The background is however TIGHTLY mean-reverting
over any local window (windowed mean over W=1000 clean pairs has std ~1.15, range +/-3 over a 200k-pair
quiet sample) -- consistent with a locked loop whose per-symbol jitter self-cancels. A genuine
timing-offset step shifts the LOCAL MEAN of raw_delta (a sustained level, not a single transient), so
the revised detector uses a windowed-mean-shift statistic instead of a per-pair magnitude threshold.
"""
import numpy as np

W_DEFAULT = 1000

def modal_cadence(tref):
    trv = tref[tref >= 0]
    if len(trv) < 2:
        return None
    dt = np.mod(np.diff(trv.astype(np.int64)), 12333)
    vals, counts = np.unique(dt, return_counts=True)
    return int(vals[counts.argmax()])

def clean_pairs(tref):
    """Return (pos, prev_pos, modal): record-index arrays into the ORIGINAL stream such that
    tref is valid at both prev_pos[k] and pos[k] (they are CONSECUTIVE valid-tref entries --
    tref is only present at slot==1, i.e. sparse, ~1 in 4 records on these enb-domain taps), and
    the tref delta between them equals the modal cadence (excludes DMA-drop-coincident pairs)."""
    modal = modal_cadence(tref)
    if modal is None:
        return np.array([], dtype=np.int64), np.array([], dtype=np.int64), modal
    valid_positions = np.flatnonzero(tref >= 0)
    if len(valid_positions) < 2:
        return np.array([], dtype=np.int64), np.array([], dtype=np.int64), modal
    trv = tref[valid_positions].astype(np.int64)
    dt = np.mod(np.diff(trv), 12333)
    keep = dt == modal
    pos = valid_positions[1:][keep]
    prev_pos = valid_positions[:-1][keep]
    return pos, prev_pos, modal

def raw_delta(countreg, pos, prev_pos):
    """Signed circular step of the 11-bit countReg accumulator between prev_pos[k] and pos[k]."""
    d = (countreg[pos].astype(np.int64) - countreg[prev_pos].astype(np.int64) + 1024) % 2048 - 1024
    return d

def baseline(delta):
    """Per-pair magnitude baseline (kept for reporting/census only -- NOT the confirm/deny gate;
    see module docstring)."""
    if len(delta) == 0:
        return 0.0, 0.0, 64.0
    med = float(np.median(delta))
    mad = float(np.median(np.abs(delta - med)))
    thresh = max(64.0, 8.0 * mad)
    return med, mad, thresh

def rolling_mean(x, w):
    """Trailing rolling mean of x with window w. Returns an array of length len(x)-w+1; element k
    is the mean of x[k:k+w]."""
    x = np.asarray(x, dtype=np.float64)
    if len(x) < w:
        return np.array([])
    c = np.cumsum(np.insert(x, 0, 0.0))
    return (c[w:] - c[:-w]) / w

def mean_shift_baseline(delta, w=W_DEFAULT):
    """Baseline (median, MAD, threshold) of the WINDOWED MEAN statistic, from a quiet delta series."""
    rm = rolling_mean(delta, w)
    if len(rm) == 0:
        return 0.0, 0.0, 10.0
    med = float(np.median(rm))
    mad = float(np.median(np.abs(rm - med)))
    thresh = max(10.0, 8.0 * mad)
    return med, mad, thresh

def mean_shift_events(delta, med, mad, thresh, w=W_DEFAULT):
    """Indices (into the windowed-mean array, 0-based, window [k, k+w) of the ORIGINAL delta
    array) where the windowed mean deviates from (med, thresh) -- a sustained local-mean shift,
    not a single-pair blip."""
    rm = rolling_mean(delta, w)
    return np.flatnonzero(np.abs(rm - med) > thresh), rm

def score_onset_window(countreg, tref, expected_onset_record, total_records, quiet_frac=0.20, w=W_DEFAULT):
    """Full Task 9 scoring (windowed-mean-shift detector): baseline from the first `quiet_frac` of
    clean pairs (away from the locus, per TASK9_PREREG.md), events searched in
    expected_onset_record +/- 0.02*total_records, reported in the ORIGINAL record-index space via
    `pos`."""
    pos, prev_pos, modal = clean_pairs(tref)
    if modal is None or len(pos) == 0:
        return {'uninformative': True, 'reason': 'no clean pairs (tref never valid or no modal cadence)'}
    quiet_n = max(w + 1, int(len(pos) * quiet_frac))
    quiet_n = min(quiet_n, len(pos))
    base_delta = raw_delta(countreg, pos[:quiet_n], prev_pos[:quiet_n])
    med, mad, thresh = mean_shift_baseline(base_delta, w)

    half = int(0.02 * total_records)
    lo, hi = max(0, expected_onset_record - half), min(total_records, expected_onset_record + half)
    win_mask = (pos >= lo) & (pos < hi)
    win_pos = pos[win_mask]
    if len(win_pos) < w + 100:
        return {'uninformative': True, 'reason': f'only {len(win_pos)} clean pairs in search window [{lo},{hi}) (need > w+100={w+100})',
                'search_lo': lo, 'search_hi': hi, 'modal_cadence': modal}
    win_idx_in_pos = np.flatnonzero(win_mask)
    # widen the delta slice used for the rolling mean so windows near the edges of the search
    # region still have full context (use pairs immediately outside the window too)
    ctx_lo = max(0, win_idx_in_pos[0] - w)
    ctx_hi = min(len(pos), win_idx_in_pos[-1] + 1)
    ctx_delta = raw_delta(countreg, pos[ctx_lo:ctx_hi], prev_pos[ctx_lo:ctx_hi])
    ev_rel, rm = mean_shift_events(ctx_delta, med, mad, thresh, w)
    # rm[k] corresponds to window starting at ctx_delta index k -> pos index (ctx_lo+k) .. record pos[ctx_lo+k]
    win_events_pos = pos[ctx_lo + ev_rel] if len(ev_rel) else np.array([], dtype=np.int64)
    # restrict reported events to those whose window START actually falls inside [lo,hi)
    win_events_pos = win_events_pos[(win_events_pos >= lo) & (win_events_pos < hi)]

    # background: same statistic computed on a quiet stretch equal in pair-count to the window,
    # taken from the middle of the file, away from both the window and the initial baseline stretch
    bg_start = max(quiet_n, len(pos) // 2)
    bg_end = min(len(pos), bg_start + max(len(win_pos), w + 200))
    bg_delta = raw_delta(countreg, pos[bg_start:bg_end], prev_pos[bg_start:bg_end])
    bg_ev_rel, _ = mean_shift_events(bg_delta, med, mad, thresh, w)
    bg_rate = len(bg_ev_rel) / max(1, len(bg_delta) - w + 1)
    win_rate = len(ev_rel) / max(1, len(ctx_delta) - w + 1)

    confirmed = len(win_events_pos) > 0
    return {
        'uninformative': False, 'search_lo': lo, 'search_hi': hi, 'modal_cadence': modal,
        'baseline_median': med, 'baseline_mad': mad, 'threshold': thresh, 'window': w,
        'window_events': win_events_pos.tolist(), 'window_shift_rate': win_rate, 'background_shift_rate': bg_rate,
        'confirmed': bool(confirmed),
    }
