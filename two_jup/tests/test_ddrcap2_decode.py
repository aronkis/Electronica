import numpy as np, os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '..'))
from ddrcap2_decode import decode

def rec(I, Q, md, mf, toff, slot, side):
    c2 = (md << 15) | (mf << 14) | (toff & 0x3FFF)
    c3 = (slot << 14) | (side & 0x3FFF)
    return [I, Q, np.int16(np.uint16(c2).astype(np.int16)), np.int16(np.uint16(c3).astype(np.int16))]

def test_fields_unpack():
    a = np.array([rec(100, -200, 1, 0, 6363, 0, 4095), rec(1, 2, 0, 1, 12332, 1, 12000),
                  rec(3, 4, 0, 0, 0, 2, 0x3FFF), rec(5, 6, 1, 1, 8191, 3, 7)], dtype=np.int16)
    d = decode(a)
    assert d['toff'].tolist() == [6363, 12332, 0, 8191]
    assert d['mark_demod'].tolist() == [True, False, False, True]
    assert d['mark_fec'].tolist() == [False, True, False, True]
    assert d['slot'].tolist() == [0, 1, 2, 3]
    assert d['heldts_lo'].tolist() == [4095, -1, -1, -1]
    assert d['tref'].tolist() == [-1, 12000, -1, -1]
    assert d['runmax_hi'].tolist() == [-1, -1, 0x3FFF, -1]
    assert d['corrthr_hi'].tolist() == [-1, -1, -1, 7]

def test_v1compat_roundtrip_markers():
    a = np.array([rec(9, 8, 1, 0, 5, 0, 0), rec(7, 6, 0, 1, 5, 1, 0)], dtype=np.int16)
    with tempfile.TemporaryDirectory() as t:
        src, dst = os.path.join(t, 'in.bin'), os.path.join(t, 'out.bin')
        a.tofile(src)
        subprocess.check_call([sys.executable, os.path.join(HERE, '..', 'ddrcap2_decode.py'), src, '--v1compat', dst])
        o = np.fromfile(dst, dtype='<i2').reshape(-1, 4)
        assert o[:, 0].tolist() == [9, 7] and o[:, 2].tolist() == [0x7FFF, 0] and o[:, 3].tolist() == [0, 0x7FFF]
