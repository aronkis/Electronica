#!/usr/bin/env python3
"""task9_sel14_detector.py -- frame-to-frame self-similarity detector (Task 9, sel14).

sel14 = Symbol_Synchronizer.Delay8_out1_re/im, the raw (RRC-filtered) sample buffer feeding the
timing-error detector -- no accumulator/phase register here, just buffered samples. The ROM plays an
identical repeating sequence, so under steady lock the buffered I content should repeat with a stable
frame-to-frame relationship. A coarse timing/skew step (the kind of event that would explain the
sel6 data-offset rung transition in §82) should show up as a transient LOSS of frame-to-frame
self-similarity right at the step (misaligned samples), not a sustained level shift.

REVISION 2 (this file; revision 1 of the two allowed for sel14, per the controller's ruling):
the original design (`FRAME_RECORDS=49332` raw-record-index framing, kept below as
`frame_corr_series`/`score_onset_frames` for provenance, NOT used to score real data any more)
failed its own positive control: baseline correlation on real data was ~0 everywhere, because these
enb-domain taps drop records at ~1-in-2049 (Tier-2 `drops_per_1e6_records`), so a 49332-record
window built by raw index averages ~24 drops and is not phase-aligned to the ROM cycle -- this is
exactly the standing dispatch instruction ("index every analysis by tref and mark_demod, never by
record index") that the original design violated.

Fix: build each "frame" by tref VALUE (0..12332), not raw record count, using only the tref-valid
(slot==1) record positions, exactly as `task9_sel13_detector.clean_pairs` already does for sel13.
A record is EXCLUDED from a frame's data (not merely flagged) if either its incoming or outgoing
tref step (to the adjacent valid-tref position) is not the modal cadence -- i.e. it is adjacent to a
DMA drop on either side. Frame-to-frame correlation is then computed only over the tref values that
are present (non-excluded) in BOTH compared frames -- so an isolated drop removes a handful of tref
positions from the comparison, not the whole frame's alignment, and does not corrupt every later
frame's alignment the way raw-index accumulation did.
"""
import numpy as np

TREF_MOD = 12333

FRAME_RECORDS = 4 * 12333  # 49332 -- kept for the deprecated raw-index functions only

# ---------------------------------------------------------------------------
# Deprecated (revision-1 / original) raw-record-index framing. NOT used to score real data --
# kept only so the failed-control result in TASK9_PREREG.md/report is reproducible.
# ---------------------------------------------------------------------------

def frame_corr_series(I, frame_records=FRAME_RECORDS):
    """DEPRECATED (see module docstring). Pearson correlation between consecutive non-overlapping
    raw-record-index windows of I."""
    n = len(I)
    n_frames = n // frame_records
    if n_frames < 2:
        return np.array([])
    frames = I[:n_frames * frame_records].astype(np.float64).reshape(n_frames, frame_records)
    fm = frames - frames.mean(axis=1, keepdims=True)
    fnorm = np.sqrt((fm ** 2).sum(axis=1))
    num = (fm[:-1] * fm[1:]).sum(axis=1)
    den = fnorm[:-1] * fnorm[1:]
    den[den == 0] = np.nan
    corr = num / den
    return np.nan_to_num(corr, nan=0.0)

def corr_baseline(corr):
    if len(corr) == 0:
        return 0.0, 0.0, -0.1
    med = float(np.median(corr))
    mad = float(np.median(np.abs(corr - med)))
    thresh = med - max(0.02, 8.0 * mad)
    return med, mad, thresh

def dip_events(corr, med, thresh):
    return np.flatnonzero(corr < thresh)

# ---------------------------------------------------------------------------
# Revision 2: tref-indexed, drop-aware framing.
# ---------------------------------------------------------------------------

