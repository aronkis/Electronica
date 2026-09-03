#!/usr/bin/env python3
"""tel_compare.py <live.npz> <sim.npz> -- register-for-register comparison of
hardware PD telemetry vs the Simulink harness replay of the same data.

Alignment: the sim consumed exactly the live dI/dQ sequence, so records align
by index after locating the sim's first record in the live sequence (exact
dI match run). Counter fields (tRef/tRefLong/taRef/symCtr) are compared as
DELTAS (absolute phase is arbitrary in the harness); decision fields
(tOff/accOff/heldTs-deltas/flags) compare directly after offset removal.
Reports per-field mismatch counts and the first divergence with context."""
import sys
import numpy as np

live = np.load(sys.argv[1]); simz = np.load(sys.argv[2])
lI = live['dI'].astype(np.int64); sI = simz['dI'].astype(np.int64)
lQ = live['dQ'].astype(np.int64); sQ = simz['dQ'].astype(np.int64)

# locate sim start in live by exact 64-symbol run match
K = 64
pat_i, pat_q = sI[:K], sQ[:K]
off = -1
for j in range(len(lI) - K):
    if np.array_equal(lI[j:j+K], pat_i) and np.array_equal(lQ[j:j+K], pat_q):
        off = j
        break
assert off >= 0, 'sim start not found in live stream (drive mismatch?)'
n = min(len(sI), len(lI) - off)
print(f'aligned: sim[0:{n}] == live[{off}:{off+n}]')
assert np.array_equal(sI[:n], lI[off:off+n]), 'dI diverges after alignment!'

import os
WARM = int(os.environ.get('TEL_WARM', 4600))  # Delay10 pipe = 4532 symbols;
# decision regs (tOff/accOff/armed) are valid after ~1 frame — set TEL_WARM
# lower for short windows
report = []
for f, mode in [('tOff','abs'), ('accOff','abs'), ('armed','abs'), ('succ','abs'),
                ('done','abs'), ('newPk','abs'), ('thrEx','abs'), ('sync','abs'),
                ('vPop','abs'), ('fifoEnt','abs'), ('runMax','abs'),
                ('tRef','delta'), ('tRefLong','delta'), ('taRef','delta'),
                ('heldTs','delta')]:
    lv = live[f].astype(np.int64)[off:off+n]
    sv = simz[f].astype(np.int64)[:n]
    if mode == 'delta':
        lv, sv = np.diff(lv), np.diff(sv)
    m = lv[WARM:] != sv[WARM:]
    bad = int(m.sum())
    first = int(np.argmax(m)) + WARM if bad else -1
    report.append((f, mode, bad, first))
    tagstr = 'OK ' if bad == 0 else 'DIFF'
    print(f'{tagstr} {f:>9} ({mode:>5}): mismatches {bad}/{n-WARM}' +
          (f'  first at rec {first} (live[{off+first}])' if bad else ''))
worst = [r for r in report if r[2] > 0]
print('\nVERDICT:', 'BIT-EXACT MATCH (post warm-up)' if not worst else
      f'{len(worst)} fields diverge — earliest at rec {min(r[3] for r in worst)}')
