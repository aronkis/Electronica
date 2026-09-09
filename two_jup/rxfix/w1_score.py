#!/usr/bin/env python3
"""w1_score.py -- RXFIX Task 10: render w1_read.sh readings into w1_reads.csv
(cumulative AND delta per reading) and evaluate the PRE-REGISTERED predictions.

  w1_score.py <run_dir> [--mode ctrl|air] [--label <text>]

Reads   <run_dir>/readings.jsonl   (one JSON line per reading, w1_read.sh format)
Writes  <run_dir>/w1_reads.csv     (t, occ, push_ptr, pop_ptr, push_on_full,
                                    pop_on_empty, census[6]; cumulative + delta)
        <run_dir>/verdict.txt      (structural checks + P/F evaluation)

WRAP ARITHMETIC.  The six census words and 0x104 are 32-bit free-running and wrap;
the two edge counters are 16-bit and wrap (W1_REGMAP.md sec 1).  Every delta here is
taken modulo the counter's own width.  A cumulative value is never compared against
another cumulative value.

WHAT IS AND IS NOT A COHERENT SNAPSHOT.  The eight W1 words are shadowed behind one
freeze level, so within a reading they are simultaneous and inter-stage arithmetic on
them is EXACT.  0x104 (frames) is NOT behind the freeze -- it is sampled aux_lag_s
after the freeze instant -- so any census-vs-frames comparison carries a pairing
error bounded by rate * aux_lag_s, which this script COMPUTES rather than assumes.
See the note on the census control in the verdict output.
"""
import argparse
import datetime
import json
import os
import sys

M32 = 1 << 32
M16 = 1 << 16
# The ninth word's fields are NOT both 16 bits: r4b_opens is 15 (W1_REGMAP sec 5).
# Using M16 for it would corrupt every opens delta across its wrap.
M15 = 1 << 15
SYM_PER_FRAME = 12333          # symbol slots per air frame (RXFIX_STATE sec 3)
SYM_PER_FRAME_PC = 12320       # after sample_discard_controller drops the 13-slot guard
CENSUS = ["cSS", "cRH", "cCFC", "cCS", "cPD", "cPC"]

# Wrap-ambiguity horizons.  A mod-2^N delta between consecutive reads is only the
# TRUE delta if strictly less than one full wrap happened in between.  At ~1,248 f/s
# the census counts 12,333 x 1,248 = 15.4e6 valids/s, so 2^32 / 15.4e6 = ~279 s; the
# 16-bit edge counters at the predicted 395 per 10 s wrap in 2^16 / 39.5 = ~1,659 s.
# Every delta here is accumulated from CONSECUTIVE reads (<= ~10-20 s apart), never
# as leg-end minus leg-start, so neither horizon is approached -- but a dropped read
# could stretch an interval, and that must be caught rather than silently aliased.
CENSUS_WRAP_S = 279.0
EDGE_WRAP_S = 1659.0
# The ninth word (0x234, W1+R4B images only).  r4b_skips is 16-bit and, at the
# pre-registered ~394 per 10 s, wraps in 2^16/39.4 = ~1,663 s.
#
# r4b_window_opens is 15-bit and advances once per DEFRAMED PACKET.  W1_REGMAP sec 5
# quotes its horizon as ~136 s "at 240 f/s" -- but THIS RIG DOES NOT RUN AT 240 f/s.
# Task 10's own air leg measured 0x104 advancing ~12,600 per 10 s = ~1,260 f/s
# (task-10-report sec 4.1), so the real horizon is 2^15/1260 = ~26 s.  That makes
# r4b_window_opens BY FAR the fastest-wrapping quantity in the instrument: 10 s reads
# are unambiguous with 2.6x to spare, a single dropped read (20 s) still is, and two
# consecutive dropped reads alias silently.  Every interval is checked against it.
R4B_SKIPS_WRAP_S = 1663.0
R4B_OPENS_WRAP_S = 26.0

# INTER-STAGE EQUALITY TOLERANCE, measured on silicon by the Step-2 loopback control
# (run 20260904_164756_w1_ctrl) rather than assumed.  The stages sit at different
# pipeline depths, so a frozen snapshot catches them at fixed offsets: cRH = cSS-1,
# cCFC = cSS-9, cPD = cSS-12352 are CONSTANT across every snapshot, while cCS
# alternates between cSS-11 and cSS-12 -- one beat of sampling phase.  A constant
# offset cancels in a delta; the one-beat jitter does not, so a stage delta can differ
# from cSS's by +-1 with ZERO loss.  Band set to +-4 for headroom.  This matters
# because the air-leg alternative (P2-alt) predicts a shortfall of ~395 per 10 s --
# roughly 100x this band, so the two are never confusable.
EQ_TOL = 4


