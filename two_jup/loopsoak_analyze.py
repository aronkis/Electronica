#!/usr/bin/env python3
"""loopsoak_analyze.py -- did the 256-sample tick appear in internal loopback?

Parses loopback_soak.sh's 10 Hz register log (t/pkts/biterr/cap/rstcs/cfc) and
tests whether bit_errors (0x108) grew in periodic ~1.5 s episodes (the tick
signature) or stayed clean. Also confirms cap_out stayed golden (0x04922282)
and packets advanced.
"""
import re, sys
import numpy as np

GOLDEN = 0x04922282

def load(path):
    t, be, pk, cap, rst, cfc = [], [], [], [], [], []
    with open(path) as f:
        for ln in f:
            m = re.search(r"t=([\d.]+).*pkts=0x([0-9a-fA-F]+).*biterr=0x([0-9a-fA-F]+).*cap=0x([0-9a-fA-F]+).*rstcs=0x([0-9a-fA-F]+).*cfc=0x([0-9a-fA-F]+)", ln)
            if not m: continue
            t.append(float(m.group(1))); pk.append(int(m.group(2),16)); be.append(int(m.group(3),16))
            cap.append(int(m.group(4),16)); rst.append(int(m.group(5),16)); cfc.append(int(m.group(6),16))
    return (np.array(t), np.array(be,dtype=np.int64), np.array(pk,dtype=np.int64),
            np.array(cap), np.array(rst,dtype=np.int64), np.array(cfc))

def main(path):
    t, be, pk, cap, rst, cfc = load(path)
    if t.size < 10:
        print("loopsoak: too few samples"); return 1
    dur = t[-1]-t[0]
    dbe = np.diff(be); dbe[dbe<0] = 0            # counter growth per 0.1 s
    dpk = np.diff(pk); dpk[dpk<0] = 0
    jumps = np.flatnonzero(dbe > 0)              # samples where bit_errors grew
    cap_golden = int(np.sum(cap == GOLDEN)); cap_frac = cap_golden/cap.size
    print(f"loopsoak: {t.size} samples over {dur:.1f}s (~{dur/1.5:.0f} tick periods @1.5s)")
    print(f"  packets advanced: {int(pk[-1]-pk[0])} ({dpk.mean()*10:.0f}/s)  rstcs total: {int(rst[-1]-rst[0])}")
    print(f"  cap_out golden (0x{GOLDEN:08x}): {cap_frac*100:.1f}% of samples")
    print(f"  bit_errors: start=0x{be[0]:x} end=0x{be[-1]:x} grew {int(be[-1]-be[0])}; "
          f"growth events={jumps.size}")
    if jumps.size >= 3:
        gaps = np.diff(t[jumps])
        med = float(np.median(gaps))
        # periodicity: is the median inter-episode gap near 1.5 s with low spread?
        periodic = 1.0 <= med <= 2.2 and float(np.std(gaps)) < 0.6*med
        print(f"  bit_error episode spacing: median={med:.2f}s std={np.std(gaps):.2f}s "
              f"({'PERIODIC ~tick' if periodic else 'not tick-periodic'})")
        verdict = "TICK PRESENT in loopback (fabric-domain)" if periodic else \
                  "errors present but NOT tick-periodic"
    elif jumps.size == 0 and cap_frac > 0.95:
        verdict = "CLEAN loopback -- NO tick episodes (ADC-delivery attribution SUPPORTED)"
    else:
        verdict = f"few/no bit-error events ({jumps.size}); cap_golden {cap_frac*100:.0f}%"
    print(f"VERDICT: {verdict}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv)>1 else "loop_soak.log"))
