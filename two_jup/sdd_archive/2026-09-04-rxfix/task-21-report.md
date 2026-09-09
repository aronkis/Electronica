# Task 21 — RXFIX_R4E: the push drop lands exactly where it was aimed, and the frame dies anyway  [sim, desk only]

Brief `task-21-brief.md` (night-2 plan 2026-09-04) · pre-registration
`two_jup/comb/RXFIX_R4E_SIM_GATE.md`, **committed before the variant, the harness or any
leg existed** (`43cfaf1`) · ledger `progress.md` (`Task 21:` lines) · branch
`per-under-1pct-2026-07`. **No board contact, no Vivado, no subagents.** Every number
below is **[sim]**.

---

## Verdict in one paragraph

**The steering is exact and the hypothesis it was built to test is false.** All 37 push
drops on `n_p10` landed at window slot **7** — dead centre of the 13-slot structural guard
window, on the RTL witness and on an independent pointer-based recount, 37/37 agreeing —
the ring parked at 22/23, `push_on_full` went **21 → 0**, and `pdPof` stayed **0** on every
leg, which is the row Task 14 §3 said would fail. **And every single one of those 37 drops
killed a frame.** Loss on `n_p10` is **11.16 %** against the baseline's 4.99 % and R4B's
6.65 %: **37/37 drops are aligned to a lost frame at a constant offset of 2 air frames, and
not one of the 47 lost frames is unattributed.** **K8 fired.** The same thing happens on
`n_m10`, where 7 drops cost 8 frames R4B does not lose (2.38 % vs 0.48 %). So the deletion
costs a frame **wherever in the frame it lands**, and the guard-band placement — which was
the entire point of the variant — buys nothing. **R4E is refuted, and it is strictly worse
than Task 20's S1 (R4D+R1) on every leg where the two differ**: on `n_p10` S1 delivers
**424 of 428** air frames against R4E's **377**, with the identical 37 events, the identical
ring trajectory and the identical `push_on_full = 0`. **Recommendation: S1 remains the 146
candidate; R4E must not be built.**

---

## 1. What R4E is, and the formula it rests on

The natural FULL-edge event is `Validate_Input_Push_Pop_block.v:129` `push_on_full_FIFO`: a
push arriving at occupancy 32 is silently discarded — **no RAM write, no `Push_Counter`
advance, and no change to the pop side at all**. One payload symbol vanishes at whatever
position in the frame the ring happened to be full, and the frame dies. R4E takes the same
deletion **deliberately**, scheduled so the vanished symbol would have been popped inside
the guard window. Five core files, R4B's set; `.push(strobe)` becomes
`.push(strobe & ~r4e_drop_en)`; the pop expression is R4B's line verbatim.

### 1.1 The drop-scheduling formula, with pointer anchors — and the brief's sketch corrected

Anchors: `FIFO_block.v:120-143` (Push_Counter), `:155-178` (Pop_Counter), `:180-192` (the
32×16 RAM, `wr_addr = Push_Counter_out1`, `rd_addr = Pop_Counter_out1`);
`Validate_Input_Push_Pop_block.v:103-113` (`Delay_out1`), `:129` (`push_on_full`), `:135/137`
(`valid_push`/`valid_pop`); `MATLAB_Function_block2.v` (the up/down counter).

1. **FIFO order.** Both pointers advance **only** on validated events and occupancy never
   exceeds 32, so no address aliases a live entry: **valid push index `p` is popped as
   valid pop index `p`.**
2. **The occupancy net is exact.** `Delay_out1 <= count`, and `count` is
   `countReg_temp`, the *combinational* next state including the current tick's
   `valid_push ^ valid_pop`. So **`O(t) = P(<t) − Q(<t)`**.
3. **Where a dropped push shows up.** Suppress the push at tick `t`: it would have been
   valid push index `P(<t)`, hence valid pop index `P(<t)`, and pops at ticks `≥ t` are
   indexed `Q(<t), Q(<t)+1, …`. The vanished symbol would have been emitted on the
   **`(O(t)+1)`-th validated pop at ticks ≥ t.**
4. **The landing slot.** With `T` the `Packet_Controller.endOut` tick and `m` the validated
   pops in `[t, T]`:

> ## `k = O(t) + 1 − m`     ⇔     in-window (`1 ≤ k ≤ 13`) ⇔ `O(t) − 12 ≤ m ≤ O(t)`

