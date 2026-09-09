### Task 8: The pre-registered burst capture (sel 6) and the §6 verdict

**Files:**
- Create: `two_jup/beat_tap_capture.sh`, `two_jup/tests/fake_anyssh.sh`, `two_jup/tests/fake_arm.sh` (from the beat plan Task 7, verbatim below)
- Create: `two_jup/ddrcap2_beat_analysis.py`, `two_jup/tests/test_ddrcap2_beat_analysis.py`
- Output: `two_jup/beatcap/<ts>_sel6/{mid,onset}.bin`, `verdict.json`; §82

**Interfaces:**
- `ddrcap2_beat_analysis.py CAPTURE.bin --out PREFIX` → `PREFIX.json` with `d0`, `onset_beat_data`, `onset_beat_toff`, `delta_beats`, `toff_after` (value), `toff_delta_is_rung` (bool, ±rung within 4 symbols), `frames_by_marker`, `frames_by_tref`, `frames_by_index`, `verdict` ∈ `P1|P2|NEITHER|UNINFORMATIVE`, and prints the same.
- API for tests: `analyse(a: np.ndarray, offsetmap: dict) -> dict`.

- [ ] **Step 1: Capture script + fakes (verbatim from the beat plan)**

Write `two_jup/beat_tap_capture.sh`, `two_jup/tests/fake_anyssh.sh`, `two_jup/tests/fake_arm.sh` exactly as given in `docs/superpowers/plans/2026-09-01-beat-tap-compare.md` Task 7 Steps 1–2 (the script sets `0x10C=(SEL<<16)|3` after the arm, triggers `mid.bin` on `0x108` delta > THRESH, then `onset.bin` at `T_trigger + PERIOD − LEAD`). Run its dry run (that plan's Step 3) and confirm `TRIGGER`, both `.bin`, and `REFUSE` on re-run.

- [ ] **Step 2: Failing analysis tests (synthetic v2 records)**

```python
# two_jup/tests/test_ddrcap2_beat_analysis.py
import numpy as np, os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '..'))
from ddrcap2_beat_analysis import analyse
P = 12333
def frame_words(offset, seed=3):
    rng = np.random.default_rng(seed); base = rng.integers(-8000, 8000, size=(P, 2)).astype(np.int16)
    return np.roll(base, offset, axis=0)
def synth(nfr, onset_frame, rung, toff0, toff_move_at=None, toff_delta=0):
    base = frame_words(0); rows = []
    for f in range(nfr):
        w = frame_words(rung) if f >= onset_frame else base
        rec = np.zeros((P, 4), dtype=np.int16); rec[:, :2] = w
        toff = toff0 + (toff_delta if (toff_move_at is not None and f >= toff_move_at) else 0)
        c2 = np.full(P, toff, dtype=np.uint16); c2[0] |= 1 << 15; c2[5] |= 1 << 14
        rec[:, 2] = c2.astype(np.int16); slot = np.arange(P) % 4; side = np.where(slot == 1, np.arange(P), 0)
        rec[:, 3] = ((slot << 14) | side).astype(np.uint16).astype(np.int16); rows.append(rec)
    return np.vstack(rows)
def omap():   # injective map for the synthetic base frame: 16 hard decisions at marker+1 -> offset
    base = frame_words(0); m = {}
    for off in range(P):
        w = 0; s = np.roll(base, off, axis=0)
        for k in range(16): w |= ((int(s[1+k, 0] < 0) << 1) | int(s[1+k, 1] < 0)) << (30 - 2*k)
        m[w] = off
    return m
def test_P1_when_toff_moves_with_data():
    r = analyse(synth(40, 20, 6363, 5000, toff_move_at=20, toff_delta=6363), omap())
    assert r['verdict'] == 'P1' and r['onset_beat_data'] // P == 20 and abs(r['delta_beats']) <= 1
def test_P2_when_toff_holds():
    r = analyse(synth(40, 20, 6240, 5000), omap())
    assert r['verdict'] == 'P2' and r['toff_after'] == 5000
def test_NEITHER_when_toff_moves_non_rung():
    r = analyse(synth(40, 20, 6299, 5000, toff_move_at=20, toff_delta=777), omap())
    assert r['verdict'] == 'NEITHER'
def test_three_way_frame_count_agrees():
    r = analyse(synth(40, 20, 6363, 5000, toff_move_at=20, toff_delta=6363), omap())
    assert abs(r['frames_by_marker'] - r['frames_by_index']) <= 1 and abs(r['frames_by_tref'] - r['frames_by_index']) <= 1
```

- [ ] **Step 3: Run → ImportError. Then write the analysis**

```python
#!/usr/bin/env python3
"""ddrcap2_beat_analysis.py -- the pre-registered spec sec 6 verdict on a DDRCAP-v2 sel-6 burst capture.
Per frame: d_data = injective offset-map lookup of the 16 hard decisions at demod-marker+1 (the sec 57/69
instrument; map two_jup/offsetmap/tap3_word_to_offset.tsv). Per beat: tOff (ch2[13:0]).
onset_beat_data = first record of the first frame with d_data != 0 after >=3 frames at 0.
onset_beat_toff = first record where tOff != d0 (d0 = modal tOff before onset_beat_data).
P1: tOff steps to d0 +/- rung (|.|<=4 symbols) and |delta_beats| <= 1 and holds >= 3 frames.
P2: tOff == d0 on every beat while d_data is on a rung for >= 3 frames.
NEITHER: tOff moves but not to d0 +/- rung. UNINFORMATIVE: no 0->rung transition in the capture.
Frame ordinality: frames_by_marker (demod marks), frames_by_tref (slot-1 wraps), frames_by_index (records/12333)."""
import argparse, json, os, sys
import numpy as np
from ddrcap2_decode import load, decode
HERE = os.path.dirname(os.path.abspath(__file__))
RUNGS = (6176, 6240, 6299, 6363, 6432, 6489, 6548); P = 12333

def load_map():
    m = {}
    for l in open(os.path.join(HERE, 'offsetmap', 'tap3_word_to_offset.tsv')):
        if not l.startswith('#'):
            w, o = l.split(); m[int(w, 16)] = int(o)
    return m

def per_frame_offsets(a, d, m, skew=1):
    sign = ((a[:, 0] < 0).astype(np.uint32) << 1) | (a[:, 1] < 0).astype(np.uint32)
    mk = np.flatnonzero(d['mark_demod']); out = []
    for i in mk:
        s = i + skew
        if s + 16 > len(a): break
        w = 0
        for k in range(16): w |= int(sign[s + k]) << (30 - 2 * k)
        out.append((int(i), m.get(w)))
    return out

def analyse(a, m):
    d = decode(a); fr = per_frame_offsets(a, d, m); r = {}
    offs = [o for _, o in fr]
    zero_run = 0; onset_idx = None
    for k, (rec, o) in enumerate(fr):
        if o == 0: zero_run += 1
        elif o is not None and o in RUNGS and zero_run >= 3:
            onset_idx = k; break
        elif o is None: pass
        else: zero_run = 0
    r['frames_by_marker'] = len(fr); r['frames_by_index'] = int(len(a) // P)
    tr = d['tref']; trv = tr[tr >= 0]; r['frames_by_tref'] = int((np.diff(trv.astype(int)) < -12000).sum()) + 1 if len(trv) else 0
    if onset_idx is None:
        r.update(verdict='UNINFORMATIVE', onset_beat_data=None, onset_beat_toff=None, delta_beats=None, d0=None, toff_after=None, toff_delta_is_rung=False)
        return r
    onset_rec = fr[onset_idx][0]; r['onset_beat_data'] = onset_rec
    toff = d['toff'].astype(int); pre = toff[:onset_rec]; v, c = np.unique(pre, return_counts=True); d0 = int(v[c.argmax()]); r['d0'] = d0
    moved = np.flatnonzero(toff != d0); moved = moved[moved >= max(0, onset_rec - 3 * P)]
    if len(moved) == 0:
        after_rung = sum(1 for _, o in fr[onset_idx:onset_idx + 3] if o in RUNGS) >= 3
        r.update(onset_beat_toff=None, delta_beats=None, toff_after=d0, toff_delta_is_rung=False, verdict='P2' if after_rung else 'UNINFORMATIVE'); return r
    ob = int(moved[0]); r['onset_beat_toff'] = ob; r['delta_beats'] = ob - onset_rec
    after = int(np.bincount(toff[ob:ob + 3 * P]).argmax()); r['toff_after'] = after
    delta = (after - d0) % 12320; delta = min(delta, 12320 - delta)
    is_rung = any(abs(delta - g) <= 4 for g in RUNGS); r['toff_delta_is_rung'] = bool(is_rung)
    held = (toff[ob:ob + 3 * P] == after).mean() >= 0.95
    r['verdict'] = 'P1' if (is_rung and abs(r['delta_beats']) <= 1 and held) else 'NEITHER'
    return r

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('capture'); ap.add_argument('--out', required=True)
    x = ap.parse_args(); r = analyse(load(x.capture), load_map())
    json.dump(r, open(x.out + '.json', 'w'), indent=1); print(json.dumps(r, indent=1)); return 0

if __name__ == '__main__':
    sys.exit(main())
```

- [ ] **Step 4: Run → 4 passed.**

- [ ] **Step 5: The arm (rig unit), then the verdict**

```bash
cd two_jup && bash launch_rig_unit.sh beatcap2-sel6-$(date +%H%M%S) beat_tap_capture.sh SEL=6 OUT=$PWD/beatcap/$(date +%Y%m%d_%H%M%S)_sel6
# ~8 min. Then:
C=beatcap/<ts>_sel6
python3 ddrcap2_decode.py $C/onset.bin --summary; python3 ddrcap2_pc.py $C/onset.bin --sel 6      # Tier-2 must PASS on THIS capture too
python3 ddrcap2_beat_analysis.py $C/onset.bin --out $C/onset_verdict
python3 ddrcap2_beat_analysis.py $C/mid.bin   --out $C/mid_verdict
```
Read-out rules (spec §6, frozen): the verdict field is the answer. If `onset.bin` is UNINFORMATIVE (window missed the onset) but `mid.bin` shows the displaced state, report the tOff behaviour in the displaced state (P2-style "holds at d0 while displaced" is still decisive; P1 needs the transition). Cross-arm tOff non-null: this arm's `d0` vs Task 7's `d0` — record both. If the two `d0` are equal AND the sim mode is equal, the tOff non-null on silicon is NOT yet demonstrated and a "held steady" result is reported as **provisional** pending a third arm (say so explicitly; do not upgrade it).

- [ ] **Step 6: §82 and commit**

Append `## §82 DDRCAP-v2 burst capture: <P1|P2|NEITHER> [silicon]` with: d0, onset beats, delta_beats, toff_after, the three frame counts, the sidecar readings at onset (heldts/tref/runmax/threshold in the 8 records around `onset_beat_toff`), and the label. Then:
```bash
git add two_jup/beat_tap_capture.sh two_jup/tests/fake_anyssh.sh two_jup/tests/fake_arm.sh two_jup/ddrcap2_beat_analysis.py two_jup/tests/test_ddrcap2_beat_analysis.py two_jup/beatcap/*/{run.log,meta.txt,errps.csv,*_verdict.json} two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "DDRCAP2 §82: pre-registered sel6 burst capture verdict (marker-moves vs data-moves)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

