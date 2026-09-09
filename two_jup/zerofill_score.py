#!/usr/bin/env python3
"""zerofill_score.py <capture.iq> [spf=49332]

Count TX zero-fill events in a capture: per-frame envelope ratio std|x|/mean|x|
collapses (~0.27 -> ~0.02) when the modulator airs a zero/constant payload at
full carrier amplitude (TX_ANOMALY_SCAN.md method). Reports flagged frames,
their spacing, and the rate -- the per-capture metric for the drain-budget
on-air A/B. int16 interleaved I,Q.
"""
import sys, numpy as np

def main():
    path = sys.argv[1]
    spf = int(sys.argv[2]) if len(sys.argv) > 2 else 49332
    raw = np.fromfile(path, dtype=np.int16)
    x = raw[0::2].astype(np.float64) + 1j * raw[1::2].astype(np.float64)
    nfr = len(x) // spf
    x = x[:nfr * spf].reshape(nfr, spf)
    a = np.abs(x)
    mean = a.mean(axis=1); std = a.std(axis=1)
    ratio = np.where(mean > 0, std / mean, 0)
    med_r, med_m = np.median(ratio), np.median(mean)
    low_ratio = np.where((ratio < 0.5 * med_r) & (mean > 0.5 * med_m))[0]
    low_mean  = np.where(mean < 0.5 * med_m)[0]
    print(f"{path}: {nfr} frames  median ratio {med_r:.3f} mean {med_m:.0f}")
    print(f"  zero/const-payload events (ratio<{0.5*med_r:.3f}, amplitude normal): "
          f"{len(low_ratio)}  rate {len(low_ratio)/nfr*100:.2f}%")
    if len(low_ratio):
        ks = low_ratio.tolist()
        print(f"  frames: {ks[:30]}{' ...' if len(ks) > 30 else ''}")
        if len(ks) > 1:
            d = np.diff(ks)
            print(f"  spacing: {d[:20].tolist()}")
    print(f"  RF-mute frames (low amplitude): {len(low_mean)}")

if __name__ == "__main__":
    main()
