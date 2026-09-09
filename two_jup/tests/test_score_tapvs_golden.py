import numpy as np, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from score_tapvs_golden import score

P = 1000
def golden(nframes, seed=1):
    rng = np.random.default_rng(seed)
    frame = rng.integers(-8000, 8000, size=(P, 2)).astype(np.int16)
    g = np.zeros((nframes * P, 4), dtype=np.int16)
    g[:, :2] = np.tile(frame, (nframes, 1))
    g[::P, 3] = 0x7FFF
    return g

def test_aligned_capture_scores_zero_offset_everywhere():
    g = golden(30)
    cap = g.copy()
    r = score(cap, g, P)
    assert r['modal_offset'] == 0 and r['first_divergence_frame'] is None and r['unmatched'] == 0

def test_jump_displacement_is_found_at_the_right_frame():
    g = golden(40)
    cap = g.copy()
    cap[20 * P:, :2] = np.roll(g[20 * P:, :2], 137, axis=0)      # one-step shift from frame 20 on
    r = score(cap, g, P)
    assert r['first_divergence_frame'] == 20
    assert r['offset_after'] == 137 and r['kind'] == 'jump'

def test_walk_is_classified_as_walk():
    g = golden(40)
    cap = g.copy()
    for k in range(1, 6):                                          # offset grows 1 record per frame, frames 20..24
        f = 20 + k - 1
        cap[f * P:(f + 1) * P, :2] = np.roll(g[f * P:(f + 1) * P, :2], k, axis=0)
    cap[25 * P:, :2] = np.roll(g[25 * P:, :2], 5, axis=0)
    r = score(cap, g, P)
    assert r['first_divergence_frame'] == 20 and r['kind'] == 'walk'

def test_iq_swap_and_rotation_do_not_break_alignment():
    g = golden(30)
    cap = g.copy()
    I, Q = g[:, 0].astype(np.int32), g[:, 1].astype(np.int32)
    cap[:, 0], cap[:, 1] = Q, -I                                   # rotate by 90 degrees then swap rails
    cap[:, 0], cap[:, 1] = cap[:, 1].copy(), cap[:, 0].copy()
    r = score(cap, g, P)
    assert r['first_divergence_frame'] is None and r['unmatched'] == 0

def test_start_offset_is_folded_into_the_anchor():
    g = golden(30)
    cap = g[311:].copy()                                           # capture starts mid-frame
    r = score(cap, g, P)
    assert r['modal_offset'] == 0 and r['first_divergence_frame'] is None