def tref_frames(I, tref, tref_mod=TREF_MOD):
    """Build one row per ROM frame (a wrap of tref from ~tref_mod-1 back to ~0), each row of length
    `tref_mod`, holding I at that tref value (NaN where missing or drop-adjacent). Uses only
    tref-valid (slot==1) record positions, same sparse indexing as task9_sel13_detector.clean_pairs.

    Returns (frames, n_valid_per_frame): `frames` is a float64 [n_frames, tref_mod] array (NaN =
    excluded); `n_valid_per_frame` is the count of non-NaN entries per frame (diagnostic)."""
    valid_pos = np.flatnonzero(tref >= 0)
    if len(valid_pos) < 2:
        return np.zeros((0, tref_mod)), np.array([])
    trv = tref[valid_pos].astype(np.int64)
    Iv = I[valid_pos].astype(np.float64)
    raw_dt = np.diff(trv)
    dt_mod = np.mod(raw_dt, tref_mod)
    vals, counts = np.unique(dt_mod, return_counts=True)
    modal = int(vals[counts.argmax()])
    wrap = raw_dt < -(tref_mod // 2)  # a genuine tref reset (scale-relative, not a magic absolute constant)
    frame_id = np.concatenate(([0], np.cumsum(wrap)))
    drop_before = np.concatenate(([True], dt_mod != modal))       # position i preceded by a bad step
    drop_after = np.concatenate((dt_mod != modal, [True]))         # position i followed by a bad step
    usable = ~drop_before & ~drop_after
    n_frames = int(frame_id[-1]) + 1
    frames = np.full((n_frames, tref_mod), np.nan)
    keep = usable & (trv >= 0) & (trv < tref_mod)
    frames[frame_id[keep], trv[keep]] = Iv[keep]
    n_valid_per_frame = (~np.isnan(frames)).sum(axis=1)
    return frames, n_valid_per_frame

def tref_frame_corr_series(frames, min_overlap=2000):
    """Pearson correlation between consecutive frame rows, over tref positions present (non-NaN)
    in BOTH frames. Returns (corr[n_frames-1], overlap_n[n_frames-1]); corr is NaN where overlap <
    min_overlap (too little shared data to trust)."""
    n_frames = frames.shape[0]
    if n_frames < 2:
        return np.array([]), np.array([])
    corr = np.full(n_frames - 1, np.nan)
    overlap = np.zeros(n_frames - 1, dtype=np.int64)
    for k in range(n_frames - 1):
        a, b = frames[k], frames[k + 1]
        m = ~np.isnan(a) & ~np.isnan(b)
        n = int(m.sum())
        overlap[k] = n
        if n < min_overlap:
            continue
        av, bv = a[m], b[m]
        am, bm = av - av.mean(), bv - bv.mean()
        na, nb = np.sqrt((am ** 2).sum()), np.sqrt((bm ** 2).sum())
        if na == 0 or nb == 0:
            continue
        corr[k] = float((am * bm).sum() / (na * nb))
    return corr, overlap

def tref_corr_baseline(corr):
    v = corr[~np.isnan(corr)]
    if len(v) == 0:
        return 0.0, 0.0, -0.1
    med = float(np.median(v))
    mad = float(np.median(np.abs(v - med)))
    thresh = med - max(0.02, 8.0 * mad)
    return med, mad, thresh

def tref_dip_events(corr, med, thresh):
    """Indices (into `corr`) where the frame-to-frame correlation drops below `thresh`. NaN
    entries (insufficient overlap) never count as events."""
    v = np.nan_to_num(corr, nan=np.inf)  # NaN -> +inf so it never reads as a dip
    return np.flatnonzero(v < thresh)

def score_onset_tref_frames(I, tref, expected_onset_record, total_records, tref_mod=TREF_MOD,
                             quiet_frac=0.20, search_frac=0.02, min_overlap=2000):
    """tref-indexed, drop-aware version of the frame-to-frame dip detector."""
    frames, n_valid = tref_frames(I, tref, tref_mod)
    n_frames = frames.shape[0]
    if n_frames < 10:
        return {'uninformative': True, 'reason': f'only {n_frames} tref-wrap frames (<10) in capture'}
    corr, overlap = tref_frame_corr_series(frames, min_overlap)
    if len(corr) < 10:
        return {'uninformative': True, 'reason': f'only {len(corr)} frame boundaries (<10)'}
    quiet_n = max(5, int(len(corr) * quiet_frac))
    med, mad, thresh = tref_corr_baseline(corr[:quiet_n])

    frame_records_nominal = 4 * tref_mod
    expected_frame = expected_onset_record // frame_records_nominal
    half_frames = max(1, int(search_frac * total_records / frame_records_nominal))
    lo, hi = max(0, expected_frame - half_frames), min(len(corr), expected_frame + half_frames)
    if hi - lo < 5:
        return {'uninformative': True, 'reason': f'only {hi-lo} frame boundaries in search window',
                'search_lo_frame': lo, 'search_hi_frame': hi}
    win = corr[lo:hi]
    win_events = lo + tref_dip_events(win, med, thresh)

    bg_lo = min(len(corr), hi)
    bg_hi = min(len(corr), bg_lo + max(hi - lo, 50))
    bg = corr[bg_lo:bg_hi]
    bg_events = tref_dip_events(bg, med, thresh) if len(bg) else np.array([])
    bg_rate = len(bg_events) / max(1, len(bg))
    win_rate = len(win_events) / max(1, len(win))

    confirmed = len(win_events) > 0
    return {
        'uninformative': False, 'search_lo_frame': lo, 'search_hi_frame': hi,
        'expected_onset_frame': expected_frame, 'baseline_median': med, 'baseline_mad': mad,
        'threshold': thresh, 'window_dip_frames': win_events.tolist(),
        'window_dip_rate': win_rate, 'background_dip_rate': bg_rate, 'confirmed': bool(confirmed),
        'n_frames_total': n_frames, 'median_overlap': float(np.median(overlap)) if len(overlap) else 0.0,
    }
