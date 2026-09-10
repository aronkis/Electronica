#!/usr/bin/env python3
"""[sim] Task 8d scorer -- comb search on the closed-loop RX harness.

For each leg prefix:
  * loss train on the EMITTED-SEQ axis (host frames): the delivered good-magic
    frames' seq numbers; every gap d>1 costs d-1 lost slots.  Same rule as
    ops/comb/common.py loss_slot_trains on silicon.
  * Peak_Search argmax series on the EPOCH axis (air frames): timingOffset,
    d(heldts), runmax, threshold crossings.
  * autocorrelation of each indicator at lags 1..128 with a permutation null
    (2000 shuffles, per-lag 95/99th percentile of |rho| and the max-over-lags
    family-wise 95th percentile).

usage: rxloop_score.py <pfx> [<pfx> ...]
"""
import sys, os, numpy as np

MAXLAG = 128
NPERM = 2000
RNG = np.random.default_rng(7)


def autocorr(x, maxlag=MAXLAG):
    x = np.asarray(x, dtype=float)
    x = x - x.mean()
    d = np.dot(x, x)
    if d <= 0:
        return np.zeros(maxlag + 1)
    r = np.empty(maxlag + 1)
    r[0] = 1.0
    for k in range(1, maxlag + 1):
        r[k] = np.dot(x[:-k], x[k:]) / d if k < len(x) else 0.0
    return r


def perm_null(x, maxlag=MAXLAG, nperm=NPERM):
    """Return (per-lag 95%, per-lag 99%, familywise 95% of max|rho|)."""
    x = np.asarray(x, dtype=float)
    if x.size < 8 or x.std() == 0:
        return None
    mx = np.empty(nperm)
    per = np.empty((nperm, maxlag))
    for i in range(nperm):
        y = RNG.permutation(x)
        r = autocorr(y, maxlag)[1:]
        per[i] = np.abs(r)
        mx[i] = np.abs(r).max()
    return (np.percentile(per, 95, axis=0), np.percentile(per, 99, axis=0),
            np.percentile(mx, 95))


def top_lags(r, n=5):
    idx = np.argsort(-np.abs(r[1:]))[:n] + 1
    return [(int(k), float(r[k])) for k in idx]


def read_frames(p):
    real, garbage, filler = [], 0, 0
    with open(p + "_frames.txt") as f:
        for ln in f:
            if ln.startswith("#"):
                continue
            w = ln.split()
            if len(w) < 6:
                continue
            ok, az, seq = int(w[3]), int(w[4]), int(w[5])
            if ok:
                real.append(seq)
            elif az:
                filler += 1
            else:
                garbage += 1
    return real, garbage, filler


def loss_train(seqs):
    """Loss indicator on the transmitted-slot axis, from good seqs in order."""
    if len(seqs) < 3:
        return np.zeros(0), 0, 0
    lo, hi = seqs[0], seqs[-1]
    span = hi - lo + 1
    ind = np.ones(span, dtype=float)
    for s in seqs:
        if lo <= s <= hi:
            ind[s - lo] = 0.0
    return ind, int(ind.sum()), span


def read_epochs(p):
    cols = {k: [] for k in ("ep", "clk", "heldts", "dheldts", "toff", "accoff",
                            "runmax", "thr", "nxcd", "nnewpk", "nsync", "pkts", "rxf")}
    with open(p + "_epochs.txt") as f:
        for ln in f:
            if ln.startswith("#"):
                continue
            w = ln.split()
            if len(w) < 13:
                continue
            for k, v in zip(cols.keys(), w):
                cols[k].append(int(v))
    return {k: np.array(v) for k, v in cols.items()}


