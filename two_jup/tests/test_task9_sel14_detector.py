import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import numpy as np
import task9_sel14_detector as sel14mod
from task9_sel14_detector import frame_corr_series, corr_baseline, dip_events

FR = 200  # small synthetic frame length for the deprecated raw-index smoke tests

def make_periodic_stream(n_frames, frame_records=FR, noise=2.0, seed=7):
    rng = np.random.default_rng(seed)
    rom = rng.integers(-1000, 1000, size=frame_records).astype(np.float64)
    I = np.tile(rom, n_frames)
    I = I + rng.normal(0, noise, size=len(I))
    return I.astype(np.int16)

def test_deprecated_raw_index_corr_still_computes_on_perfectly_aligned_synthetic_data():
    # smoke test only: the deprecated raw-index framer works fine on ARTIFICIALLY perfect,
    # never-dropped synthetic data (this is exactly why its failure on real (dropped) data was a
    # surprise worth documenting -- see TASK9_PREREG.md Addendum 3/4). Not used to score real data.
    I = make_periodic_stream(40)
    corr = frame_corr_series(I, FR)
    assert len(corr) == 39
    assert np.median(corr) > 0.9

TM = 50  # small synthetic tref modulus for the revision-2 (tref-indexed) tests

def make_tref_stream(n_frames, tref_mod=TM, records_per_symbol=4, noise=1.0, seed=3, drop_frac=0.0):
    """Synthetic enb-domain stream: tref valid only at slot==1 (1 in `records_per_symbol` records),
    I periodic per tref_mod-symbol frame (a repeating 'ROM'), with random drops removing some
    records (tref stays monotone across a drop -- consistent with how the real board's DMA drop
    behaves: missing records, not corrupted ones)."""
    rng = np.random.default_rng(seed)
    rom = rng.integers(-1000, 1000, size=tref_mod).astype(np.float64)
    total_symbols = n_frames * tref_mod
    tref_vals = np.tile(np.arange(tref_mod), n_frames)
    I_vals = np.tile(rom, n_frames) + rng.normal(0, noise, size=total_symbols)
    I = np.repeat(I_vals, records_per_symbol)
    tref = np.full(len(I), -1, dtype=np.int64)
    tref[records_per_symbol - 1::records_per_symbol] = tref_vals
    if drop_frac > 0:
        keep = rng.random(len(I)) > drop_frac / records_per_symbol
        I, tref = I[keep], tref[keep]
    return I.astype(np.int16), tref.astype(np.int32)

def test_tref_frames_steady_state_high_correlation():
    I, tref = make_tref_stream(30, noise=1.0)
    frames, nvalid = sel14mod.tref_frames(I, tref, TM)
    assert frames.shape[0] >= 25
    corr, overlap = sel14mod.tref_frame_corr_series(frames, min_overlap=20)
    valid_corr = corr[~np.isnan(corr)]
    assert len(valid_corr) > 10
    assert np.median(valid_corr) > 0.9  # steady periodic ROM content -> high correlation once tref-aligned

def test_tref_frames_robust_to_scattered_drops():
    I, tref = make_tref_stream(30, noise=1.0, drop_frac=0.05)
    frames, nvalid = sel14mod.tref_frames(I, tref, TM)
    corr, overlap = sel14mod.tref_frame_corr_series(frames, min_overlap=20)
    valid_corr = corr[~np.isnan(corr)]
    assert len(valid_corr) > 10
    assert np.median(valid_corr) > 0.8  # drops shouldn't tank correlation once excluded properly

def test_tref_injected_dip_is_confirmed_at_locus():
    I, tref = make_tref_stream(30, noise=1.0)
    onset_frame = 15
    onset_rec = np.flatnonzero(tref >= 0)[onset_frame * TM]  # first tref-valid record of that frame
    I = I.copy().astype(np.float64)
    # a real skew/misalignment, not a mean shift (Pearson correlation is invariant to additive
    # constants) -- roll the content after onset_rec so it no longer lines up tref-value-for-
    # tref-value with its neighbor frame.
    I[onset_rec:] = np.roll(I[onset_rec:], (TM // 3) * 4)
    total_records = len(I)
    r = sel14mod.score_onset_tref_frames(I.astype(np.int16), tref, expected_onset_record=onset_rec,
                                          total_records=total_records, tref_mod=TM,
                                          search_frac=0.5, min_overlap=20)
    assert r['uninformative'] is False
    assert r['confirmed'] is True

def test_tref_negative_control_far_from_injection():
    I, tref = make_tref_stream(30, noise=1.0)
    onset_frame = 25
    onset_rec = np.flatnonzero(tref >= 0)[onset_frame * TM]
    I = I.copy().astype(np.float64)
    I[onset_rec:] += 600.0
    total_records = len(I)
    r = sel14mod.score_onset_tref_frames(I.astype(np.int16), tref, expected_onset_record=3 * TM * 4,
                                          total_records=total_records, tref_mod=TM,
                                          search_frac=0.15, min_overlap=20)
    assert r['uninformative'] is False
    assert r['confirmed'] is False

def test_uninformative_when_too_few_tref_frames():
    I, tref = make_tref_stream(2, tref_mod=TM)
    r = sel14mod.score_onset_tref_frames(I, tref, expected_onset_record=TM * 4,
                                          total_records=len(I), tref_mod=TM)
    assert r['uninformative'] is True
