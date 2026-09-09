import numpy as np, os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '..'))
from ddrcap2_pc import check_common, check_sel
P = 12333
def synth(nfr=30, toff=6000, slot_ok=True):
    n = nfr * P; rng = np.random.default_rng(0)
    a = np.zeros((n, 4), dtype=np.int16); a[:, 0] = rng.integers(-8000, 8000, n); a[:, 1] = rng.integers(-8000, 8000, n)
    c2 = np.full(n, toff, dtype=np.uint16); c2[::P] |= 1 << 15; c2[7::P] |= 1 << 14
    slot = (np.arange(n) % 4) if slot_ok else np.zeros(n, dtype=int)
    side = np.where(slot == 1, np.arange(n) % P, 100)
    a[:, 2] = c2.astype(np.int16); a[:, 3] = ((slot << 14) | side).astype(np.uint16).astype(np.int16)
    return a
def test_common_passes_on_good_synthetic():
    r = check_common(synth()); assert all(v for k, v in r.items() if k != 'd0'), r; assert r['d0'] == 6000
def test_common_fails_when_slots_do_not_cycle():
    r = check_common(synth(slot_ok=False)); assert r['slots_cycle'] is False
def test_sel13_underflow_rate():
    a = synth(); a[:, 0] = 0; a[::4, 0] = np.int16(-32768)   # underflow bit every 4th record = 1/symbol at 4 records/symbol
    assert check_sel(a, 13)['underflow_per_symbol'] is True

# --- fix round 1: sel12 peak-shape rule replaced; sel13/14/15 tref_cadence replaces demod_marks_periodic ---

def test_sel12_peak_one_per_frame_pass():
    a = synth(); a[:, 0] = 0; a[:, 1] = 0
    for i in range(30):
        base = i * P
        a[base + 100, 0] = 1000   # the one primary (>0.8x frame max)
        a[base + 200, 0] = 700    # a secondary in (0.45,0.8]xmax
    r = check_sel(a, 12)
    assert r['peak_one_per_frame'] is True

def test_sel12_peak_one_per_frame_fail_two_primaries():
    a = synth(); a[:, 0] = 0; a[:, 1] = 0
    for i in range(30):
        base = i * P
        a[base + 100, 0] = 1000
        a[base + 150, 0] = 999    # second record also >0.8x max -> not exactly one
    r = check_sel(a, 12)
    assert r['peak_one_per_frame'] is False

def test_sel13_uses_tref_cadence_not_demod_marks():
    a = synth()
    r = check_common(a, sel=13)
    assert 'demod_marks_periodic' not in r
    assert 'tref_cadence' in r
    assert r['tref_cadence'] is True   # synth's default tref (index % P) has a clean modal delta

def _build_tref(deltas, p=P):
    import numpy as _np
    tr = _np.zeros(len(deltas) + 1, dtype=_np.int64)
    tr[1:] = _np.cumsum(deltas)
    return _np.mod(tr, p)

def test_tref_cadence_helper_passes_on_sparse_bursts():
    from ddrcap2_pc import _tref_cadence
    rng = np.random.default_rng(3); n = 5000
    deltas = np.ones(n - 1, dtype=np.int64)
    burst = rng.choice(n - 1, size=int(0.002 * (n - 1)), replace=False)
    deltas[burst] = 150
    tr = _build_tref(deltas)
    passed, stats = _tref_cadence(tr, n=n * 4)
    assert passed is True

def test_tref_cadence_helper_fails_on_heavy_bursts():
    from ddrcap2_pc import _tref_cadence
    rng = np.random.default_rng(2); n = 5000
    deltas = np.ones(n - 1, dtype=np.int64)
    burst = rng.choice(n - 1, size=int(0.10 * (n - 1)), replace=False)
    deltas[burst] = 150
    tr = _build_tref(deltas)
    passed, stats = _tref_cadence(tr, n=n * 4)
    assert passed is False
    assert stats['frac_drop_gt2x_modal'] > 0.05

def test_sel12_tolerance_band_passes_at_2_of_499():
    nfr = 500
    a = synth(nfr=nfr); a[:, 0] = 0; a[:, 1] = 0
    for i in range(nfr):
        a[i * P + 100, 0] = 1000
    for i in (10, 20):   # 2 bad frames of 499 scored = 99.60% clean, >= 99.5% band
        a[i * P + 150, 0] = 999
    r = check_sel(a, 12)
    assert r['peak_one_per_frame'] is True
    assert 'sel12_exceptions' in r and '2 exception frame' in r['sel12_exceptions']

def test_sel12_tolerance_band_fails_below_995():
    nfr = 500
    a = synth(nfr=nfr); a[:, 0] = 0; a[:, 1] = 0
    for i in range(nfr):
        a[i * P + 100, 0] = 1000
    for i in (10, 20, 30, 40, 50):   # 5 bad frames of 499 scored = 98.99% clean, < 99.5% band
        a[i * P + 150, 0] = 999
    r = check_sel(a, 12)
    assert r['peak_one_per_frame'] is False

def test_sel8_uses_tref_cadence_and_liveness_rules():
    a = synth()
    # 39-value cyclic alphabet, matching the real sel8 sample-value diversity seen on silicon
    # (2026-09-02 arm) -- exercises the sel8-specific not_constant threshold (20), not the
    # generic common-check threshold (100), which sel8 is exempted from (see ddrcap2_pc.py).
    levels = np.arange(-19, 20) * 100
    a[:, 0] = levels[np.arange(len(a)) % 39].astype(np.int16)
    a[:, 1] = levels[(np.arange(len(a)) + 5) % 39].astype(np.int16)
    rc = check_common(a, sel=8)
    assert 'demod_marks_periodic' not in rc
    assert 'not_constant_IQ' not in rc
    assert 'tref_cadence' in rc and rc['tref_cadence'] is True
    rs = check_sel(a, 8)
    assert rs['not_constant'] is True
    assert rs['both_signs_present'] is True
    assert rs['demod_marks_present'] is True
    assert rs['tx_marks_present'] is True

def test_sel8_liveness_fails_on_constant_rail():
    a = synth(); a[:, 0] = 1000; a[:, 1] = 1000
    rs = check_sel(a, 8)
    assert rs['not_constant'] is False
    assert rs['both_signs_present'] is False