def _epoch(ts):
    try:
        return datetime.datetime.fromisoformat(ts).timestamp()
    except Exception:
        return None


def u(x):
    return int(x, 16) if isinstance(x, str) else int(x)


def d32(a, b):
    return (b - a) % M32


def d16(a, b):
    return (b - a) % M16


def decode(words):
    """witA = {16'b0, occTrue[5:0], pushPtr[4:0], popPtr[4:0]}  (W1_REGMAP sec 1)
       witB = {push_on_full[31:16], pop_on_empty[15:0]}"""
    a = u(words["witA"])
    b = u(words["witB"])
    return {
        "witA_raw": a,
        "resv": (a >> 16) & 0xFFFF,          # documented ZERO -- a structural decode check
        "occ": (a >> 10) & 0x3F,             # TRUE occupancy 0..32 (32 and 0 are distinct)
        "push_ptr": (a >> 5) & 0x1F,
        "pop_ptr": a & 0x1F,
        "pop_on_empty": b & 0xFFFF,
        "push_on_full": (b >> 16) & 0xFFFF,
        **{c: u(words[c]) for c in CENSUS},
        **_decode_r4b(words),
    }


def d15(a, b):
    return (b - a) % M15


def _decode_r4b(words):
    """The ninth word, present only on a W1+R4B image (W1_REGMAP sec 5):
       r4bWit = {r4b_locked, r4b_skips[15:0], r4b_window_opens[14:0]}
    Bit 31 is the lock flag, bits 30:15 the skip counter, bits 14:0 the window
    counter -- derived from the RTL (rxfix_inject.py R4B_WIT_ASSIGN), not from the
    Task 12b brief, whose field list (r4b_prefilled/armed, opens[15:0]) predates the
    controller's 17:07 ruling and does not fit 32 bits."""
    if "r4bWit" not in words:
        return {}
    w = u(words["r4bWit"])
    return {
        "r4b_raw": w,
        "r4b_locked": (w >> 31) & 1,
        "r4b_skips": (w >> 15) & 0xFFFF,
        "r4b_opens": w & 0x7FFF,
    }


def load(run_dir):
    p = os.path.join(run_dir, "readings.jsonl")
    rows = []
    for ln in open(p):
        ln = ln.strip()
        if not ln:
            continue
        r = json.loads(ln)
        if r.get("dry") or r.get("error") or not r.get("words"):
            rows.append({"raw": r, "bad": r.get("error") or ("dry" if r.get("dry") else "no words")})
            continue
        d = decode(r["words"])
        d["raw"] = r
        d["bad"] = None
        d["ts"] = r["ts"]
        d["freeze_effective"] = r.get("freeze_effective")
        d["r4b_moved"] = r.get("r4b_moved")
        d["aux_lag_s"] = r.get("aux_lag_s")
        aux = r.get("aux") or {}
        d["frames"] = u(aux["0x104"]) if "0x104" in aux else None
        d["fstart"] = u(aux["0x124"]) if "0x124" in aux else None
        rows.append(d)
    return rows


def structural(rows):
    """Checks that do not depend on any prediction: they test the DECODE itself.
    Step 1's stop condition is 'do these addresses return witA or garbage', and
    these make that test sharper than 'the number looks plausible'."""
    out, fails = [], []
    good = [r for r in rows if not r["bad"]]
    if not good:
        return ["no usable readings"], ["NO_USABLE_READINGS"]

    allsame = all(
        all(g[k] == good[0][k] for k in ["witA_raw"] + CENSUS) for g in good
    )
    if allsame and len(good) > 1:
        fails.append("STUCK: witA and all six census words identical across every reading")
    out.append(f"readings usable: {len(good)}/{len(rows)}")

    zeros = [c for c in ["witA_raw"] + CENSUS if all(g[c] == 0 for g in good)]
    if zeros:
        fails.append(f"CONST_0: always zero across every reading: {','.join(zeros)}")

    bad_resv = [g["ts"] for g in good if g["resv"] != 0]
    if bad_resv:
        fails.append(f"DECODE: witA[31:16] must be zero, is not, on {len(bad_resv)} reading(s)")
    else:
        out.append("witA[31:16] == 0 on every reading (decode check PASS)")

    bad_occ = [(g["ts"], g["occ"]) for g in good if g["occ"] > 32]
    if bad_occ:
        fails.append(f"DECODE: occTrue > 32 on {len(bad_occ)} reading(s): {bad_occ[:3]}")
    else:
        out.append("occTrue <= 32 on every reading (decode check PASS)")

    if any("r4b_raw" in g for g in good):
        r4b = [g for g in good if "r4b_raw" in g]
        out.append(f"ninth word 0x234 present on {len(r4b)}/{len(good)} readings (W1+R4B image)")
        if all(g["r4b_raw"] == 0 for g in r4b):
            fails.append("CONST_0: 0x234 reads zero on every reading -- either the image is "
                         "W1-only (no R4B) or the ninth word is not decoded")
        if all(g["r4b_raw"] == r4b[0]["r4b_raw"] for g in r4b) and len(r4b) > 1:
            fails.append("STUCK: 0x234 identical across every reading")
        nl = [g["ts"] for g in r4b if not g["r4b_locked"]]
        if nl:
            out.append(f"WARNING: r4b_locked = 0 on {len(nl)} reading(s) -- the steering is "
                       f"NOT armed there (lock = 8 pcEnd pulses since reset)")
        else:
            out.append("r4b_locked = 1 on every reading (steering armed)")

    nf = [g["ts"] for g in good if g["freeze_effective"] is False]
    if nf:
        out.append(f"WARNING: freeze_effective=false on {len(nf)} reading(s) -- DISCARDED "
                   f"(not a coherent snapshot; W1_REGMAP sec 2)")
    return out, fails


