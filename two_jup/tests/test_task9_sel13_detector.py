import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import numpy as np
from task9_sel13_detector import (clean_pairs, raw_delta, baseline, rolling_mean,
                                   mean_shift_baseline, mean_shift_events, score_onset_window)

def make_stream(n, modal=1, countreg_step=17, drop_at=None, noise=0):
    tref = np.arange(n, dtype=np.int64) % 12333
    if drop_at is not None:
        tref[drop_at:] = (tref[drop_at:] + 500) % 12333
    steps = np.full(n, countreg_step, dtype=np.int64)
    if noise:
        rng = np.random.default_rng(1234)
        steps = steps + rng.integers(-noise, noise + 1, size=n)
    countreg = (np.cumsum(steps) % 2048).astype(np.int32)
    return countreg.astype(np.int16), tref.astype(np.int32)

def test_clean_pairs_excludes_drop():
    countreg, tref = make_stream(1000, drop_at=500)
    pos, prev_pos, modal = clean_pairs(tref)
    assert modal == 1
    straddle = (prev_pos == 499) & (pos == 500)
    assert not straddle.any()

def test_rolling_mean_basic():
    x = np.array([1.0, 2.0, 3.0, 4.0, 5.0])
    rm = rolling_mean(x, 2)
    assert np.allclose(rm, [1.5, 2.5, 3.5, 4.5])

def test_no_events_in_steady_stream():
    countreg, tref = make_stream(20000, countreg_step=17)
    r = score_onset_window(countreg, tref, expected_onset_record=10000, total_records=20000, w=200)
    assert r['uninformative'] is False
    assert r['confirmed'] is False
    assert len(r['window_events']) == 0

def test_injected_mean_shift_is_confirmed_at_locus():
    countreg, tref = make_stream(20000, countreg_step=17, noise=5)
    onset = 10000
    countreg = countreg.copy()
    # a sustained step (mean shift), not a single transient -- same character as a real
    # timing-offset step: every step AFTER onset is offset by +40 relative to baseline.
    delta = np.full(20000, 0, dtype=np.int64)
    delta[onset:] = 40
    shifted = (np.cumsum(np.diff(countreg.astype(np.int64), prepend=0) + delta) % 2048).astype(np.int16)
    countreg = shifted
    r = score_onset_window(countreg, tref, expected_onset_record=onset, total_records=20000, w=200)
    assert r['uninformative'] is False
    assert r['confirmed'] is True
    assert len(r['window_events']) >= 1
    assert min(abs(e - onset) for e in r['window_events']) <= 400  # within ~2 window-widths of the true step

def test_negative_control_window_far_from_injection_reports_nothing():
    countreg, tref = make_stream(20000, countreg_step=17, noise=5)
    onset = 18000  # near the end
    countreg = countreg.copy()
    delta = np.full(20000, 0, dtype=np.int64)
    delta[onset:] = 40
    shifted = (np.cumsum(np.diff(countreg.astype(np.int64), prepend=0) + delta) % 2048).astype(np.int16)
    countreg = shifted
    # score a window centered far from the injected onset -- must not fire
    r = score_onset_window(countreg, tref, expected_onset_record=5000, total_records=20000, w=200)
    assert r['uninformative'] is False
    assert r['confirmed'] is False

def test_drop_coincident_step_is_not_a_false_event():
    # a huge tref jump (drop) is excluded from clean_pairs entirely
    countreg, tref = make_stream(3000, countreg_step=17, drop_at=1500)
    pos, prev_pos, modal = clean_pairs(tref)
    straddle = (prev_pos == 1499) & (pos == 1500)
    assert not straddle.any()

def test_uninformative_when_insufficient_clean_pairs_in_window():
    countreg, tref = make_stream(300, countreg_step=17)
    r = score_onset_window(countreg, tref, expected_onset_record=150, total_records=300, w=200)
    assert r['uninformative'] is True
