#!/usr/bin/env python3
"""gonogo_verdict.py <capture.iq> — fast link go/no-go from a raw Rx capture.
Method: dec2 -> wide-range 4th-power CFO removal -> correlate against the known
golden frame -> LS-fit a 65-tap channel on the best frame -> residual EVM.
Verdict: GO if residual < 10% (good-boot measured 5.7%), NOGO if > 12% (bad 16.3%).
Exit code: 0=GO, 1=NOGO, 2=NOSIGNAL/error. Prints one summary line."""
import sys
import numpy as np

CAP = sys.argv[1]
GOLD = '/mnt/onetb/scratch/qpsk_variants/two_jup/golden_tx.iq'
FR = 9064
L = 65

try:
    d = np.fromfile(CAP, dtype=np.int16)
    I = d[0::2].astype(float); Q = d[1::2].astype(float)
    n = min(len(I), len(Q))
    y = (I[:n] + 1j*Q[:n])[::2]                      # dec2 to golden domain
    if np.sqrt(np.mean(np.abs(y)**2)) < 5:
        print('VERDICT=NOSIGNAL rms<5'); sys.exit(2)
    y = y - y.mean(); y = y/np.sqrt(np.mean(np.abs(y)**2))
    g = np.fromfile(GOLD, dtype=np.int16)
    x = (g[0::2].astype(float) + 1j*g[1::2].astype(float))[:FR]
    x = x/np.sqrt(np.mean(np.abs(x)**2))
    # wide-range CFO (4th power, +-50 kHz)
    fs = 1.92e6
    N = 1 << min(17, int(np.log2(len(y))))
    w = y[:N]**4
    W = np.fft.fftshift(np.abs(np.fft.fft(w*np.hanning(N), 1 << 18)))
    f = np.linspace(-fs/2, fs/2, 1 << 18)
    m = np.abs(f) < 200e3; W2 = W.copy(); W2[~m] = 0
    cfo = f[np.argmax(W2)]/4
    y = y*np.exp(-2j*np.pi*cfo/fs*np.arange(len(y)))
    # frame sync via FFT correlation
    M = min(len(y), 200000)
    yv = y[:M]
    F = 1 << int(np.ceil(np.log2(M)))
    C = np.abs(np.fft.ifft(np.fft.fft(yv, F)*np.conj(np.fft.fft(x, F))))[:M-FR]
    pk = int(np.argmax(C))
    # LS channel fit on 3 frames starting at pk (average residual)
    half = (L-1)//2
    # convolution (Toeplitz) matrix rows: valid region
    idx = np.arange(L-1, FR)
    X = np.zeros((len(idx), L), dtype=complex)
    for t in range(L):
        X[:, t] = x[idx - t]
    XtXi = np.linalg.pinv(X.conj().T @ X) @ X.conj().T
    evs = []
    for q in range(3):
        s = pk + q*FR - half
        if s < 0 or s+FR > len(y):
            continue
        yy = y[s:s+FR][L-1:]
        h = XtXi @ yy
        r = yy - X @ h
        evs.append(np.linalg.norm(r)/np.linalg.norm(yy))
    if not evs:
        print('VERDICT=NOSIGNAL noframes'); sys.exit(2)
    ev = float(np.median(evs))
    corr_ok = C[pk] > 3*np.median(C)
    verdict = 'GO' if (ev < 0.10 and corr_ok) else ('NOGO' if ev > 0.12 or not corr_ok else 'MARGINAL')
    print(f'VERDICT={verdict} residEVM={100*ev:.1f}% cfo={cfo:+.0f}Hz corr={C[pk]/np.median(C):.1f}x')
    sys.exit(0 if verdict == 'GO' else 1)
except Exception as e:
    print(f'VERDICT=ERROR {e}'); sys.exit(2)
