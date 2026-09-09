#!/bin/bash
# =============================================================================
# acceptance_rxq.sh -- formal PER acceptance for the queued-request RX driver.
#
# Plan gate: delivered PER 95% Clopper-Pearson upper bound, >=3 warm runs, fixed
# geometry/LO, spread reported. Runs N sequential reverse captures (148->146,
# +20k off-null, -M 32, QPSK_RX_QUEUED=1) and analyzes each on the reliable
# metric (host_seq gaps), steady-state window (t>=15 s past the framelog rotate,
# excluding the one-time RF-enable warmup cluster).
#
# Usage: acceptance_rxq.sh [nruns]   (default 3)
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
N=${1:-3}
STAMP=$(date +%Y%m%d_%H%M%S)
for i in $(seq 1 "$N"); do
  OUT=$D/r3cap/accept_rxq_${STAMP}_r$i
  echo "=== acceptance run $i/$N -> $OUT ==="
  # SIDE=A runs the FORWARD direction (capture on 148); the LO_B_RX off-null
  # override is the REVERSE-capture policy and is applied only for SIDE=B so
  # A-runs keep bringup's own symmetric CFO policy (2026-08-12, Track V).
  SIDE=${SIDE:-B}
  LOENV=""; [ "$SIDE" = B ] && LOENV="LO_B_RX=1900020000"
  env $LOENV RXQ=1 GATE_TRIES=12 "$D/capture_r3.sh" "$SIDE" -n 8000000 -o "$OUT" \
    || { echo "RUN $i CAPTURE FAILED"; exit 1; }
  [ -f "$OUT/frames.bin" ] || { echo "RUN $i: no frames.bin"; exit 1; }
done

python3 - "$D" "$STAMP" "$N" <<'PY'
import sys, glob
import numpy as np
sys.path.insert(0, sys.argv[1])
from frame_taxonomy import read_frames

def cp_upper(k, n, conf=0.975):   # 95% two-sided CI upper limit (conservative)
    """Clopper-Pearson upper bound via beta quantile (bisection; no scipy)."""
    if n == 0: return 1.0
    if k >= n: return 1.0
    a, b = k + 1, n - k
    lo, hi = 0.0, 1.0
    # regularized incomplete beta I_x(a,b) via continued fraction (Lentz)
    import math
    def betacf(x, a, b):
        MAXIT, EPS, FPMIN = 200, 3e-12, 1e-300
        qab, qap, qam = a+b, a+1.0, a-1.0
        c, d = 1.0, 1.0 - qab*x/qap
        if abs(d) < FPMIN: d = FPMIN
        d = 1.0/d; h = d
        for m in range(1, MAXIT+1):
            m2 = 2*m
            aa = m*(b-m)*x/((qam+m2)*(a+m2))
            d = 1.0 + aa*d;  d = FPMIN if abs(d) < FPMIN else d
            c = 1.0 + aa/c;  c = FPMIN if abs(c) < FPMIN else c
            d = 1.0/d; h *= d*c
            aa = -(a+m)*(qab+m)*x/((a+m2)*(qap+m2))
            d = 1.0 + aa*d;  d = FPMIN if abs(d) < FPMIN else d
            c = 1.0 + aa/c;  c = FPMIN if abs(c) < FPMIN else c
            d = 1.0/d; de = d*c; h *= de
            if abs(de-1.0) < EPS: break
        return h
    def ibeta(x, a, b):
        if x <= 0: return 0.0
        if x >= 1: return 1.0
        lb = math.lgamma(a+b) - math.lgamma(a) - math.lgamma(b) + a*math.log(x) + b*math.log(1-x)
        front = math.exp(lb)
        if x < (a+1)/(a+b+2):
            return front * betacf(x, a, b) / a
        return 1.0 - front * betacf(1-x, b, a) / b  # symmetry (recompute front for swapped)
    # note: symmetry branch needs front for (b,a); do a clean bisection on ibeta directly
    def cdf(x): return ibeta(x, a, b)
    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = (lo+hi)/2
        if cdf(mid) < conf: lo = mid
        else: hi = mid
    return hi

def analyze(path):
    fr = read_frames(path); clean = fr['crc_ok'] != 0
    tm = fr['t_mono_ns'].astype(np.int64); t0 = tm[0]
    ci = np.flatnonzero(clean); ct = (tm[ci]-t0)/1e9
    cseq = fr['host_seq'][ci].astype(np.int64)
    d = np.diff(cseq); lost = d-1; gt = ct[:-1]; st = gt >= 15
    span = int(cseq[-1] - cseq[np.searchsorted(ct, 15.0)]) if (ct >= 15).any() else 0
    miss = int(lost[st].sum()); rl = lost[st]; rl = rl[rl > 0]
    bins = {'1': int((rl==1).sum()), '2': int((rl==2).sum()),
            '3-4': int(((rl>=3)&(rl<=4)).sum()), '5-20': int(((rl>=5)&(rl<=20)).sum()),
            '21-100': int(((rl>=21)&(rl<=100)).sum()), '>100': int((rl>100).sum())}
    # lag-33 on the singles train
    hss = np.sort(np.unique(cseq[ct>=15])); lo_ = hss[0]
    pres = np.zeros(hss[-1]-lo_+1, dtype=np.int8); pres[hss-lo_] = 1
    idx = np.flatnonzero(1-pres); runs = []; i = 0
    while i < len(idx):
        j = i
        while j+1 < len(idx) and idx[j+1] == idx[j]+1: j += 1
        runs.append((idx[i], j-i+1)); i = j+1
    sp = np.zeros(hss[-1]-lo_+1)
    for p, l in runs:
        if l == 1: sp[p] = 1
    ac33 = float('nan')
    if sp.sum() > 3:
        spc = sp - sp.mean(); ac = np.correlate(spc, spc, 'full')[len(spc)-1:]
        ac33 = float(ac[33]/ac[0])
    return miss, span, bins, ac33

base, stamp, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
tot_k = tot_n = 0
pers = []
print(f"=== ACCEPTANCE: {n} warm runs, QPSK_RX_QUEUED=1, +20k, -M32, steady t>=15s ===")
for i in range(1, n+1):
    path = f"{base}/r3cap/accept_rxq_{stamp}_r{i}/frames.bin"
    miss, span, bins, ac33 = analyze(path)
    per = 100*miss/max(span, 1); pers.append(per)
    ub = 100*cp_upper(miss, span)
    tot_k += miss; tot_n += span
    print(f"  run {i}: PER={per:.2f}% (miss {miss}/{span})  CP95-UB={ub:.2f}%  lag33={ac33:.3f}  bins={bins}")
ub_all = 100*cp_upper(tot_k, tot_n)
print(f"\n  POOLED: PER={100*tot_k/max(tot_n,1):.2f}% (miss {tot_k}/{tot_n})  CP95-UB={ub_all:.2f}%")
print(f"  spread: {min(pers):.2f}%..{max(pers):.2f}%")
print(f"  GATE (<1% at 95% UB): {'PASS' if ub_all < 1.0 else 'NOT MET'}")
PY
echo "ACCEPTANCE_RXQ_DONE"