**Corollary, and it corrects the brief.** At pcEnd itself (`m = 0`) the symbol that will be
popped at slot `k` was pushed **`(O − k)` pushes back** — *not* `(O − 1 + k)` as the brief
sketched. With `O ≥ 24` that is **11–23 pushes in the past**: there is nothing left to drop,
so the decision **cannot** be taken at pcEnd and must be taken `m = O + 1 − k` validated
pops *before a pcEnd that has not happened yet* — 12–31 pops, ≈ 48–124 enb ticks. No
structural signal sits there (`startOut` is ~12,320 pops away), so the predictor is a
**measured** frame period:

```
r4e_pcnt   = validated pops since the last pcEnd        (FIFO_validPop, saturating)
r4e_period = validated pops between the last two pcEnds (latched at pcEnd)
k_hat      = O + 1 − r4e_period + r4e_pcnt
arm  <=>  r4e_pcnt + O ∈ [r4e_period + 6, r4e_period + 10]     i.e. k_hat ∈ [7, 11]
```

The band is **asymmetric on purpose**: `k_hat` rises with time, so the registered compare
(1 tick), the registered decision (1 more), the wait for a strobe (~1 pop) and a push in
the gap all push the realised `k` **up**, never down.

**The landing slot is measured, not predicted.** At the drop the RTL latches `r4e_pcnt` and
`r4e_occ`; at the next pcEnd it forms `m = r4e_pcnt − r4e_land_a` (read before the reload)
and records `k = r4e_land_occ + 1 − m`. `wrap_byte_sro4e.v` recomputes the same quantity
from **taps that share no net with the steering** — occupancy from `(fifoPush − fifoPop) mod
32` (*not* `occTrue`/`Delay_out1`, which is what `r4eOcc` carries), `m` from `fifoVPop`,
reference from `pcE`.

### 1.2 The RTL, in words

`Rate_Handle.v`, one `enb_1_2_0`-gated async-reset process, R4B's blocks (a)–(f) unchanged
after the prefix rename plus:

* **(g)** the validated-pop clock: `r4e_pcnt` (+1 per `FIFO_validPop`, reloaded at
  `r4e_pcend_d`, saturating at `14'h3FFF`), `r4e_period` latched there, and `r4e_per_ok`
  = period in `[64, 16382]` — a missed pcEnd saturates `pcnt`, which both fails `per_ok`
  and can never satisfy the arm band, so a lost deframer **fails toward baseline**.
* **(h)** resolve the pending drop's measured landing slot at the pcEnd it was aimed at;
  update `{land_last, land_min, land_max, land_out}`.
* **(i)** the drop: `r4e_do_drop = r4e_drop_en & strobe`, counters, and the latch of
  `pcnt`/`occ` for (h).
* **(j)** the registered decision:
  `r4e_drop_en <= r4e_locked & r4e_per_ok & r4e_occ_ge24 & ~r4e_drop_done & r4e_sched_lo & r4e_sched_hi`.

`Logical_Operator_out1` is **R4B's line character for character** (test 139 also bans
`r4e_do_extra` / `r4e_extra_en` / `r4e_extras` / a phase-2 term outright), and the only new
combinational term anywhere is `~r4e_drop_en` on the push — a flop output. Test 138 pins
that every R4B **code** line survives the rename verbatim.

### 1.3 The tenth read word, 0x238, and its stated deviation

`r4eWit` is 64 bits, R4D's shape. 0x234 keeps R4B's `{locked, skips[15:0], opens[14:0]}`;
0x238 is `{land_out[3:0], land_max[3:0], land_min[3:0], land_last[3:0], drops[15:0]}`.
**Deviation:** the brief asked for a landing-slot **histogram** in one word; a 13-bin
histogram does not fit beside a 16-bit counter, so the silicon form is the **order
statistic** — `land_out ≠ 0` is the falsifier, `min ≥ 1 ∧ max ≤ 13` the pass — and the full
histogram is produced in sim by the wrapper trace. Documented in `W1_REGMAP.md` §6 with the
deviation called out and the changed at-rest expectations (§6.3).

---

## 2. The two gated preconditions, both measured before the sweep

### 2.1 The pcEnd period in validated pops — measured for the first time

The whole schedule rests on it and it had never been measured. `wrap_byte_sro4e.v` writes
one line per pcEnd to `<p>_period.txt`. Post-lock, on the two legs that actually drop:

