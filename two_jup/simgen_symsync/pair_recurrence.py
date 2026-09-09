#!/usr/bin/env python3
"""pair_recurrence.py -- (a) replicate the 8/25-alternation fingerprint at
full-log scale on the forward captures; (b) bridge host_seq <-> reg_packets.

Corrupt-frame positioning (the hole-census discipline, N4/LOSS_LEDGER): a
corrupt frame's own host_seq is garbage (decoded from corrupt payload), so a
class event = a maximal run of crc=0 records sandwiched between good records
whose seqs leave a hole exactly matching the run (delivered-but-corrupt).
  good(seq=a) [crc0 x m] good(seq=b):  gap=b-a-1
  gap>=1 and m>=gap -> corrupt frames at a+1..a+gap (event size=gap)
  gap==0            -> crc0 records without displacement (reread noise): skip
  gap>m             -> mixture of corrupt + undelivered (mid-gap class): skip
Events of size 1..2 with size<=2 = the singles class (mutes/bursts excluded).

For each event we record: host_seq position (a+1), event size, reg_packets of
the first crc0 record and of the bracketing good records (unit bridge).

Outputs per capture: interval histogram over event starts (host_seq units),
8/25-alternation test, mod-33 phase, CV; and the host_seq<->reg_packets
relation (slope on good records + event recurrence in reg_packets units).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from frame_taxonomy import read_frames


def events_of(path, settle=15.0):
    fr = read_frames(path)
    t = np.asarray(fr["t_mono_ns"], dtype=np.float64) / 1e9
    t -= t[0]
    keep = t >= settle
    hs = np.asarray(fr["host_seq"], dtype=np.int64)[keep]
    crc = np.asarray(fr["crc_ok"])[keep]
    pk = np.asarray(fr["reg_packets"], dtype=np.int64)[keep]

    ev = []           # (seq_start, size, pk_first_bad, pk_good_before, pk_good_after)
    last_good_seq = None
    last_good_pk = None
    runm = 0
    run_pk_first = None
    for i in range(len(hs)):
        if crc[i]:
            s = hs[i]
            if last_good_seq is not None and s > last_good_seq:
                gap = s - last_good_seq - 1
                if gap >= 1 and runm >= gap:
                    ev.append((last_good_seq + 1, gap, run_pk_first,
                               last_good_pk, pk[i]))
            if last_good_seq is None or s >= last_good_seq or s < last_good_seq - 1000:
                last_good_seq = s
                last_good_pk = pk[i]
            runm = 0
            run_pk_first = None
        else:
            if runm == 0:
                run_pk_first = pk[i]
            runm += 1
    return ev, hs, crc, pk


def analyze(path, label):
    ev, hs, crc, pk = events_of(path)
    small = [e for e in ev if e[1] <= 2]
    singles = sum(1 for e in small if e[1] == 1)
    doubles = sum(1 for e in small if e[1] == 2)
    starts = np.array([e[0] for e in small], dtype=np.int64)
    starts = np.unique(starts)
    iv = np.diff(starts)
    iv = iv[(iv > 0) & (iv < 200)]
    hist = {}
    for x in iv:
        hist[int(x)] = hist.get(int(x), 0) + 1
    top = sorted(hist.items(), key=lambda kv: -kv[1])[:8]
    c8 = sum(hist.get(x, 0) for x in (7, 8, 9))
    c16 = sum(hist.get(x, 0) for x in (15, 16, 17))
    c24 = sum(hist.get(x, 0) for x in (23, 24, 25, 26))
    c33 = sum(hist.get(x, 0) for x in (32, 33, 34))
    cv = float(np.std(iv) / np.mean(iv)) if len(iv) > 2 else float("nan")
    # 8/25 alternation: fraction of 8-intervals immediately followed by 24-26
    ivl = np.diff(starts)
    alt = 0
    n8 = 0
    for i in range(len(ivl) - 1):
        if 7 <= ivl[i] <= 9:
            n8 += 1
            if 23 <= ivl[i + 1] <= 26:
                alt += 1
    # mod 33 phase of starts
    m33 = np.bincount(starts % 33, minlength=33)
    m33top = np.argsort(m33)[::-1][:4]
    print(f"== {label}")
    print(f"   small events: {len(small)} (S:D={singles}:{doubles}, "
          f"double_frac={doubles/max(len(small),1):.2f}); all events incl. big: {len(ev)}")
    print(f"   intervals(<200): n={len(iv)} CV={cv:.2f} top: {top}")
    print(f"   bands: c8={c8} c16={c16} c24-26={c24} c32-34={c33}"
          f"  |  8->24-26 alternation: {alt}/{n8}")
    print(f"   start mod 33 top bins: {[(int(b), int(m33[b])) for b in m33top]}"
          f" (of {m33.sum()})")
    return dict(label=label, small=small, hist=hist, iv=iv, starts=starts)


def bridge(path, label):
    fr = read_frames(path)
    hs = np.asarray(fr["host_seq"], dtype=np.int64)
    crc = np.asarray(fr["crc_ok"])
    pk = np.asarray(fr["reg_packets"], dtype=np.int64)
    g = crc == 1
    hsg, pkg = hs[g], pk[g]
    # windowed slope d(pk)/d(hs) on good records over 1000-frame spans
    slopes = []
    step = 5000
    for i in range(0, len(hsg) - step, step):
        dh = hsg[i + step - 1] - hsg[i]
        dp = pkg[i + step - 1] - pkg[i]
        if dh > 100 and 0 <= dp < 10 * dh:
            slopes.append(dp / dh)
    print(f"   [{label}] d(reg_packets)/d(host_seq) on good records: "
          f"median={np.median(slopes):.4f} (n={len(slopes)} windows)")
    return float(np.median(slopes)) if slopes else float("nan")


def main():
    caps = sys.argv[1:] or [
        "../r3cap/singles_reread/frames.bin",
        "../r3cap/singles_disc/frames.bin",
        "../r3cap/cp1_verdict2/frames.bin",
        "../r3cap/evm_swap_A/frames.bin",
        "../r3cap/accept_rxq_20260812_201153_r1/frames.bin",
    ]
    res = []
    for p in caps:
        label = os.path.basename(os.path.dirname(p))
        try:
            r = analyze(p, label)
            sl = bridge(p, label)
            r["slope"] = sl
            res.append(r)
        except Exception as e:
            print(f"== {label}: FAILED {e}")
    return res


if __name__ == "__main__":
    main()
