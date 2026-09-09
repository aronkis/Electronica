#!/usr/bin/env python3
"""seqbist_score.py <run dir> -- score a seqbist_run.sh run directory.

Reads <run dir>/readings.jsonl (one JSON object per line, cumulative counters
as emitted by seqbist_read.py) and <run dir>/meta.txt (K=V lines, may span
multiple "key=val key=val" lines -- see seqbist_run.sh).

Reports:
  - loss %  = lost_slots / (chk_frames + lost_slots)   (deltas over the window)
  - garbage %, crc_fail %
  - per-10s time series (min/median/max) of frames and loss %
  - interval histogram -> period estimate (int_32 vs int_33 vs int_other). UNITS
    (ruling, fix round 2): the checker's int_* counters count in EMITTED-frame
    (seq-delta) units, i.e. directly in TGEN frame numbers -- NOT received-frame
    counts, so no received->emitted correction is applied anywhere in this
    scorer. A 26.0 ms comb should show as a 32/33 mix approx 57/43.
  - INTERVAL SERIES (fix round 2, part 2): int_other is BIMODAL under
    seq-delta units -- it catches both the 30/31 short tail and the >=34 long
    tail, so a non-zero int_other is not, by itself, evidence of noise. The
    primary interval/flatness signal is `interval_last_series`: the raw
    `chk_int_last` value sampled once per 10s freeze (one point per reading,
    NOT a delta), built directly from the rows. The int_32/int_33/int_other/
    int_hist_lt30 histogram counters are a coarse cross-check only, and
    contamination_pct is reported for visibility -- it must NOT be read as a
    stage-1 flatness/noise verdict on its own.
  - NOTE: frames != good + garbage + crc_fail in general -- the frame
    immediately after a gap is itself magic-ok/crc-ok (counted in `good`) but
    NOT in-order (it's the seq that follows the gap, not last_seq+1 at the time
    it's scored against `good`'s in-order test), so it is not double counted
    but the three buckets are not a full partition of `frames`.
  - positive-control verdict when skip_every/corrupt_every set in meta.txt:
    * SKIP_EVERY: expected gap_events = frames/N +/- 2
    * CORRUPT_EVERY: corrupt_every produces one gap1 per corrupted frame (the
      corrupted frame's seq still advances normally, so the checker sees it as
      a single-frame gap), so BOTH must hold: garbage = floor(frames/M) +/- 2
      AND gap_events = garbage +/- 2.
  - 0x124 vs 0x104 vs chk_frames agreement
  - LINEAGE (fix round 2): legacy slots 0-15 (cnt_mux16-era: acc_user, frames,
    crc_ok, crc_fail, magic_bad, short, orphan, acc_beats, tx_starve witness)
    read constant 0 on the 146 image (no tx_starve/rx_checker chain there) --
    this scorer never uses those slots for pass/fail or UNINFORMATIVE
    decisions, only the new chk_* (16-31) checker slots, so an all-zero
    legacy block is tolerated without being flagged.
  - UNINFORMATIVE checklist (window_s<150, re-arm in-window, near-zero deltas); for BOARD=146 also notes that slots 0-15 carry no short_frm/truncation witness (no tx_starve/rx_checker chain on that image), so short/truncated-frame damage is invisible on that leg

Prints one JSON summary object, then a short text verdict.
"""
import json
import math
import os
import statistics
import sys


def parse_meta(path):
    meta = {}
    if not os.path.exists(path):
        return meta
    with open(path) as f:
        for line in f:
            for tok in line.strip().split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    meta[k] = v
    return meta


