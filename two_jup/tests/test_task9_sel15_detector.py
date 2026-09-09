import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import numpy as np
import task9_sel15_detector as m

def test_unpack_matches_design_doc_bit_packing():
    # I[7:3]=push=0b10101=21, I[15:8]=rhctr (ignored); Q[15:11]=pop=0b01100=12
    I = np.array([ (21 << 3) | (5 << 8) ], dtype=np.uint16)
    Q = np.array([ (12 << 11) ], dtype=np.uint16)
    a = np.zeros((1,4), dtype=np.int16)
    a[:,0] = I.astype(np.int16); a[:,1] = Q.astype(np.int16)
    push, pop = m.unpack(a)
    assert push[0] == 21 and pop[0] == 12

def test_occupancy_bounded_and_wraps():
    push = np.array([5, 0, 31])
    pop = np.array([2, 31, 0])
    occ = m.occupancy(push, pop)
    assert list(occ) == [3, (0-31) % 32, 31]

def test_level_shift_confirmed_when_beyond_quiet_spread():
    rng = np.random.default_rng(1)
    quiet = np.clip(10 + rng.integers(-1, 2, size=2000), 0, 31)
    displaced = np.clip(25 + rng.integers(-1, 2, size=2000), 0, 31)
    r = m.level_shift(quiet, displaced)
    assert r['uninformative'] is False
    assert r['confirmed'] is True
    assert abs(r['diff']) > 10

def test_level_shift_not_confirmed_when_same_level():
    rng = np.random.default_rng(2)
    quiet = np.clip(10 + rng.integers(-1, 2, size=2000), 0, 31)
    displaced = np.clip(10 + rng.integers(-1, 2, size=2000), 0, 31)
    r = m.level_shift(quiet, displaced)
    assert r['uninformative'] is False
    assert r['confirmed'] is False

def test_clean_occupancy_excludes_drop_adjacent():
    n = 2000
    tref = np.arange(n) % 12333
    tref[1000:] = (tref[1000:] + 500) % 12333  # drop at 1000
    push = np.full(n, 10, dtype=np.int32)
    pop = np.zeros(n, dtype=np.int32)
    occ, pos, modal = m.clean_occupancy(push, pop, tref)
    assert 1000 not in pos  # excluded as the later half of the straddling pair
