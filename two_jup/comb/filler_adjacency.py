#!/usr/bin/env python3
"""two_jup/comb/filler_adjacency.py -- desk test of the FILLER-ADJACENCY
hypothesis: "frame loss is a false preamble detection inside an all-zero
FILLER air frame, and the filler is inserted whenever the host daemon's TX
queue runs dry".

Reads the TX board's QTXLOG02 dump (cap/txlog_peer.bin on the credited legs)
and the RX board's frames.bin / failhdr.bin, and answers:

  Q1  submit-gap census: how often does the host actually starve the
      modulator?  Reported with THREE criteria, because the naive one is a
      trap:
        (a) dt > 1 air frame          -- UNINFORMATIVE (see below)
        (b) inflight == 0             -- queue empty before the submit
        (c) gap_ns != QPSK_GAP_NONE   -- txgap_note fired (queue empty after
                                        the reap); this is the daemon's own
                                        dry-queue detector
      (a) is uninformative because tx_send blocks on DMA slot availability,
      so the submit cadence is slaved to the air rate and dt is centred ON
      the frame period; ~half of all gaps exceed it by construction.

  Q2  adjacency: for every lost RX slot (loss_slot_trains) and every
      parseable failhdr seq, was the submit at that seq -- or the one before
      it -- dry?  P(dry|lost) vs P(dry) overall, odds ratio, attributable
      fraction, circular-shift permutation null.

  Q3  is the submit cadence itself periodic at the comb lag?  Autocorrelate
      the CONTINUOUS dt series on the seq axis (a 100-event binary train has
      no usable spectrum), lags 1..128; lag 32 x 802.93 us = 25.7 ms.

  Q4  cross-leg table (forward 8.1 % vs reverse 3.7 %) against the dry
      fractions.

Join discipline (README_hostlog.md sec 4 + sec 5.5): the two boards keep
independent CLOCK_MONOTONIC, so the TX<->RX clip is done on the SEQ axis
(intersection of the TX seq span and the RX live-window seq span), never on
time.  Duplicate submits of the same seq are collapsed to the FIRST submit
for the per-seq axis, and counted separately.

Usage:
  python3 two_jup/comb/filler_adjacency.py RUNDIR [RUNDIR ...] [--txlog NAME]
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from frame_taxonomy import read_frames                      # noqa: E402
from common import loss_slot_trains, fft_autocorr           # noqa: E402
from joinlog import read_txlog, read_failhdr, QPSK_GAP_NONE  # noqa: E402

AIR_FRAME_NS = 802_930.0   # one air frame at spf=49332, fs=61.44 MS/s
MAX_LAG = 128
N_SHUFFLE = 200


def submit_census(tx):
    """Q1 -- the three criteria."""
    t = tx["t_submit_ns"].astype(np.int64)
    dt = np.diff(t)
    g = tx["gap_ns"]
    meas = g != QPSK_GAP_NONE
    n = len(tx)
    c = dict(
        n_submits=int(n),
        n_distinct_seq=int(np.unique(tx["seq"]).size),
        n_dup_submits=int(n - np.unique(tx["seq"]).size),
        dt_median_ns=float(np.median(dt)),
        dt_p99_ns=float(np.percentile(dt, 99)),
        dt_p99_9_ns=float(np.percentile(dt, 99.9)),
        dt_max_ns=int(dt.max()),
        # (a) UNINFORMATIVE criterion, reported only to defuse it
        frac_dt_gt_1f=float((dt > AIR_FRAME_NS).mean()),
        frac_dt_gt_2f=float((dt > 2 * AIR_FRAME_NS).mean()),
        n_dt_gt_2f=int((dt > 2 * AIR_FRAME_NS).sum()),
        # (b) queue empty before submit
        n_inflight0=int((tx["inflight"] == 0).sum()),
        frac_inflight0=float((tx["inflight"] == 0).mean()),
        # (c) daemon's own dry detector
        n_gap_measured=int(meas.sum()),
        frac_gap_measured=float(meas.mean()),
        n_gap_gt_1f=int((g[meas] > AIR_FRAME_NS).sum()),
        n_gap_gt_2f=int((g[meas] > 2 * AIR_FRAME_NS).sum()),
        gap_max_ns=int(g[meas].max()) if meas.any() else 0,
        n_spins_nonzero=int((tx["spins"] > 0).sum()),
    )
    c["frac_gap_gt_1f"] = c["n_gap_gt_1f"] / n
    return c


def seq_axis(tx, lo, hi):
    """Per-seq arrays over [lo,hi]: first-submit time, dry indicator, present."""
    n = hi - lo + 1
    s = tx["seq"].astype(np.int64)
    sel = (s >= lo) & (s <= hi)
    s = s[sel]
    t = tx["t_submit_ns"].astype(np.int64)[sel]
    infl = tx["inflight"][sel]
    gap = tx["gap_ns"][sel]
    idx = s - lo
    t_first = np.full(n, -1, dtype=np.int64)
    dry = np.zeros(n, dtype=np.int8)
    present = np.zeros(n, dtype=np.int8)
    # reverse order so the FIRST submit of a duplicated seq wins the write
    order = np.arange(len(s))[::-1]
    t_first[idx[order]] = t[order]
    present[idx] = 1
    dry_rec = (infl == 0) | (gap != QPSK_GAP_NONE)
    np.logical_or.at(dry, idx, dry_rec)   # any submit of that seq was dry
    return t_first, dry, present


def contingency(loss, dry_any, name, rng):
    """Q2 -- P(dry|lost) vs P(dry), OR, attributable fraction, perm null."""
    n = len(loss)
    a = int(((loss == 1) & (dry_any == 1)).sum())     # lost & dry
    b = int(((loss == 1) & (dry_any == 0)).sum())     # lost & not dry
    c = int(((loss == 0) & (dry_any == 1)).sum())     # kept & dry
    d = int(((loss == 0) & (dry_any == 0)).sum())     # kept & not dry
    p_dry_given_loss = a / max(a + b, 1)
    p_dry = (a + c) / n
    orr = ((a + 0.5) * (d + 0.5)) / ((b + 0.5) * (c + 0.5))
    # attributable fraction: at most every dry slot causes a loss
    af = a / max(a + b, 1)
    # circular-shift permutation null on P(dry|lost)
    null = np.empty(N_SHUFFLE)
    li = np.flatnonzero(loss == 1)
    for k in range(N_SHUFFLE):
        sh = int(rng.integers(1, n))
        null[k] = dry_any[(li + sh) % n].mean()
    return dict(
        name=name, n_slots=n, n_lost=a + b, n_dry=a + c,
        a=a, b=b, c=c, d=d,
        p_dry_given_loss=p_dry_given_loss, p_dry=p_dry,
        odds_ratio=orr, attributable_frac=af,
        null_mean=float(null.mean()), null_p95=float(np.percentile(null, 95)),
        exceeds_null=bool(p_dry_given_loss > np.percentile(null, 95)),
    )


def q3(dts, rng):
    """Autocorrelation of the continuous inter-submit-gap series, lags 1..128.
    Lag 32 x 802.93 us = 25.69 ms = the comb period.

    OUTLIER CLIP (required): every leg contains one ~200 ms inter-submit gap
    (the mid-capture wedge).  Zero-mean autocorrelation is a variance-weighted
    statistic, so that single sample dominates the whole series and crushes
    every real line to ~0.01.  dt is therefore clipped to [0, 2 air frames]
    before the transform; the clip touches <= 10 samples per leg (reported as
    n_clipped) and is the difference between seeing the cadence line and not.
    """
    dts = np.asarray(dts, dtype=np.float64)
    n_clipped = int((dts > 2 * AIR_FRAME_NS).sum() + (dts < 0).sum())
    dts = np.clip(dts, 0.0, 2 * AIR_FRAME_NS)
    ac = fft_autocorr(dts, max_lag=MAX_LAG)
    nullmax = np.empty(50)
    for k in range(50):
        p = rng.permutation(dts)
        nullmax[k] = np.abs(fft_autocorr(p, max_lag=MAX_LAG)[1:]).max()
    top = np.argsort(-np.abs(ac[1:]))[:5] + 1
    return dict(
        n=int(len(dts)), n_clipped=n_clipped,
        ac_lag1=float(ac[1]), ac_lag32=float(ac[32]), ac_lag33=float(ac[33]),
        ac_lag64=float(ac[64]), ac_lag96=float(ac[96]),
        top_lags=[[int(l), float(ac[l])] for l in top],
        null_p95_maxabs=float(np.percentile(nullmax, 95)),
        lag32_ms=32 * AIR_FRAME_NS / 1e6,
    )


def rx_comb(lt):
    """The RX loss train's own comb line, computed on the SAME lag axis as the
    host cadence series so the two can be compared leg by leg.  (accept_analyze
    quotes lag 33; lag 32 is the 25.69 ms line and is the one to compare.)"""
    a = fft_autocorr(lt["all_loss"].astype(np.float64), max_lag=MAX_LAG)
    sg = fft_autocorr(lt["singles"].astype(np.float64), max_lag=MAX_LAG)
    return dict(all_loss_lag32=float(a[32]), all_loss_lag33=float(a[33]),
                singles_lag32=float(sg[32]), singles_lag33=float(sg[33]))


def analyse(rundir, txname, rng):
    cap = os.path.join(rundir, "cap")
    out = dict(run=os.path.basename(rundir.rstrip("/")), txlog=txname)
    hdr, tx = read_txlog(os.path.join(cap, txname))
    out["txlog_hdr"] = dict(n_records=hdr["n_records"], total=hdr["total"],
                            wrapped=hdr["wrapped"])
    out["q1"] = submit_census(tx)

    # A whitened leg (QPSK_WHITEN=1) logs the WHITENED header seq word in the
    # txlog, so the TX<->RX seq join is impossible there (README_hostlog.md
    # sec 2: "with QPSK_WHITEN=1 they are whitened and every class is
    # meaningless -- exactly the pre-existing caveat on host_seq").  Detect it
    # and fall back to Q1 + a record-axis Q3.
    sq = tx["seq"].astype(np.int64)
    joinable = float((np.diff(sq) == 1).mean()) > 0.5
    out["joinable"] = joinable
    out["seq_monotone_frac"] = float((np.diff(sq) == 1).mean())
    if not joinable:
        # collapse duplicate submits of the same seq: a duplicate inserts an
        # extra sample and shifts every later one, which desynchronises the
        # lag axis (empirically 0.68 -> 0.015 at lag 32 on this leg).
        keep = np.ones(len(sq), bool)
        keep[1:] = np.diff(sq) != 0
        dts = np.diff(tx["t_submit_ns"].astype(np.int64)[keep]).astype(np.float64)
        out["q3"] = q3(dts, rng)
        out["q3"]["axis"] = ("record (submit order, duplicate seqs collapsed); "
                             "seq whitened, no RX join")
        out["note"] = ("txlog seq is WHITENED -- Q2 adjacency and the seq-axis "
                       "Q3 are INVALID on this leg; Q1 and the record-axis Q3 stand")
        fr = read_frames(os.path.join(cap, "frames.bin"))
        lt = loss_slot_trains(fr)
        if lt["usable"]:
            out["loss"] = dict(n_slots=int(lt["n_slots"]),
                               n_lost=int(lt["all_loss"].sum()),
                               n_singles=int(lt["singles"].sum()),
                               per_pct=100.0 * float(lt["all_loss"].mean()))
            out["rx_comb"] = rx_comb(lt)
        return out

    fr = read_frames(os.path.join(cap, "frames.bin"))
    lt = loss_slot_trains(fr)
    if not lt["usable"]:
        out["error"] = "loss_slot_trains unusable"
        return out
    tx_lo, tx_hi = int(tx["seq"].min()), int(tx["seq"].max())
    lo = max(tx_lo, int(lt["lo"]))
    hi = min(tx_hi, int(lt["hi"]))
    out["clip"] = dict(tx_lo=tx_lo, tx_hi=tx_hi, rx_lo=int(lt["lo"]),
                       rx_hi=int(lt["hi"]), lo=lo, hi=hi,
                       live_end_s=lt["live_end"], dur_s=lt["dur"])
    off = lo - int(lt["lo"])
    n = hi - lo + 1
    all_loss = lt["all_loss"][off:off + n]
    singles = lt["singles"][off:off + n]
    t_first, dry, present = seq_axis(tx, lo, hi)
    out["never_sent"] = int((present == 0).sum())
    out["loss"] = dict(n_slots=int(n), n_lost=int(all_loss.sum()),
                       n_singles=int(singles.sum()),
                       per_pct=100.0 * all_loss.mean())
    out["rx_comb"] = rx_comb(lt)

    # dry at this seq, or at the seq immediately before it
    dry_prev = np.zeros_like(dry)
    dry_prev[1:] = dry[:-1]
    dry_any = ((dry | dry_prev) > 0).astype(np.int8)
    out["q2"] = [contingency(all_loss, dry_any, "all_loss ~ dry(seq or seq-1)", rng),
                 contingency(singles, dry_any, "singles ~ dry(seq or seq-1)", rng),
                 contingency(all_loss, dry, "all_loss ~ dry(seq)", rng)]

    # failhdr arm (corrupt-at-host frames); seq is raw header bytes
    fh_path = os.path.join(cap, "failhdr.bin")
    if os.path.exists(fh_path):
        fhh, fh = read_failhdr(fh_path)
        fseq = fh["host_seq"].astype(np.int64)
        ok = (fh["fail_class"] == 3) & (fseq >= lo) & (fseq <= hi)  # CRC-fail: header parsed
        corrupt = np.zeros(n, dtype=np.int8)
        corrupt[fseq[ok] - lo] = 1
        out["failhdr_hdr"] = dict(n_records=fhh["n_records"], total=fhh["total"],
                                  wrapped=fhh["wrapped"],
                                  n_class3_in_span=int(ok.sum()))
        out["q2"].append(contingency(corrupt, dry_any,
                                     "failhdr class3 (CRC, seq parseable) ~ dry", rng))

    # Q3 -- autocorrelation of the CONTINUOUS submit-cadence series on the seq axis
    have = t_first >= 0
    tf = t_first.astype(np.float64)
    if have.sum() > 1:
        tf[~have] = np.interp(np.flatnonzero(~have), np.flatnonzero(have), tf[have])
    dts = np.diff(tf)
    out["q3"] = q3(dts, rng)
    out["q3"]["axis"] = "seq (interpolated over never-sent slots)"
    ac = None
    # same for the binary dry train -- reported ONLY to show it is unusable:
    # a ~130-event binary train over 875k slots has no meaningful spectrum.
    acd = fft_autocorr(dry.astype(np.float64), max_lag=MAX_LAG)
    out["q3"]["dry_ac_lag32"] = float(acd[32])
    out["q3"]["dry_ac_maxabs_1_128"] = float(np.abs(acd[1:]).max())
    out["q3"]["dry_n_events"] = int(dry.sum())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rundirs", nargs="+")
    ap.add_argument("--txlog", default="txlog_peer.bin")
    ap.add_argument("--json", default=None)
    a = ap.parse_args()
    rng = np.random.default_rng(20260904)
    res = []
    for rd in a.rundirs:
        r = analyse(rd, a.txlog, rng)
        res.append(r)
        print(json.dumps(r, indent=1, default=float))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(res, f, indent=1, default=float)


if __name__ == "__main__":
    main()
