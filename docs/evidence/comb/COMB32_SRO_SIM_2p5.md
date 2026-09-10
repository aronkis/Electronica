> Evidence ledger, moved verbatim from `two_jup/comb/COMB32_SRO_SIM_2p5.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# COMB32 — SRO reproduction at the measured 2.5 ppm  [sim]

Date 2026-09-04 · **desk only, no board contact** · Verilator 5.020 on the built 148
netlist `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/` (Aug-12 gen, txfixF3
lineage). **Every number here is [sim]** unless labelled otherwise.

Follow-up to `COMB32_SRO_SIM.md`, which found NOT REPRODUCED at ±0.63 / +1.26 ppm and
measured the governing law: `Rate_Handle` FIFO occupancy drifts `12333·s` entries per
frame, so the ring reaches an edge only after `(edge − 5)/(12333·s)` frames. Those legs
never reached an edge — the largest excursion was occupancy 25 of 32.

`TX_SEL8_DESK.md` then supplied the missing number [silicon]: the receiver's valid chain
deletes exactly one symbol, strictly one-sided, at **2.57 ppm (09-04 sel8, 1 per 31.5
frames)** and **2.51 ppm (09-03 sel13, 1 per 32.35 frames)**, downstream of the
interpolator (`Symbol_Synchronizer.validOut → … → Correlator.validOut`), lag-32
autocorrelation +0.82. The earlier ≤ 0.06 ppm bound is retracted there: it counted
post-deletion valid symbols, which the deletion holds at exactly 12,333.

At 2.5 ppm the drift law gives **0.0308 entries/frame = one entry per 32.4 frames** — the
comb period, to 1 %. This document runs that point.

## Pre-registered predictions (written before the legs were scored)

| leg | s (ppm) | frames | occupancy start | first edge at frame | edge events in the run | period |
|---|---|---|---|---|---|---|
| `q_m2p5` | −2.5 | 420 | 5 | 5/0.0308 ≈ **162** (underflow, occ → 0) | ~8 | 32.4 |
| `q_p2p5` | +2.5 | 420 | 5 | 27/0.0308 ≈ **876** (overflow, occ → 32) — **beyond the run** | 0 | — |
| `q_m10` | −10 | 210 | 5 | 5/0.123 ≈ **41** (underflow) | ~21 | 8.1 |

So the two signs are **not** symmetric, and that asymmetry is a prediction, not an
artefact: occupancy starts at 5 of 32, so the underflow edge is 5 entries away and the
overflow edge 27. The brief's "~65–160 frames at one sign" is the underflow sign.

*(results below)*

---

## 1. Method

Harness `wrap_byte_sro.v` + `sim_sro.cpp` (`obj_byte_sro`), extended for this task with the
full valid chain the silicon finding implicates, all hierarchical references verified
against the netlist:

| tap | netlist source |
|---|---|
| `ss` = `Symbol_Synchronizer.validOut` | `Frequency_and_Time_Synchronizer.v` |
| `cfc`, `cs` | `Coarse_Frequency_Compensator_validOut`, `Carrier_Synchronizer_validOut` |
| `pd` | `Preamble_Detector_validOut` |
| **`corr` = `Correlator.validOut`** | `Preamble_Detector.v:154-162` |
| `tref` | `Peak_Search.timing_Reference_out1` (`Peak_Search.v:58`, mod-12333) |
| `push`/`pop`/occupancy | `FIFO_block.v:113,148` inside `Rate_Handle` |

Replay is `cadence 2, vphase 0` (see `COMB32_SRO_SIM.md` §5 — cadence 4 duplicates every
ADC sample). Stimulus is the TX RTL's own output, tiled from a verified int16-exact
49,332-sample period, fractionally resampled in numpy; s = 0 round-trips to 6.4e-13 LSB.

### A scorer defect found and fixed before any verdict
My first `tref` census diffed `timing_Reference` between **consecutive `Correlator.validOut`
events**. That is self-referential — `tref` is *clocked by* `Correlator.validOut`, so the
difference is 1 by construction and the census returned all zeros on every leg. The
correct analogue of `dtref_census.py` buckets by **local sample time**: each `_frames.txt`
row is one 49,332-input-sample window, so `12333 − corr` is the symbol deficit the valid
chain delivered against the local clock over that window — which is what the silicon
census measures by diffing `tref` against the free-running local slot counter. All
census numbers below use the local-time form; the event-indexed one is retained in the
output only as a check.

## 2. `q_m10` — s = −10 ppm, 210 frames (the accelerated leg)  **REPRODUCES**

| quantity | predicted | measured |
|---|---|---|
| occupancy drift | 0.123 entries/frame | excess pushes **−26** over 204 frames vs −25.2 predicted |
| first FIFO edge (underflow, occ → 0) | frame ~41 | **frame 34** |
| first lost frame | just after the edge | **frame 38** |
| loss comb period | 8.1 frames | **lag-8 autocorrelation +0.669** (permutation null p95 **+0.219**) |

- Frames: 204 scored, **157 OK, 47 CORRUPT, 0 MISSING → 23.04 % loss**. `biterr` 1,490
  against 51 on every clean leg.
- Loss index series begins `38, 39, 40, 46, 48, 54, 56, 62, 64, 70, …`; spacings run
  `6,2,6,2,6,2,…` — a period-8 comb with a doublet, harmonic at lag 16 (+0.587).
- FIFO: occupancy 4 → 0, first edge f=34, **131 of 204 frames sitting at an edge**
  thereafter.
- **Valid-chain census in local time is STRICTLY ONE-SIDED** — deficit 21, surplus **0** —
  and identical at every stage `ss = cfc = cs = pd = corr = 21`. This is the silicon
  signature (`TX_SEL8_DESK.md`: 48 deletions, zero insertions).
- The interpolator strobe (FIFO push) itself shows deficit 26, surplus 0.

**Reading.** At −10 ppm the ring reaches its underflow edge, and from that point the
receiver deletes symbols one-sidedly and loses frames on a comb whose period is exactly
the occupancy-drift period. The loss is caused by the FIFO reaching an edge, not by the
pointer phase.

### One honest discrepancy against silicon
In this sim the deficit **originates at the interpolator strobe** (push deficit 26), because
a genuine sample-rate offset was injected. On silicon `TX_SEL8_DESK.md` reports the
interpolator strobe `I[15]` **balanced** while `tref` is one-sided. Those are not
necessarily in conflict: at 2.5 ppm the strobe imbalance is 0.031 symbols per frame, and
the sel13 usable runs are ~0.2 frames long, so an `I[15]` census over those runs has
nowhere near the sensitivity to resolve it. But it is a real difference between the sim's
fingerprint and the capture's, and it is not resolved here.

## 3. `q_m2p5` — s = −2.5 ppm, 420 frames — **the decisive leg: REPRODUCES at period 32.375**

| quantity | predicted | measured |
|---|---|---|
| occupancy drift | 0.0308 entries/frame | excess pushes **−13** over 414 frames vs −12.76 predicted |
| first FIFO edge (occ → 0) | frame ~162 | **frame 137** |
| first lost frame | after the edge | **frame 154** |
| **comb period** | **32.4 frames** | **32.375 frames** |

- Frames: 414 scored, **397 OK, 17 CORRUPT, 0 MISSING → 4.11 % loss**; `biterr` 617 vs 51 clean.
- Losses arrive in **9 groups** at frames `154, 186, 218, 251, 283, 316, 348, 381, 413`;
  group spacings `32, 32, 33, 32, 33, 32, 33, 32` → **mean 32.375 frames**.
- Loss autocorrelation **lag 32 = +0.452** against a permutation null p95 of **+0.208**
  (lag 65 = +0.638, the second harmonic of the 32.4 half-integer period).
- **Correlator local symbol deficit: 8 events, total 8 symbols deleted, surplus 0 —
  strictly one-sided**, at frames `161, 194, 226, 259, 291, 324, 356, 389`, spacings
  `33,32,33,32,33,32,33` (mean 32.571).
- **Coincidence: 8/8 deficit events have a loss group within 8 frames; 8/9 loss groups
  have a deficit event.** The two series are phase-locked at a constant ≈ −7-frame offset
  (loss group onset precedes the bucket in which the deficit is booked), so the honest
  statement is *same period, locked phase*, not *same frame*.
- FIFO: occupancy 5 → 0, first `occ == 0` at frame **137**, 213 of 414 frames at the edge.

### Comparison with silicon
| source | rate | comb period |
|---|---|---|
| 09-04 sel8 [silicon] | 2.57 ppm | 31.5 frames |
| 09-03 sel13 [silicon] | 2.51 ppm | 32.35 frames |
| **this sim, −2.5 ppm [sim]** | 2.5 ppm | **32.375 frames** |

## 4. `q_p2p5` — s = +2.5 ppm, 420 frames — **the sign control: clean, as pre-registered**

- **414/414 OK, zero corrupt, zero missing, 0.00 % loss**; `biterr` 51 = the clean baseline.
- Valid chain **perfectly balanced at every stage**: deficit 0, surplus 0 for `ss`, `cfc`,
  `cs`, `pd`, `corr`; every mark delivers exactly 12,333 (min = max = 12,333).
- FIFO: occupancy 5 → 18, **13 steps at mean spacing 32.42 frames**, and **zero frames at
  an edge**. Excess pushes +13, vs +12.76 predicted.

**This is the load-bearing control.** The +2.5 ppm leg has the *same* occupancy-drift
period as the −2.5 ppm leg (32.42 vs 32.375 frames) and the *same* pointer-phase beat, yet
loses nothing — because occupancy walks away from the edge (5 → 18) instead of into it.
The loss is caused by the ring **reaching an edge**, not by the drift and not by the mod-32
pointer phase. It also confirms the asymmetry pre-registered in §"Pre-registered
predictions": with occupancy starting at 5 of 32, underflow is 5 entries away and overflow
27, so at 420 frames only the negative sign can reach an edge.

## 5. Scaling control

| leg | s | comb period measured | 1/(12333·\|s\|) |
|---|---|---|---|
| `q_m2p5` | −2.5 ppm | **32.375** frames | 32.43 |
| `q_m10` | −10 ppm | **8.100** frames | 8.11 |

Ratio of measured periods **3.997** against the exact 4.000 expected from 1/\|s\|.

---

## VERDICT

> **REPRODUCED — period 32.375 frames at −2.5 ppm [sim].**
>
> Driving the built 148 receiver RTL with a −2.5 ppm sample-rate offset reproduces the
> silicon comb: frames are lost on a **32.375-frame** period (silicon: 31.5 frames at
> 2.57 ppm, 32.35 at 2.51 ppm), lag-32 loss autocorrelation **+0.452** against a
> permutation null of +0.208, and the receiver's valid chain shows a **strictly one-sided**
> symbol deficit (8 deletions, **zero** insertions) at `Symbol_Synchronizer.validOut`
> through `Correlator.validOut` — the `TX_SEL8_DESK.md` signature. The deficit series and
> the loss series are phase-locked with the same period (8/8 deficit events carry a loss
> group). At −10 ppm the same mechanism gives **8.100** frames against 8.11 predicted;
> the two measured periods scale as 1/\|s\| to 0.1 %.
>
> **Mechanism, corrected — [correction 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]:** `Rate_Handle`'s
> 32-entry ring (`FIFO_block.v:113,148`, `AddrWidth(5)` at `:180`; `reset_1` tied to constant
> 0 at `Rate_Handle.v:97,106`, so it is never re-centred) IS full/empty guarded one level down
> (`Validate_Input_Push_Pop_block.v:119-137`). An SRO makes pushes and pops differ by
> `12333·s` per frame, so occupancy walks at one entry per `1/(12333·s)` frames — but the two
> edges are not symmetric: the EMPTY edge only suppresses a pop, producing a skipped valid
> slot with **no data loss**, and only the FULL edge suppresses a push and deletes a symbol.
> This −2.5 ppm stimulus drains the ring toward EMPTY (`gen_sro_stim.py:72-73`), which is the
> benign edge — so the netlist as read does not explain this leg's 4.11% loss at that edge.
> The harness's occupancy metric, `sim_sro.cpp:115`'s `(pushPtr − popPtr) & 31`, cannot
> distinguish 0 from 32, so "occupancy reached an edge" here cannot be read as "reached FULL"
> without the true occupancy tap. The period/loss numbers above (32.375 frames, 8/8 one-sided
> deficit, lag-32 +0.452) are reproduced and unchanged; what is retracted is the claim that the
> ring's own full/empty edge is, without further evidence, the deleting stage. The deleting
> stage is being re-localised with true occupancy/guard taps by Task 1
> (`COMB32_SRO_SIM_TAPS.md`), against both the Rate_Handle FULL edge and the
> Preamble_Detector realignment FIFO (`Preamble_Detector.v:321-334`) as candidates. The comb
> period itself is still the *occupancy-drift* period, `1/(12333·SRO)`, regardless of which
> stage is doing the deleting.
>
> **This corrects `COMB32_SRO_SIM.md` (2026-09-03) and settles what it left open.** That
> report was right that at ±0.63/1.26 ppm nothing is lost, right that the pointer-phase
> beat of 32 is not the mechanism, and explicit that "whether a wrap corrupts anything is
> untested". It is now tested: **a wrap does corrupt, one frame per wrap.** The reason the
> earlier legs saw nothing is that they never reached an edge (best occupancy 25 of 32) —
> exactly the gap that report named as the single outstanding question.
> The "128.7 frames" figure there was the drift period *at 0.63 ppm*; at the real 2.5 ppm
> SRO the same law gives 32.4, which is the comb.

## 6. Scope limits

1. Every air frame is byte-identical (tiled BIST ROM payload); payload-dependent effects
   cannot appear.
2. Noiseless, CFO-free, no multipath or AGC transients on these three legs.
3. The absolute *phase* of the comb depends on the initial occupancy (5 of 32 here), which
   on hardware is set at reset and is not observable — so the sim predicts the period and
   the sign asymmetry, not which frame index is hit.
4. **RESOLVED since this document was written (2026-09-04, commits 9fc1a61 / f9c1f17).**
   The point flagged here was that in this sim the deficit originates at the interpolator
   strobe (push deficit 13 at −2.5 ppm), whereas `TX_SEL8_DESK.md` reported `I[15]`
   *balanced* on silicon. That tension is gone, and in the direction guessed here: the
   silicon "balanced" figures were a **drop-boundary artefact** (a DMA burst removes a
   whole multiple of 4 records, so filtering on record contiguity alone does not exclude
   drop-straddling groups and manufactures balanced ±1 pairs). Correctly filtered, the
   interpolator is **0.0 ± 1.3 ppm against a 2.5 ppm deletion — a ~2σ gap, disfavoured but
   NOT excluded.** So the sim's interpolator-origin deficit is *compatible* with the
   capture; the silicon census is simply not yet sensitive enough to arbitrate. See
   `DTREF_CENSUS_CONTROLS.md` and `TX_SEL8_DESK.md` for the corrected census.
6. **Scope of the claim, per the same commits:** the 09-02 control run shows the usual
   ~8 % loss with *zero* deletions, so this mechanism does **not** explain the bulk loss —
   it accounts for the **32-frame comb component only**, which is all this document
   claims.
5. `q_p2p5` bounds the positive sign only out to 420 frames; its first edge is ~876.

## 7. Commands and raw outputs

```sh
cd two_jup/comb/sro_sim
B=../../../jupiter_240k5_byte/rtl_sim/obj_byte_sro/Vwrap_byte_sro
python3 gen_sro_stim.py tx5.iq s_m2p5.iq --ppm -2.5 --frames 420
python3 gen_sro_stim.py tx5.iq s_p2p5.iq --ppm  2.5 --frames 420
python3 gen_sro_stim.py tx5.iq s_m10.iq  --ppm -10  --frames 210
$B rx s_m2p5.iq 20719440 8400 q_m2p5 2 0     # via runall2.sh under systemd-run --unit=srorun2
$B rx s_p2p5.iq 20719440 8400 q_p2p5 2 0
$B rx s_m10.iq  10359720 8400 q_m10  2 0
python3 score_sro2.py r_p000 q_m2p5 q_p2p5 q_m10
```

Build: `systemd-run --user --unit=srobuild2 --collect … build_sro.sh`. Legs ran six-up in
~45 min. Raw: `q_<tag>_{deliv,frames,marks,anom,res}.txt`; `_frames.txt` is the local-time
census (one row per 49,332-input-sample window), `_marks.txt` is indexed by demod frame
mark. `.iq` stimulus is regenerable and not committed.
