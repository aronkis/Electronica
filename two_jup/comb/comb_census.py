#!/usr/bin/env python3
"""comb_census.py FILE.bin [--failhdr F] [--txlog T] [--out OUT.json]

Census of the residual loss over the live window (settle 15s, live-window
end rule, same as accept_analyze.py):

  fail_class census (0-4)        from frames.bin's fail_class word (was
                                  `reserved`; enum qpsk_fail_class in
                                  host_app_k5/qpsk_join.h). Captures made
                                  before the COMB Task-1 daemon change always
                                  read fail_class==0 -- this is flagged, not
                                  silently reported as "all OK".
  corruption-onset histogram      first_zero_off from the failhdr ring (--failhdr),
  (64 B bins)                     binned in 64-byte offsets, QPSK_FZO_NONE
                                  (no zero tail found) reported separately.
  run-length bins                 singles/doubles/3-4/5-20/21-100/>100,
                                  reusing the same reconstruction
                                  accept_analyze.py's PER decomposition uses
                                  (two_jup/comb/common.py:loss_slot_trains).
  TX<->RX join (--txlog)          per lost RX frame (host_seq values with no
                                  crc_ok==1 record): NEVER_SENT (no txlog
                                  record for that seq) / SENT_NOT_DECODED
                                  (txlog record exists) / UNJOINABLE (outside
                                  the txlog's t_submit_ns coverage span).
                                  DECODED_NOT_DELIVERED (--delivered)         a
                                  decoded (crc_ok==1) frame whose seq is
                                  absent from a supplied delivery-confirmation
                                  set (tun/qpsk_perf sequence set; see
                                  joinlog.read_delivered_seqs). Without
                                  --delivered this class stays UNCLASSIFIED
                                  with an explicit note, never silently
                                  folded into OK or another class.
  fail_class x crc_ok cross-tab   surfaces the crc_ok==0 & fail_class==0
                                  inconsistency README_hostlog.md sec 2 warns
                                  about in -B mode (the implication
                                  crc_ok==0 => fail_class>0 does not hold
                                  there).

Prints a short table and (with --out) writes the full result as JSON.
"""
import argparse
import json
import sys

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from common import interp_t_mono_ns, loss_slot_trains, read_frames
from joinlog import QPSK_FZO_NONE, read_delivered_seqs, read_failhdr, read_txlog

FAIL_CLASS_NAMES = {0: "OK", 1: "MAGIC", 2: "LEN", 3: "CRC", 4: "ZEROTAIL"}


def fail_class_census(fr, lo_t, hi_t, ts):
    w = (ts >= lo_t) & (ts < hi_t)
    fc = fr["reserved"][w].astype(np.int64)
    counts = {FAIL_CLASS_NAMES.get(k, str(k)): int((fc == k).sum())
              for k in range(5)}
    other = int(((fc < 0) | (fc > 4)).sum())
    if other:
        counts["OTHER"] = other
    degenerate = counts.get("OK", 0) == int(w.sum()) and int(w.sum()) > 0
    return dict(counts=counts, n=int(w.sum()), degenerate_all_ok=degenerate)


def fail_class_crc_ok_crosstab(fr, lo_t, hi_t, ts):
    """fail_class x crc_ok cross-tab over the same window as
    fail_class_census(). Surfaces README_hostlog.md sec 2's warning:
    `crc_ok==0 => fail_class>0` does NOT hold in -B mode (the noisy-bucket
    scorer sets crc_ok = (bucket==QBER_CLEAN), independent of header parse),
    so a nonzero crc_ok==0 & fail_class==0 cell is expected there and a bug
    signal in -G/tun mode (what the legs run). crc_ok==1 & fail_class!=0 is
    always inconsistent (a decoded frame cannot have failed a check) and is
    flagged regardless of mode."""
    w = (ts >= lo_t) & (ts < hi_t)
    crc_ok = fr["crc_ok"][w].astype(np.int64)
    fc = fr["reserved"][w].astype(np.int64)
    table = {}
    for crc in (0, 1):
        row = {}
        for cls in range(5):
            row[FAIL_CLASS_NAMES.get(cls, str(cls))] = int(((crc_ok == crc) & (fc == cls)).sum())
        table[f"crc_ok={crc}"] = row
    inconsistent_crc0_class0 = table["crc_ok=0"]["OK"]
    inconsistent_crc1_classN = int(sum(v for k, v in table["crc_ok=1"].items() if k != "OK"))
    return dict(table=table,
                crc_ok0_fail_class0=inconsistent_crc0_class0,
                crc_ok1_fail_class_nonzero=inconsistent_crc1_classN)