def deltas(rows):
    good = [r for r in rows if not r["bad"] and r["freeze_effective"] is not False]
    out = []
    for i in range(1, len(good)):
        a, b = good[i - 1], good[i]
        ta, tb = _epoch(a["ts"]), _epoch(b["ts"])
        dt = (tb - ta) if (ta and tb) else None
        rec = {"ts": b["ts"], "dt_s": dt,
               "occ": b["occ"], "push_ptr": b["push_ptr"], "pop_ptr": b["pop_ptr"],
               "pop_on_empty": b["pop_on_empty"], "push_on_full": b["push_on_full"],
               "d_pop_on_empty": d16(a["pop_on_empty"], b["pop_on_empty"]),
               "d_push_on_full": d16(a["push_on_full"], b["push_on_full"]),
               "aux_lag_s": b["aux_lag_s"]}
        for c in CENSUS:
            rec[c] = b[c]
            rec["d_" + c] = d32(a[c], b[c])
        if "r4b_raw" in a and "r4b_raw" in b:
            rec["r4b_locked"] = b["r4b_locked"]
            rec["r4b_skips"] = b["r4b_skips"]
            rec["r4b_opens"] = b["r4b_opens"]
            rec["d_r4b_skips"] = d16(a["r4b_skips"], b["r4b_skips"])
            rec["d_r4b_opens"] = d15(a["r4b_opens"], b["r4b_opens"])
            rec["r4b_moved"] = b.get("r4b_moved")
        else:
            rec["r4b_locked"] = rec["r4b_skips"] = rec["r4b_opens"] = None
            rec["d_r4b_skips"] = rec["d_r4b_opens"] = rec["r4b_moved"] = None
        if a["frames"] is not None and b["frames"] is not None:
            rec["frames"] = b["frames"]
            rec["d_frames"] = d32(a["frames"], b["frames"])
        else:
            rec["frames"] = rec["d_frames"] = None
        out.append(rec)
    return good, out


def write_csv(run_dir, good, dl):
    cols = (["ts", "occ", "push_ptr", "pop_ptr", "pop_on_empty", "push_on_full", "frames"]
            + CENSUS
            + ["d_pop_on_empty", "d_push_on_full", "d_frames"]
            + ["d_" + c for c in CENSUS]
            + ["r4b_locked", "r4b_skips", "r4b_opens", "d_r4b_skips", "d_r4b_opens"]
            + ["dt_s", "aux_lag_s"])
    p = os.path.join(run_dir, "w1_reads.csv")
    with open(p, "w") as f:
        f.write(",".join(cols) + "\n")
        if good:
            g = good[0]
            first = {c: g.get(c) for c in cols}
            first["ts"] = g["ts"]
            f.write(",".join("" if first.get(c) is None else str(first.get(c, "")) for c in cols) + "\n")
        for r in dl:
            f.write(",".join("" if r.get(c) is None else str(r.get(c))for c in cols) + "\n")
    return p