| leg | min | mode | max | spread | verdict (ceiling 6) |
|---|---|---|---|---|---|
| `n_p10` | 12332 | **12333** (378) | 12334 | **2** | **OK** |
| `n_m10` (smoke, 25 frames) | 12332 | **12333** (7) | 12333 | **1** | **OK** |
| `n_p000` | 12333 | 12333 (414) | 12334 | **1** | OK |
| `n_m10c` | 12332 | 12333 (314) | 12334 | **2** | OK |
| tiled | 12332 | 12333 (118) | 12334 | **2** | OK |
| `n_m10` (full) | 12332 | 12333 (334) | **24666** | 12334 | *see below* |
| `n_m40` | 12332 | 12332 (192) | **19396** | 7064 | *see below* |
| `lol` | 12332 | 12333 (377) | **23998** | 11666 | *see below* |

The three wide-spread rows are **one missed pcEnd each** (`n_m10` 24666 = exactly
2 × 12333, i.e. one deframed packet skipped; `lol` 23998 is the forced outage). The
precondition is about the *drop* legs, and on both of them the spread is ≤ 2. On the three
legs with an outlier, `r4e_per_ok`'s saturation/plausibility guard is what prevents a
mis-scheduled drop — and none of those legs drops at all, so the guard was never the
operative term. **The RTL's latched `r4e_period` equals the previous harness interval on
414/414, 415/415 and 154/154 of the clean legs.**

### 2.2 The smoke, on `n_m10` and not `n_p000` — passed

At 0 ppm the ring never reaches 24 after lock (§4), so a `p000` smoke would have exercised
**zero drops**. `n_m10` sits at `oMax = 31` from lock (frame 11) through frame 73, so a
25-frame smoke hits the 31 → 23 ratchet immediately. Result: 7 drops, frames 12–18,
occupancy 30 → 24 (`occTrue_end` 22), **every landing slot 7 (six) or 8 (one)**, RTL and
independent recount 7/7 identical, `k = occ + 1 − m` 7/7, three-way counts 7 = 7 = 7,
`pd_push_on_full = 0`. **The declared re-centring branch (any `k ≥ 13` ⇒ retarget to
`[5,9]` and re-smoke) was NOT taken** — recorded here because it was pre-registered before
any histogram was read.

---

## 3. The gate table, filled with raw numbers

Raw output `two_jup/comb/sro_sim/t21_score.txt`, **regenerated after the K13 fix below** so
that the committed raw output and this table agree (the first run keyed the pre-arm boundary
on skips alone via `t12b_prearm.py`'s `<pfx>_skipwin.txt`, which R4E does not write; that
compared post-drop frames as if they were pre-arm and printed a false "real failure" block.
`t21_score.sh` now regenerates the compatibility view from `<pfx>_win.txt` with the boundary
at the first steering action **of either kind**, and the `_skipwin.txt` files are committed
so K13 is reproducible). Baselines `b_p000`/`b_m10`/`b_m40`/`tb_m10`
(Task 7), `t_lol` (Task 6), `b_m10c`/`b_p10` (Task 12b) were **not** re-run; R4B's own
delivered streams are the identity references. `T7_NAIR=428` exported.

