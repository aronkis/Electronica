#!/usr/bin/env python3
"""two_jup/tests/test_comb_tools.py -- T0b analysis tooling tests.

Covers: synthetic period-32 loss recovery via FFT autocorrelation with the
permutation null respected; a pure-noise train flags no lag; comb-phase
histograms (fixed-phase non-uniform, random uniform); fail-class census on a
synthetic frames.bin; the TX<->RX join classification (never-sent /
sent-not-decoded / delivered-excluded); and round-trip reads of the
QPSK_FAILHDR / QPSK_TXLOG record formats (host_app_k5/qpsk_join.h).

Run: python3 -m pytest two_jup/tests/test_comb_tools.py -v
     (or: python3 two_jup/tests/test_comb_tools.py)
"""
import os
import struct
import sys
import tempfile

import numpy as np
import pytest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(REPO, "comb"))

from comb.common import fft_autocorr, loss_slot_trains, permutation_null  # noqa: E402
from comb.comb_phase import phase_histogram  # noqa: E402
from comb.comb_census import (  # noqa: E402
    class4_split, fail_class_census, failhdr_window_mask, tx_rx_join,
)
from comb.joinlog import (  # noqa: E402
    FAILHDR_DTYPE, LOG_HDR, TXLOG_DTYPE, read_delivered_seqs, read_failhdr, read_txlog,
)

FRAME_REC = struct.Struct("<QQIIIIIIII")
assert FRAME_REC.size == 48
FAILHDR_REC = struct.Struct("<QIIBBH12s")
assert FAILHDR_REC.size == 32
TXLOG_REC = struct.Struct("<QQIIIHH")
assert TXLOG_REC.size == 32


# --------------------------------------------------------------- fixtures --
def write_frames_bin(path, records):
    """records: list of dicts with keys t_mono_ns,t_real_ns,host_seq,crc_ok,
    reg_packets,reg_biterr,reg_rstcs,reg_cfc,reg_adcforensic,fail_class
    (fail_class packed into the `reserved`/last field)."""
    with open(path, "wb") as f:
        for r in records:
            f.write(FRAME_REC.pack(
                r.get("t_mono_ns", 0), r.get("t_real_ns", 0),
                r.get("host_seq", 0), r.get("crc_ok", 0),
                r.get("reg_packets", 0), r.get("reg_biterr", 0),
                r.get("reg_rstcs", 0), r.get("reg_cfc", 0),
                r.get("reg_adcforensic", 0), r.get("fail_class", 0),
            ))


def make_synthetic_capture(path, n_slots=6000, period=32, frame_dt_ns=800_000,
                            settle_s=0.0, extra_tail_s=2.0, seed=0):
    """A clean-except-every-Nth-slot-lost capture: emits one clean frame_rec
    per slot except for slots where lost_mask is True (skipped -- an isolated
    single loss, matching accept_analyze's/loss_slot_trains's singles
    construction). Starts host_seq at 1000 to exercise the `lo` offset.
    Returns the set of lost host_seq values.
    """
    lo = 1000
    lost = set(range(lo + period - 1, lo + n_slots, period))  # isolated singles
    t0 = 0
    records = []
    for i in range(n_slots):
        seq = lo + i
        t_ns = t0 + i * frame_dt_ns
        if seq in lost:
            continue
        records.append(dict(t_mono_ns=t_ns, host_seq=seq, crc_ok=1, fail_class=0))
    write_frames_bin(path, records)
    return lost


# ------------------------------------------------------- autocorr / null --
def test_fft_autocorr_matches_direct_correlate():
    rng = np.random.default_rng(1)
    x = rng.integers(0, 2, size=500).astype(np.float64)
    xc = x - x.mean()
    direct = np.correlate(xc, xc, "full")[len(xc) - 1:len(xc) - 1 + 33]
    direct = direct / direct[0]
    got = fft_autocorr(x, max_lag=32)
    np.testing.assert_allclose(got, direct, atol=1e-8)


def test_period32_recovered_as_top_lag_with_null_respected():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "frames.bin")
        make_synthetic_capture(path, n_slots=8000, period=32)
        import comb.common as common
        fr = common.read_frames(path)
        lt = loss_slot_trains(fr, settle_s=0.0)
        assert lt["usable"]
        x = lt["singles"]
        ac = fft_autocorr(x, max_lag=128)
        null = permutation_null(x, max_lag=128, n_shuffle=200, seed=0)
        lag = int(np.argmax(ac[1:129])) + 1
        assert lag == 32, f"expected top lag 32, got {lag}"
        assert ac[32] > null, f"lag32 value {ac[32]} did not clear null {null}"


