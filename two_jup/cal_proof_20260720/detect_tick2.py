#!/usr/bin/env python3
# Coherent lag-256 repeat detector (matched to a duplicated block).
# y[n] = x[n]*conj(x[n-256]); at a true repeat y[n]=|x[n]|^2 (real, positive)
# for 256 consecutive n, so a 256-tap moving sum of y, normalized by the moving
# sum of |x|^2, -> 1.0.  On random data the phases of y are uniform -> ~0.
# O(N) via cumulative sums.  Reports coherence peaks (repeat episodes).
import sys, numpy as np
FS = 1_920_000; LAG = 256; WIN = 256

def load(path):
    d = np.fromfile(path, dtype="<i2").astype(np.float64)
    d = d[:(len(d)//2)*2].reshape(-1, 2)
    return d[:,0] + 1j*d[:,1]

def movsum(a, w):
    c = np.cumsum(np.concatenate([[0], a]))
    return c[w:] - c[:-w]

def analyze(x, label, thr=0.5):
    n = len(x); dur = n/FS
    y = x[LAG:] * np.conj(x[:-LAG])          # length n-LAG
    pw = np.abs(x[LAG:])**2
    num = np.abs(movsum(y, WIN))
    den = movsum(pw, WIN) + 1e-9
    coh = num/den                             # 0..1, ->1 at a repeat
    peak_mask = coh > thr
    idx = np.flatnonzero(peak_mask)
    episodes = []
    if len(idx):
        groups = np.split(idx, np.flatnonzero(np.diff(idx) > FS*0.2)+1)
        for g in groups:
            c = g[np.argmax(coh[g])]
            episodes.append((c, coh[c]))
    centers = np.array([e[0]/FS for e in episodes])
    periods = np.diff(centers) if len(centers) > 1 else np.array([])
    print(f"== {label} ==")
    print(f"  dur={dur:.2f}s  median_coh={np.median(coh):.4f}  max_coh={coh.max():.3f}  episodes(coh>{thr})={len(episodes)}")
    if len(episodes):
        print(f"  peak coherences: {', '.join(f'{c:.2f}' for _,c in episodes[:12])}")
        print(f"  rate={len(episodes)/dur:.2f}/s")
    if len(periods):
        print(f"  period: median={np.median(periods):.4f}s min={periods.min():.4f} max={periods.max():.4f} n={len(periods)}")
    print(f"  VERDICT: {'REPEAT/TICK PRESENT' if len(episodes)>=2 else 'no periodic 256-repeat'}")
    return len(episodes)

if __name__ == "__main__":
    if sys.argv[1] == "--selftest":
        np.random.seed(0)
        sym = np.random.randint(0,4,size=12*240000)
        x = np.repeat(np.exp(1j*(np.pi/4+np.pi/2*sym)), 8)
        x = x + 0.05*(np.random.randn(len(x))+1j*np.random.randn(len(x)))
        xi=list(x); pos=int(0.7*FS); k=0
        while pos < len(x)-512:
            xi[pos:pos] = list(x[pos-256:pos]); k+=1; pos += int(1.49*FS)
        xi=np.array(xi)[:len(x)]
        print(f"[selftest] injected {k} repeats:")
        analyze(xi, "synthetic")
    else:
        for p in sys.argv[1:]:
            analyze(load(p), p.split("/")[-1])