| # | leg | criterion | **measured** | |
|---|---|---|---|---|
| **K1** | `n_p000` | content identity with R4B; `r4e_drops = 0`; occ never ≥ 24 | `_deliv.txt` **and** `_seq.txt` **byte-identical** to `r4b_p000` (424/425 lines, `cmp` clean); **0 drops**; 8 skips at slot 1, frames 13–20 | **PASS** |
| **K2** | `n_p10` | LOSS ≤ 1 % on **both** denominators | **11.16 %** seq-keyed (seq 5..425, expect 421, OK 374, corrupt 0, **missing 47**) and **11.92 %** air-frames-fed (`t7_ok` **377 of 428**). Baseline 4.99 % / 403 of 428; R4B 6.65 % / 396 of 428 | **FAIL** |
| **K3** | `n_p10` | `push_on_full` = 0 after lock | **0** (baseline 21, R4B 28) | **PASS** |
| **K4** | `n_p10` | ~37 drops, one per ~8.1 frames, every landing slot in [1,13], plateau 22/23 | **37 drops**, air frames 132–424, spacing **8:32, 9:4, mean 8.11**; **landing slot 7 on all 37**, on both counters; occupancy at every drop **23**, `m = 17` on all 37; `occTrue_end` **23** | **PASS** |
| **K5** | all seven | `pdPof = 0`, `pdOcc` flat 12333 | **`pd_push_on_full = 0` and `pd_pop_on_empty = 0` on all seven legs; `pdOcc_end = 12333` on all seven** | **PASS** |
| **K6** | negatives vs R4B | byte-identical where the ring never reaches 24; else 31→23 then identical | `n_m40`, tiled, `n_m10c`, `lol`: **`_deliv.txt` and `_seq.txt` byte-identical to R4B** (`cmp` clean; 424/425, 164/165, 425/426, 414/415 lines), 0 drops. **`n_m10` FAILS the loss clause**: 7 drops ratchet 30 → 24 in frames 12–18 as predicted, but LOSS is **2.38 %** (411 of 421; `t7_ok` 414 of 428) against R4B's **0.48 %** (422 of 428) | **FAIL** (4 of 5 clauses pass; the `n_m10` loss clause fails) |
| **K7** | all | three-way witness agreement | trace lines by `kind` = `r3_skips`/`r3_extras` in `_res.txt` = kind-4/kind-5 in `_ep.txt` on **all seven legs** (8/0, 37/7, 210/0, 24/0, 60/0, 7/37, 17/0). The kind-priority caveat never bit: no coincidence occurred | **PASS** |
| **K8** | all | **FALSIFIER** | **FIRED.** On `n_p10`, **37 of 37 drops have a lost frame at a constant offset of 2 air frames**, and **0 of the 47 lost frames is more than ±1 from a drop**. On `n_m10`, the 7 drops at frames 12–18 cost seq **10–17** — eight frames R4B does not lose. K2 is also > 3 % with K3 and K4 passing, which is the gate's second trigger | **FALSIFIER FIRED** |
| K9 | all | wrapper provenance | `WRAP4E_FILE wrap_byte_sro4e.v t21` + `WRAP4E_DEFINE RXFIX_R4E` on **all seven** legs and the smoke; no other `wrap_byte_sro` file in the verilate log | **PASS** |
| K10 | all | no air frame carries both a skip and a drop | **0 frames** on every leg — `r4e_period` cannot be contaminated | **PASS** |
| K11 | injector | W1+R4E kit-shaped | test 149: `verify_zip` green for **both** variants on **both** zips; `RXFIX_W1` and `RXFIX_R4E` present, `r4eWit` assembled in the kit's `Rate_Handle`. Prefix hazard closed both ways (test 137) | **PASS** |
| K12 | injector | lint | **0 errors** on four trees; **0 warnings on any `r4e_` net**; warning counts **57 / 71 / 59 / 73** — identical to R4B's four logs | **PASS** |
| K13 | paired legs | pre-arm structural identity | byte-identical to the baseline **including `sidx`** before the first steering action of either kind: **p000 6/6, m10 6/6, m40 1/1, m10c 5/5, p10 6/6** | **PASS** |

**Ten of thirteen rows pass; K2, K6 and K8 fail.** The three failures are the same fact
seen three ways. K6 is reported as a FAIL and not softened to a partial: its own criterion
is "LOSS ≤ R4B's 0.48 %" on `n_m10` and the measurement is 2.38 %. Four of its five clauses
passing is stated in the cell, not in the verdict.

### 3.1 The two denominators, raw, on every leg

`t7_ok` of the **428** air frames fed, beside the seq-keyed span. Never two percentages.

| leg | baseline | R4B | **R4E** | S1 = R4D+R1 (Task 20) |
|---|---|---|---|---|
| `n_p000` | 423 | 423 | **423** | 423 |
| `n_m10` | 378 | **422** | **414** | 422 |
| `n_m40` | 93 | 405 | **405** | 405 |
| `n_m10c` | 304 | 422 | **422** | 422 |
| **`n_p10`** | **403** | 396 | **377** | **424** |

