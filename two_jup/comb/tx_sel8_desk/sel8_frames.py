#!/usr/bin/env python3
"""sel8_frames.py SRC BASE.npz OUT.npz -- per-TX-frame metrics from DDRCAP-v2 sel8.

Frames are anchored on their own timed mark_fec (never on record position); the
symbol-rate sampling phase and the modulator+RRC group delay are taken from the
Barker offset scan in sel8_base.py. Missing (DMA-dropped) samples are tracked by
an explicit presence mask and every metric is computed over present samples only,
with the per-frame present-count kept as a covariate.
"""
import sys
import numpy as np

FRAME_SYM = 12333
SPS = 4
FRAME_SAMP = FRAME_SYM * SPS
NPRE = 13
BARKER = np.array([1, 1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1], dtype=np.float64)


def main(src, basep, out):
    b = np.load(basep)
    ts = b['ts']; mf = b['mark_fec']; off0 = int(b['best_off'])
    a = np.memmap(src, dtype='<i2', mode='r').reshape(-1, 4)
    good = ts >= 0
    T = int(ts[good].max()) + 1
    Ia = np.zeros(T, np.int16); Qa = np.zeros(T, np.int16); pr = np.zeros(T, bool)
    gi = np.flatnonzero(good); gt = ts[gi]
    Ia[gt] = np.array(a[:, 0])[gi]; Qa[gt] = np.array(a[:, 1])[gi]; pr[gt] = True
    del gi, gt, a
    print(f"time span {T} samples, present {pr.mean()*100:.1f}%")

    tm = ts[mf]; tm = tm[tm >= 0]
    t0 = tm[0]
    k = np.rint((tm - t0) / FRAME_SAMP).astype(np.int64)
    keep = np.abs((tm - t0) - k * FRAME_SAMP) < 2000
    tm = tm[keep]; k = k[keep]
    m = len(tm)

    # ---- Barker fine search in the BASEBAND itself (mark-independent) ----
    SW = 48                                   # +-48 symbols around the predicted spot
    sy = np.arange(NPRE) * SPS
    lags = np.arange(-SW, SW + 1) * SPS
    pk_off = np.full(m, np.nan); pk_val = np.full(m, np.nan)
    corr_at_mark = np.full(m, np.nan)
    for i in range(m):
        base = tm[i] + off0
        w = base + lags[:, None] + sy[None, :]
        okw = (w >= 0) & (w < T)
        w = np.clip(w, 0, T - 1)
        p = pr[w].all(axis=1) & okw.all(axis=1)
        if not p.any():
            continue
        z = Ia[w].astype(np.float64) + 1j * Qa[w].astype(np.float64)
        den = np.abs(z).sum(axis=1)
        c = np.abs((z * BARKER).sum(axis=1)) / np.maximum(den, 1e-9)
        c[~p] = np.nan
        c[den < 1e-9] = np.nan
        if np.isnan(c).all():
            continue
        j = np.nanargmax(c)
        pk_off[i] = lags[j] / SPS
        pk_val[i] = c[j]
        if p[SW]:
            corr_at_mark[i] = c[SW]

    # ---- whole-frame symbol-rate metrics + hard bits ----
    keys = ('meanabs', 'evm', 'nzero', 'npresent', 'pre_amp', 'body_amp')
    o = {kk: np.full(m, np.nan) for kk in keys}
    NB = FRAME_SYM - NPRE
    bits = np.zeros((m, 2 * 256), np.int8)     # first 256 data symbols of each frame
    bits_ok = np.zeros(m, bool)
    for i in range(m):
        s0 = tm[i] + off0
        idx = s0 + np.arange(FRAME_SYM) * SPS
        if idx[0] < 0 or idx[-1] >= T:
            continue
        p = pr[idx]
        o['npresent'][i] = p.sum()
        if p.sum() < 2000:
            continue
        z = (Ia[idx].astype(np.float64) + 1j * Qa[idx].astype(np.float64))[p]
        r = np.abs(z)
        ma = r.mean()
        o['meanabs'][i] = ma
        o['nzero'][i] = float((r < 0.3 * ma).sum()) / p.sum()
        zn = z / ma
        m4 = (zn ** 4).mean()
        phi = (np.angle(m4) - np.pi) / 4.0
        w = zn * np.exp(-1j * phi)
        s = 1 / np.sqrt(2.0)
        dec = (np.sign(w.real) + 1j * np.sign(w.imag)) * s
        o['evm'][i] = float(np.sqrt((np.abs(w - dec) ** 2).mean()))
        pp = p[:NPRE]
        if pp.all():
            o['pre_amp'][i] = np.abs(Ia[idx[:NPRE]].astype(float) + 1j * Qa[idx[:NPRE]].astype(float)).mean() / ma
        pb = p[NPRE:]
        if pb.sum() > 100:
            o['body_amp'][i] = r[NPRE:][:pb.sum()].mean() / ma if False else np.abs(z).mean() / ma
        # hard bits over the first 256 DATA symbols (needs them all present)
        d0 = idx[NPRE:NPRE + 256]
        if pr[d0].all():
            zz = (Ia[d0].astype(float) + 1j * Qa[d0].astype(float)) * np.exp(-1j * phi)
            bits[i, 0::2] = (zz.real > 0).astype(np.int8)
            bits[i, 1::2] = (zz.imag > 0).astype(np.int8)
            bits_ok[i] = True

    np.savez(out, k=k, tm=tm, pk_off=pk_off, pk_val=pk_val, corr_at_mark=corr_at_mark,
             bits=bits, bits_ok=bits_ok, **o)
    print(f"frames {m}  bits_ok {bits_ok.sum()}  peak found {np.isfinite(pk_val).sum()}")
    print(f"wrote {out}")


if __name__ == '__main__':
    main(*sys.argv[1:4])