def acquisition(A, good, dl, acq_dl):
    """G14: the acquisition dip right after an arm can fire a few skips while the ring
    is momentarily FULL (~1 frame each).  Report it SEPARATELY from steady state.

    THE SEPARATION IS EXACT AND NEEDS NO NEW INSTRUMENT.  The arm's 0x000 soft reset
    zeroes the edge counters -- measured on silicon, not assumed: Task 10 sec 3.1 saw
    pop_on_empty read 44, then 10 after arm #1, then 44 after arm #2, each value being
    that acquisition's OWN transient.  So the FIRST reading's CUMULATIVE
    push_on_full / pop_on_empty / r4b_skips IS the post-arm transient, and every
    steady-state number in this report is a delta BETWEEN readings, which cannot
    contain it.  A delta could never have resolved it anyway: ~30 frames at ~1,250 f/s
    is 24 ms, far inside one 10 s read.

    A cumulative value is therefore meaningful HERE and nowhere else in this file."""
    A("-- acquisition window (G14): the FIRST reading's CUMULATIVE counters --")
    if not good:
        A("   no usable readings")
        A("")
        return
    g = good[0]
    A(f"   first reading {g['ts']}: these are counts accumulated since the arm's 0x000")
    A("   soft reset zeroed them, i.e. THIS ARM's acquisition transient -- not a rate.")
    A(f"     occupancy at first read = {g['occ']}  (push_ptr {g['push_ptr']}, pop_ptr {g['pop_ptr']})")
    A(f"     pop_on_empty cumulative = {g['pop_on_empty']}")
    A(f"     push_on_full cumulative = {g['push_on_full']}"
      + ("   <-- NON-ZERO: the acquisition dip reached the FULL edge, which is exactly"
         if g['push_on_full'] else "   (zero: the FULL edge was not reached during this acquisition)"))
    if g['push_on_full']:
        A("       what G14 predicts on a positive-SRO acquisition dip; each such event")
        A("       costs about one frame and belongs in this window, NOT in the steady-state")
        A("       verdicts.  It is also the FIRST silicon exercise of push_on_full at all")
        A("       (Task 9 concern 2 / Task 10 concern 1: it had read 0 everywhere).")
    if "r4b_skips" in g:
        A(f"     r4b_skips cumulative  = {g['r4b_skips']}  (steering skips taken since the arm)")
        A(f"     r4b_opens cumulative  = {g['r4b_opens']}  (windows opened since the arm; 15-bit)")
        A(f"     r4b_locked at first read = {g['r4b_locked']}")
    if acq_dl:
        A(f"   PLUS {len(acq_dl)} interval(s) excluded from the steady-state verdicts by")
        A("   --acq-intervals, reported here instead:")
        for r in acq_dl:
            A(f"     {r['ts']}  occ={r['occ']}  d_poe={r['d_pop_on_empty']}  "
              f"d_pof={r['d_push_on_full']}"
              + (f"  d_r4b_skips={r['d_r4b_skips']}  d_r4b_opens={r['d_r4b_opens']}"
                 if r.get('d_r4b_opens') is not None else ""))
    A("   HOST-SIDE HALF, NOT SCORED HERE: losses in the first ~30 frames after the arm")
    A("   come from the leg's own frame series (capture_r3 / accept_analyze), and are")
    A("   reported separately from the steady-state PER for the same reason.")
    A("")


