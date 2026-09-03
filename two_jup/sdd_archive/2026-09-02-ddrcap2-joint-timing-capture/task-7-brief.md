### Task 7: Tier-2 silicon positive controls (one arm, five captures) + one-shot capture script

**Files:**
- Create: `two_jup/ddrcap2_capture.sh`, `two_jup/ddrcap2_pc.py`, `two_jup/tests/test_ddrcap2_pc.py`
- Output: `two_jup/ddrcap2_pc/<ts>/sel{6,12,13,14,15}.bin` + `pc.log`; §81 addendum

**Interfaces:**
- `ddrcap2_capture.sh SEL NAME` (env `B`, `SZ` default 134217728, `OUT`): sets `0x10C=(SEL<<16)|3`, verifies `0x20C` golden, captures, host-stat-before-delete, records pre/post capTAP in `OUT/meta.txt`. No arm inside (runs on the current arm).
- `ddrcap2_pc.py FILE --sel N` → per-channel PASS/FAIL lines and `TIER2 sel<N> PASS|FAIL`. Rules: liveness (not constant, not a counter: ddrcap_pc_large parts 1 & 4 via `--v1compat`), marker cadence 1/frame, slot cycling ≥ 99 %, toff ∈ [0,12332] steady ≥ 95 %; sel12: ≥ 0.5 peaks/frame above half-max; sel13: countReg not constant and underflow bit mean 0.25±0.03 (4 records/symbol); sel14: not constant, not ramp; sel15: RhCtr < 32 and nonzero, push/pop advance. Records `toff mode` as `d0` for the cross-arm non-null.

- [ ] **Step 1: Failing test for the PC scorer (synthetic)**

```python
# two_jup/tests/test_ddrcap2_pc.py
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
```

- [ ] **Step 2: Run → ImportError.**

- [ ] **Step 3: Write the PC scorer and the capture script**

```python
#!/usr/bin/env python3
"""ddrcap2_pc.py FILE --sel N -- Tier-2 silicon positive controls (spec sec 4). Prints PASS/FAIL per rule."""
import argparse, sys
import numpy as np
from ddrcap2_decode import load, decode

def _ramp(x):
    d = np.diff(x[:200000].astype(np.int32)); v, c = np.unique(d, return_counts=True); return c.max() / len(d) >= 0.95

def check_common(a):
    d = decode(a); n = len(a); r = {}
    r['not_constant_IQ'] = len(np.unique(a[:200000, 0])) > 100
    r['not_ramp_IQ'] = not _ramp(a[:, 0])
    md = np.flatnonzero(d['mark_demod']); g = np.diff(md)
    r['demod_marks_periodic'] = len(md) > 10 and (np.abs(g - np.median(g)) <= 2).mean() >= 0.95
    r['slots_cycle'] = (np.diff(d['slot'].astype(int)) % 4 == 1).mean() >= 0.99
    t = d['toff']; v, c = np.unique(t, return_counts=True); r['d0'] = int(v[c.argmax()])
    r['toff_range_steady'] = r['d0'] <= 12332 and c.max() / n >= 0.95
    tr = d['tref'][d['tref'] >= 0]; dt = np.diff(tr.astype(int))
    r['tref_monotone'] = len(tr) > 100 and ((dt > 0) | (dt < -12000)).mean() >= 0.95
    return r

def check_sel(a, sel):
    d = decode(a); r = {}
    if sel == 12:
        mag = (a[:, 0].astype(np.uint16).astype(np.uint32) << 16) | a[:, 1].astype(np.uint16)
        fr = max(1, int(d['mark_demod'].sum())); r['peaks_per_frame_ok'] = 0.5 <= (mag > mag.max() / 2).sum() / fr <= 3
    elif sel == 13:
        uf = (a[:, 0].astype(np.uint16) >> 15) & 1; cnt = a[:, 0].astype(np.uint16) & 0x7FF
        r['countreg_not_constant'] = len(np.unique(cnt[:200000])) > 8
        r['underflow_per_symbol'] = abs(uf.mean() - 0.25) <= 0.03       # 4 records/symbol at enb_1_2_0 -> one underflow per 4 records (Task 4 §80)
    elif sel == 14:
        r['not_constant'] = len(np.unique(a[:200000, 0])) > 100; r['not_ramp'] = not _ramp(a[:, 0])
    elif sel == 15:
        ctr = a[:, 0].astype(np.uint16) >> 8; push = (a[:, 0].astype(np.uint16) >> 3) & 0x1F; pop = a[:, 1].astype(np.uint16) >> 11
        r['rhctr_bounded_nonzero'] = 0 < ctr.max() < 32; r['push_pop_advance'] = len(np.unique(push)) > 4 and len(np.unique(pop)) > 4
    return r

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('file'); ap.add_argument('--sel', type=int, required=True)
    x = ap.parse_args(); a = load(x.file)
    r = check_common(a); r.update(check_sel(a, x.sel)); ok = True
    for k, v in r.items():
        if k == 'd0': print(f"  d0 (toff mode) = {v}"); continue
        print(f"  {k:28s} {'PASS' if v else 'FAIL'}"); ok &= bool(v)
    print(f"TIER2 sel{x.sel} {'PASS' if ok else 'FAIL'}"); return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
```

