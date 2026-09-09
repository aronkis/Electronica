#!/usr/bin/env python3
"""Loop-signal trajectory summary for a Vwrap_byte_taps run directory.

Prints, in stage order, coarse stats over the run: cfcFreq (3rd col of _cfc),
and per-stage symbol-stream health (line counts + RMS of I/Q in fixed frames)
for ss, cfc, cs, pa, con. Used to name the first signal that differs between
the +15k and -15k runs.
"""
import sys, numpy as np

def load(path, ncol):
    try:
        a = np.loadtxt(path, delimiter=',', dtype=np.int64, ndmin=2)
    except Exception:
        return np.zeros((0, ncol), dtype=np.int64)
    return a

def main():
    d, pfx = sys.argv[1], sys.argv[2]
    cfc = load(f"{d}/{pfx}_cfc.txt", 3)
    if len(cfc):
        f = cfc[:, 2]
        n = len(f)
        segs = [f[int(n*a):int(n*b)] for a, b in
                [(0, .1), (.1, .3), (.3, .6), (.6, 1.)]]
        print(f"cfcFreq n={n} first10%med={np.median(segs[0]):.0f} "
              f"seg2med={np.median(segs[1]):.0f} seg3med={np.median(segs[2]):.0f} "
              f"lastmed={np.median(segs[3]):.0f} min={f.min()} max={f.max()} "
              f"std_last={np.std(segs[3]):.1f}")
    for st, nc in [('ss', 2), ('cs', 2), ('pa', 3), ('con', 2)]:
        a = load(f"{d}/{pfx}_{st}.txt", nc)
        if not len(a):
            print(f"{st} EMPTY"); continue
        iq = a[:, 0].astype(float) + 1j * a[:, 1].astype(float)
        n = len(iq)
        tail = iq[int(n*0.6):]
        # constellation coherence: |mean(z^4)|/mean(|z|^4) -> 1 for clean QPSK
        z4 = tail**4
        coh = abs(np.mean(z4)) / max(np.mean(np.abs(z4)), 1e-9)
        print(f"{st} n={n} rms_tail={np.sqrt(np.mean(np.abs(tail)**2)):.0f} "
              f"qpsk_coh_tail={coh:.3f}")
        if st == 'pa':
            print(f"pa syncPulses={int(a[:,2].sum())}")

if __name__ == '__main__':
    main()