def verdict(run_dir, mode, label, rows, good, dl, notes, fails, acq_dl=()):
    L = []
    A = L.append
    A(f"=== W1 verdict: mode={mode} label={label} run={run_dir} ===")
    A("")
    A("-- structural / decode checks (independent of any prediction) --")
    for n in notes:
        A("   " + n)
    for f in fails:
        A("   FAIL " + f)
    if fails:
        A("")
        A("   AXI DECODE NOT PROVEN -- the W1 words do not behave like registers.")
        A("   Per the Task 10 brief this is the finding; do not evaluate P1/P2/P3 on it.")
        open(os.path.join(run_dir, "verdict.txt"), "w").write("\n".join(L) + "\n")
        return "DECODE_FAIL"
    A("")
    if not dl:
        A("   fewer than two usable readings -- no deltas; UNINFORMATIVE")
        open(os.path.join(run_dir, "verdict.txt"), "w").write("\n".join(L) + "\n")
        return "UNINFORMATIVE"

    acquisition(A, good, dl, acq_dl)

    A("-- per-reading deltas (steady state; the acquisition window above is excluded) --")
    A("   " + " ".join(f"{c:>13}" for c in
                       ["occ", "d_poe", "d_pof", "d_frames", "d_cSS", "d_cRH", "d_cCFC",
                        "d_cCS", "d_cPD", "d_cPC"]))
    for r in dl:
        A("   " + " ".join(f"{v:>13}" for v in
                           [r["occ"], r["d_pop_on_empty"], r["d_push_on_full"],
                            r["d_frames"], r["d_cSS"], r["d_cRH"], r["d_cCFC"],
                            r["d_cCS"], r["d_cPD"], r["d_cPC"]]))
    A("")

    # ---- the census control -------------------------------------------------
    A("-- census control --")
    A('   Brief: "each delta over 10 s equals the emitted-frame count x 12,333 within')
    A('   +-1 frame (frames from the checker / 0x104), all six equal to each other."')
    A("   The +-1 FRAME HALF OF THAT IS NOT ACHIEVABLE against 0x104, and not because")
    A("   of noise: 0x104 is not behind the W1 freeze (only the eight W1 words are), so")
    A("   it is sampled aux_lag_s AFTER the frozen census.  The achievable bound is")
    A("   computed per reading below as rate x aux_lag_s.  Split into two tests:")
    A("")
    up = ["cSS", "cRH", "cCFC", "cCS", "cPD"]
    A("   (a) STRONG, EXACT (one coherent frozen snapshot, no pairing error):")
    A("       the five pre-discard census deltas equal each other.")
    A(f"       Equality is judged within EQ_TOL=+-{EQ_TOL}, measured (not assumed) from the")
    A("       Step-2 loopback control: the stages sit at fixed pipeline offsets that cancel")
    A("       in a delta, except cCS which jitters one beat -- so +-1 occurs with ZERO loss.")
    A("       P2-alt's predicted shortfall is ~395 per 10 s, ~100x this band.")
    eq_fail = []
    maxdev = 0
    for r in dl:
        vals = {c: r["d_" + c] for c in up}
        dev = max(abs(v - r["d_cSS"]) for v in vals.values())
        maxdev = max(maxdev, dev)
        if dev > EQ_TOL:
            eq_fail.append((r["ts"], vals, dev))
    A(f"       max |stage delta - cSS delta| over the window = {maxdev}")
    if eq_fail:
        A(f"       RESULT: NOT equal (beyond +-{EQ_TOL}) on {len(eq_fail)}/{len(dl)} readings.")
        for ts, v, dev in eq_fail[:4]:
            A(f"         {ts}  dev={dev}  " + " ".join(f"{k}={x}" for k, x in v.items()))
    else:
        A(f"       RESULT: EQUAL within +-{EQ_TOL} on all {len(dl)} readings.")
    A("")
    A("   (b) cPC is EXPECTED TO BE SHORT BY 13 PER FRAME -- by design, not a deletion.")
    A("       sample_discard_controller drops the 13-slot inter-frame guard, so")
    A("       cPC delta = 12,320 x frames while every stage above it is 12,333 x frames")
    A("       (W1_REGMAP sec 3).  Pre-registered separately BEFORE the leg so a designed")
    A("       guard-drop is not read as evidence for P2-alt.")
    for r in dl:
        if r["d_cSS"]:
            k = r["d_cSS"] / SYM_PER_FRAME
            exp_pc = SYM_PER_FRAME_PC * k
            A(f"       {r['ts']}  frames(from cSS)={k:9.2f}  cPC exp={exp_pc:12.0f} "
              f"got={r['d_cPC']:12d}  diff={r['d_cPC'] - exp_pc:+10.0f}")
    A("")
    A("   (c) WEAK, bounded (frames from the un-frozen 0x104):")
    for r in dl:
        if r["d_frames"]:
            k = r["d_cSS"] / SYM_PER_FRAME
            lag = r["aux_lag_s"]
            rate = r["d_frames"] / 10.0
            bound = (rate * lag) if isinstance(lag, (int, float)) else float("nan")
            A(f"       {r['ts']}  0x104 delta={r['d_frames']:8d}  cSS/12333={k:9.2f}  "
              f"diff={k - r['d_frames']:+8.2f} frames  pairing bound=+-{bound:.1f} frames "
              f"(aux_lag={lag}s)")
    A("")

    # ---- edge counters ------------------------------------------------------
    A("-- counter wrap accounting (coordinator item 2) --")
    dts = [r["dt_s"] for r in dl if r["dt_s"]]
    if dts:
        A(f"   read spacing: min {min(dts):.1f}s max {max(dts):.1f}s over {len(dl)} intervals")
        amb_c = [r["ts"] for r in dl if r["dt_s"] and r["dt_s"] >= CENSUS_WRAP_S]
        amb_e = [r["ts"] for r in dl if r["dt_s"] and r["dt_s"] >= EDGE_WRAP_S]
        A(f"   census wrap horizon {CENSUS_WRAP_S:.0f}s -> "
          f"{'AMBIGUOUS intervals: ' + str(amb_c) if amb_c else 'no interval reaches it (all deltas unambiguous)'}")
        A(f"   edge   wrap horizon {EDGE_WRAP_S:.0f}s -> "
          f"{'AMBIGUOUS intervals: ' + str(amb_e) if amb_e else 'no interval reaches it (all deltas unambiguous)'}")
    tot = {c: sum(r["d_" + c] for r in dl) for c in CENSUS}
    A("   wraps traversed over the whole window (sum of per-interval deltas / modulus):")
    for c in CENSUS:
        A(f"     {c:5s} total {tot[c]:>14,}  = {tot[c] / M32:6.2f} x 2^32")
    tp = sum(r["d_pop_on_empty"] for r in dl)
    tq = sum(r["d_push_on_full"] for r in dl)
    A(f"     pop_on_empty total {tp:>8,}  = {tp / M16:5.2f} x 2^16")
    A(f"     push_on_full total {tq:>8,}  = {tq / M16:5.2f} x 2^16")
    A("   (every figure above is accumulated from consecutive reads, never leg-end")
    A("    minus leg-start -- a raw end-minus-start subtraction would alias.)")
    A("")
    A("-- edge counters --")
    tot_poe = sum(r["d_pop_on_empty"] for r in dl)
    tot_pof = sum(r["d_push_on_full"] for r in dl)
    occs = sorted({r["occ"] for r in dl})
    A(f"   pop_on_empty: total delta over the window = {tot_poe}, per reading "
      f"{[r['d_pop_on_empty'] for r in dl]}")
    A(f"   push_on_full: total delta over the window = {tot_pof}, per reading "
      f"{[r['d_push_on_full'] for r in dl]}")
    A(f"   witA occupancy values seen: {occs}")
    A(f"   cumulative pop_on_empty (last reading) = {dl[-1]['pop_on_empty']}, "
      f"push_on_full = {dl[-1]['push_on_full']}")
    A("")

    # ---- the ninth word ----------------------------------------------------
    has_r4b = any(r.get("d_r4b_opens") is not None for r in dl)
    r4b_tot_skips = r4b_tot_opens = 0
    r4b_rate = 0.0
    if has_r4b:
        rr = [r for r in dl if r.get("d_r4b_opens") is not None]
        r4b_tot_skips = sum(r["d_r4b_skips"] for r in rr)
        r4b_tot_opens = sum(r["d_r4b_opens"] for r in rr)
        r4b_rate = r4b_tot_skips / len(rr)
        A("-- R4B witnesses (ninth word 0x234) --")
        A(f"   r4b_locked: {sorted({r['r4b_locked'] for r in rr})}  "
          f"(1 = eight pcEnd pulses seen since reset; armed == locked in this design)")
        A(f"   r4b_skips  per interval: {[r['d_r4b_skips'] for r in rr]}  total {r4b_tot_skips}")
        A(f"   r4b_opens  per interval: {[r['d_r4b_opens'] for r in rr]}  total {r4b_tot_opens}")
        A(f"   mean r4b_skips per read interval = {r4b_rate:.1f}")
        moved = [r["r4b_moved"] for r in rr if r["r4b_moved"] is not None]
        if moved:
            A(f"   0x234 advanced WITHIN the freeze window on {sum(1 for m in moved if m)}/"
              f"{len(moved)} readings -- expected: the ninth word is deliberately OUTSIDE "
              f"W1's freeze shadow (W1_REGMAP sec 5.1), and this is its liveness control.")
        amb_o = [r["ts"] for r in rr if r["dt_s"] and r["dt_s"] >= R4B_OPENS_WRAP_S]
        amb_s = [r["ts"] for r in rr if r["dt_s"] and r["dt_s"] >= R4B_SKIPS_WRAP_S]
        A(f"   wrap horizons: r4b_opens (15-bit, ~1 per frame) {R4B_OPENS_WRAP_S:.0f}s -> "
          f"{'AMBIGUOUS: ' + str(amb_o) if amb_o else 'no interval reaches it'}; "
          f"r4b_skips (16-bit) {R4B_SKIPS_WRAP_S:.0f}s -> "
          f"{'AMBIGUOUS: ' + str(amb_s) if amb_s else 'no interval reaches it'}")
        A(f"   opens total {r4b_tot_opens:,} = {r4b_tot_opens / M15:.2f} x 2^15; "
          f"skips total {r4b_tot_skips:,} = {r4b_tot_skips / M16:.2f} x 2^16")
        A("")

    if mode == "ctrl":
        A("-- Step 2 control verdicts --")
        A(f"   NULL (steady loopback): pop_on_empty delta 0 and push_on_full delta 0 "
          f"-> {'PASS' if tot_poe == 0 and tot_pof == 0 else 'NOT MET'} "
          f"(poe={tot_poe}, pof={tot_pof})")
        A(f"   occupancy constant in steady loopback -> "
          f"{'PASS' if len(occs) == 1 else 'NOT CONSTANT'} (values {occs})")
        ptrs = {(r["push_ptr"], r["pop_ptr"]) for r in dl}
        A(f"   pointer fields advance mod 32 between reads -> "
          f"{'PASS' if len(ptrs) > 1 else 'STATIC'} ({len(ptrs)} distinct (push,pop) pairs)")
        if has_r4b:
            rr = [r for r in dl if r.get("d_r4b_opens") is not None]
            A("")
            A("   -- R4B controls (Task 13 step 5) --")
            A(f"   r4b_armed (= locked) = 1 on every interval -> "
              f"{'PASS' if all(r['r4b_locked'] == 1 for r in rr) else 'NOT MET'}")
            A(f"   r4b_window_opens advances at the FRAME rate (liveness positive control; "
              f"a static value means no pcEnd, so no skip could ever fire) -> "
              f"{'PASS' if all(r['d_r4b_opens'] > 0 for r in rr) else 'NOT MET'} "
              f"(per interval {[r['d_r4b_opens'] for r in rr]})")
            A(f"   occupancy after lock in 8-10 -> "
              f"{'PASS' if all(8 <= r['occ'] <= 10 for r in rr) else 'NOT MET'} (occ {occs})")
            A(f"   pop_on_empty delta 0 in steady loopback (the EMPTY edge is what the "
              f"steering prevents) -> {'PASS' if tot_poe == 0 else 'NOT MET'} (poe={tot_poe})")
            A(f"   r4b_skips: advance then go flat (self-centring at 9/10) -> "
              f"per interval {[r['d_r4b_skips'] for r in rr]}")
        open(os.path.join(run_dir, "verdict.txt"), "w").write("\n".join(L) + "\n")
        return "CTRL_SCORED"

    # ---- air leg: the pre-registered predictions ---------------------------
    n = len(dl)
    poe_rate = tot_poe / n
    A("-- Step 3 pre-registered verdicts (air leg) --")
    pinned_empty = all(r["occ"] <= 1 for r in dl)
    pinned_full = all(r["occ"] >= 31 for r in dl)
    p1 = pinned_empty and (335 <= poe_rate <= 455) and tot_pof == 0
    A(f'   P1: "witA occupancy pinned at the EMPTY edge (0-1) on every in-window read;')
    A(f'       pop_on_empty delta ~ 395 +- 60 per 10 s; push_on_full delta 0."')
    A(f"       -> {'HOLDS' if p1 else 'DOES NOT HOLD'}: occ={occs}, "
      f"mean pop_on_empty delta={poe_rate:.1f}/10s, push_on_full total={tot_pof}")
    A("")
    eq5 = not eq_fail
    A(f'   P2: "per 10 s, symbol-sync strobe delta = Rate_Handle-out delta EXACTLY,')
    A(f'       every downstream stage delta equal to it ... I.e. the sim\'s prediction is')
    A(f'       that NO stage is short in valid count while pop_on_empty runs at ~395 per 10 s."')
    ssrh = all(abs(r["d_cSS"] - r["d_cRH"]) <= EQ_TOL for r in dl)
    A(f"       -> cSS == cRH on all readings: {ssrh}; all five pre-discard stages equal: {eq5}")
    A(f"       -> {'HOLDS' if (ssrh and eq5) else 'DOES NOT HOLD'}")
    A("")
    A(f'   P2-alt: "some stage\'s delta is short by the pop_on_empty delta."')
    hits = []
    for r in dl:
        poe = r["d_pop_on_empty"]
        if poe <= 0:
            continue
        band = max(EQ_TOL, 0.1 * poe)
        for c in up:
            if c == "cSS":
                continue
            if abs((r["d_cSS"] - r["d_" + c]) - poe) <= band:
                hits.append((r["ts"], c))
    A(f"       -> {'HOLDS for ' + str(sorted({c for _, c in hits})) if hits else 'DOES NOT HOLD'} "
      f"({len(hits)} stage-readings short by exactly the pop_on_empty delta)")
    A("")
    A("-- falsifiers --")
    f1 = poe_rate < 1 and not pinned_empty
    A(f'   F1: "pop_on_empty delta ~ 0 while occupancy is NOT pinned at 0 and frames still')
    A(f'       die at the comb rate -> the hole is not at the ring." -> {"FIRES" if f1 else "does not fire"}')
    f2 = pinned_empty and (335 <= poe_rate <= 455) and eq5
    A(f'   F2: "occupancy pinned at 0 AND pop_on_empty delta ~ 395 AND every census delta')
    A(f'       equal -> the suppressed pop removes nothing from the valid stream ... the death')
    A(f'       is a TIME-domain effect ... not a symbol deletion."')
    A(f'       -> {"FIRES (this is the sim-EXPECTED outcome, P2)" if f2 else "does not fire"}')
    f3 = eq5 and poe_rate < 1
    A(f'   F3: "all census deltas exact and pop_on_empty ~ 0 with frames dying at the comb ->')
    A(f'       the entire symbol-rate path is exonerated on silicon."')
    A(f'       -> {"FIRES" if f3 else "does not fire"}')
    A("")
    A("   THIRD BRANCH, pre-registered before the window (not in the brief's P/F set):")
    A("   if occupancy is pinned near 32 with push_on_full incrementing, that is NOT")
    A("   'the FULL-edge counter finally worked' -- on a forward leg it is a SIGN ERROR")
    A("   in the campaign model (RXFIX_STATE sec 2 item (a) already flags the sign as")
    A("   not fitting), and it is a larger finding than P1/F1/F2/F3.")
    A(f"       -> {'FIRES: occupancy pinned HIGH with push_on_full active' if (pinned_full and tot_pof > 0) else 'does not fire'}")

    if has_r4b:
        rr = [r for r in dl if r.get("d_r4b_opens") is not None]
        A("")
        A("=== TASK 13 PRE-REGISTRATION (W1+R4B image) -- THE OPERATIVE VERDICTS ===")
        A("   The P1/P2/F1/F2/F3 block above is TASK 10's pre-registration, written for the")
        A("   W1-only image, and it is printed here as the BASELINE it was.  Under R4B, P1")
        A("   (occupancy pinned at 0-1, pop_on_empty ~ 394) is EXPECTED TO FAIL, and that")
        A("   failure IS the fix working: the steering exists to lift the ring off the EMPTY")
        A("   edge.  Do not read a failed P1 here as a regression.")
        A("")
        occ_ok = all(8 <= r["occ"] <= 10 for r in rr)
        A(f'   T13-P1: "occupancy 8-10 on every in-window read."')
        A(f"      -> {'HOLDS' if occ_ok else 'DOES NOT HOLD'} (occ values seen {occs})")
        poe_ok = all(r["d_pop_on_empty"] <= 3 for r in rr)
        A(f'   T13-P2: "pop_on_empty delta 0 (<= 3 per 10 s)."')
        A(f"      -> {'HOLDS' if poe_ok else 'DOES NOT HOLD'} "
          f"(per interval {[r['d_pop_on_empty'] for r in rr]})")
        skips_ok = 334 <= r4b_rate <= 454
        A(f'   T13-P3: "r4b_skips ~ 394 +- 60 per 10 s (the holes become skips)."')
        A(f"      -> {'HOLDS' if skips_ok else 'DOES NOT HOLD'} (mean {r4b_rate:.1f} per read)")
        A(f'   T13-P4: "push_on_full 0."')
        A(f"      -> {'HOLDS' if tot_pof == 0 else 'DOES NOT HOLD'} (total {tot_pof})")
        A("   T13-P5/P6/P7 (checker gap events per 10 s < 100, PER <= 3 %, lag-32 < 0.1 with")
        A("   no 25 ms comb) are host-side and are scored from the leg's own artefacts")
        A("   (capture_r3 / accept_analyze.py / comb_autocorr.py / comb_period_ms.py), not")
        A("   from the register readings -- they are NOT evaluated here.")
        A("")
        A("   -- falsifiers (register-side halves) --")
        fb = (r4b_rate < 40) and (poe_rate > 300)
        A(f'   F-B: "r4b_skips ~ 0 and pop_on_empty ~ 394 -> steering never engaged on')
        A(f'        silicon (lock/window logic; read r4b_armed/window_opens and stop)."')
        A(f"      -> {'FIRES' if fb else 'does not fire'} "
          f"(skips {r4b_rate:.1f}/read, pop_on_empty {poe_rate:.1f}/read, "
          f"locked={sorted({r['r4b_locked'] for r in rr})}, "
          f"opens/interval {[r['d_r4b_opens'] for r in rr][:6]})")
        A(f'   F-A: "r4b_skips ~ 394 but PER unchanged and the lag-32 comb present -> the')
        A(f'        skip position does not matter on silicon."  Register-side half:')
        A(f"      -> skips {'ARE' if skips_ok else 'are NOT'} at the predicted rate; the PER")
        A(f"         and lag-32 halves decide it, from the leg artefacts.")
        A(f'   F-C: "PER improves but a NEW loss class appears" -- entirely host-side.')
    open(os.path.join(run_dir, "verdict.txt"), "w").write("\n".join(L) + "\n")
    return "AIR_SCORED"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--mode", default="air", choices=["ctrl", "air"])
    ap.add_argument("--label", default="")
    ap.add_argument("--acq-intervals", type=int, default=0,
                    help="exclude the first N read INTERVALS from the steady-state "
                         "verdicts and report them in the acquisition window instead "
                         "(default 0: the first reading's cumulative counters already "
                         "carry the post-arm transient, and no delta contains it)")
    a = ap.parse_args()
    rows = load(a.run_dir)
    notes, fails = structural(rows)
    good, dl = deltas(rows)
    csv = write_csv(a.run_dir, good, dl)          # the CSV keeps EVERY interval
    acq_dl, dl = dl[:a.acq_intervals], dl[a.acq_intervals:]
    if a.acq_intervals and not dl:
        print(f"W1_SCORE_REFUSED --acq-intervals {a.acq_intervals} would leave no "
              f"steady-state intervals (have {len(acq_dl)})")
        return 2
    rc = verdict(a.run_dir, a.mode, a.label, rows, good, dl, notes, fails, acq_dl)
    print(open(os.path.join(a.run_dir, "verdict.txt")).read())
    print(f"W1_SCORE {rc} csv={csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
