#!/usr/bin/env python3
"""iq_perturb.py -- sample-domain disturbance injector for the reproduction
harness (Workstream R, Class-A air/numeric perturbations).

Applies a controlled disturbance to an int16-interleaved I/Q capture slice
BEFORE it enters either replay leg (float evm_ideal_ref / bit-true netlist).
Sample-domain is deliberate: evm_ideal_ref estimates CFO and rotation GLOBALLY
over the block, so a transient poked into the float sync objects mid-stream is
absorbed by the global estimators -- a real air/numeric disturbance must live
in the samples both legs ingest identically.

Perturbations (each starts at sample --n0):
  --cfo HZ        frequency step: x[n] *= exp(j 2pi (HZ/FS) (n-n0)),  n >= n0
  --phase DEG     phase step:     x[n] *= exp(j DEG),                 n >= n0
  --gain G        AGC kick:       x[n] *= G over [n0, n0+--win)
  --drop L        dropout:        zero L samples at n0 (or --insert to splice
                                  L zeros in, growing the stream by L)

Format: flat little-endian interleaved int16 I,Q,I,Q... (same as pair.iq /
raw.iq / iq_prep.py output). Values are clipped to int16 range on write.

Usage:
    iq_perturb.py IN.iq OUT.iq --fs 1920000 --n0 100000 --cfo 500
    iq_perturb.py --selftest
"""
import argparse
import sys

import numpy as np

I16 = np.iinfo(np.int16)


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


def perturb(x, fs, n0, cfo=0.0, phase_deg=0.0, gain=1.0, win=0,
            drop=0, insert=False):
    """Return a perturbed copy of complex vector x."""
    y = x.copy()
    n = y.size
    if n0 < 0 or n0 >= n:
        raise ValueError(f"n0 {n0} out of range [0,{n})")

    if cfo:
        k = np.arange(n) - n0
        step = np.where(k >= 0, np.exp(1j * 2 * np.pi * (cfo / fs) * k), 1.0)
        y = y * step
    if phase_deg:
        ph = np.exp(1j * np.deg2rad(phase_deg))
        y[n0:] = y[n0:] * ph
    if gain != 1.0:
        w = win if win > 0 else 1
        e = min(n0 + w, n)
        y[n0:e] = y[n0:e] * gain
    if drop:
        if insert:
            y = np.concatenate([y[:n0], np.zeros(drop, dtype=complex), y[n0:]])
        else:
            e = min(n0 + drop, n)
            y[n0:e] = 0
    return y


# --- estimate a local frequency (Hz) from phase progression, for the selftest
def _local_freq(x, fs, a, b):
    seg = x[a:b]
    ph = np.unwrap(np.angle(seg))
    slope = np.polyfit(np.arange(seg.size), ph, 1)[0]   # rad/sample
    return slope * fs / (2 * np.pi)


def selftest():
    fails = []
    fs = 1_920_000.0
    n = 200_000
    n0 = 100_000
    t = np.arange(n)
    base_hz = 1000.0
    x = 5000.0 * np.exp(1j * 2 * np.pi * (base_hz / fs) * t)   # clean tone

    # 1. CFO step: frequency after n0 shifts by exactly +cfo
    df = 500.0
    y = perturb(x, fs, n0, cfo=df)
    f_before = _local_freq(y, fs, 10_000, 40_000)
    f_after = _local_freq(y, fs, 130_000, 160_000)
    print(f"[selftest] cfo: before={f_before:.1f} Hz after={f_after:.1f} Hz "
          f"(want {base_hz:.0f} -> {base_hz+df:.0f})")
    if abs(f_before - base_hz) > 5:
        fails.append(f"cfo pre-step freq drifted ({f_before:.1f})")
    if abs(f_after - (base_hz + df)) > 5:
        fails.append(f"cfo post-step freq {f_after:.1f} != {base_hz+df:.0f}")

    # 2. phase step: angle jumps by exactly the requested amount at n0
    y = perturb(x, fs, n0, phase_deg=90.0)
    jump = np.rad2deg(np.angle(y[n0] / x[n0]))
    print(f"[selftest] phase: jump at n0 = {jump:.2f} deg (want 90)")
    if abs(((jump - 90 + 180) % 360) - 180) > 0.5:
        fails.append(f"phase jump {jump:.2f} != 90")

    # 3. gain kick over a window
    y = perturb(x, fs, n0, gain=2.0, win=1000)
    r = np.abs(y[n0 + 500]) / np.abs(x[n0 + 500])
    r_out = np.abs(y[n0 + 2000]) / np.abs(x[n0 + 2000])
    print(f"[selftest] gain: in-win ratio={r:.2f} (want 2), out-win={r_out:.2f} (want 1)")
    if abs(r - 2.0) > 0.01 or abs(r_out - 1.0) > 0.01:
        fails.append("gain kick window wrong")

    # 4. dropout: samples zeroed; insert grows the stream
    y = perturb(x, fs, n0, drop=256)
    if np.any(y[n0:n0 + 256] != 0):
        fails.append("dropout did not zero samples")
    yi = perturb(x, fs, n0, drop=256, insert=True)
    if yi.size != x.size + 256:
        fails.append(f"insert size {yi.size} != {x.size+256}")
    print(f"[selftest] drop: zeroed OK; insert size {yi.size} (want {x.size+256})")

    # 5. round-trip int16 save/load preserves the perturbation shape
    import tempfile, os
    y = perturb(x, fs, n0, cfo=df)
    tf = tempfile.mktemp(suffix=".iq")
    save_iq(tf, y)
    z = load_iq(tf)
    os.unlink(tf)
    f_after2 = _local_freq(z, fs, 130_000, 160_000)
    print(f"[selftest] roundtrip: post-step freq {f_after2:.1f} Hz (want {base_hz+df:.0f})")
    if abs(f_after2 - (base_hz + df)) > 5:
        fails.append(f"roundtrip freq {f_after2:.1f} wrong")

    if fails:
        print("\nSELFTEST FAILED:")
        for x_ in fails:
            print("  -", x_)
        return 1
    print("\nSELFTEST OK")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("infile", nargs="?")
    ap.add_argument("outfile", nargs="?")
    ap.add_argument("--fs", type=float, default=1_920_000.0, help="sample rate Hz")
    ap.add_argument("--n0", type=int, default=0, help="disturbance onset sample")
    ap.add_argument("--cfo", type=float, default=0.0, help="frequency step Hz")
    ap.add_argument("--phase", type=float, default=0.0, help="phase step deg")
    ap.add_argument("--gain", type=float, default=1.0, help="gain multiplier")
    ap.add_argument("--win", type=int, default=0, help="gain-kick window samples")
    ap.add_argument("--drop", type=int, default=0, help="dropout samples at n0")
    ap.add_argument("--insert", action="store_true", help="splice (grow) instead of zero")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.infile or not args.outfile:
        ap.error("INFILE and OUTFILE required (or --selftest)")
    x = load_iq(args.infile)
    y = perturb(x, args.fs, args.n0, cfo=args.cfo, phase_deg=args.phase,
                gain=args.gain, win=args.win, drop=args.drop, insert=args.insert)
    save_iq(args.outfile, y)
    print(f"wrote {args.outfile}: {y.size} samples "
          f"(cfo={args.cfo} phase={args.phase} gain={args.gain} drop={args.drop}"
          f"{' insert' if args.insert else ''} @n0={args.n0})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