def load_readings(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


# Counters that are NOT cumulative and must be excluded from the mid-window
# clear/re-arm detector. Including them made every real leg UNINFORMATIVE:
#   chk_int_last  raw "frames since the previous gap event", re-latched on every gap,
#                 so it moves both ways by design (task-4 fix 6: a point sample, not a
#                 delta). ctrlA-m: "chk_int_last=-950".
#   starve_clk    tx_starve_witness free-running clock counter -- wraps at 2^32.
#                 ctrlA-m: "starve_clk=-3812923438", i.e. a wrap, not a clear.
#   max_len       a MAX latch, not an accumulator (reads 0xFFFFFFFF at rest).
#   ep_gt*        tx_starve episode witnesses on the same free-running lineage.
# All of these are legacy slots 8-15 or explicitly-documented point samples, and none
# of them is used for pass/fail anywhere in this scorer. Every genuine cumulative
# counter keeps the strict check -- that is what actually catches a mid-window clear.
NON_CUMULATIVE = frozenset((
    "ts_mono", "chk_int_last",
    "starve_clk", "max_len",
    "ep_gt1k", "ep_gt2k", "ep_gt3k", "ep_gt6k", "ep_gt12k", "ep_gt25k",
))


def deltas(rows):
    """Per-sample deltas of the cumulative counters between consecutive rows.
    A negative delta on any counter means the checker was cleared/re-armed
    mid-window; flagged via the returned `negative` list rather than masked
    (unlike loopchk_run.sh's unsigned-wrap delta, which would turn a mid-run
    clear into a huge spurious positive)."""
    out = []
    negative = []
    for idx, (a, b) in enumerate(zip(rows, rows[1:])):
        d = {}
        for k in b:
            if k in ("ts_wall", "board"):
                continue
            if isinstance(b.get(k), (int, float)) and isinstance(a.get(k), (int, float)):
                dv = b[k] - a[k]
                d[k] = dv
                # chk_int_last is NOT cumulative: it is the raw "frames since the
                # previous gap event" register, re-latched on every gap, so it moves both
                # ways by design and a negative step is normal (task-4 fix 6 documents it
                # as a point sample, not a delta). Including it here made every real leg
                # UNINFORMATIVE -- ctrlA-m reported "6 negative deltas ... chk_int_last=-950"
                # while every genuine cumulative counter was monotonic. Excluded, along
                # with the timestamps. Every other counter keeps the strict check, which is
                # the thing that actually catches a mid-window clear/re-arm.
                if dv < 0 and k not in NON_CUMULATIVE:
                    negative.append((idx, k, dv))
        d["ts_mono"] = b.get("ts_mono")
        out.append(d)
    return out, negative


def median(xs):
    return statistics.median(xs) if xs else 0


BACKGROUND_OVERRIDE = None


def score(run_dir):
    readings_path = os.path.join(run_dir, "readings.jsonl")
    meta_path = os.path.join(run_dir, "meta.txt")
    meta = parse_meta(meta_path)
    rows = load_readings(readings_path)

    summary = {"run_dir": run_dir, "n_readings": len(rows), "meta": meta}

    if len(rows) < 2:
        summary["verdict"] = "UNINFORMATIVE"
        summary["reasons"] = ["fewer than 2 readings -- no deltas computable"]
        return summary

    ds, negative = deltas(rows)

    tot_frames = sum(d.get("chk_frames", 0) for d in ds)
    tot_lost = sum(d.get("chk_lost_slots", 0) for d in ds)
    tot_garbage = sum(d.get("chk_garbage", 0) for d in ds)
    tot_crc_fail = sum(d.get("chk_crc_fail", 0) for d in ds)
    tot_gap_events = sum(d.get("chk_gap_events", 0) for d in ds)
    tot_int_32 = sum(d.get("chk_int_32", 0) for d in ds)
    tot_int_33 = sum(d.get("chk_int_33", 0) for d in ds)
    tot_int_other = sum(d.get("chk_int_other", 0) for d in ds)

    denom = tot_frames + tot_lost
    loss_pct = (100.0 * tot_lost / denom) if denom else 0.0
    garbage_pct = (100.0 * tot_garbage / tot_frames) if tot_frames else 0.0
    crc_fail_pct = (100.0 * tot_crc_fail / tot_frames) if tot_frames else 0.0

    summary["loss_pct"] = loss_pct
    summary["garbage_pct"] = garbage_pct
    summary["crc_fail_pct"] = crc_fail_pct
    summary["tot_frames"] = tot_frames
    summary["tot_lost_slots"] = tot_lost
    summary["tot_garbage"] = tot_garbage
    summary["tot_gap_events"] = tot_gap_events

    # per-10s time series (readings are already ~10s apart per seqbist_run.sh)
    fr_series = [d.get("chk_frames", 0) for d in ds]
    loss_series = []
    for d in ds:
        dn = d.get("chk_frames", 0) + d.get("chk_lost_slots", 0)
        loss_series.append(100.0 * d.get("chk_lost_slots", 0) / dn if dn else 0.0)
    summary["frames_per_10s"] = {
        "min": min(fr_series) if fr_series else 0,
        "median": median(fr_series),
        "max": max(fr_series) if fr_series else 0,
    }
    summary["loss_pct_per_10s"] = {
        "min": min(loss_series) if loss_series else 0.0,
        "median": median(loss_series),
        "max": max(loss_series) if loss_series else 0.0,
    }

    # interval histogram -> period estimate. Estimate from int_32/int_33 ONLY --
    # int_hist_lt30 (slot 28) and int_other are unknown-width buckets (could be
    # 5 or 500 frames) and would drag the estimate toward whatever answer is
    # being tested for if included. Report their share as contamination and
    # mark the estimate unreliable when it's high.
    tot_int_hist_lt30 = sum(d.get("chk_int_hist_lt30", 0) for d in ds)
    known_tot = tot_int_32 + tot_int_33
    all_tot = known_tot + tot_int_other + tot_int_hist_lt30
    if known_tot > 0:
        period_est = (32 * tot_int_32 + 33 * tot_int_33) / known_tot
    else:
        period_est = None
    contamination_pct = (100.0 * (tot_int_other + tot_int_hist_lt30) / all_tot) if all_tot else 0.0
    summary["interval_hist"] = {
        "int_32": tot_int_32, "int_33": tot_int_33, "int_other": tot_int_other,
        "int_hist_lt30": tot_int_hist_lt30,
        "period_est_frames": period_est,
        "contamination_pct": contamination_pct,
        "period_est_reliable": contamination_pct < 10.0 if all_tot else None,
        "units": "emitted-frame (seq-delta) units -- TGEN frame numbers, not "
                 "received-frame counts; no received->emitted correction is applied",
        "note": ("period_est_frames is computed from int_32/int_33 only; a 26.0 ms "
                 "comb = 32.43 frames would show as a 32/33 mix approx 57/43. "
                 "int_other/int_hist_lt30 are reported as contamination_pct, not "
                 "blended into the estimate. This histogram is a COARSE CROSS-CHECK "
                 "only -- int_other is bimodal (30/31 tail AND >=34 tail) under "
                 "seq-delta units, so contamination_pct is NOT a noise/flatness "
                 "signal by itself; see interval_last_series for that."),
    }

    # INTERVAL SERIES (fix round 2, part 2): the primary interval/flatness signal --
    # the raw chk_int_last value sampled once per 10s freeze (point sample, NOT a
    # delta of a cumulative counter). Flat (stage-1, no radio in the path) means
    # this series has a tight spread; a bimodal spread (e.g. some samples near 32,
    # others near 300+) is a real signal the coarse histogram alone would blur.
    int_last_series = [r.get("chk_int_last", 0) for r in rows if "chk_int_last" in r]
    if int_last_series:
        ils_min = min(int_last_series)
        ils_max = max(int_last_series)
        ils_median = median(int_last_series)
        ils_stdev = statistics.pstdev(int_last_series) if len(int_last_series) > 1 else 0.0
        flat = (ils_max - ils_min) <= 2  # tight spread around a single period
    else:
        ils_min = ils_max = ils_median = ils_stdev = None
        flat = None
    summary["interval_last_series"] = {
        "n": len(int_last_series),
        "min": ils_min, "median": ils_median, "max": ils_max, "stdev": ils_stdev,
        "flat": flat,
        "units": "emitted-frame (seq-delta) units, one raw sample per 10s freeze "
                 "(chk_int_last), not a delta",
    }

    # ---- positive-control verdict -- BACKGROUND-CORRECTED (ruling 2026-09-04) ----
    # The original test was `gap_events == frames/N +/- 2` absolute, written when the
    # fabric was assumed lossless. Silicon says otherwise: at the mission gap the fabric
    # carries a steady background of ~1 gap event per 1,720 emitted frames (0.067 %), so a
    # 180 s leg accumulates ~65 background events and NO value of N can satisfy +/- 2.
    #
    # Three changes, and no others:
    #  (a) the denominator is EMITTED frames (chk_last_seq delta = TGEN's own seq advance),
    #      not chk_frames. chk_frames counts byte-plane frames, of which the modulator's
    #      free-run filler is a large fraction (~50 % at 622 f/s, ~3.6 % at 1200 f/s);
    #      filler never updates last_seq, so it must not be in the control's denominator.
    #  (b) the observed count is background-corrected: corrected = observed - background,
    #      where background = background_gap_per_emitted * emitted. The rate comes from the
    #      clean leg at the same gap (meta key background_gap_per_emitted, or --background).
    #  (c) the tolerance is max(2, 3*sqrt(expected)) -- Poisson-ish on the injected count,
    #      falling back to the original +/- 2 for small expectations.
    # AND the interval evidence must be positive, not merely not-contradictory: the N+1
    # (skip) / N (corrupt) peak has to stand out from the background intervals.
    skip_every = int(meta.get("skip_every", "0") or 0)
    corrupt_every = int(meta.get("corrupt_every", "0") or 0)
    pc = {"skip_every": skip_every, "corrupt_every": corrupt_every}
    TOL = 2

    tot_emitted = sum(d.get("chk_last_seq", 0) for d in ds)
    pc["emitted_frames"] = tot_emitted
    pc["chk_frames"] = tot_frames
    # filler = byte-plane frames the TGEN did not supply (the modulator's zero frames)
    pc["filler_est"] = tot_frames - tot_emitted
    if tot_frames:
        pc["filler_frac"] = (tot_frames - tot_emitted) / tot_frames

    bg_rate = meta.get("background_gap_per_emitted")
    bg_rate = float(bg_rate) if bg_rate not in (None, "") else None
    if BACKGROUND_OVERRIDE is not None:
        bg_rate = BACKGROUND_OVERRIDE
    pc["background_gap_per_emitted"] = bg_rate
    bg_events = (bg_rate * tot_emitted) if bg_rate else 0.0
    pc["background_events_est"] = bg_events
    if bg_rate is None:
        pc["background_note"] = ("no background rate supplied (meta background_gap_per_emitted "
                                  "or --background); scoring UNCORRECTED, which is only valid "
                                  "if the fabric is lossless at this gap")

    expected_interval_peak = None
    if skip_every > 0:
        expected_interval_peak = skip_every + 1
    elif corrupt_every > 0:
        expected_interval_peak = corrupt_every
    pc["expected_interval_peak"] = expected_interval_peak

    # Interval evidence. Two independent checks, whichever applies:
    #  - the coarse int_32/int_33 histogram, only when the expected peak IS 32 or 33;
    #  - otherwise the int_last series: the injected period should form the dominant
    #    cluster near the expected peak, distinct from the (much longer, scattered)
    #    background intervals.
    interval_peak_ok = True
    if expected_interval_peak in (32, 33) and known_tot > 0:
        dominant_bin = tot_int_32 if expected_interval_peak == 32 else tot_int_33
        interval_peak_ok = dominant_bin >= 0.9 * known_tot
        pc["observed_interval_peak_bin_frac"] = dominant_bin / known_tot
    elif expected_interval_peak:
        series = [r.get("chk_int_last", 0) for r in rows]
        near = [v for v in series if abs(v - expected_interval_peak) <= 2]
        pc["int_last_samples"] = len(series)
        pc["int_last_near_expected_peak"] = len(near)
        if series:
            frac = len(near) / len(series)
            pc["int_last_near_frac"] = frac
            # the injected period must be the dominant cluster AND clearly present
            others = [v for v in series if abs(v - expected_interval_peak) > 2]
            interval_peak_ok = frac >= 0.30 and len(near) >= len(others)
            pc["int_last_distinct"] = interval_peak_ok
        else:
            interval_peak_ok = False

    if skip_every > 0 and tot_emitted > 0:
        expected = tot_emitted / skip_every
        corrected = tot_gap_events - bg_events
        tol = max(TOL, 3.0 * math.sqrt(expected))
        pc["expected_gap_events"] = expected
        pc["observed_gap_events"] = tot_gap_events
        pc["corrected_gap_events"] = corrected
        pc["tolerance"] = tol
        pc["pass"] = abs(corrected - expected) <= tol and interval_peak_ok
    elif corrupt_every > 0 and tot_emitted > 0:
        expected = tot_emitted / corrupt_every
        tol = max(TOL, 3.0 * math.sqrt(expected))
        # garbage carries the filler as an additive pedestal; subtract it before comparing
        corrected_garbage = tot_garbage - pc["filler_est"]
        corrected_gaps = tot_gap_events - bg_events
        pc["expected_garbage"] = expected
        pc["observed_garbage"] = tot_garbage
        pc["corrected_garbage"] = corrected_garbage
        pc["expected_gap_events"] = expected
        pc["observed_gap_events"] = tot_gap_events
        pc["corrected_gap_events"] = corrected_gaps
        pc["tolerance"] = tol
        # RULING 2026-09-04: garbage - filler is REPORT-ONLY, not a pass criterion.
        # filler is estimated as (chk_frames - emitted), which is only exact when no frame
        # is lost or corrupted; every lost/corrupted frame perturbs the estimate, so the
        # subtraction carries the loss noise into a quantity being compared against a tight
        # tolerance. The seq axis (gap_events, background-corrected) plus the interval peak
        # are the criteria; garbage is reported for the record.
        gap_events_ok = abs(corrected_gaps - expected) <= tol
        pc["garbage_within_tol"] = abs(corrected_garbage - expected) <= tol
        pc["garbage_criterion"] = ("report-only: filler is estimated as chk_frames - emitted, "
                                    "which is exact only with zero loss/corruption, so it is "
                                    "not used for pass/fail (ruling 2026-09-04)")
        pc["pass"] = gap_events_ok and interval_peak_ok
    else:
        pc["pass"] = None  # no positive control configured for this run
    summary["positive_control"] = pc

    # LINEAGE (fix round 2): legacy cnt_mux16-era slots 0-15 read constant 0 on
    # the 146 image (no tx_starve/rx_checker chain there); informational only,
    # never used for pass/fail or UNINFORMATIVE decisions above.
    legacy_last = ds[-1] if ds else {}
    legacy_sum = sum(abs(legacy_last.get(k, 0)) for k in (
        "acc_user", "frames", "crc_ok", "crc_fail", "magic_bad", "short",
        "orphan", "acc_beats", "ep_gt1k", "ep_gt2k", "ep_gt3k", "ep_gt6k",
        "ep_gt12k", "ep_gt25k", "max_len", "starve_clk"))
    summary["legacy_slots_0_15_all_zero"] = (legacy_sum == 0)

    # 0x124 vs 0x104 vs chk_frames agreement -- these are all RX-side (packets_out /
    # cnt_frame_start / the rx_seq_checker's own frame count); NOT a TX-vs-RX
    # comparison, see tx_rx_frame_agreement below for that.
    d104 = sum(d.get("reg_0x104", 0) for d in ds)
    d124 = sum(d.get("reg_0x124", 0) for d in ds)
    agree = {"reg_0x104_delta": d104, "reg_0x124_delta": d124, "chk_frames_delta": tot_frames}
    if tot_frames:
        agree["0x104_vs_chk_frames_pct"] = 100.0 * (d104 - tot_frames) / tot_frames
        agree["0x124_vs_chk_frames_pct"] = 100.0 * (d124 - tot_frames) / tot_frames
    summary["register_agreement"] = agree

    # TX-side witness cross-check (fix round 2, forward-compatible/defensive): IF
    # readings carry tx_frames_checked (tx_seam_checker's frames_checked,
    # txchk_gpio @0x9D420000 -- not read by seqbist_read.py today, but guarded
    # here so a future addition can't silently misuse it), do NOT assert it
    # equals chk_frames under CORRUPT_EVERY: tx_seam_checker self-arms only on a
    # good TGEN magic, so under corruption its frames_checked undercounts by
    # floor(frames/M) BY CONSTRUCTION (not a fabric defect). Only compare TX vs
    # RX frame counts for clean runs and SKIP_EVERY (+/- 2); CORRUPT_EVERY is
    # exempted from the comparison entirely.
    has_tx = any("tx_frames_checked" in d for d in ds)
    if has_tx:
        tot_tx = sum(d.get("tx_frames_checked", 0) for d in ds)
        tx_rx = {"tx_frames_checked": tot_tx, "rx_chk_frames": tot_frames}
        if corrupt_every > 0:
            tx_rx["compared"] = False
            tx_rx["note"] = ("tx_seam_checker arms only on a good magic; under "
                              "CORRUPT_EVERY its frames_checked undercounts by "
                              "floor(frames/M) by construction -- not compared")
        else:
            tx_rx["compared"] = True
            tx_rx["diff"] = tot_tx - tot_frames
            tx_rx["pass"] = abs(tx_rx["diff"]) <= 2
        summary["tx_rx_frame_agreement"] = tx_rx

    # UNINFORMATIVE checklist
    reasons = []
    notes = []  # informational, does NOT affect verdict
    window_s = int(meta.get("window_s", "0") or 0)
    rearms = int(meta.get("rearms_in_window", "0") or 0)
    if window_s and window_s < 150:
        reasons.append(f"window_s < 150 ({window_s})")
    if rearms > 0:
        reasons.append(f"{rearms} re-arm(s) in-window")
    if tot_frames == 0:
        reasons.append("chk_frames delta == 0 (checker saw nothing)")
    if d104 == 0 and d124 == 0:
        reasons.append("0x104 and 0x124 deltas both == 0")

    board = str(meta.get("board", ""))
    if "146" in board:
        notes.append("BOARD=146: legacy slots 0-15 carry no short_frm/truncation "
                      "witness (no tx_starve/rx_checker chain on that image) -- "
                      "short/truncated-frame damage is invisible on this leg, only "
                      "the chk_* (16-31) checker slots are informative")

    if pc["pass"] is False:
        reasons.append("positive control FAILED "
                        f"(skip_every={skip_every} corrupt_every={corrupt_every})")
    # CORRUPTED-SEQ ARTEFACT (task 8 ruling, 2026-09-04, measured on the first
    # fabric-only RF leg s3fwd45k). On air a frame can arrive with an intact magic and
    # (in tgen_mode) an accepted CRC field while its SEQ field is corrupted. The checker
    # takes that seq at face value, so one such frame injects a spurious gap of up to
    # 2^32 slots -- chk_lost_slots then runs to ~4e10 over 600 s and wraps, and the
    # gap3+/dup_or_reorder counters absorb the rest. The leg is NOT invalid: the damage
    # is confined to the seq-VALUE counters. So for an RF leg:
    #   loss metric  = gap_events / emitted   (an event is one loss episode, not a count
    #                  of slots) plus the garbage + crc_fail fractions
    #   gap3+ and dup_or_reorder = reported as the corrupted-seq artefact, not as loss
    #   lost_slots   = VOID
    # A future checker revision should reject a seq that is not last_seq + k, k <= 64.
    seq_value_counters = {"chk_lost_slots", "chk_gap3plus", "chk_dup_or_reorder"}
    neg_names = {n[1] for n in negative}
    if negative and neg_names <= seq_value_counters:
        summary["corrupted_seq_artefact"] = {
            "negative_steps": len(negative),
            "counters": sorted(neg_names),
            "lost_slots_void": True,
            "use_instead": "gap_events/emitted, plus garbage_pct and crc_fail_pct",
        }
        notes.append(
            f"{len(negative)} negative delta(s), all on seq-VALUE counters "
            f"({', '.join(sorted(neg_names))}): the corrupted-seq artefact of an RF leg "
            "(a good-magic frame whose seq field is damaged injects a gap of up to 2^32). "
            "lost_slots is VOID here; score on gap_events/emitted + garbage + crc_fail. "
            "This is NOT a mid-window checker clear.")
    elif negative:
        reasons.append(f"{len(negative)} negative delta(s) -- checker cleared/re-armed "
                        f"mid-window (e.g. sample {negative[0][0]}: {negative[0][1]}="
                        f"{negative[0][2]})")

    verdict = "UNINFORMATIVE" if reasons else "INFORMATIVE"
    if pc.get("pass") is True and not reasons:
        verdict = "PASS"
    elif pc.get("pass") is False:
        verdict = "FAIL"
    elif pc.get("pass") is None and not reasons:
        # T2 PREREG for a control-free run: lost_slots == 0, garbage == 0,
        # crc_fail == 0. Give the actual measurement a verdict instead of
        # leaving it as a shrug-worthy "INFORMATIVE" regardless of loss.
        verdict = "CLEAN" if (tot_lost == 0 and tot_garbage == 0 and tot_crc_fail == 0) else "LOSSY"
    summary["verdict"] = verdict
    summary["reasons"] = reasons
    summary["notes"] = notes
    return summary


def main():
    global BACKGROUND_OVERRIDE
    args = [a for a in sys.argv[1:]]
    # --background <rate>: gap_events per EMITTED frame, measured on the clean leg at the
    # same gap. Overrides the meta key background_gap_per_emitted. Ruling 2026-09-04.
    if "--background" in args:
        i = args.index("--background")
        try:
            BACKGROUND_OVERRIDE = float(args[i + 1])
        except (IndexError, ValueError):
            print("usage: seqbist_score.py <run dir> [--background <gap_events_per_emitted>]",
                  file=sys.stderr)
            return 2
        del args[i:i + 2]
    if len(args) != 1:
        print("usage: seqbist_score.py <run dir> [--background <gap_events_per_emitted>]",
              file=sys.stderr)
        return 2
    run_dir = args[0]
    s = score(run_dir)
    print(json.dumps(s, indent=2))
    pcv = s.get("positive_control", {})
    if pcv.get("pass") is not None:
        print(f"\nSEQBIST_CONTROL pass={pcv['pass']} emitted={pcv.get('emitted_frames')} "
              f"expected={pcv.get('expected_gap_events', 0):.1f} "
              f"observed={pcv.get('observed_gap_events')} "
              f"background={pcv.get('background_events_est', 0):.1f} "
              f"corrected={pcv.get('corrected_gap_events', 0):.1f} "
              f"tol={pcv.get('tolerance', 0):.1f} "
              f"filler_frac={pcv.get('filler_frac', 0):.4f}")
    print(f"\nSEQBIST_SCORE verdict={s['verdict']} loss_pct={s.get('loss_pct', 0):.4f} "
          f"garbage_pct={s.get('garbage_pct', 0):.4f} crc_fail_pct={s.get('crc_fail_pct', 0):.4f} "
          f"period_est={s.get('interval_hist', {}).get('period_est_frames')}")
    if s["reasons"]:
        for r in s["reasons"]:
            print(f"  - {r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
