#!/usr/bin/env python3
"""Deep dive: lockstep cross-checks, tap-loss anatomy, episode microscope."""
import sys
import numpy as np

z = np.load(sys.argv[1])
tRef = z['tRef'].astype(np.int64); tOff = z['tOff'].astype(np.int64)
sync = z['sync'].astype(bool); done = z['done'].astype(bool)
newPk = z['newPk'].astype(bool); succ = z['succ'].astype(bool)
thrEx = z['thrEx'].astype(bool); armed = z['armed'].astype(bool)
corr = z['corr'].astype(np.int64)
heldTs = z['heldTs'].astype(np.int64); tRefLong = z['tRefLong'].astype(np.int64)
symCtr = z['symCtr'].astype(np.int64); sw = z['streamword'].astype(np.int64)
taRef = z['taRef'].astype(np.int64); accOff = z['accOff'].astype(np.int64)
n = len(tRef)

# 1. cross-lockstep: does PD's free counter EVER diverge from tap symbol count?
d_l = np.diff(tRefLong - symCtr)
d_r = np.mod(np.diff(tRef - tRefLong), 1133)
print(f'LOCKSTEP tRefLong-symCtr divergences: {np.count_nonzero(d_l)}')
for i in np.where(d_l != 0)[0][:10]:
    print(f'  rec {i}: (tRefLong-symCtr) {tRefLong[i]-symCtr[i]} -> {tRefLong[i+1]-symCtr[i+1]} at symCtr {symCtr[i]}')
print(f'LOCKSTEP (tRef-tRefLong) mod1133 changes: {np.count_nonzero(d_r)}')

# 2. tap-loss anatomy: joint (dSym, dWord)
dS = np.diff(symCtr); dW = np.diff(sw)
print('\njoint (dSymCtr,dStreamword) top pairs:')
pairs, cnt = np.unique(np.stack([dS, dW]), axis=1, return_counts=True)
order = np.argsort(-cnt)
for j in order[:10]:
    print(f'  dSym={pairs[0,j]:>3} dWord={pairs[1,j]:>4}  x{cnt[j]}')
# strobe-stall check: dSym==1 but dWord>10
st = np.where((dS == 1) & (dW > 10))[0]
print(f'strobe-stall candidates (dSym=1, dWord>10): {len(st)}')
for i in st[:10]:
    print(f'  rec {i}: dWord={dW[i]} at symCtr {symCtr[i]} (t={sw[i]/8/240000:.4f}s)')
# beats-per-symbol drift around episodes: words per symbol via regression per 10k-sym chunk
print('\nwords/symbol per 0.25s chunk (nominal 8.000):')
for c0 in range(0, n - 60000, 60000):
    c1 = c0 + 60000
    r = (sw[c1] - sw[c0]) / (symCtr[c1] - symCtr[c0])
    print(f'  sym[{symCtr[c0]}..{symCtr[c1]}] t={c0/240000:.2f}s: {r:.4f}')

# 3. sync spacing in SYMBOL units
si = np.where(sync)[0]
ds_sym = np.diff(symCtr[si])
u, c = np.unique(ds_sym, return_counts=True)
print(f'\nsync spacing (symCtr units): ' + ', '.join(f'{a}x{b}' for a, b in zip(u, c)))
for i in np.where(ds_sym != 1133)[0]:
    print(f'  gap {ds_sym[i]} ending symCtr {symCtr[si[i+1]]} (t={si[i+1]/240000:.3f}s) tOff {tOff[si[i]]}->{tOff[si[i+1]]}')

# 4. episode microscope: records around each tOff change
ch = np.where(np.diff(tOff) != 0)[0]
for e in ch:
    print(f'\n== microscope: tOff {tOff[e]}->{tOff[e+1]} at rec {e} symCtr {symCtr[e]} ==')
    # find surrounding newPk/done landmarks
    lo = max(0, e - 6)
    for i in range(lo, min(n, e + 7)):
        print(f'  r{i} sym {symCtr[i]} tRef {tRef[i]:>4} tOff {tOff[i]:>4} '
              f'corr {corr[i]:>11} done={int(done[i])} newPk={int(newPk[i])} succ={int(succ[i])} '
              f'thr={int(thrEx[i])} sync={int(sync[i])} armed={int(armed[i])} '
              f'taRef {taRef[i]:>4} accOff {accOff[i]:>4} heldTs {heldTs[i]}')

# 5. correlation-peak positions independent of PS: use newPk stream
npi = np.where(newPk)[0]
print(f'\nnewPk count {len(npi)}')
# peak phase = symCtr mod 1133 at newPk (where in the frame peaks land)
ph = np.mod(tRef[npi], 1133)
# report distinct phase runs
runs = []
cur = ph[0]; c0 = 0
for j in range(1, len(ph)):
    if abs(int(ph[j]) - int(cur)) > 2:
        runs.append((c0, j - 1, int(cur)))
        c0 = j; cur = ph[j]
runs.append((c0, len(ph) - 1, int(cur)))
print('newPk tRef-phase runs (start_idx,end_idx,phase, t_start):')
for a, b, p in runs[:30]:
    print(f'  peaks[{a}..{b}] phase~{p} t={npi[a]/240000:.3f}s..{npi[b]/240000:.3f}s')
