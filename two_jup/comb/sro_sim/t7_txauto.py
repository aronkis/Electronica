#!/usr/bin/env python3
"""[sim] Task 7 H-A free test: does the TILED TX stimulus itself carry a
32-symbol periodic structure at the SYMBOL rate, under the SAME pipeline that
task 6 applied to the receiver symbol stream (decimate to 1 sample/symbol,
CFO-invariant differential d[n]=s[n]*conj(s[n-1]), remove mean, normalise,
circular cross-correlation between consecutive frames)?

tx5.iq frames are int16-identical, so the frame-to-frame cross-correlation IS
the circular autocorrelation of one frame -- exactly what the tiled SRO
stimulus presents to the receiver.
"""
import numpy as np, sys
P, SPS = 49332, 4
raw = np.fromfile(sys.argv[1] if len(sys.argv)>1 else 'tx5.iq', dtype='<i2')
x = raw[0::2].astype(np.float64) + 1j*raw[1::2].astype(np.float64)
nfr = len(x)//P
fr = x[2*P:3*P]                       # a settled frame
for ph in range(SPS):
    s = fr[ph::SPS]                   # 12333 symbols
    d = s[1:]*np.conj(s[:-1])
    d = d - d.mean()
    d = d/np.sqrt((np.abs(d)**2).mean())
    n = len(d)
    R = np.fft.ifft(np.fft.fft(d)*np.conj(np.fft.fft(d)))/n     # circular autocorr
    rho = np.abs(R)
    lags = [0,1,2,4,8,16,31,32,33,64,96,128]
    print(f'phase {ph}: sym_power={np.mean(np.abs(s)**2):.3e} ' +
          ' '.join(f'l{l}={rho[l]:.3f}' for l in lags))
    top = np.argsort(rho[1:n//2])[::-1][:5]+1
    print(f'          top non-zero lags: ' + ', '.join(f'{l}({rho[l]:.3f})' for l in top))
