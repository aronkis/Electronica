> Evidence ledger, moved verbatim from `two_jup/comb/COMB32_SRO_SIM_TAPS.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# COMB32 — SRO harness with the TRUE guarded-ring taps (T0a)  [sim]

Date 2026-09-04 · **desk only, no board contact** · Verilator on
`jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/` (Aug-12 gen, txfixF3 lineage).
**Every number in this document is [sim].**

Supersedes the FIFO section of `COMB32_SRO_SIM_2p5.md`, which measured ring occupancy as
`(pushPtr − popPtr) & 31` (`sim_sro.cpp:115`) — a metric that cannot distinguish an EMPTY
ring (0) from a FULL one (32) and whose scorer tested the wrong edge value (31, not 32).
`RATE_HANDLE_FIX_SURVEY.md` §0/§6 called for the true taps; this is their return.

## 1. What was tapped

`jupiter_240k5_byte/rtl_sim/wrap_byte_sro.v` (lint-clean, `verilator --lint-only`, no
`%Error`) gains six hierarchical taps; `sim_sro.cpp` aggregates them per 49,332-sample
input frame and **appends** them as columns 21–30 of `_frames.txt` (columns 1–20 are
byte-identical to the previous format, so older scorers keep parsing), plus columns 13–18
of `_marks.txt`.

| tap | netlist path (under `…u_Frequency_and_Time_Synchronizer`) | width |
|---|---|---|
| `occTrue` | `u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.Delay_out1` | 6 b, 0…32 |
| `rhPopEmpty` | same instance `.pop_on_empty_FIFO` (`Validate_Input_Push_Pop_block.v:119`) | 1 b |
| `rhPushFull` | same instance `.push_on_full_FIFO` (`:129`) | 1 b |
| `pdOcc` | `u_Preamble_Detector.u_FIFO.u_Validate_Input_Push_Pop.Delay_out1` | 14 b, 0…12333 |
| `pdPopEmpty` | same instance `.pop_on_empty_FIFO` (`Validate_Input_Push_Pop.v:121`) | 1 b |
| `pdPof` | same instance `.push_on_full_FIFO` (`Validate_Input_Push_Pop.v:131`) | 1 b |

**On `pushOnFullRaw`.** The brief names
`u_Preamble_Detector.u_FIFO.Validate_Input_Push_Pop_pushOnFullRaw`. That signal exists only
in the *slack-patched* build tree (`Validate_Input_Push_Pop.v:136-138`, the `enSlack`
variant). The s1_rtl tree the harness elaborates is the **pre-patch** source — it has no
`enSlack` and no `push_on_full_raw` (`grep -rn 'pushOnFullRaw|push_on_full_raw|enSlack'`
over the whole tree returns nothing). In that tree `push_on_full_FIFO` **is** the raw
event, so `pdPof` above is the exact equivalent. No substitution is hidden.

Edge thresholds are per-FIFO and are now taken from the netlist rather than from the
pointer width: ring FULL = **32** (`Compare_To_Constant1_block.v:36`), PD FIFO FULL =
**12333** (`Compare_To_Constant1.v:36`); EMPTY = 0 for both.

Per frame the harness records the true occupancy at the frame's first and last beat
(`occTS`/`occTE`) **and its min/max envelope** (`occTmin`/`occTmax`) — a momentary edge
touch inside a frame is invisible to boundary sampling and would have produced a false
negative.

### Tap self-check
Per frame, `occTE − occTS` must equal (validated pushes − validated pops) up to the
boundary beat's own push/pop (|dev| ≤ 1, since the occupancy register is read one beat
before the push/pop sampled on the same beat is applied). **PASS on all legs**, max
deviation 0 (r_p000) / 1 (the SRO legs). The taps are the RTL's own arithmetic, not a
reconstruction.

### Scorer changes (`two_jup/comb/sro_sim/score_sro2.py`)
- edge test moved off the pointer metric onto `occTrue`, against 0 **and 32** (and 0/12333
  for the PD FIFO), evaluated on the per-frame envelope;
- `exc = pushes − pops` (the old `push.sum() − 12333·n` is retained as a separate,
  explicitly labelled line);
- phase-lock score, both directions, per event kind: fraction of lost/corrupt frames with
  an event of that kind within ±1 frame (**this is the gate**), the reciprocal fraction of
  events with a loss within ±1, the nearest-offset list, and the best constant alignment
  offset (**diagnostic only — never the gate**);
- the legacy pointer metric is kept as a column and printed with a warning label.

## 2. Legs

Command: `Vwrap_byte_sro rx <stim> <nsamp> 8400 <prefix> 2 0`; scored with
`score_sro2.py r_p000 <prefix>`. Stimulus from `gen_sro_stim.py` on the committed TX-RTL
capture `tx5.iq` (s = 0 round-trips exact). `q_p2p5` was regenerated at **920 frames**
(`s_p2p5_920.iq`, 45,385,440 samples) because the FULL edge is predicted near frame 876,
beyond the old 420-frame run. Runs under transient `systemd --user` units
(`t1-build`, `t1-legs-a`, `t1-legs-b`), never a harness background job.

### 2.1 Loss and occupancy

| leg | s (ppm) | frames scored | loss % | biterr | true occupancy start→end | envelope | first true edge | which edge |
|---|---|---|---|---|---|---|---|---|
| `r_p000` | 0 | 162 | **0.00** | 51 (clean) | 5 → 5 | 5..6 | none | — |
| `q_m2p5` | −2.5 | 417 | **4.11** | 617 | 5 → 0 | 0..5 | **f = 137** | **EMPTY (0)** |
| `q_m10` | −10 | 207 | **23.04** | 1490 | 5 → 0 | 0..5 | **f = 34** | **EMPTY (0)** |
| `q_p2p5` | +2.5 | 914 | **0.11** | 86 | 5 → 31 | 5..**32** | **f = 843** | **FULL (32)** |

`exc = pushes − pops` over the scored window: 0 (`r_p000`), −5 (`q_m2p5`), −5 (`q_m10`),
**+26** (`q_p2p5`). On the two negative legs the ring is pinned at its EMPTY edge, so the
net drift is absorbed by the suppressed pops rather than accumulating; on the positive leg
it accumulates all the way to FULL. The legacy `push.sum() − 12333·n` figures
(0 / −13 / −26 / +26) are the raw strobe deficits/surpluses and agree with the 12,333·s·n
prediction (−12.8 / −25.5 / +28.2).

**The +2.5 ppm prediction is confirmed to within 33 frames.** `COMB32_SRO_SIM_2p5.md`
pre-registered the first overflow edge at frame ≈ 876 (27 entries of headroom at
0.0308 entries/frame); the true occupancy first touches 32 at **f = 843** and the first
`push_on_full` fires at **f = 875**. The old 420-frame run could not have seen it.

### 2.2 Suppression events per leg (totals over the scored window)

| leg | `pop_on_empty` (ring) | `push_on_full` (ring) | `pdPof` (PD FIFO) | `pd pop_on_empty` | PD occupancy envelope |
|---|---|---|---|---|---|
| `r_p000` | **0** | **0** | **0** | **0** | 12333..12333 |
| `q_m2p5` | **8** | **0** | **0** | **0** | 12332..12333 |
| `q_m10` | **21** | **0** | **0** | **0** | 12332..12333 |
| `q_p2p5` | **0** | **2** (f = 875, 907) | **0** | **0** | 12333..12333 |

`q_m2p5` events at f = 161, 194, 226, 259, 291, 324, 356, 389 (spacings 33,32,33,32,33,32,33
→ mean 32.57). `q_m10` events at f = 40, 48, 56, 64, 72, 81, 89, 97, 105, 113, 121, 129, …
(spacing 8).

**`pdPof` and `pd pop_on_empty` are identically zero on EVERY leg, both signs.**
`push_on_full` on the Rate_Handle ring is zero at both negative signs (the ring drains to
EMPTY and never approaches FULL) and fires exactly twice at +2.5 ppm, where the ring fills. The PD FIFO's
occupancy does dip to 12,332 for one epoch after a skipped valid slot — that dip is
recorded in `pdOccMin` — but *neither of its guards fires*, so that FIFO deletes nothing
and drops nothing.

### 2.3 Comb period and phase lock

| leg | comb period | losses within ±1 of `pop_on_empty` (**GATE, ≥80 %**) | reciprocal: events with a loss within ±1 | best constant offset (diagnostic) |
|---|---|---|---|---|
| `r_p000` | — (no losses) | n/a | n/a | n/a |
| `q_p2p5` | no comb (1 loss in 914; all autocorrelations ≈ 0.000) | **100 % (1/1) against `push_on_full`** — gate met, but n = 1 | 50 % (1/2) | +1 → 100 % |
| `q_m2p5` | **32.4 frames** (lag-32 autocorr +0.452, permutation null p95 +0.208) | **47.1 % (8/17)** — gate NOT met | **87.5 % (7/8)** | +1 → 47.1 % |
| `q_m10` | **8.1 frames** (lag-8 +0.669, null p95 +0.219) | **55.3 % (26/47)** — gate NOT met | **95.2 % (20/21)** | −1 → 89.4 % |

On the two negative legs `push_on_full`, `pdPof` and `pd pop_on_empty` score **0 % — they
have no events at all**, so no verdict can rest on them there. On `q_p2p5` it is the
reverse: `pop_on_empty`, `pdPof` and `pd pop_on_empty` have no events, and the single lost
frame sits exactly on the first `push_on_full`.

### 2.4 The valid-chain census, and one apparent contradiction

In **local sample time** (each `_frames.txt` row = one 49,332-sample input frame, nominal
12,333 symbols) the deficit is strictly one-sided and matches the event count **exactly,
one for one**:

| leg | local deficit | local surplus | `pop_on_empty` events |
|---|---|---|---|
| `r_p000` | 0 | 0 | 0 |
| `q_m2p5` | **8** | **0** | **8** |
| `q_m10` | **21** | **0** | **21** |
| `q_p2p5` | 0 | 0 | 0 (`push_on_full` = 2) |

identically at every stage `ss = cfc = cs = pd = corr`. On `q_p2p5` the local-time census is
**balanced** (deficit 0, surplus 0) even though two symbols were deleted at the FULL edge:
the interpolator strobe is running *fast* there (surplus 28, deficit 2), so the two
suppressed pushes are absorbed by the surplus and the valid chain still delivers 12,333
symbols per local frame. That is precisely why the FULL edge costs 0.11 % and the EMPTY
edge costs 4.11 % — see §3.1.

*The apparent contradiction:* the **mark-space** census on the same legs reports
deletions 256 **and** insertions 288 (q_m2p5). That is not a contradiction of
"strictly one-sided": mark-space measures the spacing between consecutive demodulator
frame marks, so a frame whose *start* is placed one symbol early or late is booked as a
matched delete/insert pair. Local sample time is the census that answers "how many symbol
slots did the valid chain deliver against the local clock", and it is one-sided.

### 2.5 The second loss comb (recorded, not explained)

At −2.5 ppm the losses form **two interleaved series**: one exactly on the `pop_on_empty`
event (194, 226, 259, 291, 324, 356, 389) and a second **~7 frames earlier**
(154, 186, 218, 251, 283, 316, 348, 381, 413). It is the second series that drags the
losses→event gate down to 47.1 %. Whether it is the same event seen through the
Preamble_Detector's 4-epoch/1-epoch delays, or an independent effect, is **not settled
here** — settling it needs the per-epoch trace, which is T2 work. Recorded as an open
question, deliberately not explained away by widening the ±1 window.

## 3. Verdicts (one per leg)

Verdict set from the plan: `RATE_HANDLE_FULL_DELETES` / `PREAMBLE_FIFO_DELETES` /
`NEITHER`, and INCONCLUSIVE where the phase-lock gate is not met.

| leg | verdict |
|---|---|
| `r_p000` (s = 0) | **NEITHER** — no events of any kind, no loss, occupancy static. Positive control passes. |
| `q_m2p5` (−2.5 ppm) | **NEITHER**, with the qualifier below. `push_on_full = pdPof = pd pop_on_empty = 0`, so neither briefed mechanism can be the cause; the ring never approaches FULL. The surviving candidate is the ring's **EMPTY** edge, which fires 8 times and accounts for the 8 deleted symbol slots one for one — but the losses→event gate is 47.1 %, so this is **INCONCLUSIVE as a phase-lock verdict**. |
| `q_m10` (−10 ppm) | **NEITHER**, same qualifier: 21 `pop_on_empty` events, 21 deleted slots, zero events of either briefed kind; gate 55.3 % → **INCONCLUSIVE as a phase-lock verdict**. |
| `q_p2p5` (+2.5 ppm, 914 fr) | **INCONCLUSIVE** — mechanism confirmed, loss rate not. The **deletion** is measured directly at the guard and is not in doubt: occupancy touches 32 at f = 843 and `push_on_full` fires at f = 875 and f = 907 (pre-registered f ≈ 876), so the FULL edge of the Rate_Handle ring demonstrably deletes symbols. But the **loss** verdict cannot be earned here: there is exactly **one** lost frame in 914, so "100 % of losses within ±1" is a single coincidence, and the reciprocal is 50 % (1 of 2 events produced a loss). `RATE_HANDLE_FULL_DELETES` is therefore asserted as a statement about the mechanism only, not as a localisation of this leg's frame loss. |

### 3.1 The two edges are NOT equally harmful — the headline asymmetry

| | EMPTY edge (negative SRO) | FULL edge (positive SRO) |
|---|---|---|
| what the guard does | suppresses a **pop** → a skipped valid slot; nothing is dropped from the RAM | suppresses a **push** → a symbol is genuinely **deleted** |
| local-time valid-chain census | deficit = event count, surplus 0 | **balanced** (the fast strobe refills the hole) |
| events at 2.5 ppm over ~900 frames | 8 in 417 frames | 2 in 914 frames |
| frame loss | **4.11 %** (−2.5 ppm), **23.04 %** (−10 ppm) | **0.11 %** (+2.5 ppm) |
| comb | yes, 32.4 frames (lag-32 +0.452 vs null +0.208) | none (all autocorrelations ≈ 0) |

The counter-intuitive result, and it is measurement: the edge the netlist survey called
**benign** is the one that destroys frames, and the edge it called **the only place
Rate_Handle loses a symbol** is nearly harmless.

*Why* — **[inferred]**, not traced: at the FULL edge the strobe is running fast, so a
deleted symbol is immediately made up and the downstream valid-counted epochs stay aligned;
at the EMPTY edge the strobe is running slow, the skipped slot is a permanent hole in valid
density, and every valid-counting epoch downstream (`Peak_Search.v:94`,
`Timing_Adjust.v:126`, `End_Generator.v:71`) slips by one against the tick-counted
`Preamble_Detector.Delay10_reg` data delay. The evidence for this is the coincidence of a
balanced local-time census with 0.11 % loss at the FULL edge and a one-sided census with
4.11 % loss at the EMPTY edge. **No individual deleted symbol was traced through to an
epoch counter** — that trace is T2 work.

This also settles the sign question for T2: **the losing sign in the sim is negative SRO**,
and the fix must address the EMPTY edge, not the FULL edge.

## 4. Does the earlier "ring deletes at the empty edge" reading survive?

**Stated plainly: half of it survives, and the half that survives is not the half that was
written.**

- `COMB32_SRO_SIM_2p5.md` said the ring reaching **an edge** causes the loss. That
  survives, and is now measured on the real occupancy rather than inferred from a pointer
  difference: the first EMPTY touch is at f = 137 (−2.5 ppm) and f = 34 (−10 ppm), and
  losses begin only after it (f = 154 and f = 38).
- `RATE_HANDLE_FIX_SURVEY.md` §0 said only the FULL edge deletes a symbol. **That part is
  confirmed** — `q_p2p5` shows exactly that, two deletions at `push_on_full` — but it turns
  out to be the *cheap* failure (0.11 % loss, no comb).
- `RATE_HANDLE_FIX_SURVEY.md` §0 said the EMPTY edge is **benign** — "a skipped valid
  slot, stream intact" — and that only the FULL edge deletes. **That does not survive as a
  statement about frame loss.** The guard does behave exactly as the netlist says (no
  garbage, no repeat, no RAM-level deletion), but the skipped valid slot is *not* harmless
  downstream: the local-time census shows one lost symbol slot per `pop_on_empty` event,
  one for one, at every stage from `Symbol_Synchronizer.validOut` to
  `Correlator.validOut`, and frames die on the same comb.
- The survey's §0 conclusion that "at the EMPTY edge the netlist loses no data — so either
  the sim's `occ==0` was the FULL edge misread, or the frame-killing step is elsewhere" is
  now decided: **it was not a misread** (`push_on_full` is zero and `occTmax` never
  exceeds 5 on either negative leg), so **the frame-killing step is elsewhere** — downstream
  of the ring, driven by the valid-density hole the EMPTY edge punches.
- The survey's strongest candidate for that downstream step — the Preamble_Detector
  realignment FIFO deleting via push-on-full — is **excluded by direct measurement**:
  `pdPof = 0` and `pd pop_on_empty = 0` on every leg. This predicts the T1 silicon result
  (`enSlack` ON changed nothing) rather than being surprised by it: `enSlack` suppresses
  only that FIFO's `push_on_full`, and there was never a `push_on_full` to suppress.

**Consequence for T2.** A fix that only makes the PD FIFO's pop occupancy-driven leaves the
skipped valid slot in the stream and cannot recover the deleted symbol. The valid-density
hole originates at `Rate_Handle`'s EMPTY edge; the fix has to be there (or the epoch
counters downstream have to tolerate a hole), not at the PD FIFO's guard. And it must
target the **EMPTY** edge specifically: the FULL edge deletes symbols but costs only
0.11 % because the fast strobe refills the hole (§3.1).

## 5. Reproduce

```
jupiter_240k5_byte/rtl_sim/build_sro.sh                    # under systemd-run --user
two_jup/comb/sro_sim/gen_sro_stim.py tx5.iq s_p2p5_920.iq --ppm 2.5 --frames 920
two_jup/comb/sro_sim/runall3.sh      # r_p000, q_m2p5, q_m10
two_jup/comb/sro_sim/runall4.sh      # q_p2p5, 920 frames
two_jup/comb/sro_sim/score_sro2.py r_p000 q_m2p5 q_m10 q_p2p5
```
Stimulus `.iq` files are NOT committed (181 MB for the 920-frame leg); regenerate them.
