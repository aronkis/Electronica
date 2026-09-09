#!/usr/bin/env python3
"""sel8_base.py SRC OUT.npz -- DDRCAP-v2 sel8 (TX baseband, Transmitter_dataOutI/Q)
time base + mark census + Barker offset scan.

Record cadence [silicon, this capture]: 1 record per modulator SAMPLE
(valid = enb_1_2_0), slot = mod-4 phase counter (slots_cycle PASS), tref (slot==1
sidecar) advances 1 per symbol -> 4 records/symbol, 12333 symbols = 49332 samples
per air frame. Record INDEX is never a time base (rx2 DMA drops bursts of records);
absolute SAMPLE time = 4*unwrapped_tref + slot, and a record is only given a time
if its own 4-record group is intact.
"""
import sys
import numpy as np

FRAME_SYM = 12333
SPS = 4
FRAME_SAMP = FRAME_SYM * SPS
BARKER = np.array([1, 1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1], dtype=np.float64)


def build(src):
    a = np.memmap(src, dtype='<i2', mode='r').reshape(-1, 4)
    n = a.shape[0]
    c2 = np.array(a[:, 2]).astype(np.uint16)
    c3 = np.array(a[:, 3]).astype(np.uint16)
    slot = (c3 >> 14).astype(np.int64)
    side = (c3 & 0x3FFF).astype(np.int64)
    mark_fec = np.flatnonzero((c2 >> 14) & 1)
    mark_dem = np.flatnonzero((c2 >> 15) & 1)
    del c2, c3

    s1 = np.flatnonzero(slot == 1)
    t1 = side[s1]
    d = np.diff(t1)
    d = np.where(d < 0, d + FRAME_SYM, d)
    gapmax = int(d.max()) if len(d) else 0
    tabs = np.empty(len(s1), dtype=np.int64)
    tabs[0] = 0
    np.cumsum(d, out=tabs[1:])

    # per-record absolute SAMPLE time; -1 where the 4-record group is broken
    idx = np.arange(n, dtype=np.int64)
    g = np.searchsorted(s1, idx, side='left')          # first slot-1 at or after i
    gsym = np.where(slot <= 1, g, g - 1)   # slot0's slot-1 is at i+1; slot1 is itself; slot2/3 look back
    ok = (gsym >= 0) & (gsym < len(s1))
    gs = np.clip(gsym, 0, len(s1) - 1)
    ok &= (s1[gs] == idx + (1 - slot))                 # group intact around i
    ts = np.where(ok, 4 * tabs[gs] + slot, -1)
    return dict(n=n, I=np.array(a[:, 0]), Q=np.array(a[:, 1]), ts=ts,
                mark_fec=mark_fec, mark_dem=mark_dem, slot=slot,
                s1=s1, tabs=tabs, dsym=d, gapmax=gapmax)


def offset_scan(B, nmax=400, lo=-320, hi=320):
    """Aggregate |Barker-13 correlation| vs sample offset from the mark record.
    Positive control for the whole preamble method: a sharp unique argmax."""
    ts, I, Q = B['ts'], B['I'], B['Q']
    mf = B['mark_fec']
    mf = mf[(mf > 2000) & (mf < B['n'] - 2000)]
    step = max(1, len(mf) // nmax)
    mf = mf[::step][:nmax]
    offs = np.arange(lo, hi + 1)
    acc = np.zeros(len(offs)); cnt = np.zeros(len(offs))
    for m in mf:
        w0, w1 = m - 2400, m + 2400
        tw = ts[w0:w1]
        good = tw >= 0
        if ts[m] < 0:
            continue
        tm = ts[m]
        # map sample time -> record index within the window
        lut = {}
        tg = tw[good]; ig = np.flatnonzero(good) + w0
        order = np.argsort(tg)
        tg = tg[order]; ig = ig[order]
        for oi, o in enumerate(offs):
            want = tm + o + SPS * np.arange(13)
            pos = np.searchsorted(tg, want)
            pos = np.clip(pos, 0, len(tg) - 1)
            hit = tg[pos] == want
            if not hit.all():
                continue
            r = ig[pos]
            z = I[r].astype(np.float64) + 1j * Q[r].astype(np.float64)
            den = np.abs(z).sum()
            if den <= 0:
                continue
            acc[oi] += abs((BARKER * z).sum()) / den
            cnt[oi] += 1
    return offs, acc, cnt


def main(src, out):
    B = build(src)
    n = B['n']
    ts = B['ts']
    mf, md = B['mark_fec'], B['mark_dem']
    d = B['dsym']
    ndrop = int((d > 1).sum())
    lost = int((d - 1)[d > 1].sum())
    span_sym = int(B['tabs'][-1] - B['tabs'][0]) + 1
    print(f"records {n}  timed {int((ts>=0).mean()*100):d}%  slot1 {len(B['s1'])}")
    print(f"tref span {span_sym} symbols = {span_sym/FRAME_SYM:.1f} frames = {span_sym/12333*8.0:.3f} ms/frame-units")
    print(f"drop events {ndrop} ({ndrop/len(d)*100:.3f}% of symbol steps) lost {lost} symbols "
          f"({lost/span_sym*100:.1f}% of span)  max symbol gap {B['gapmax']} (ambiguity if >=12333/2)")
    print(f"mark_fec {len(mf)}  mark_demod {len(md)}")

    # ---- task 1: mark spacing in SAMPLE time ----
    tmf = ts[mf]
    good = tmf >= 0
    tg = tmf[good]
    dd = np.diff(tg)
    q = dd / FRAME_SAMP
    exact = np.abs(q - np.rint(q)) * FRAME_SAMP
    print(f"timed marks {good.sum()}/{len(mf)}; consecutive-mark sample gaps: "
          f"all multiples of {FRAME_SAMP}? max residual {exact.max():.0f} samples")
    v, c = np.unique(np.rint(q).astype(int), return_counts=True)
    print("  gap/frame histogram: " + ", ".join(f"{a}x{b}" for a, b in zip(v, c)))

    offs, acc, cnt = offset_scan(B)
    ok = cnt > 0.5 * cnt.max()
    sc = np.where(ok, acc / np.maximum(cnt, 1), 0.0)
    best = int(offs[sc.argmax()])
    srt = np.sort(sc)[::-1]
    print(f"Barker offset scan: argmax offset {best} samples, score {sc.max():.4f}, "
          f"2nd-best(non-adjacent) {np.sort(sc[np.abs(offs-best)>2])[-1]:.4f}, median {np.median(sc[ok]):.4f}")
    np.savez(out, ts=ts, mark_fec=mf, mark_dem=md, offs=offs, sc=sc, cnt=cnt,
             best_off=best, span_sym=span_sym, n=n)
    print(f"wrote {out}")


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