def class4_split(failhdr_arr):
    """Task-1-review rule: class 4 (ZEROTAIL) must be split, not reported as
    one bucket. first_zero_off == 0 means the WHOLE slice is a zero suffix --
    an entirely-zero RX carve slot (a delivery-plane hole; under
    rxq_zerohdr such slots land in class 1 instead, per README_hostlog.md
    sec 2, so a first_zero_off==0 class-4 record here means zerohdr was NOT
    in effect). first_zero_off > 0 is a real partial zero tail -- the TX
    ALIGNLOSS signature the campaign is chasing. Only failhdr records (not
    frames.bin's bare fail_class) carry first_zero_off, so this split is
    only available with --failhdr. first_zero_off carries an estimated +/-10%
    measurement tolerance (Task 1 review) -- material for cross-tap onset
    matching in T3/T4, not for this exact split (0 vs >0 is exact)."""
    fc = failhdr_arr["fail_class"].astype(np.int64)
    fzo = failhdr_arr["first_zero_off"].astype(np.int64)
    c4 = fc == 4
    n_c4 = int(c4.sum())
    if n_c4 == 0:
        return dict(n_class4=0, delivery_hole_fzo0=0, alignloss_fzo_gt0=0)
    delivery_hole = int(((fzo == 0) & c4).sum())
    alignloss = int(((fzo > 0) & c4).sum())
    return dict(n_class4=n_c4, delivery_hole_fzo0=delivery_hole,
                alignloss_fzo_gt0=alignloss)


def failhdr_window_mask(failhdr_arr, t0_mono_ns, lo_t, hi_t):
    """failhdr_rec.t_mono_ns is documented as the SAME clock as
    frame_rec.t_mono_ns (qpsk_join.h:176), so the failhdr ring must be
    clipped to the identical [SETTLE_S, live_end) window as
    fail_class_census() before any downstream split -- Task-2-review finding
    1. Without this, the settle ramp and any post-live_end wedge tail (where
    unfilled carve slots are common) land directly on the class-4
    delivery-hole-vs-ALIGNLOSS split. t0_mono_ns is frames.bin's own first
    record's t_mono_ns (both files come from the same daemon lifetime)."""
    fh_ts = (failhdr_arr["t_mono_ns"].astype(np.int64) - t0_mono_ns) / 1e9
    return (fh_ts >= lo_t) & (fh_ts < hi_t)