def test_pure_noise_train_flags_no_lag_above_null():
    # NOTE: an iid train is itself exchangeable with the permutation null, so
    # this is expected to fail for ~5% of seeds by construction (that's what
    # "95th percentile" means) -- seed 7 is fixed for a reproducible pass;
    # see the seed sweep in the T0b report for the empirical ~5% rate.
    rng = np.random.default_rng(7)
    n = 8000
    x = (rng.random(n) < 0.045).astype(np.float64)  # ~4.5% iid loss, no structure
    ac = fft_autocorr(x, max_lag=128)
    null = permutation_null(x, max_lag=128, n_shuffle=200, seed=7)
    assert np.max(np.abs(ac[1:129])) <= null, (
        "an iid noise train should not clear its own permutation null")


# ------------------------------------------------------------- phase test --
def test_phase_histogram_fixed_comb_is_nonuniform():
    n = 8000
    period = 32
    x = np.zeros(n, dtype=np.int8)
    x[period - 1::period] = 1  # fixed phase = period-1
    r = phase_histogram(x, period)
    assert r["pvalue"] < 0.05
    assert r["argmax"] == period - 1


def test_phase_histogram_random_train_is_uniform():
    rng = np.random.default_rng(7)
    n = 20000
    period = 32
    x = (rng.random(n) < 0.03).astype(np.int8)
    r = phase_histogram(x, period)
    assert r["pvalue"] >= 0.05, f"random train falsely flagged non-uniform (p={r['pvalue']})"


# ------------------------------------------------------------------ census --
def test_fail_class_census_on_synthetic_frames():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "frames.bin")
        # 10 OK, 3 MAGIC, 2 LEN, 4 CRC, 1 ZEROTAIL, spread over 1s so the
        # live-window logic (settle=0 override) sees them all as one window.
        records = []
        counts = {0: 10, 1: 3, 2: 2, 3: 4, 4: 1}
        seq = 0
        t_ns = 0
        for cls, n in counts.items():
            for _ in range(n):
                records.append(dict(t_mono_ns=t_ns, host_seq=seq,
                                     crc_ok=1 if cls == 0 else 0, fail_class=cls))
                seq += 1
                t_ns += 800_000
        write_frames_bin(path, records)
        import comb.common as common
        fr = common.read_frames(path)
        ts = (fr["t_mono_ns"].astype(np.int64) - fr["t_mono_ns"][0]) / 1e9
        fc = fail_class_census(fr, 0.0, ts[-1] + 1.0, ts)
        assert fc["counts"]["OK"] == 10
        assert fc["counts"]["MAGIC"] == 3
        assert fc["counts"]["LEN"] == 2
        assert fc["counts"]["CRC"] == 4
        assert fc["counts"]["ZEROTAIL"] == 1
        assert not fc["degenerate_all_ok"]


def test_fail_class_census_flags_degenerate_pre_instrumentation_capture():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "frames.bin")
        records = [dict(t_mono_ns=i * 800_000, host_seq=i, crc_ok=1, fail_class=0)
                   for i in range(50)]
        write_frames_bin(path, records)
        import comb.common as common
        fr = common.read_frames(path)
        ts = (fr["t_mono_ns"].astype(np.int64) - fr["t_mono_ns"][0]) / 1e9
        fc = fail_class_census(fr, 0.0, ts[-1] + 1.0, ts)
        assert fc["degenerate_all_ok"]


# --------------------------------------------------------------- TX/RX join --
def _txlog_array(records):
    """records: list of dicts with t_submit_ns/seq (other fields defaulted)."""
    dt = TXLOG_DTYPE
    arr = np.zeros(len(records), dtype=dt)
    for i, r in enumerate(records):
        arr[i] = (r.get("t_submit_ns", 0), r.get("t_complete_ns", 0),
                  r["seq"], r.get("gap_ns", 0xFFFFFFFF), r.get("slot", 0),
                  r.get("inflight", 0), r.get("spins", 0))
    return arr


def _lt_fixture(lo, hi, all_loss, cw, cw_t_mono_ns):
    return dict(usable=True, lo=lo, hi=hi,
                all_loss=np.array(all_loss, dtype=np.int8),
                cw=np.array(cw, dtype=np.int64),
                cw_t_mono_ns=np.array(cw_t_mono_ns, dtype=np.int64))


