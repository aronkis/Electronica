import numpy as np, os, sys, pytest
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '..'))
from ddrcap2_beat_analysis import analyse

# Two periods are exercised: 12320 (the measured sel6 demod-marker period on
# silicon) and 12333 (the DDR record/tref-modulus period, kept distinct to
# prove frames_by_index tracks the *measured* marker gap of the fixture
# rather than a hardcoded constant -- see final-fix brief item A).
PERIODS = (12320, 12333)

def frame_words(period, offset, seed=3):
    rng = np.random.default_rng(seed); base = rng.integers(-8000, 8000, size=(period, 2)).astype(np.int16)
    return np.roll(base, offset, axis=0)
def synth(period, nfr, onset_frame, rung, toff0, toff_move_at=None, toff_delta=0):
    base = frame_words(period, 0); rows = []
    for f in range(nfr):
        w = frame_words(period, rung) if f >= onset_frame else base
        rec = np.zeros((period, 4), dtype=np.int16); rec[:, :2] = w
        toff = toff0 + (toff_delta if (toff_move_at is not None and f >= toff_move_at) else 0)
        c2 = np.full(period, toff, dtype=np.uint16); c2[0] |= 1 << 15; c2[5] |= 1 << 14
        rec[:, 2] = c2.astype(np.int16); slot = np.arange(period) % 4; side = np.where(slot == 1, np.arange(period), 0)
        rec[:, 3] = ((slot << 14) | side).astype(np.uint16).astype(np.int16); rows.append(rec)
    return np.vstack(rows)
def omap(period):   # injective map for the synthetic base frame: 16 hard decisions at marker+1 -> offset
    base = frame_words(period, 0); m = {}
    for off in range(period):
        w = 0; s = np.roll(base, off, axis=0)
        for k in range(16): w |= ((int(s[1+k, 0] < 0) << 1) | int(s[1+k, 1] < 0)) << (30 - 2*k)
        m[w] = off
    return m

@pytest.mark.parametrize('period', PERIODS)
def test_P1_when_toff_moves_with_data(period):
    r = analyse(synth(period, 40, 20, 6363, 5000, toff_move_at=20, toff_delta=6363), omap(period))
    assert r['verdict'] == 'P1' and r['onset_beat_data'] // period == 20 and abs(r['delta_beats']) <= 1

@pytest.mark.parametrize('period', PERIODS)
def test_P2_when_toff_holds(period):
    r = analyse(synth(period, 40, 20, 6240, 5000), omap(period))
    assert r['verdict'] == 'P2' and r['toff_after'] == 5000

@pytest.mark.parametrize('period', PERIODS)
def test_NEITHER_when_toff_moves_non_rung(period):
    r = analyse(synth(period, 40, 20, 6299, 5000, toff_move_at=20, toff_delta=777), omap(period))
    assert r['verdict'] == 'NEITHER'

@pytest.mark.parametrize('period', PERIODS)
def test_three_way_frame_count_agrees(period):
    # Meaningful, not trivially true: frames_by_index must track the
    # *measured* marker period of this fixture (period), not the module's
    # legacy P=12333 constant -- so this must also pass when period=12320,
    # where a hardcoded-P version of frames_by_index would be off by ~1%.
    r = analyse(synth(period, 40, 20, 6363, 5000, toff_move_at=20, toff_delta=6363), omap(period))
    assert r['measured_period'] == period
    assert abs(r['frames_by_marker'] - r['frames_by_index']) <= 1 and abs(r['frames_by_tref'] - r['frames_by_index']) <= 1

def test_frames_by_index_uses_measured_period_not_hardcoded_12333():
    # Direct regression for item A: a 12320-period fixture must NOT be
    # scored against a hardcoded 12333 (which would silently under-report
    # frames_by_index by ~1 frame per ~950 frames and, on multi-thousand-
    # frame captures, drift the count enough to look like a real drop).
    period = 12320
    r = analyse(synth(period, 40, 20, 6240, 5000), omap(period))
    assert r['measured_period'] == 12320
    assert r['frames_by_index'] == 40
