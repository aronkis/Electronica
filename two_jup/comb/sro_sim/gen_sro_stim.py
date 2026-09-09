#!/usr/bin/env python3
"""[sim] COMB32 SRO stimulus generator (2026-09-03).

Takes a TX-RTL capture (int16 interleaved I,Q at 4 sps, produced by
`Vwrap_byte_sro txcap`), verifies it is exactly frame-periodic with period
49332 samples, and emits resampled streams y[n] = x(n*(1+s)) using a
32-tap Kaiser-windowed sinc with modular (periodic) source indexing.

s = 0 traverses the identical code path and must reproduce the source to
0 LSB (the sinc kernel collapses to a delta at integer offsets) -- asserted.

Optional: CFO rotation (Hz at Fs=61.44e6) and AWGN at a stated Es/N0.
Noise convention: Es = mean|x|^2 * SPS (energy per QPSK symbol, 4 sps),
N0 spread over the full 61.44 MHz complex bandwidth.
"""
import argparse, numpy as np

P = 49332           # samples per air frame
FS = 61.44e6
SPS = 4
NTAP = 32           # even; taps at offsets -NTAP/2+1 .. NTAP/2
BETA = 8.0

def kaiser_sinc(frac):
    """frac: array of fractional delays in [0,1). Returns (len(frac), NTAP)."""
    k = np.arange(-NTAP // 2 + 1, NTAP // 2 + 1)          # NTAP taps
    d = frac[:, None] - k[None, :]                         # distance
    h = np.sinc(d)
    w = np.i0(BETA * np.sqrt(np.maximum(0.0, 1 - (d / (NTAP / 2)) ** 2))) / np.i0(BETA)
    return h * w

def resample_periodic(x, s, nout, chunk=1 << 19, wrap=True):
    n0 = len(x)
    out = np.empty(nout, dtype=np.complex128)
    k = np.arange(-NTAP // 2 + 1, NTAP // 2 + 1)
    for a in range(0, nout, chunk):
        b = min(a + chunk, nout)
        t = np.arange(a, b, dtype=np.float64) * (1.0 + s)
        i = np.floor(t).astype(np.int64)
        f = t - i
        H = kaiser_sinc(f)
        idx = (i[:, None] + k[None, :])
        idx = (idx % n0) if wrap else np.clip(idx, 0, n0 - 1)
        out[a:b] = np.einsum('ij,ij->i', H, x[idx])
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src'); ap.add_argument('out')
    ap.add_argument('--ppm', type=float, default=0.0)
    ap.add_argument('--frames', type=int, default=165)
    ap.add_argument('--cfo', type=float, default=0.0, help='Hz')
    ap.add_argument('--esn0', type=float, default=None, help='dB, omit for noiseless')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--no-tile', action='store_true',
                    help='[T7] the source is a LONG non-repeating capture: do not '
                         'assert frame-periodicity and do not tile/wrap. Instead '
                         'CERTIFY that no two consecutive frames are int16-identical, '
                         'and resample the whole capture with edge clamping.')
    a = ap.parse_args()

    raw = np.fromfile(a.src, dtype='<i2')
    x = raw[0::2].astype(np.float64) + 1j * raw[1::2].astype(np.float64)
    if a.no_tile:
        nfr = len(x) // P
        assert nfr >= 3, f'need >=3 frames in {a.src}, have {nfr}'
        # inverse of the tiling assert: NO two consecutive frames may be identical
        nrep = sum(1 for f in range(nfr - 1)
                   if np.abs(x[f*P:(f+1)*P] - x[(f+1)*P:(f+2)*P]).max() == 0)
        print(f'non-tiled source: {nfr} frames, consecutive-identical pairs = {nrep}')
        assert nrep == 0, 'source IS frame-periodic -- this is not a non-repeating capture'
        s = a.ppm * 1e-6
        # keep the read index inside the capture: t_max = (nout-1)*(1+s) + NTAP/2
        nmax = int((len(x) - NTAP) / (1.0 + abs(s))) - 1
        nout = min(a.frames, nmax // P) * P
        y = resample_periodic(x, s, nout, wrap=False)
        if s == 0.0:
            err = np.abs(y - x[:nout]).max()
            print(f'  s=0 identity check: max|y-x| = {err:.3e} LSB')
            assert err < 1.0
        if a.cfo != 0.0:
            y = y * np.exp(2j * np.pi * a.cfo * np.arange(nout) / FS)
        if a.esn0 is not None:
            rng = np.random.default_rng(a.seed)
            es = np.mean(np.abs(y) ** 2) * SPS
            n0 = es / (10 ** (a.esn0 / 10.0))
            sig = np.sqrt(n0 / 2.0)
            y = y + rng.normal(0, sig, nout) + 1j * rng.normal(0, sig, nout)
        iq = np.empty(2 * nout, dtype='<i2')
        clip = int(np.sum(np.abs(np.concatenate([y.real, y.imag])) > 32767))
        iq[0::2] = np.clip(np.round(y.real), -32768, 32767)
        iq[1::2] = np.clip(np.round(y.imag), -32768, 32767)
        iq.tofile(a.out)
        print(f'WROTE {a.out} nsamp={nout} frames={nout//P} ppm={a.ppm} cfo={a.cfo} '
              f'esn0={a.esn0} clip={clip} rms={np.sqrt(np.mean(np.abs(y)**2)):.1f}')
        return
    # frame-periodicity check on the raw int16 stream, skipping 1 warm-up frame
    nfr = len(x) // P
    assert nfr >= 3, f'need >=3 frames in {a.src}, have {nfr}'
    per = None
    for f in range(1, nfr - 1):
        d = np.abs(x[f * P:(f + 1) * P] - x[(f + 1) * P:(f + 2) * P]).max()
        if d == 0:
            per = f
            break
    assert per is not None, 'TX capture is NOT frame-periodic -- tiling invalid'
    xp = x[per * P:(per + 1) * P]
    print(f'periodic from frame {per}; period {P} samples verified exact (int16)')

    nout = a.frames * P
    s = a.ppm * 1e-6
    y = resample_periodic(xp, s, nout)
    if s == 0.0:
        ref = np.tile(xp, a.frames)
        err = np.abs(y - ref).max()
        print(f'  s=0 identity check: max|y-x| = {err:.3e} LSB')
        assert err < 1.0
    if a.cfo != 0.0:
        y = y * np.exp(2j * np.pi * a.cfo * np.arange(nout) / FS)
    if a.esn0 is not None:
        rng = np.random.default_rng(a.seed)
        es = np.mean(np.abs(y) ** 2) * SPS
        n0 = es / (10 ** (a.esn0 / 10.0))
        sig = np.sqrt(n0 / 2.0)
        y = y + rng.normal(0, sig, nout) + 1j * rng.normal(0, sig, nout)
    iq = np.empty(2 * nout, dtype='<i2')
    clip = int(np.sum(np.abs(np.concatenate([y.real, y.imag])) > 32767))
    iq[0::2] = np.clip(np.round(y.real), -32768, 32767)
    iq[1::2] = np.clip(np.round(y.imag), -32768, 32767)
    iq.tofile(a.out)
    print(f'WROTE {a.out} nsamp={nout} frames={a.frames} ppm={a.ppm} cfo={a.cfo} '
          f'esn0={a.esn0} clip={clip} rms={np.sqrt(np.mean(np.abs(y)**2)):.1f}')

if __name__ == '__main__':
    main()
