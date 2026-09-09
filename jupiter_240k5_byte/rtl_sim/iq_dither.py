#!/usr/bin/env python3
"""iq_dither.py -- SAMPLE-boundary injection hook for the replay harness
(STAGE-1d of the 2026-08-13 staged task). Applies a parameterized PERIODIC
disturbance to an int16-interleaved I/Q capture before it enters the bit-true
netlist replay:

  --type timing    periodic fractional-DELAY dither (stresses the symbol-sync
                   loop specifically):  y[n] = x(n + A*sin(2*pi*f*n/fs + phi0))
                   A in SAMPLES (peak), windowed-sinc (Kaiser) interpolation.
  --type resample  constant fractional resample offset: y[n] = x(n*(1+eps)),
                   eps = --amp (e.g. 1e-6). Same interpolator.
  --type phase     periodic phase dither: y[n] = x[n]*exp(j*A*sin(...)),
                   A in RADIANS peak.
  --type amp       periodic amplitude dither: y[n] = x[n]*(1+A*sin(...)).

  --cadence_hz F   dither frequency (Hz at --fs).
  --amp A          peak amplitude (samples / rad / fractional, per type).
  --phi0 DEG       dither start phase.
  --phase_drift R  linear dither-frequency drift, Hz per second (chirp), so the
                   dither phase walks relative to the frame grid.

Geometry: fs = 61.44 MS/s, frame = 49332 samples (f1536). 156 Hz -> period
393846 samples = 7.984 frames (the ~8-frame lattice candidate).

Format: flat little-endian interleaved int16 I,Q (pair.iq convention).
"""
import argparse
import sys

import numpy as np

I16 = np.iinfo(np.int16)
NTAP = 32          # windowed-sinc taps (even); delay support +/- NTAP/2 samples
BETA = 8.0


def load_iq(path):
    raw = np.fromfile(path, dtype="<i2").astype(np.float64)
    if raw.size % 2:
        raw = raw[:-1]
    return raw[0::2] + 1j * raw[1::2]


def save_iq(path, x):
    out = np.empty(x.size * 2, dtype=np.float64)
    out[0::2] = np.real(x)
    out[1::2] = np.imag(x)
    out = np.clip(np.round(out), I16.min, I16.max).astype("<i2")
    out.tofile(path)


def frac_delay(x, d, chunk=1 << 20):
    """y[n] = x(n + d[n]) via NTAP windowed-sinc, vectorized (chunked)."""
    n = x.size
    y = np.empty(n, dtype=complex)
    half = NTAP // 2
    kk = np.arange(NTAP)
    for s in range(0, n, chunk):
        e = min(s + chunk, n)
        dc = d[s:e]
        di = np.floor(dc).astype(np.int64)
        mu = dc - di                     # in [0,1)
        base = np.arange(s, e, dtype=np.int64) + di - (half - 1)
        win_arg = kk[None, :] - (half - 1) - mu[:, None]     # (m, NTAP)
        wk = np.i0(BETA * np.sqrt(np.clip(1 - (win_arg / half) ** 2, 0, None))) / np.i0(BETA)
        h = np.sinc(win_arg) * wk
        hs = h.sum(axis=1, keepdims=True)
        h /= np.where(hs == 0, 1, hs)    # DC-normalize per output sample
        acc = np.zeros(e - s, dtype=complex)
        for k in range(NTAP):
            idx = np.clip(base + k, 0, n - 1)
            acc += h[:, k] * x[idx]
        y[s:e] = acc
    return y


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("infile")
    ap.add_argument("outfile")
    ap.add_argument("--fs", type=float, default=61.44e6)
    ap.add_argument("--type", default="timing",
                    choices=["timing", "resample", "phase", "amp"])
    ap.add_argument("--cadence_hz", type=float, default=156.0)
    ap.add_argument("--amp", type=float, default=0.1)
    ap.add_argument("--phi0", type=float, default=0.0, help="deg")
    ap.add_argument("--phase_drift", type=float, default=0.0, help="Hz/s chirp")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    x = load_iq(args.infile)
    n = x.size
    t = np.arange(n) / args.fs
    ph = 2 * np.pi * (args.cadence_hz * t + 0.5 * args.phase_drift * t * t) \
        + np.deg2rad(args.phi0)

    if args.type == "timing":
        d = args.amp * np.sin(ph)
        y = frac_delay(x, d)
    elif args.type == "resample":
        d = args.amp * np.arange(n, dtype=np.float64)
        y = frac_delay(x, d)
    elif args.type == "phase":
        y = x * np.exp(1j * args.amp * np.sin(ph))
    else:  # amp
        y = x * (1.0 + args.amp * np.sin(ph))

    save_iq(args.outfile, y)
    print(f"wrote {args.outfile}: {n} samples type={args.type} "
          f"f={args.cadence_hz} amp={args.amp} phi0={args.phi0} "
          f"drift={args.phase_drift}")
    return 0


def selftest():
    fails = []
    fs = 61.44e6
    n = 400_000
    tvec = np.arange(n)
    fc = 1.0e6
    x = 8000.0 * np.exp(1j * 2 * np.pi * (fc / fs) * tvec)

    # 1. constant delay of 0.5 samples == phase shift of tone by 2pi*fc/fs*0.5
    y = frac_delay(x, np.full(n, 0.5))
    a = np.angle(np.vdot(x[100:-100], y[100:-100]))
    want = 2 * np.pi * fc / fs * 0.5
    print(f"[selftest] const 0.5-sample delay: tone phase {a:.5f} rad (want {want:.5f})")
    if abs(a - want) > 1e-3:
        fails.append("const delay phase wrong")
    # amplitude preserved
    g = np.mean(np.abs(y[100:-100])) / np.mean(np.abs(x[100:-100]))
    print(f"[selftest] gain through interpolator: {g:.5f} (want ~1)")
    if abs(g - 1) > 5e-3:
        fails.append("interpolator gain off")

    # 2. sinusoidal timing dither == phase modulation of the tone at f_dith
    A, fd = 0.2, 156.0 * 200      # scale fd so several periods fit in n
    ph = 2 * np.pi * fd * np.arange(n) / fs
    y = frac_delay(x, A * np.sin(ph))
    dphi = np.angle(y[2000:-2000] / x[2000:-2000])
    amp_meas = (dphi.max() - dphi.min()) / 2
    want = 2 * np.pi * fc / fs * A
    print(f"[selftest] dither PM depth {amp_meas:.6f} rad (want {want:.6f})")
    if abs(amp_meas - want) > 0.05 * want + 1e-4:
        fails.append("dither depth wrong")

    if fails:
        print("SELFTEST FAILED:", fails)
        return 1
    print("SELFTEST OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