```bash
#!/bin/bash
# ddrcap2_capture.sh SEL NAME -- one 512 MB capture of one selector on the CURRENT arm (no arm inside).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=${W:-$D/anyssh.sh}; B=${B:-10.0.0.148}; SEL=${1:?SEL}; NAME=${2:?NAME}
SZ=${SZ:-134217728}; GOLD=BCF94856; OUT=${OUT:-$D/ddrcap2_pc/$(date +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }; norm(){ printf %s "$1" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F'; }
DRA='/sys/kernel/debug/iio/iio:device0/direct_reg_access'
rd(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo $1 > $DRA; cat $DRA" 2>/dev/null | tr -d '\r' | tail -1; }
wr(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo '$1 $2' > $DRA" >/dev/null 2>&1; }
[ -e "$OUT/$NAME.bin" ] && { log "REFUSE: $OUT/$NAME.bin exists"; exit 5; }
wr 0x10C "0x$(printf %X $(( (SEL<<16) | 3 )))"; sleep 2
C0=$(rd 0x20C); [ "$(norm "$C0")" = "$GOLD" ] || { log "ABORT: capTAP $C0 != golden"; exit 4; }
$W $B "cd /tmp && rm -f g.bin && iio_readdev -b 4096 -s $SZ axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/g.bin 2>/dev/null; stat -c 'BOARD %s' /tmp/g.bin" 2>/dev/null | tail -1 | tee -a "$OUT/run.log"
$W $B "cat /tmp/g.bin" > "$OUT/$NAME.bin" 2>/dev/null; GOT=$(stat -c %s "$OUT/$NAME.bin" 2>/dev/null || echo 0)
[ "$GOT" -ge $(( SZ*4*9/10 )) ] && $W $B "rm -f /tmp/g.bin" >/dev/null 2>&1 || log "SHORT: $GOT bytes, board file kept"
C1=$(rd 0x20C); log "$NAME sel$SEL bytes=$GOT pre=$C0 post=$C1"; echo "$NAME sel=$SEL bytes=$GOT pre=$C0 post=$C1" >> "$OUT/meta.txt"
[ "$(norm "$C1")" = "$GOLD" ] || log "WARN: post capTAP not golden -- capture not credited"
```

- [ ] **Step 4: Run the unit tests → 3 passed. Then the five captures on the post-flash arm (one rig unit)**

```bash
cd two_jup && OUT=$PWD/ddrcap2_pc/$(date +%Y%m%d_%H%M%S) && export OUT
bash launch_rig_unit.sh ddrcap2-pc-$(date +%H%M%S) /bin/bash -c "for s in 6 12 13 14 15; do OUT=$OUT bash $PWD/ddrcap2_capture.sh \$s sel\$s || exit \$?; sleep 2; done"
# after it finishes (~15 min): 
for s in 6 12 13 14 15; do python3 ddrcap2_pc.py $OUT/sel$s.bin --sel $s | tee -a $OUT/pc.log; done
```
Expected: `TIER2 sel6 PASS` … `TIER2 sel15 PASS`. Record `d0` from sel6; the cross-arm non-null for tOff is satisfied when `d0` differs from the sim gate's tOff mode (§80) OR from the next arm's `d0` (Task 8's arm). A FAIL marks that channel DEAD for the campaign (it may not report), and is written up, not fixed on the rig.

- [ ] **Step 5: §81 addendum + commit**

```bash
git add two_jup/ddrcap2_capture.sh two_jup/ddrcap2_pc.py two_jup/tests/test_ddrcap2_pc.py two_jup/ddrcap2_pc/*/pc.log two_jup/ddrcap2_pc/*/meta.txt two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "DDRCAP2 Tier-2 silicon positive controls: five selectors on one arm, per-channel verdicts (§81)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