def test_join_never_sent_sent_not_decoded_and_delivered_excluded():
    # 3 slots (seq 0,1,2): seq0 missing (never sent), seq1 present/decoded
    # (delivered -- excluded from the lost set entirely), seq2 missing (sent
    # but not decoded). Clean anchors at seq1 (t=1000) only, so interpolated
    # times for seq0/seq2 fall inside a generous txlog span below.
    lt = _lt_fixture(lo=0, hi=2, all_loss=[1, 0, 1], cw=[1], cw_t_mono_ns=[1000])
    tx_arr = _txlog_array([dict(seq=2, t_submit_ns=1000)])  # only seq2 ever submitted
    result = tx_rx_join(lt, tx_arr)
    assert result["n_lost_rx"] == 2
    assert result["never_sent"] == 1
    assert 0 in result["sample_never_sent"]
    assert result["sent_not_decoded"] == 1
    assert 2 in result["sample_sent_not_decoded"]
    assert result["unjoinable_time"] == 0
    # seq1 (delivered) never appears in either bucket
    assert 1 not in result["sample_never_sent"]
    assert 1 not in result["sample_sent_not_decoded"]


def test_join_treats_arq_resend_as_sent_any_record():
    # Task-1-review rule 3: the TX log can hold SEVERAL records for the same
    # seq (ARQ resends); "sent" means ANY record with that seq, not exactly
    # one. seq0 is resent 3x and must still classify as sent_not_decoded
    # (not, say, triple-counted or rejected).
    # Single-anchor interpolation (common.py:interp_t_mono_ns) returns the
    # anchor's own time for any seq, so the lost seq (0) interpolates to
    # t=5000; keep the txlog's t_submit_ns span bracketing that.
    lt = _lt_fixture(lo=0, hi=0, all_loss=[1], cw=[10], cw_t_mono_ns=[5000])
    tx_arr = _txlog_array([
        dict(seq=0, t_submit_ns=4900),
        dict(seq=0, t_submit_ns=5000),  # resend
        dict(seq=0, t_submit_ns=5100),  # resend
    ])
    result = tx_rx_join(lt, tx_arr)
    assert result["n_lost_rx"] == 1
    assert result["sent_not_decoded"] == 1
    assert result["never_sent"] == 0


def test_join_span_is_annotation_only_never_a_veto():
    # Defect fix (2026-09-03, first real cross-board leg
    # two_jup/comb/runs/20260903_175236_legB_m16r2): the t_submit_ns span
    # must NEVER veto the never_sent/sent_not_decoded classification -- it
    # is an ANNOTATION (unjoinable_time) only. Losses at seq 10 (interpolated
    # t~10_000, inside the txlog span [0, 50_000]) and seq 90 (t~90_000,
    # OUTSIDE it): seq10 is not in the txlog -> never_sent regardless of
    # span; seq90 is ALSO not in the txlog -> ALSO never_sent (not
    # "unjoinable" -- absence from the log always means never_sent), and is
    # additionally counted in unjoinable_time because its estimated time
    # falls outside the log's coverage span.
    lt = _lt_fixture(lo=0, hi=100, all_loss=[0] * 101, cw=[0, 100],
                      cw_t_mono_ns=[0, 100_000])
    lt["all_loss"][10] = 1  # seq=10, t~10_000: inside span
    lt["all_loss"][90] = 1  # seq=90, t~90_000: outside span
    tx_arr = _txlog_array([dict(seq=5, t_submit_ns=0),
                            dict(seq=45, t_submit_ns=50_000)])
    result = tx_rx_join(lt, tx_arr)
    assert result["n_lost_rx"] == 2
    # BOTH are never_sent (neither seq is in the txlog) -- the span never
    # changes this.
    assert result["never_sent"] == 2
    assert 10 in result["sample_never_sent"]
    assert 90 in result["sample_never_sent"]
    assert result["sent_not_decoded"] == 0
    # unjoinable_time is the coverage annotation: only seq90's estimated
    # time falls outside [0, 50_000].
    assert result["unjoinable_time"] == 1
    assert 90 in result["sample_unjoinable_time"]
    assert 10 not in result["sample_unjoinable_time"]


