#!/usr/bin/env python3
"""Verdict: does the bit-true RTL receiver, fed the CAPTURE-branch samples,
reproduce the +32-strobe displacement at the episode air-instants?
Input: sim_byte_taps _pd.txt (I,Q,sync per PD strobe) from the ev1 replay.
Live truth: sync spacing 2298/2266@onset(t~0.83s), 1101@recovery(t~1.0s),
repeat at ~2.31/2.48s; all other spacings 1133."""
import sys
import numpy as np

pd = sys.argv[1] if len(sys.argv) > 1 else '/dev/shm/simtap/ev1_pd.txt'
sync = []
with open(pd) as f:
    for k, line in enumerate(f):
        # format: I,Q,sync
        if line.rstrip().endswith(',1'):
            sync.append(k)
sync = np.array(sync)
print(f'sim strobes: {k+1}, sync pulses: {len(sync)}')
ds = np.diff(sync)
u, c = np.unique(ds, return_counts=True)
print('sim inter-sync spacing histogram:', dict(zip(u.tolist(), c.tolist())))
print('\nnon-1133 spacings with strobe positions (t = strobe/240k):')
for i in np.where(ds != 1133)[0]:
    print(f'  gap {ds[i]} at strobe {sync[i]}..{sync[i+1]} (t={sync[i]/240000:.3f}s)')
# live episode air-times for ev1 (tap-domain): onset 0.831/2.307, recovery 0.996/2.477
print('\nLIVE truth (ev1): onsets ~0.83s & ~2.31s (+32), recoveries ~1.00s & ~2.48s (-32)')
disp = np.any((ds > 2200) & (ds < 2400)) or np.any((ds > 1090) & (ds < 1110))
print('\nVERDICT:', 'REPRODUCED — displacement present in RTL replay (data/RTL mechanism)'
      if disp else 'NOT REPRODUCED — RTL fed captured samples stays metronomic (fork/physical divergence)')