def report_series(name, x, out):
    x = np.asarray(x, dtype=float)
    if x.size < 16 or x.std() == 0:
        out.append(f"    {name:<22s} n={x.size:5d}  constant/too short -- no autocorrelation")
        return
    ml = min(MAXLAG, x.size // 3)
    r = autocorr(x, ml)
    nul = perm_null(x, ml)
    tl = top_lags(r, 5)
    fam = f"{nul[2]:.3f}" if nul else "n/a"
    out.append(f"    {name:<22s} n={x.size:5d} mean={x.mean():.4f} sd={x.std():.4f} "
               f"null95(max|rho|)={fam}")
    out.append("      top lags: " + ", ".join(f"{k}:{v:+.3f}" for k, v in tl))
    for k in (2, 3, 16, 30, 32, 33, 34, 62, 64, 65, 66, 96, 128):
        if k <= ml:
            flag = ""
            if nul is not None and abs(r[k]) > nul[0][k - 1]:
                flag = " *"
            if nul is not None and abs(r[k]) > nul[1][k - 1]:
                flag = " **"
            lm = ""
            if 1 < k < ml and abs(r[k]) > abs(r[k-1]) and abs(r[k]) > abs(r[k+1]):
                lm = " localmax"
            out.append(f"      lag {k:3d}: rho={r[k]:+.3f}{flag}{lm}")


def main():
    out = []
    for p in sys.argv[1:]:
        if not os.path.exists(p + "_epochs.txt"):
            out.append(f"== {p}: MISSING")
            continue
        summ = {}
        sp = p + "_summary.txt"
        if os.path.exists(sp):
            for ln in open(sp):
                if "=" in ln:
                    k, v = ln.strip().split("=", 1)
                    summ[k] = v
        e = read_epochs(p)
        real, garbage, filler = read_frames(p)
        ind, lost, span = loss_train(real)
        out.append("")
        out.append(f"== {os.path.basename(p)}  esn0={summ.get('esn0','?')} "
                   f"cfo={summ.get('cfo_hz','?')} epochs={len(e['ep'])} "
                   f"clk={summ.get('clk_end','?')} timeout={summ.get('timeout','?')}")
        out.append(f"   loop_balance={summ.get('loop_balance','?')} "
                   f"clipped={summ.get('clipped','?')} sigma={summ.get('sigma','?')}")
        out.append(f"   rx frames: good={len(real)} garbage={garbage} filler={filler}")
        out.append(f"   loss train: span={span} lost_slots={lost} "
                   f"PER={100.0*lost/span if span else 0:.3f}%")
        dh = e["dheldts"][1:]
        nslip = int(np.sum(dh != 12333))
        out.append(f"   d(heldts): median={np.median(dh):.0f} "
                   f"!=12333 on {nslip}/{len(dh)} epochs")
        toff = e["toff"]
        mode = int(np.bincount(toff).argmax()) if toff.size else 0
        out.append(f"   argmax position (timingOffset): mode={mode} "
                   f"unique={len(np.unique(toff))} min={toff.min() if toff.size else 0} "
                   f"max={toff.max() if toff.size else 0} "
                   f"off-mode epochs={int(np.sum(toff != mode))}")
        out.append(f"   runmax/thr: median runmax={np.median(e['runmax']):.3g} "
                   f"median thr={np.median(e['thr']):.3g} "
                   f"median xings/epoch={np.median(e['nxcd']):.1f} "
                   f"syncpulses/epoch={np.mean(e['nsync']):.3f}")
        out.append("   --- autocorrelation (permutation null, 2000 shuffles) ---")
        if span:
            report_series("loss indicator[seq]", ind, out)
        report_series("toff[epoch]", toff, out)
        report_series("toff!=mode[epoch]", (toff != mode).astype(float), out)
        report_series("dheldts!=12333[epoch]", np.concatenate([[0], (dh != 12333)]).astype(float), out)
        report_series("runmax[epoch]", e["runmax"], out)
        report_series("nxcd[epoch]", e["nxcd"], out)
        thr = e["thr"].astype(float)
        margin = np.where(thr != 0, e["runmax"].astype(float) / np.where(thr == 0, 1, thr), 0.0)
        report_series("runmax/thr[epoch]", margin, out)
    print("\n".join(out))


if __name__ == "__main__":
    main()