def test_join_cross_board_all_lost_outside_span_but_sent_classifies_correctly():
    # The exact defect scenario from the first real cross-board leg
    # (two_jup/comb/runs/20260903_175236_legB_m16r2): every lost seq's
    # interpolated RX time falls OUTSIDE the TX log's t_submit_ns coverage
    # span (different boards, unrelated CLOCK_MONOTONIC epochs) but every
    # lost seq WAS actually submitted (present in the txlog). Before the
    # fix this returned unjoinable == n_lost_rx and sent_not_decoded == 0;
    # after the fix, sent_not_decoded == n_lost_rx and unjoinable_time is
    # reported separately (still counting all of them, since the span truly
    # doesn't cover the RX-side estimated times -- that's just not allowed
    # to change the classification).
    lo, hi = 1000, 1009
    all_loss = [1] * 10  # every slot in [1000,1009] is lost
    # Clean anchors are far outside this synthetic little range (RX-side
    # timescale), forcing every lost seq's interpolated time (near 0) to sit
    # outside the TX log's span (deliberately on a totally different
    # numeric scale, mimicking two different boards' CLOCK_MONOTONIC).
    lt = _lt_fixture(lo=lo, hi=hi, all_loss=all_loss, cw=[lo - 1, hi + 1],
                      cw_t_mono_ns=[0, 100])
    tx_arr = _txlog_array([dict(seq=s, t_submit_ns=10_000_000 + s)
                            for s in range(lo, hi + 1)])  # ALL lost seqs sent
    result = tx_rx_join(lt, tx_arr)
    assert result["n_lost_rx"] == 10
    assert result["sent_not_decoded"] == 10
    assert result["never_sent"] == 0
    assert result["unjoinable_time"] == 10  # reported separately, doesn't veto


def test_class4_split_delivery_hole_vs_alignloss():
    # Task-1-review rule 1: class 4 must split on first_zero_off == 0
    # (all-zero carve slice -- delivery-plane hole) vs > 0 (real TX
    # ALIGNLOSS). Build 2 class-4 records (one each way) plus one class-1
    # (ignored by the split) and confirm the counts land correctly.
    recs = np.zeros(3, dtype=FAILHDR_DTYPE)
    recs[0] = (0, 1, 0, 4, 0, 0xFFFF, tuple(b"\x00" * 12))            # fzo==0
    recs[1] = (0, 2, 500, 4, 0, 0xFFFF, tuple(b"\x00" * 12))          # fzo>0
    recs[2] = (0, 3, 0xFFFFFFFF, 1, 0, 0xFFFF, tuple(b"\x00" * 12))   # class 1, not 4
    r = class4_split(recs)
    assert r["n_class4"] == 2
    assert r["delivery_hole_fzo0"] == 1
    assert r["alignloss_fzo_gt0"] == 1


def test_failhdr_window_excludes_out_of_window_records():
    # Task-2-review finding 1: failhdr.t_mono_ns must be clipped to the same
    # [SETTLE_S, live_end) window as the frames census before any split --
    # otherwise settle-ramp / post-live_end junk contaminates class4_split.
    t0 = 1_000_000_000  # arbitrary frames.bin t_mono_ns[0]
    recs = np.zeros(3, dtype=FAILHDR_DTYPE)
    # record 0: t = t0 + 5s -- BEFORE settle (SETTLE_S=15s) -> excluded
    recs[0] = (t0 + 5 * 10**9, 1, 0, 4, 0, 0xFFFF, tuple(b"\x00" * 12))
    # record 1: t = t0 + 20s -- inside [15, 100) -> included
    recs[1] = (t0 + 20 * 10**9, 2, 500, 4, 0, 0xFFFF, tuple(b"\x00" * 12))
    # record 2: t = t0 + 200s -- AFTER live_end=100 -> excluded
    recs[2] = (t0 + 200 * 10**9, 3, 0, 4, 0, 0xFFFF, tuple(b"\x00" * 12))
    mask = failhdr_window_mask(recs, t0, 15.0, 100.0)
    assert list(mask) == [False, True, False]
    windowed = recs[mask]
    r = class4_split(windowed)
    assert r["n_class4"] == 1
    assert r["alignloss_fzo_gt0"] == 1  # only record 1 (fzo=500) survives
    assert r["delivery_hole_fzo0"] == 0  # record 0's fzo==0 must NOT count


# --------------------------------------------------- decoded_not_delivered --
def test_join_classifies_decoded_not_delivered_with_delivered_set():
    # Task-2-review finding 2: --delivered plumbed through -> a decoded
    # (crc_ok==1, in lt['cw']) frame absent from the delivered set is
    # DECODED_NOT_DELIVERED, not silently folded into OK.
    lt = _lt_fixture(lo=0, hi=2, all_loss=[0, 0, 0], cw=[0, 1, 2],
                      cw_t_mono_ns=[0, 1000, 2000])
    tx_arr = _txlog_array([dict(seq=0, t_submit_ns=0), dict(seq=1, t_submit_ns=1000),
                            dict(seq=2, t_submit_ns=2000)])
    delivered = {0, 2}  # seq 1 decoded but never delivered
    result = tx_rx_join(lt, tx_arr, delivered_seqs=delivered)
    assert result["decoded_not_delivered"] == 1
    assert 1 in result["sample_decoded_not_delivered"]
    assert 0 not in result["sample_decoded_not_delivered"]
    assert 2 not in result["sample_decoded_not_delivered"]


