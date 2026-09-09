#!/usr/bin/env python3
"""[sim] Task 7: is task 6's rho(0)=0.50 / rho(+-32)=0.50 double peak an artefact of
how the receiver symbol dump was SEGMENTED into frames?

h_m10_ring.txt is one row per beat over frames 37.00-42.07 of the -10 ppm leg.  Take
the Rate_Handle validOut symbols and segment them two ways:
  (A) by VALID COUNT   -- 12333 output symbols per frame (the epoch the receiver uses)
  (B) by INPUT SAMPLE  -- sidx // 49332 (the input-sample frame bucket)
then run task 6's pipeline (differential, mean-removed, normalised, circular
cross-correlation of consecutive frames) on each.  A segmentation that alternates
between two alignments produces exactly a 50/50 bimodal split.
"""
import numpy as np, collections
rows = []
for ln in open('h_m10_ring.txt'):
    if ln.startswith('#'): continue
    a = ln.rstrip().split(',')
    if len(a) < 15: continue
    if int(a[7]):                      # vout
        rows.append((int(a[0]), int(a[8]), int(a[9])))   # sidx, outI, outQ
print(f'{len(rows)} validOut symbols')
sidx = np.array([r[0] for r in rows]); y = np.array([r[1] + 1j*r[2] for r in rows], dtype=complex)

def score(frames, tag):
    out = []
    for k in range(len(frames)-1):
        a, b = frames[k], frames[k+1]
        n = min(len(a), len(b))
        if n < 4000: continue
        def prep(z):
            d = z[1:n]*np.conj(z[:n-1]); d = d - d.mean()
            return d/np.sqrt((np.abs(d)**2).mean())
        A, B = prep(a), prep(b)
        m = len(A)
        R = np.abs(np.fft.ifft(np.fft.fft(B)*np.conj(np.fft.fft(A)))/m)
        lag = int(np.argmax(R)); 
        out.append((k, lag, R[0], R[32 % m], R[(m-32) % m], R.max()))
    print(f'  [{tag}] pairs={len(out)}')
    for k, lag, r0, rp, rm, rmax in out:
        print(f'    pair {k}->{k+1}: argmax_lag={lag if lag<m//2 else lag-m:+5d} '
              f'rho(0)={r0:.3f} rho(+32)={rp:.3f} rho(-32)={rm:.3f} max={rmax:.3f}')

# (A) by valid count
NA = 12333
fa = [y[i*NA:(i+1)*NA] for i in range(len(y)//NA)]
score(fa, 'A: segmented by VALID COUNT (12333/frame)')
# (B) by input-sample bucket
buck = collections.defaultdict(list)
for s, v in zip(sidx, y): buck[s//49332].append(v)
ks = sorted(buck)[1:-1]
fb = [np.array(buck[k]) for k in ks]
print('  frame lengths (B):', [len(f) for f in fb])
score(fb, 'B: segmented by INPUT SAMPLE (sidx//49332)')