def onset_histogram(failhdr_arr, bin_bytes=64):
    fzo = failhdr_arr["first_zero_off"].astype(np.int64)
    none_mask = fzo == QPSK_FZO_NONE
    n_none = int(none_mask.sum())
    have = fzo[~none_mask]
    hist = {}
    if have.size:
        bins = (have // bin_bytes).astype(np.int64)
        for b in sorted(set(bins.tolist())):
            lo = int(b * bin_bytes)
            hist[f"[{lo},{lo + bin_bytes})"] = int((bins == b).sum())
    return dict(bin_bytes=bin_bytes, n_none=n_none, n_have=int(have.size), hist=hist)


def tx_rx_join(lt, tx_arr, delivered_seqs=None):
    """lt: usable loss_slot_trains() result (must carry 'cw'/'cw_t_mono_ns',
    i.e. produced by the current loss_slot_trains -- see common.py). tx_arr:
    the full txlog structured array (JOINLOG.TXLOG_DTYPE), not just a seq
    set -- ARQ can submit several txlog records for the SAME seq (a resend);
    "sent" is any record with that seq (Task-1-review rule 3), which a `set`
    over tx_arr['seq'] gives for free since duplicates collapse.

    Classification is SEQ-MEMBERSHIP FIRST (Defect fix, 2026-09-03: a same-
    host loopback capture never exposed this, but the first real cross-board
    leg did -- comb_census.py:190-195 was applying the t_submit_ns span gate
    BEFORE testing seq membership, so on any RF leg every lost seq fell into
    unjoinable by construction, and with the wrong-board's txlog everything
    fell into never_sent). The correct order:
      1. seq present in the TX log (any record, ARQ resends included)
         -> SENT (sent_not_decoded, or decoded_not_delivered per
         --delivered); seq absent -> NEVER_SENT. This is decided ONLY by
         set membership, never veto'd by the time span.
      2. The TX log's t_submit_ns COVERAGE SPAN is used ONLY to ANNOTATE:
         `unjoinable_time` counts how many of the lost seqs' ESTIMATED
         times (common.py:interp_t_mono_ns -- a lost RX frame has no
         t_mono_ns of its own) fall outside [t_submit.min(), .max()]. This
         is a coverage diagnostic (e.g. "the txlog dump doesn't span this
         part of the capture"), reported alongside the real classification,
         and NEVER changes never_sent/sent_not_decoded/decoded_not_delivered.

    On a same-host loopback capture t_mono_ns is directly comparable across
    the TX and RX paths (one CLOCK_MONOTONIC), so `unjoinable_time` is a
    meaningful coverage check there. On a real cross-board forward/reverse
    leg the two boards' CLOCK_MONOTONIC are NOT the same clock, so
    `unjoinable_time` on a cross-board join is not a trustworthy coverage
    signal either -- report it, do not interpret it. CALLERS PRINT A RUNTIME
    CAVEAT (see main()) about this.

    delivered_seqs: optional set of int seqs (joinlog.read_delivered_seqs) --
    the tun/qpsk_perf delivery-confirmation set qpsk_join.h:239-241 declares
    but does not (yet) have an on-disk producer for. When given, DECODED
    frames (lt['cw'], i.e. crc_ok==1 in-window) whose seq is absent from
    this set are classified DECODED_NOT_DELIVERED; when absent, the whole
    class stays the UNCLASSIFIED placeholder string (qpsk_join.h:239-241:
    "delivered may be NULL ... a decoded frame is reported OK -- state that
    ... rather than silently calling the class absent"), never silently
    folded into OK.
    """
    all_loss = lt["all_loss"]
    lost_positions = np.flatnonzero(all_loss)
    lost_seqs = (lost_positions + lt["lo"]).astype(np.int64)

    txlog_seqs = set(tx_arr["seq"].astype(np.int64).tolist())  # any record = sent
    t_submit = tx_arr["t_submit_ns"].astype(np.int64)
    span_lo = int(t_submit.min()) if t_submit.size else None
    span_hi = int(t_submit.max()) if t_submit.size else None

    est_t = interp_t_mono_ns(lt, lost_seqs) if lost_seqs.size else np.array([], dtype=np.int64)

    never_sent, sent_not_decoded, unjoinable_time = [], [], []
    for s, t in zip(lost_seqs.tolist(), est_t.tolist()):
        # (1) seq membership decides the class, unconditionally.
        if s in txlog_seqs:
            sent_not_decoded.append(s)
        else:
            never_sent.append(s)
        # (2) span coverage is annotation only -- never vetoes (1) above.
        if span_lo is not None and (t < span_lo or t > span_hi):
            unjoinable_time.append(s)

    if delivered_seqs is not None:
        decoded_seqs = lt["cw"].astype(np.int64).tolist()
        not_delivered = sorted(s for s in decoded_seqs if s not in delivered_seqs)
        decoded_not_delivered = len(not_delivered)
        sample_decoded_not_delivered = not_delivered[:10]
    else:
        decoded_not_delivered = "UNCLASSIFIED (no delivery-confirmation source given)"
        sample_decoded_not_delivered = []

    return dict(
        n_lost_rx=int(lost_seqs.size),
        never_sent=len(never_sent),
        sent_not_decoded=len(sent_not_decoded),
        decoded_not_delivered=decoded_not_delivered,
        unjoinable_time=len(unjoinable_time),
        txlog_t_submit_span_ns=[span_lo, span_hi],
        sample_never_sent=never_sent[:10],
        sample_sent_not_decoded=sent_not_decoded[:10],
        sample_unjoinable_time=unjoinable_time[:10],
        sample_decoded_not_delivered=sample_decoded_not_delivered,
    )


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("file", help="frames.bin")
    ap.add_argument("--failhdr", help="failhdr.bin (QFAILH01)")
    ap.add_argument("--txlog", help="txlog.bin (QTXLOG02)")
    ap.add_argument("--delivered",
                     help="raw <u4 seq array, no header -- see "
                          "joinlog.read_delivered_seqs -- classifies "
                          "DECODED_NOT_DELIVERED in the join")
    ap.add_argument("--out", help="write full result as JSON to this path")
    args = ap.parse_args(argv)

    fr = read_frames(args.file)
    lt = loss_slot_trains(fr)
    tag = args.file.split("/")[-2] if "/" in args.file else args.file
    result = dict(path=args.file, usable=lt["usable"], dur=lt["dur"],
                  live_end=lt["live_end"], wedged=lt["wedged"])
    if not lt["usable"]:
        print(f"{tag}: UNUSABLE (live window {lt['live_end']:.0f}s of {lt['dur']:.0f}s"
              f"{', WEDGED' if lt['wedged'] else ''})")
        if args.out:
            with open(args.out, "w") as f:
                json.dump(result, f, indent=2)
        return

    from common import SETTLE_S
    tm = fr["t_mono_ns"].astype(np.int64)
    t0_mono_ns = int(tm[0])
    ts = (tm - tm[0]) / 1e9
    fc = fail_class_census(fr, SETTLE_S, lt["live_end"], ts)
    ct = fail_class_crc_ok_crosstab(fr, SETTLE_S, lt["live_end"], ts)
    result["fail_class_census"] = fc
    result["fail_class_crc_ok_crosstab"] = ct
    result["run_bins"] = lt["run_bins"]
    result["validity_frac"] = lt["validity_frac"]
    result["n_slots"] = lt["n_slots"]
    result["slot_lo"] = lt["lo"]
    result["slot_hi"] = lt["hi"]

    print(f"=== {tag}  live {lt['live_end']:.0f}s/{lt['dur']:.0f}s"
          f"{' [WEDGE]' if lt['wedged'] else ''} ===")
    print(f"  fail_class census (n={fc['n']}): {fc['counts']}"
          + ("  [DEGENERATE: all fail_class==0 -- pre-COMB-instrumentation "
             "capture, fail_class not populated]" if fc["degenerate_all_ok"] else ""))
    print(f"  run-length bins: {lt['run_bins']}")
    if ct["crc_ok0_fail_class0"] or ct["crc_ok1_fail_class_nonzero"]:
        print(f"  fail_class x crc_ok cross-tab: crc_ok=0&fail_class=0 (OK only in -B "
              f"mode)={ct['crc_ok0_fail_class0']}  crc_ok=1&fail_class!=0 (always "
              f"inconsistent)={ct['crc_ok1_fail_class_nonzero']}")

    if args.failhdr:
        fh_hdr, fh_arr_raw = read_failhdr(args.failhdr)
        fh_mask = failhdr_window_mask(fh_arr_raw, t0_mono_ns, SETTLE_S, lt["live_end"])
        fh_arr = fh_arr_raw[fh_mask]
        oh = onset_histogram(fh_arr)
        c4 = class4_split(fh_arr)
        result["failhdr"] = dict(header=fh_hdr, n_raw=int(fh_arr_raw.size),
                                  n_windowed=int(fh_arr.size),
                                  onset_histogram=oh, class4_split=c4)
        print(f"  onset histogram (failhdr n_records={fh_hdr['n_records']} raw, "
              f"{fh_arr.size} in live window, wrapped={fh_hdr['wrapped']}): "
              f"n_none={oh['n_none']} n_have={oh['n_have']}")
        for k, v in sorted(oh["hist"].items(), key=lambda kv: -kv[1])[:10]:
            print(f"    {k}: {v}")
        print(f"  class4 split (windowed): n_class4={c4['n_class4']}  "
              f"delivery_hole(fzo==0)={c4['delivery_hole_fzo0']}  "
              f"alignloss(fzo>0)={c4['alignloss_fzo_gt0']}")

    if args.txlog:
        print("  [CAVEAT] TX<->RX join classification (never_sent/sent_not_decoded) "
              "is decided by seq membership ONLY. The t_submit_ns span is an "
              "ANNOTATION (unjoinable_time), never a veto on classification -- "
              "CLOCK_MONOTONIC is per-machine and NOT comparable across boards, "
              "so unjoinable_time is a meaningful coverage check only for a "
              "same-host (loopback) capture; on a cross-board leg, report it, "
              "do not interpret it.")
        tx_hdr, tx_arr = read_txlog(args.txlog)
        delivered_seqs = None
        if args.delivered:
            delivered_seqs = read_delivered_seqs(args.delivered)
        join = tx_rx_join(lt, tx_arr, delivered_seqs=delivered_seqs)
        result["txlog"] = dict(header=tx_hdr)
        result["join"] = join
        print(f"  TX<->RX join (txlog n_records={tx_hdr['n_records']}, "
              f"wrapped={tx_hdr['wrapped']}, t_submit_span={join['txlog_t_submit_span_ns']}):")
        print(f"    lost_rx={join['n_lost_rx']}  never_sent={join['never_sent']}  "
              f"sent_not_decoded={join['sent_not_decoded']}  "
              f"unjoinable_time(annotation only)={join['unjoinable_time']}  "
              f"decoded_not_delivered={join['decoded_not_delivered']}")

    if args.out:
        def _clean(o):
            if isinstance(o, dict):
                return {k: _clean(v) for k, v in o.items()}
            if isinstance(o, list):
                return [_clean(v) for v in o]
            if isinstance(o, (np.integer,)):
                return int(o)
            if isinstance(o, (np.floating,)):
                return float(o)
            if isinstance(o, bytes):
                return o.decode("ascii", "replace")
            return o
        with open(args.out, "w") as f:
            json.dump(_clean(result), f, indent=2)


if __name__ == "__main__":
    main(sys.argv[1:])