def test_join_decoded_not_delivered_stays_unclassified_without_delivered_arg():
    lt = _lt_fixture(lo=0, hi=0, all_loss=[0], cw=[0], cw_t_mono_ns=[0])
    tx_arr = _txlog_array([dict(seq=0, t_submit_ns=0)])
    result = tx_rx_join(lt, tx_arr)  # no delivered_seqs
    assert result["decoded_not_delivered"] == "UNCLASSIFIED (no delivery-confirmation source given)"


def test_read_delivered_seqs_roundtrip():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "delivered.bin")
        with open(path, "wb") as f:
            for seq in (3, 7, 9):
                f.write(struct.pack("<I", seq))
        got = read_delivered_seqs(path)
        assert got == {3, 7, 9}


# --------------------------------------------- end-to-end join integration --
def test_join_end_to_end_real_loss_slot_trains_pipeline():
    # Task-2-review finding 9: feed a REAL loss_slot_trains() output (not a
    # hand-built _lt_fixture dict) into tx_rx_join(), so a key/dtype drift
    # between the two functions would fail this test.
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "frames.bin")
        lost = make_synthetic_capture(path, n_slots=500, period=32)
        import comb.common as common
        fr = common.read_frames(path)
        lt = loss_slot_trains(fr, settle_s=0.0)
        assert lt["usable"]
        lost_seqs = sorted(lost)
        # TX log covers every seq except the very first lost one (never_sent).
        # t_submit_ns must be on the SAME scale as the synthetic capture's own
        # t_mono_ns (frame_dt_ns=800_000 in make_synthetic_capture) so the
        # interpolated lost-frame times (common.py:interp_t_mono_ns) fall
        # inside the txlog's coverage span, not a different clock's numbers.
        tx_recs = [dict(seq=s, t_submit_ns=(s - lt["lo"]) * 800_000)
                   for s in range(lt["lo"], lt["hi"] + 1) if s != lost_seqs[0]]
        tx_arr = _txlog_array(tx_recs)
        result = tx_rx_join(lt, tx_arr)
        assert result["n_lost_rx"] == len(lost_seqs)
        assert result["never_sent"] == 1
        assert lost_seqs[0] in result["sample_never_sent"]
        assert result["sent_not_decoded"] == len(lost_seqs) - 1


# ----------------------------------------------------- dump completeness --
def test_read_failhdr_rejects_truncated_dump():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "failhdr.bin")
        with open(path, "wb") as f:
            f.write(LOG_HDR.pack(b"QFAILH01", 32, 5, 1, 5, 0))  # claims 5 records
            f.write(FAILHDR_REC.pack(0, 1, 0xFFFFFFFF, 1, 0, 0xFFFF, b"\x00" * 12))  # only 1
        with pytest.raises(ValueError, match="INCOMPLETE DUMP"):
            read_failhdr(path)


# ----------------------------------------------------------- log formats --
def test_failhdr_roundtrip():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "failhdr.bin")
        n = 3
        with open(path, "wb") as f:
            f.write(LOG_HDR.pack(b"QFAILH01", 32, n, 123456789, n, 0))
            for i in range(n):
                f.write(struct.pack("<QIIBBH12s", 1000 + i, 42 + i, 0xFFFFFFFF,
                                     1, 0, 0xFFFF, b"\x51\x4B" + b"\x00" * 10))
        hdr, arr = read_failhdr(path)
        assert hdr["n_records"] == n
        assert hdr["magic"] == b"QFAILH01"
        assert not hdr["wrapped"]
        assert arr.dtype == FAILHDR_DTYPE
        assert list(arr["host_seq"]) == [42, 43, 44]
        assert list(arr["fail_class"]) == [1, 1, 1]


def test_txlog_roundtrip():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "txlog.bin")
        n = 2
        with open(path, "wb") as f:
            f.write(LOG_HDR.pack(b"QTXLOG02", 32, n, 987654321, n, 1))
            f.write(struct.pack("<QQIIIHH", 100, 200, 7, 5000, 0, 0, 0))
            f.write(struct.pack("<QQIIIHH", 300, 0, 8, 0xFFFFFFFF, 1, 1, 3))
        hdr, arr = read_txlog(path)
        assert hdr["n_records"] == n
        assert hdr["wrapped"] is True
        assert arr.dtype == TXLOG_DTYPE
        assert list(arr["seq"]) == [7, 8]
        assert arr["t_complete_ns"][1] == 0  # never reaped


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
