#!/usr/bin/env python3
"""singles_cadence.py -- score a frames.bin for the forward singles-comb class.

Answers two questions the campaign turns on:
  1. Are the losses singles/doubles (the comb) or longer bursts (a different class)?
  2. Is the spacing of bad runs LOCKED to the -M DMA transfer boundary?

Self-test: `python3 singles_cadence.py --selftest` synthesizes frames.bin content with
a KNOWN signature and asserts recovery. No hardware needed. A scorer that has never
caught a planted fault is not trusted with a negative result.
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_taxonomy import DTYPE, read_frames


# host_seq is the host's own frame counter; reg_packets is the hardware
# packet counter that actually advances on DMA transfer boundaries. Offset
# them by a constant in the fixture so the two are NOT congruent mod any M --
# otherwise a test that reads the wrong field would still pass, which is
# exactly the bug this offset exists to catch.
_RP_OFFSET = 5_000_003


def _synth(n, m, kind, seed=7):
    """Fabricate a frames.bin-shaped array with a known loss signature."""
    rng = np.random.default_rng(seed)
    fr = np.zeros(n, dtype=DTYPE)
    fr["t_mono_ns"] = (np.arange(n) * 803_000).astype(np.uint64)  # 803 us/frame
    fr["host_seq"] = np.arange(n, dtype=np.uint32)
    rp = np.arange(n, dtype=np.int64) + _RP_OFFSET
    fr["reg_packets"] = rp.astype(np.uint32)
    ok = np.ones(n, dtype=bool)
    if kind == "boundary_singles":
        # one bad frame at every DMA transfer boundary, keyed on reg_packets
        # (the hardware counter) -- the class we are hunting
        ok[(rp % m) == 0] = False
    elif kind == "random_singles":
        # same PER, boundary-blind
        ok[rng.choice(n, size=n // m, replace=False)] = False
    elif kind == "bursts":
        for onset in range(m, n - 10, 7 * m):
            ok[onset:onset + 5] = False
    elif kind == "clean":
        pass
    elif kind == "ber_mode_boundary_singles":
        # -B (BER mode) shape: crc_ok is meaningfully populated, host_seq is
        # BER-mode garbage (a handful of constant/near-constant values, NOT a
        # per-frame counter -- ber_run() never assigns a host sequence), and
        # reg_packets is a clean 1-per-frame ramp. Plant boundary-aligned
        # losses on reg_packets, same as "boundary_singles" above, so a
        # correct --seq reg_packets score recovers them and a --seq host_seq
        # score cannot (there is no usable universe in host_seq at all).
        fr["host_seq"] = (np.arange(n, dtype=np.uint32) % 4)  # 4 unique "garbage" values
        ok[(rp % m) == 0] = False
    else:
        raise ValueError(kind)
    fr["crc_ok"] = ok.astype(np.uint32)
    return fr


def classify(frames, m, seq_field="host_seq"):
    """Score a frames array for the singles-comb signature at -M = m.

    seq_field selects which column carries the per-frame sequence used to
    build the [lo, hi] frame universe and detect holes:
      - "host_seq" (default): the host's own frame counter. Populated in
        tun/echo/-S(+QPSK_SEQ_KEEPM) modes. Nothing already committed changes
        behaviour -- this is the pre-existing default.
      - "reg_packets": the hardware packet counter. This is the ONLY usable
        sequence under -B (BER mode): -B populates crc_ok correctly but
        host_seq is BER-mode garbage (a handful of unique non-sequential
        values), because -B carries no per-frame host sequence at all. See
        qpsk_tun.c ber_run()/framelog_record() call site.
    The boundary-lock residue is ALWAYS computed on reg_packets (the hardware
    counter that actually advances on DMA transfer boundaries), independent
    of which field is used as the sequence -- this was already true before
    this option existed and is unchanged.
    """
    if seq_field not in ("host_seq", "reg_packets"):
        raise ValueError(f"unknown seq_field {seq_field!r}; expected "
                          "'host_seq' or 'reg_packets'")
    seq = frames[seq_field].astype(np.int64)
    crc = frames["crc_ok"].astype(np.int64)
    # Derive the sequence range from CRC-good records only. A corrupt frame's
    # own host_seq field can be scrambled by the same event that flipped
    # crc_ok (confirmed on real hardware capture: every out-of-plausible-range
    # host_seq co-occurs with crc_ok==0) -- an outlier host_seq must not be
    # allowed to define the frame universe, or a handful of corrupted records
    # blow n_frames up to billions and per to ~1.0. This does not exclude
    # holes from the denominator; it only chooses a trustworthy [lo, hi] to
    # count them against.
    # DE-WRAP the sequence before anything else. With --seq reg_packets the field is
    # a FREE-RUNNING FABRIC counter, and the loopback arming sequence deliberately
    # pulses 0x000 (fabric reset), which zeroes it MID-CAPTURE. Measured on
    # r3cap/loopback_20260823_001537: 99,546 of 99,547 consecutive diffs are exactly
    # +1 and ONE diff is -134,529 -- a reset, not a loss. Left uncorrected that single
    # step is read as a 134k-frame hole and inflates PER from 4.5% to 29.3%.
    # A real loss shows as a SMALL POSITIVE gap and is preserved; only a large
    # negative step is treated as a counter reset and stitched.
    d = np.diff(seq)
    # Only de-wrap a field that actually behaves like a counter. A garbage/unset
    # sequence field is full of large negative steps too, and stitching those would
    # manufacture a plausible-looking monotonic sequence out of noise -- hiding
    # exactly the corruption the guards below exist to catch. Require that the field
    # is overwhelmingly +1-stepping first.
    counter_like = d.size > 0 and (d == 1).mean() > 0.5
    # A genuine reset is a LASTING renumbering: the counter drops and then keeps
    # counting from the new base. A single scrambled record is an ISOLATED SPIKE --
    # one huge step up immediately followed by one huge step down. Treating that
    # spike's down-step as a reset would stitch a ~3e9 offset onto the rest of the
    # capture. So a reset qualifies only if it is NOT the tail of such a spike.
    # ANY backwards step in a counter-like field is a reset candidate -- do not use a
    # magnitude threshold, because the drop equals whatever the counter had reached
    # (measured: -134,529, which a 2**20 threshold silently misses). The spike test is
    # what separates the two cases: an isolated scrambled record steps far UP and then
    # straight back DOWN, so its two steps cancel; a real reset does not.
    if counter_like:
        cand = np.flatnonzero(d < 0)
        resets = np.array(
            [i for i in cand
             if not (i > 0 and d[i - 1] > 0 and abs(int(d[i - 1]) + int(d[i])) <= 2)],
            dtype=int)
    else:
        resets = np.array([], dtype=int)
    n_resets = int(resets.size)
    if n_resets:
        offs = np.zeros(seq.size, dtype=np.int64)
        for r in resets:
            # everything after the reset continues from the pre-reset high-water mark
            offs[r + 1:] += int(seq[r]) - int(seq[r + 1]) + 1
        seq = seq + offs

    ok_seq = seq[crc != 0]
    # REFUSE to score rather than invent a universe. With zero CRC-good records
    # there is no trustworthy [lo, hi]; the old fallback to seq.min()/seq.max()
    # over ALL records let scrambled host_seq values fabricate an ~2^32 span and
    # report per=1.0 -- a confident, completely wrong number. That happened for
    # real on 2026-08-22: QPSK_FRAMELOG only fills crc_ok/host_seq in tun/echo/-B
    # modes (see qpsk_tun.c framelog_record call sites); under -S every record is
    # logged crc_ok=0 with host_seq unset, so the capture is UNSCORABLE by this
    # tool and must be reported as such, not scored. This guard is NOT bypassed
    # by --seq reg_packets: it is a property of crc_ok, not of which sequence
    # field is chosen, so a -S-mode capture still refuses to score even under
    # --seq reg_packets.
    if not ok_seq.size:
        raise ValueError(
            f"unscorable capture: 0 of {seq.size} records have crc_ok!=0. "
            "QPSK_FRAMELOG populates crc_ok/host_seq only in tun/echo/-B modes; "
            "a -S-mode framelog carries neither. Re-capture in a mode that fills "
            "them, or score the -S arm from its own ok=/junk= sequence accounting.")
    # REFUSE on a degenerate sequence field too. This is a DIFFERENT failure
    # mode than the all-crc_ok==0 case above: measured on real hardware, a -B
    # (BER mode) capture populates crc_ok correctly but host_seq collapses to
    # a handful of unique values (4 unique values over 35,022 records) because
    # -B never assigns a per-frame host sequence at all. That capture would
    # sail past the check above (crc_ok is mostly 1) and silently score a
    # tiny, meaningless [lo, hi] built from 3-4 distinct values instead of
    # raising. A genuine per-frame counter -- even with holes -- has span
    # (hi-lo+1) within a small factor of the good-record count; a field that
    # repeats the same handful of values thousands of times does not.
    n_unique = int(np.unique(ok_seq).size)
    dup_ratio = ok_seq.size / n_unique
    if dup_ratio > 10:
        raise ValueError(
            f"unscorable capture: --seq {seq_field} is degenerate -- "
            f"{ok_seq.size} crc-good records collapse to only {n_unique} "
            f"unique values (dup_ratio={dup_ratio:.1f}). This field does not "
            "advance per frame (e.g. -B/BER mode carries no host sequence); "
            "use --seq reg_packets for -B captures.")
    lo, hi = int(ok_seq.min()), int(ok_seq.max())
    n_frames = hi - lo + 1
    # Sanity rail: a plausible capture spans far fewer frames than it has records
    # times a generous hole factor. A span in the billions means the seq field is
    # not what we think it is.
    if n_frames > 100 * max(seq.size, 1) + 1000:
        raise ValueError(
            f"implausible sequence span {n_frames} for {seq.size} records "
            f"(host_seq range [{lo}, {hi}]) -- refusing to score.")

    # bad = delivered-but-CRC-failed, PLUS every seq that never arrived (a hole).
    # Holes are losses and belong in the denominator; excluding them is the exact
    # mistake the -B accounting made. A CRC-failed record whose own (possibly
    # scrambled) host_seq falls outside [lo, hi] cannot be indexed into the
    # domain; its true slot is simply absent from the stream and is picked up
    # as a hole instead, so it is not silently dropped.
    bad = np.zeros(n_frames, dtype=bool)
    present = np.zeros(n_frames, dtype=bool)
    idx = seq - lo
    in_range = (idx >= 0) & (idx < n_frames)
    present[idx[in_range]] = True
    bad[idx[in_range & (crc == 0)]] = True
    bad |= ~present

    n_bad = int(bad.sum())
    per = n_bad / n_frames if n_frames else 0.0

    # maximal consecutive runs of bad frames
    padded = np.concatenate(([False], bad, [False]))
    edges = np.flatnonzero(padded[1:] != padded[:-1])
    starts, ends = edges[0::2], edges[1::2]
    lens = ends - starts
    singles = int((lens == 1).sum())
    doubles = int((lens == 2).sum())
    longer = int((lens >= 3).sum())

    hist = {}
    if len(starts) > 1:
        for d in np.diff(starts):
            hist[int(d)] = hist.get(int(d), 0) + 1

    # Boundary lock: the DMA transfer boundary is counted by the HARDWARE
    # packet counter reg_packets, not by host_seq (the host's own frame
    # counter, not aligned to transfers). A hole has no record and therefore
    # no reg_packets value -- it cannot be scored, so holes stay in n_bad/per
    # (the loss denominator) but are excluded here, not silently dropped.
    # Forward-filling a hole's reg_packets from its predecessor was tried and
    # rejected: on the real banked capture it manufactures a null (drops
    # measured enrichment from 1.68x to 0.92x) instead of reporting "can't
    # score this".
    #
    # Baseline is the OBSERVED all-(delivered)-frame boundary-residue rate,
    # not the theoretical 2/M -- frames are not uniform over residues on real
    # hardware (0.1461 observed vs 0.1250 theoretical at M=16 on the banked
    # capture), so 2/M understates the true baseline and overstates
    # enrichment.
    rp = frames["reg_packets"].astype(np.int64)
    res_all = rp % m
    base_hits = int(((res_all == 0) | (res_all == m - 1)).sum())
    boundary_base = base_hits / rp.size if rp.size else 0.0

    rp_corrupt = rp[crc == 0]
    n_boundary_scored = int(rp_corrupt.size)
    if n_boundary_scored:
        res_c = rp_corrupt % m
        hit_c = int(((res_c == 0) | (res_c == m - 1)).sum())
        boundary_hit_frac = hit_c / n_boundary_scored
    else:
        boundary_hit_frac = 0.0

    boundary_enrichment = (boundary_hit_frac / boundary_base
                            if boundary_base > 0 else 0.0)
    boundary_locked = bool(n_boundary_scored >= 200 and
                            boundary_enrichment >= 1.4)

    return {"n_resets": n_resets, "n_frames": n_frames, "n_bad": n_bad, "per": per,
            "singles": singles, "doubles": doubles, "longer": longer,
            "boundary_hit_frac": boundary_hit_frac,
            "boundary_base": boundary_base,
            "boundary_enrichment": boundary_enrichment,
            "n_boundary_scored": n_boundary_scored,
            "boundary_locked": boundary_locked,
            "spacing_hist": hist}


def _selftest():
    n, m = 20000, 16
    r = classify(_synth(n, m, "boundary_singles"), m)
    assert r["singles"] > 0 and r["longer"] == 0, r
    assert r["boundary_locked"] is True, r
    assert r["boundary_enrichment"] > 1.4, r

    r = classify(_synth(n, m, "random_singles"), m)
    assert r["boundary_locked"] is False, r

    r = classify(_synth(n, m, "bursts"), m)
    assert r["longer"] > 0 and r["singles"] == 0, r

    r = classify(_synth(n, m, "clean"), m)
    assert r["n_bad"] == 0 and r["per"] == 0.0 and r["boundary_locked"] is False, r

    # holes must count as bad: delete 1 record and confirm the denominator is intact
    fr = _synth(n, m, "clean")
    r = classify(np.delete(fr, 500), m)
    assert r["n_bad"] == 1 and r["n_frames"] == n, r

    # a corrupted host_seq on a CRC-failed record must not hijack the frame
    # range: real hardware capture shows corrupted frames can scramble their
    # own host_seq field, not just crc_ok. Plant one (garbage seq, crc failed,
    # valid neighbors) and confirm n_frames stays sane and the frame is still
    # counted bad (via the hole its true, absent slot leaves behind).
    fr = _synth(n, m, "clean")
    fr["host_seq"][500] = 3_000_000_000
    fr["crc_ok"][500] = 0
    r = classify(fr, m)
    assert r["n_frames"] == n, r
    assert r["n_bad"] == 1, r

    # -B-shaped fixture: crc_ok populated, host_seq degenerate/garbage,
    # reg_packets a clean 1-per-frame ramp with planted boundary-aligned
    # losses (real hardware shape measured 2026-08-22: 34,363 good / 659 bad
    # crc_ok, 4 unique host_seq values, reg_packets exactly 1-per-frame).
    fr = _synth(n, m, "ber_mode_boundary_singles")
    r = classify(fr, m, seq_field="reg_packets")
    assert r["singles"] > 0 and r["longer"] == 0, r
    assert r["boundary_locked"] is True, r
    assert r["boundary_enrichment"] > 1.4, r
    # the garbage-seq guard must not be silently bypassed by --seq: the same
    # capture must still REFUSE to score under the default host_seq.
    try:
        classify(fr, m, seq_field="host_seq")
        raise AssertionError(
            "classify() must raise on a -B-shaped capture under the default "
            "host_seq field, not silently score a degenerate sequence")
    except ValueError:
        pass

    print("SINGLES_CADENCE_SELFTEST_OK")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("frames", nargs="?")
    ap.add_argument("--M", type=int, default=16)
    ap.add_argument("--seq", choices=("host_seq", "reg_packets"),
                     default="host_seq",
                     help="sequence field for the frame universe/holes "
                          "(default host_seq; use reg_packets for -B "
                          "captures, which carry no per-frame host_seq)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        _selftest()
    else:
        r = classify(read_frames(a.frames), a.M, seq_field=a.seq)
        for k in ("n_resets", "n_frames", "n_bad", "per", "singles", "doubles", "longer",
                  "n_boundary_scored", "boundary_hit_frac", "boundary_base",
                  "boundary_enrichment", "boundary_locked"):
            print(f"{k:>18} : {r[k]}")
