### Task 3: Record decoder

**Files:**
- Create: `two_jup/ddrcap2_decode.py`, `two_jup/tests/test_ddrcap2_decode.py`

**Interfaces:**
- `decode(a: np.ndarray) -> dict` with keys `I, Q` (int16 arrays), `mark_demod, mark_fec` (bool), `toff` (uint16, 0..16383), `slot` (uint8), `side` (uint16) — all length N — plus `heldts_lo, tref, runmax_hi, corrthr_hi` (each a masked array: value where `slot==k`, `-1` elsewhere, int32).
- CLI: `ddrcap2_decode.py IN.bin --v1compat OUT.bin` writes a 4×int16 file `[I, Q, 0x7FFF|0, 0x7FFF|0]` so `t6_score_large.py` and `ddrcap_pc_large.py` work unchanged; `--summary` prints record count, marker counts, toff min/max/mode, slot histogram.

- [ ] **Step 1: Failing tests**

```python
# two_jup/tests/test_ddrcap2_decode.py
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
```

- [ ] **Step 2: Run → ImportError.**

- [ ] **Step 3: Write the decoder**

```python
#!/usr/bin/env python3
"""ddrcap2_decode.py -- DDRCAP-v2 record decoder (spec sec 2).
ch2 = {mark_demod, mark_fec, timingOffset[13:0]}, ch3 = {slot[1:0], side[13:0]}.
--v1compat writes [I, Q, 0x7FFF|0, 0x7FFF|0] so the v1 scorers run unchanged."""
import argparse, sys
import numpy as np

SLOTS = ('heldts_lo', 'tref', 'runmax_hi', 'corrthr_hi')

def load(path):
    a = np.fromfile(path, dtype='<i2')
    return a[:(len(a) // 4) * 4].reshape(-1, 4)

def decode(a):
    c2 = a[:, 2].astype(np.uint16); c3 = a[:, 3].astype(np.uint16)
    d = {'I': a[:, 0], 'Q': a[:, 1],
         'mark_demod': (c2 >> 15) & 1 == 1, 'mark_fec': (c2 >> 14) & 1 == 1,
         'toff': c2 & 0x3FFF, 'slot': (c3 >> 14).astype(np.uint8), 'side': c3 & 0x3FFF}
    for k, name in enumerate(SLOTS):
        v = np.full(len(a), -1, dtype=np.int32)
        m = d['slot'] == k
        v[m] = d['side'][m]
        d[name] = v
    return d

def v1compat(a):
    d = decode(a)
    o = np.zeros_like(a)
    o[:, 0] = a[:, 0]; o[:, 1] = a[:, 1]
    o[:, 2] = np.where(d['mark_demod'], 0x7FFF, 0).astype(np.int16)
    o[:, 3] = np.where(d['mark_fec'], 0x7FFF, 0).astype(np.int16)
    return o

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('src'); ap.add_argument('--v1compat'); ap.add_argument('--summary', action='store_true')
    x = ap.parse_args(); a = load(x.src)
    if x.v1compat:
        v1compat(a).astype('<i2').tofile(x.v1compat); print(f"wrote {len(a)} v1-compat records")
    if x.summary or not x.v1compat:
        d = decode(a); t = d['toff']
        vals, cnts = np.unique(t, return_counts=True)
        print(f"records {len(a)}  demod_marks {int(d['mark_demod'].sum())}  tx_marks {int(d['mark_fec'].sum())}")
        print(f"toff min {int(t.min())} max {int(t.max())} mode {int(vals[cnts.argmax()])} ({cnts.max()/len(t):.3f})  distinct {len(vals)}")
        print(f"slot histogram {np.bincount(d['slot'], minlength=4).tolist()}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
```

- [ ] **Step 4: Run → 2 passed.**

- [ ] **Step 5: Commit**

```bash
git add two_jup/ddrcap2_decode.py two_jup/tests/test_ddrcap2_decode.py
git commit -s -m "DDRCAP2 decoder: unpack tOff/markers/sidecar, v1-compatible writer for the existing scorers

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