`n_m40`'s seq range is unscoreable by `score_t7.py` on every variant (`SEQ RANGE
IMPLAUSIBLE`, one corrupt header seq field widens the range to 15,729,147) — the same
artefact Task 12b §6.3 recorded. **`n_m40` was NOT rescored here.** The inference is stated
so it cannot be read as a measurement: R4E's `r4e_m40_deliv.txt` and `r4e_m40_seq.txt` are
`cmp`-clean against `r4b_m40`'s, and Task 12b's **0.74 %** came from a *bounded* rescore of
those same bytes against the 432 frames the TGEN emitted (`tx432.iq.frames.txt`) — identical
streams therefore give the identical bounded rescore, so **0.74 % carries over by
byte-identity, not by re-measurement**. The directly measured air-fed count is **405 of
428** on both. The tiled control scores **0.00 %** (159/159) and `lol` is byte-identical to R4B,
both matching R4B exactly.

---

## 4. Which legs could differ at all — the pre-registered structural prediction, confirmed

From the banked Task 12b `_frames.txt`, recomputed before the run:

| leg | lock frame | max `oMax` after lock | frames `oMax ≥ 24` | predicted | **measured** |
|---|---|---|---|---|---|
| `n_p000` | 13 | 10 | 0 | cannot differ | **0 drops, byte-identical** |
| `n_m40` | 19 | 10 | 0 | cannot differ | **0 drops, byte-identical** |
| tiled | 10 | 10 | 0 | cannot differ | **0 drops, byte-identical** |
| `n_m10c` | 13 | 10 | 0 | cannot differ | **0 drops, byte-identical** |
| `lol` | 10 | 10 | 0 | cannot differ | **0 drops, byte-identical** |
| `n_m10` | 11 | 31 | 63 | ~8 drops frames 11–19, 31→23; skips move 191 → **~133** and rise 30 → **~36** | **7 drops frames 12–18, 30→24; skips 191 → 134, 30 → 37** |
| `n_p10` | 13 | 32 | 300 | ~37 drops from frame ~129, one per 8.1 | **37 drops from frame 132, spacing 8.11** |

**Both quantitative predictions landed.** The `n_m10` skip-side shift (191 → 134 predicted
~133; 30 → 37 predicted ~36) is a prediction about the RTL text made from banked data and
confirmed to the frame. The steering does exactly what it was designed to do.

---

## 5. The landing-slot histogram — the claim the gate was built to test, and it holds

356 skips and 44 drops over seven legs. `land_rtl` is the RTL's own measurement;
`land_harness` is the wrapper's, from `(fifoPush − fifoPop) mod 32`, `fifoVPop` and `pcE` —
**no shared net with the steering**.

| leg | drops | `land_rtl` | `land_harness` | agree | `m` | occ at drop (Delay_out1 / pointers) | `land_out` |
|---|---|---|---|---|---|---|---|
| `r4e_p10` | **37** | **7:37** | **7:37** | **37/37** | 17:37 | 23:37 / 23:37 | **0** |
| `r4e_m10` | **7** | **7:6 8:1** | **7:6 8:1** | **7/7** | 18,19,20,20,22,23,24 | 24..30 / 24..30 | **0** |
| smoke `sk4e_m10` | 7 | 7:6 8:1 | 7:6 8:1 | 7/7 | 18..24 | 24..30 / 24..30 | 0 |
| other five | 0 | — | — | — | — | — | 0 |

**`k = occ + 1 − m` holds on 44 of 44 drops on the harness numbers** — Fact 4 of the
pre-registration verified against the silicon-independent recount. The two occupancy
sources disagree on **0 of 44**. Skips: **356/356 at slot 1** (one at slot 3 on `m10c`),
RTL and independent recount agreeing 356/356, `dt_enb = 4·slot − 1` throughout — R4B's
result reproduced exactly.

**So the mechanism is not in question. The drop is placed where it was aimed, to the slot,
and measured twice.**

---

## 6. K8: why it fired, and the law it exposes

### 6.1 The alignment is total

| leg | events | lost frames | aligned | unattributed |
|---|---|---|---|---|
| `b_p10` (baseline) | 21 `push_on_full`, frames 259–421 | **21** | 19 at offset 2, 2 at ±1 | **0** |
| `r4b_p10` | 28 `push_on_full`, frames 202–421 | **28** | 25 at offset 2 | **0** |
| **`r4e_p10`** | **37 drops**, frames 132–424 | **47** | **37/37 at offset exactly 2** | **0** |
| **`r4e_m10`** | **7 drops**, frames 12–18 | **8** (seq 10–17) | 7/7 at offset 2 | 0 |

On `n_p10`, 27 drops cost one frame and 10 cost two (seq `F−2` and `F−1`); every one of the
47 lost frames is within ±1 of a drop. The 10 double-cost drops all follow an 8-frame gap
and their `tref` values are interleaved with the single-cost ones, so no separator is
offered — the fact is reported, not explained.

### 6.2 The law: loss counts DELETIONS, not their position

The comb rate is the same on all three variants — one ring deletion per **8.11** air frames
at +10 ppm (`12,333 × 10⁻⁵ = 0.1233` entries/frame). What each variant changes is **when the
comb starts**, and the frame count follows mechanically:

| | acts at occupancy | first event | events predicted `(428 − f₀)/8.11` | events measured | lost frames |
|---|---|---|---|---|---|
| `b_p10` | 32 (FULL) | 259 | 20.8 | **21** | **21** |
| `r4b_p10` | 32, ring parked +7 by acquisition skips | 202 | 27.9 | **28** | **28** |
| `r4e_p10` | **24** (+ the same +7 parking) | **132** | 36.5 | **37** | **47** |

R4E's 127-frame advance decomposes as **65 frames** for acting at 24 instead of 32
(`8 / 0.1233`) plus R4B's **57 frames** of acquisition parking (Task 12b §6.2, measured
exactly there) = 122 predicted against 127 measured. **This is Task 12b §6.1's law with the
sign unchanged: where the steering parks the ring sets when the comb starts, not how fast it
runs — and R4E moved the trigger 8 entries lower, so it started the comb earlier and paid
for it.**

**The guard band bought nothing.** A deletion at slot 7 of the 13-slot window costs exactly
what a deletion at a random payload position costs: one frame, sometimes two.

### 6.3 Why — and it is *not* the Task 14 mechanism

`pdPof = 0` and `pd_pop_on_empty = 0` on **all seven legs**, `pdOcc_end = 12333`
everywhere. The Preamble_Detector realignment FIFO — the stage that destroyed R4D — is
**untouched**, exactly as §0.1 of the pre-registration argued it would be. So Task 14 §3's
stated reason ("(b) faces the same wall from the other side") is **still wrong**, and R4E
fails for a *different* reason.

**What the evidence establishes, and what it does not.** The measurements below prove a
*negative* — the deletion is invisible to every valid counter and every epoch register in
the receive chain, so no stage can compensate for it and nothing flags it, and the frame
carrying the shifted symbols decodes wrong. They do **not** locate the decode failure at a
named stage the way Task 14 did: Task 14 earned "the asymmetry has a location" because
`pdPof` *fired* in the same air frame as the deaths, and there is no equivalent firing
witness here. The data-to-epoch phase slip below is **the reading the evidence supports**,
not a located mechanism:

* a dropped push removes a symbol from the **data** while leaving the **valid count**
  unchanged (that is the whole point of the variant);
* every downstream epoch counter is **valid-counted** — `Peak_Search.timing_Reference`
  (`tref`), `Timing_Adjust.taRef` — so none of them sees the deletion;
* and the measurement shows the slip directly: on `r4e_p10` the `tref` at the drop, taken
  at a **constant** pcEnd-relative position (`slot_harness = 12317` on **all 37** drops),
  walks **12160 → 12124, exactly −1 per drop, 36 of 36 deltas equal to −1**. The deframer's
  frame boundary moves one symbol per drop relative to the valid-counted epoch, and it
  never moves back.

R4B's skip does **not** do this: it removes a valid *and* a symbol together, so data and
epoch stay locked. On the **same leg**, R4E's own 7 EMPTY-side skips sit at a **constant**
`tref` of 12177 (one at 12178) — identical to R4B's 7 skips on `r4b_p10`, which are also
12177/12178 — while the 37 drops ramp. Same run, same window, same file: the skip holds the
phase and the drop walks it. **That is
the asymmetry, and it is the mirror image of Task 14's: a `+1` valid dies in the PD FIFO; a
`−1` symbol with no `−1` valid dies in the epoch phase.** Both directions of "perturb the
ring by one" cost a frame; only R4B's simultaneous `−1`/`−1` is free.

### 6.4 The per-stage dump the falsifier demands

K8 requires a `sim_stagewin` dump around one drop. Built as `sim_stagewin4e.cpp` — a
**copy** of Task 11's driver with a third arm mode `drop` keying on `r3Extras`; the two
pre-existing modes are untouched, so a `skip`/`hole` run of this binary is the Task 11
driver. Unit `t21_sw`, `n_p10`, 136 air frames, W = 96 beats, two events with a matched
same-phase reference one air frame earlier.

**The dump is decisive, and it says the drop is invisible to every valid counter in the
chain.** `r4e_p10_stagewin.txt`, 193 enb beats around the first drop (air frame 132) with
the matched same-phase window one air frame (49,332 beats) earlier as the no-event
reference. Sums over the two 193-beat windows:

| quantity | **event window** | matched reference | |
|---|---|---|---|
| validated ring **pushes** | **47** | **49** | **the deletion** (−1 from the drop, −1 window-edge strobe) |
| validated ring **pops** | **48** | **48** | identical |
| `Rate_Handle.validOut` | **48** | **48** | identical |
| `Coarse_Frequency_Compensator.validOut` | **48** | **48** | identical |
| `Preamble_Detector.validOut` | **48** | **48** | identical |
| `Correlator.validOut` | **48** | **48** | identical |
| `Packet_Controller.validOut` | **41** | **41** | identical |
| `push_on_full` / `pop_on_empty` | **0 / 0** | 0 / 0 | neither edge is touched |
| `psTref` over the window | 12159 → 12164 | 12159 → 12164 | **identical** |
| `taRef` over the window | 12170 → 12175 | 12170 → 12175 | **identical** |
| `psToff` | 12180 | 12180 | constant |

Beat by beat, the strobe pattern in the event window has a **hole at rel −1** — the beat the
registered witness `r4e_drops` increments off — where the reference and the surrounding
mod-4 phase both have a validated push; the ring occupancy then runs one entry lower
(22/23 against 23/24) for the rest of the window. **Nothing else differs.** Every stage from
the ring's own pop to `Packet_Controller.validOut` emits the *same number of valids at the
same beats*, and both valid-counted epoch registers — Peak_Search's `psTref` and
Timing_Adjust's `taRef` — advance identically in the two windows.

**That is the whole finding in one table.** The drop is a pure data deletion: it removes a
symbol and leaves every valid count, every FIFO edge and every epoch counter in the receive
chain bit-identical to a frame in which nothing happened. So no stage can compensate for it,
nothing flags it, and the frame whose symbols were shifted by it decodes wrong. The K8
dump confirms the mechanism named in §6.3 rather than the one that killed R4D.

---

## 7. R4E against Task 20's S1 (R4D+R1) — stated plainly

S1 is the current 146 candidate and its build is under way. **The S1 figures below are
Task 20's own leg outputs read from disk (`r4dr1_*_res.txt`); nothing here re-scored them,
and no S1 leg was re-run.** The two variants act on the **same** edge with the **same**
trigger and produce the **same** ring behaviour:

| `n_p10` | R4E (drop a push) | S1 = R4D+R1 (extra pop + valid-indexed PD pop) |
|---|---|---|
| events after lock | **37** | **37** |
| `r3_skips` | 7 | 7 |
| `rh_push_on_full` | **0** | **0** |
| `occTrue_end` | **23** | **23** |
| `pd_push_on_full` | 0 | 0 |
| **`t7_ok` of 428 fed** | **377** | **424** |
| **`t7_nomagic`** | **50** | **3** |

**Identical at the ring, 47 frames apart at the output.** R4E **loses** to S1 on `n_p10` by
a wide margin, and **loses on `n_m10` as well** (414 vs 422 of 428). On the five legs where
neither steers the FULL side (`p000`, `m40`, tiled, `m10c`, `lol`) the two are
**byte-identical to each other and to R4B**. There is no leg on which R4E is better than S1,
and none on which it is even equal except the five where it does nothing.

**The reason is R1.** S1 pairs the FULL-side perturbation with `RXFIX_R1`, which makes the
PD realignment FIFO's pop **valid-indexed** rather than tick-indexed, so the `+1` is
absorbed *and* the data-to-epoch phase is maintained by construction. R4E has no such
partner: it avoids the PD FIFO deletion by not adding a valid at all, but nothing in the
design maintains the data-to-epoch phase across a deleted symbol.

**If the FULL side is to be steered from `Rate_Handle`, the epoch bookkeeping has to be
fixed alongside it.** That is what S1 does and what R4E does not. **A hypothetical R4E+R1
is not cut and not gated here**; it is a coherent next candidate (drop the push, and let the
valid-indexed pop re-align the delayed chain), but it is a new variant with a new gate, and
S1 already passes.

---

## 8. Tests, lint and provenance

* **`python3 -m unittest test_rxfix_inject` → 151 tests, OK** — 135 pre-existing (none
  modified) + **16 new `TestR4E`**, tests 136–151. They pin: R4E is a clone of R4B on the
  skip side (138, code lines only — comments are deliberately rewritten); the FULL side
  drops a **push** and adds no pop term (139); the schedule is a measured period in
  validated pops with the asymmetric band (140); the landing slot is resolved at the pcEnd
  (141); the FULL-side decision is registered (142); one drop per pcEnd (143); mutual
  exclusion with R3/R3S/R4/**R4B**/R4D in both directions (144); all three lineages (145);
  the 64-bit witness at every level (146, 147); the two read words leave W1 byte-identical
  (148); **W1+R4E on a kit-shaped tree with `verify_zip` green on both zips (149)**; no
  top-level port and no lost assign (150); reverse order fails loudly (151); and the
  **`RXFIX_R4`/`RXFIX_R4B` prefix hazard closed in both directions (137)** — the hazard that
  has already bitten twice.
* **Lint**, logs banked in `two_jup/comb/sro_sim/`:

| log | tree | `%Error` | `%Warning` | warnings on any `r4e_` net |
|---|---|---|---|---|
| `r4e_lint_s1_rtl.log` | R4E alone, s1_rtl | **0** | 57 | **0** |
| `r4e_lint_txfixF3.log` | R4E alone, txfixF3 | **0** | 71 | **0** |
| `r4e_lint_w1r4e_s1_rtl.log` | **W1+R4E**, s1_rtl | **0** | 59 | **0** |
| `r4e_lint_w1r4e_txfixF3.log` | **W1+R4E**, txfixF3 | **0** | 73 | **0** |

Identical warning counts to R4B's four logs, which is the expected result for a variant
whose only new nets are in one module.

* **Harness provenance.** `wrap_byte_sro4e.v` is a **sixth** file declaring
  `module wrap_byte_sro`; it prints `WRAP4E_FILE`/`WRAP4E_DEFINE` at time 0 and
  `build_sro_rxfix4e.sh` greps the verilate log for the other **five** and refuses a tree
  carrying any other steering marker. `sim_sro.cpp` links **unmodified**, which is what makes
  K1 a test of the RTL and not of a re-typed driver.

---

## 9. What this gate establishes, and what it does not

**Establishes:**

1. **The push-drop steering is exact.** 44 drops, every one at the slot the formula aimed
   at, measured twice from disjoint nets, with `k = occ + 1 − m` verified 44/44.
2. **The FULL edge is fully controllable from `Rate_Handle` by dropping a push**:
   `push_on_full` 21 → 0, ring parked at 22/23, no PD-FIFO involvement whatsoever.
3. **The guard-band hypothesis is false for a deleted symbol.** A deletion costs a frame
   wherever it lands; loss counts deletions, and moving the trigger from occupancy 32 to 24
   simply starts the comb 127 frames earlier and costs 16 more of them.
4. **The asymmetry has a second half, and the PD FIFO is provably innocent of it.** Task 14
   *located* the `+1`-valid failure in the PD realignment FIFO, with `pdPof` firing in the
   same air frame as the deaths. This gate does not claim an equivalent location for the
   `−1`-symbol failure: what it establishes is that the deletion is **invisible to every
   valid counter and every epoch register in the chain** (the K8 dump, §6.4, event vs
   matched reference identical on all seven of them), and that `pdPof = 0` on all seven
   legs rules out Task 14's mechanism. The valid-counted-epoch reading — `tref` walking −1
   per drop at a constant pcEnd-relative position, against a constant `tref` for R4B's
   skips on the same leg — is consistent with every measurement and is reported as the
   reading the evidence supports, not as a located stage.
5. **The pcEnd period in validated pops is 12,333 ± 1**, measured for the first time.

**Does not establish:** any PER claim, any timing or resource claim, anything about
silicon. R4E has never been synthesised and **must not be built**.

---

## 10. Recommendation

* **Do not build R4E.** It is worse than doing nothing on `n_p10` (11.16 % vs 4.99 %) and
  worse than R4B on `n_m10` (2.38 % vs 0.48 %).
* **S1 (R4D+R1) remains the 146 candidate**, unaffected by anything here; this gate
  independently reproduces its ring behaviour and confirms it is the only variant that
  converts FULL-edge control into delivered frames.
* The R4E tree, wrapper, build, scorers and witnesses stay banked. If the controller ever
  wants the push-side variant, the experiment to run is **R4E + R1**, pre-registered against
  the prediction that R1's valid-indexed PD pop re-aligns the delayed chain across a deleted
  symbol; that is a new variant and a new gate, and it is not needed while S1 passes.

## 11. Rails

Sim only; no board contact; no Vivado; no subagents. R4B, R4D, R4, R3S, Task 7's
`sim_sro.cpp`, Task 11's `sim_stagewin.cpp` and every wrapper before `wrap_byte_sro4e.v`
untouched. Task 20's `r4dr1_*` outputs were **read, never written**. Commits: `43cfaf1`
(pre-registration, before any code), `10b27b7` (variant + harness + build), `65904ed`
(tests, scorers, launcher, `W1_REGMAP.md` §6), `61670fb` (ledger), `7847376` (lint logs,
smoke, legs launched). Heartbeat unit `t21hb`.
