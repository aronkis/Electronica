import numpy as np, subprocess, sys, os, tempfile
HERE = os.path.dirname(__file__)
def test_cut_writes_only_iq_columns_in_order():
    a = np.arange(40, dtype=np.int16).reshape(10, 4)      # records: [0 1 2 3], [4 5 6 7], ...
    with tempfile.TemporaryDirectory() as d:
        src, dst = os.path.join(d, 'in.bin'), os.path.join(d, 'out.iq')
        a.tofile(src)
        subprocess.check_call([sys.executable, os.path.join(HERE, '..', 'ddr_to_iq.py'), src, dst, '--start', '2', '--count', '3'])
        out = np.fromfile(dst, dtype='<i2')
        assert out.tolist() == [8, 9, 12, 13, 16, 17]
