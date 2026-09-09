# Task 12 — RXFIX_R4: pre-filled ring + lock-armed skip-only steering  [sim, desk only]

Brief `two_jup/sdd_archive/2026-09-04-rxfix/task-12-brief.md` · pre-registration
`two_jup/comb/RXFIX_R4_SIM_GATE.md` (committed **before** any leg was started, 7269cd8)
· ledger `progress.md` (`Task 12:` lines) · branch `per-under-1pct-2026-07`.
**No board contact, no Vivado, no subagents.** Every number below is **[sim]**.

## Verdict in one paragraph

**R4 passes the row R3S failed, and fails two rows R3S never had to face.** At −10 ppm
on the certified non-repeating stimulus, loss falls **10.93 % → 0.48 %** and the *only*
two frames lost are **seq 133 and 134** — Task 7's already-recorded, non-hole-aligned
pair, lost in the baseline too. **G4 PASSES.** The tiled control goes
**22.01 % → 0.00 %**, a clean sweep (**G10 PASSES**; R3S was 1.89 %). Both improvements
come from the same place: R3S's entire residual was the frames straddling the one
EMPTY-edge hole that had to happen before it could arm, and R4 has no arming hole — at
−10 ppm `rh_pop_on_empty` in the scored window is **0**, the ring is held flat at
occupancy 8/9 from air frame 200 to the end, and **not one of the 29 steered skips
costs a frame** (0.00 lost frames per skip against the baseline's 2.00 per hole).
**But the pre-fill does not do what the brief said it would**, and the two rows that
tested the pre-fill directly both fail: at 0 ppm R4 takes **8 skips where 0 was
pre-registered (G2 FAIL)** and settles at occupancy **9/10, not [14, 18] (G3 FAIL)**,
because the acquisition deficit is larger than anything a 32-deep ring can be
pre-filled with. **G7 also fails**: −40 ppm is 4.48 %, not ≤ 1 %, for a cause that is
identified and is *not* the steering. **7 of 11 gates pass; G2, G3, G7 and G9 fail and
are reported as failures, not reinterpreted.**

## 1. The RTL change, in words, with line anchors

Seven internal modules, **no new TxRxComposite or IP port**; injector variant `R4` in
`two_jup/skidfix/rxfix_inject.py`, marker `RXFIX_R4`, structural (paren-balanced)
insertion so both netlist lineages take it. Anchors are in the generated tree
`jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R4/`.

| file | change | anchor |
|---|---|---|
| `sample_discard_controller.v` | `output activeOut` = the discard-window state, read-only | `:38` port, `:58` decl, `:221` `assign activeOut = active;` |
| `Packet_Controller.v` | `output guardOut = ~sdc_active_r4` | `:36` port, `:53` decl, `:168` pin, `:171` assign |
| `Frequency_and_Time_Synchronizer.v` | wire the guard back into `Symbol_Synchronizer`; **no port added** | `:111` wire, `:125` `.guardIn(...)`, `:198` `.guardOut(...)` |
| `Symbol_Synchronizer.v` | `input guardIn`, passed to `Rate_Handle` | `:35` port, `:47` decl, `:461` pin |
| `FIFO_block.v` | `output [5:0] occOut` | `:36` port, `:52` decl, `:114` pin |
| `Validate_Input_Push_Pop_block.v` | `output [5:0] occOut = Delay_out1` | `:33` port, `:49` decl, `:147` assign |
| `Rate_Handle.v` | **the pre-fill and the steering** | `:34` `guardIn` port, `:127-170` the block, `:184` `.occOut(r4_occ)` |

**The pre-fill** (`Rate_Handle.v:139` and `:153-155`). One term added to the pop
expression, and one sticky flop:

```verilog
  assign Logical_Operator_out1 = r4_pop_nom & r4_prefilled & ( ~r4_do_skip);  // :139
...
          if (r4_occ >= 6'b010000) begin                                      // :153
            r4_prefilled <= 1'b1;                                             // :154
          end
```

Until `r4_prefilled` is set, **every pop is suppressed** and the ring only fills.
Measured on all five legs: `r4_prefilled` sets at **input sample 79**, inside air frame
0, and the ring reaches `oMax = 17` there. It is a one-shot: nothing clears it but
reset.

**The steering** (`Rate_Handle.v:127-139`):

```verilog
  assign r4_pop_nom = validIn & Compare_To_Constant_out1;                     // :127
  assign r4_locked  = r4_frames == 4'b1000;                                   // :134
  assign r4_do_skip = r4_prefilled & r4_locked & guardIn & (r4_occ <= 6'b001000) &
              ( ~r4_skip_done) & r4_pop_nom;                                  // :136-137
```

`r4_locked` is R3S's four-flop count of `guardIn` **falling** edges (eight deframer
frames): before the deframer frames its first packet `sample_discard_controller.active`
is 0 for ever, so `guardIn = ~active` is constant 1 and never falls, and every falling
edge is one deframer frame start. **The lock term earned its place**: pre-fill
completes in air frame 0 but lock lands at air frame 13, and `guardIn` is stuck at 1 in
that gap, so without it a stray skip would latch `r4_skip_done` — which clears only on
`~guardIn` (`:161-162`) — and disable the steering for the whole run. Measured: the
first skip on every leg is at or after the lock frame, never before.

**The identity claim is weaker than R3S's, deliberately.** R3S ANDed its skip with
`r3s_armed`, so before arming its pop expression was *literally* the baseline line and
the s = 0 identity followed from the text. R4 gates the pop on `r4_prefilled`, so R4's
pop expression is **never** the baseline expression. The 0 ppm row is measured content
identity plus a latency offset, and a test (`test_79`) asserts the pop line still
mentions `r4_prefilled` so nobody re-derives the stronger claim by accident.

## 2. The pre-registered gate table, filled with raw numbers

Binary `obj_byte_sro_rxfix4/Vwrap_byte_sro` = the R4 tree + **Task 7's `sim_sro.cpp`,
unmodified**. All five legs used the same `nsamp` as the banked baselines
(21,114,096 / 8,139,780), verified before launch. Baselines were **not re-run**.

| # | leg | quantity | PASS criterion | **measured** | |
|---|---|---|---|---|---|
| G1 | `r4_p000` | delivered content vs `b_p000` | every frame's nwords/FNV/user equal | **423/423 common seq equal, identical seq sets**; `packets`, `biterr`, `capout=a037d28a`, `nrxw` all identical | **PASS** |
| G2 | `r4_p000` | `r4_skips` | **exactly 0** | **8** (air frames 13–20) | **FAIL** |
| G3 | `r4_p000` | occupancy after acquisition | **[14, 18]** | **9/10** flat, frames 21→428 | **FAIL** |
| G4 | `r4_m10` | LOSS (seq denominator) + only seq 133/134 | ≤ 0.5 %, those two only | **0.48 %** (2 of 421); lost seq = **133, 134** exactly | **PASS** |
| G5 | `r4_m10` | `r4_skips`, all ≤ 60 slots from the epoch boundary | 15–35 | **29**, **all 29 at `tref` = 21** | **PASS** |
| G6 | `r4_m10` | `rh_pop_on_empty` in the scored window | **= 0** | **0** (23 total, all in air frame 0) | **PASS** |
| G7 | `r4_m40` | LOSS | ≤ 1 % | **4.71 %** (405 byte-exact of **425 delivered**); 4.48 % on Task 11's 424-frame denominator; baseline **78.07 %** | **FAIL** |
| G8 | `r4_m40` | `r4_skips` | 150–260 | **210** | **PASS** |
| G9 | `r4_m40` | `rh_pop_on_empty` in the scored window | **= 0** | **7** (air frames 6,8,10,12,14,16,18) | **FAIL** |
| G10 | `r4_tm10` | LOSS (`score_sro2.py`, Task 6 definition) | **= 0.00 %** | **0.00 %** (159 of 159 OK; baseline **22.01 %**) | **PASS** |
| G11 | all five | wrapper provenance | both lines present | `WRAP4_FILE wrap_byte_sro4.v t12a` + `WRAP4_DEFINE RXFIX_R4` on **all five** | **PASS** |

**G4 passes with no headroom, and that is worth saying out loud.** The row admits at
most **2 lost frames of 421** (a third would be 0.71 % and a fail), and both losses are
Task 7's inherited seq 133/134 pair. The row is passed exactly as written — it is not
passed comfortably.

Loss against the two predecessors, like for like:

| leg | baseline | R3S (Task 11) | **R4** |
|---|---|---|---|
| −10 ppm non-repeating | 10.93 % | 0.95 % | **0.48 %** |
| −40 ppm non-repeating | 78.07 % | 4.48 % | **4.71 %** (4.48 % on Task 11's denominator) |
| tiled control −10 ppm | 22.01 % | 1.89 % | **0.00 %** |
| 0 ppm | 0.00 % | 0.00 % | **0.00 %** |

**The −40 ppm denominator, stated before it is used.** The pre-registration scores this
leg by "honest delivered/byte-exact count", and the leg **delivered 425** packets, so
the figure is **405 / 425 = 4.71 %**. Task 11 quoted `s_m40` as 4.48 % against a
424-frame denominator, and R4 gives **4.48 % on that same denominator** — so the two
match only when the denominator is chosen to make them match. `r4_m40` and `s_m40` land
on the same *count* (405 byte-exact, `t7_bad = 2`, `t7_nomagic = 17`) while delivering
**different streams** (`md5 f877aeb6…` vs `09e3c5ed…`). The honest statement is that R4
is **no better than R3S at −40 ppm to within the denominator convention**, not that the
two are measurably equal. G7 fails on either denominator.

### The measured pre-fill latency, and why it is not the constant I pre-registered

Per-seq `sidx` delta, `r4_p000 − b_p000`, over the 423 common frames:

```
  0:10   4:1   8:1   12:1   16:1   20:1   24:1   28:1   32:406
```

Read on the seq axis: **delta 0 for seq 2–9** (before the steering starts), a **ramp of
exactly 4 input samples — one symbol — per frame across seq 10–16** (the eight steering
events at air frames 13–20), then **a flat +32 input samples = 8 symbols for seq
17–422**, i.e. **406 of the 406 frames delivered while the stimulus was still flowing**.
The last two frames (seq 423, 424) read 0 because `sim_sro.cpp`'s `sidx` freezes at
`nsamp` in *both* runs — Task 11's truncation artifact, appearing at the tail of a
full-length run too.

So **the constant is +32 samples (8 symbols), not the +64 (16 symbols) pre-registered**,
and the reason is §3: the 8 symbols of standing occupancy are built by the eight
steering skips, **not** by the pre-fill, which acquisition had already consumed.
`delta = 4 × (occ_R4 − occ_baseline)` holds frame by frame across the whole ramp.

## 3. Why G2 and G3 fail: the pre-fill cannot survive acquisition

Measured `r4_p000` occupancy, air frame by air frame, against `b_p000`:

| air frame | 0 | 1–12 | 13 → 20 | 21 → 428 |
|---|---|---|---|---|
| `b_p000` oMin/oMax | 0/6, **pe = 34** | 1/2 | 1/2 | 1/2 |
| `r4_p000` oMin/oMax | 0/**17**, **pe = 23** | 1/2 | 1/2 → 9/10 | **9/10, pe = 0** |

The pre-fill *works* — the ring reaches 17 at sample 79. Then the acquisition transient
drains it completely and still takes 23 pop-into-empty events, so by air frame 1 the
ring is back at 1/2 and frames 1–12 track the baseline **exactly**. **The 0 ppm
acquisition deficit is ≈ 34 ring entries** — that is what the baseline's 34
`pop_on_empty` events are — which is larger than the 16 pre-filled *and larger than the
32-deep ring*. **No pre-fill depth could have survived it.** The brief's sentence "the
steady-state occupancy is ~16 regardless of the acquisition transient" is false on the
0 ppm leg, on the −10 ppm leg (§3 of the pre-registration already recorded `b_m10` air
frame 2 going 1 → 31 with `push_on_full = 17`) and on the −40 ppm leg. It holds on
**one** of the four: the tiled control, whose acquisition costs nothing
(`push_on_full = 0`, `pop_on_empty = 0` for the entire run), where the ring runs
**16 → 8 and never touches either edge**.

What actually sets the operating point is the **steering**. Lock lands at air frame 13;
the `occ ≤ 8` predicate then fires once per guard window for frames 13–20, ratcheting
occupancy 1 → 9; at 9 the predicate goes false and the ring sits flat at 9/10 with
`pop_on_empty = 0` for the remaining 407 frames. **R4 does lift the ring off the EMPTY
edge at 0 ppm — by steering, not by pre-filling, and at the price of 8 skips that the
pre-registration said would be 0.** Those 8 skips cost **nothing** in delivered content
(G1 is exact) and all 8 land at `tref` 12322/12323, within 11 slots of the epoch
boundary.

This is the finding that matters downstream, and it is why **Task 12b has already
dropped the pre-fill** on the strength of the smoke diagnostics: the pre-fill buys 8
symbols of latency and one row of the gate table, and the steering would have reached
the same operating point without it.

### G7 and G9: what is left at −40 ppm

`r4_m40` loses 19 of 424. The cause is identified and it is **not** the steering:
**seven EMPTY-edge holes at air frames 6, 8, 10, 12, 14, 16 and 18 — every one of them
before the first steered skip at frame 19.** At −40 ppm the ring drifts 0.493 entries
per frame, so with the pre-fill consumed by acquisition the ring is at the EMPTY edge
from frame 3, while `r4_locked` cannot be true until eight deframer frames have passed.
The steering then takes over completely: 210 skips from frame 19 onward and **not one
further hole in the remaining 409 frames**. R3S had the identical structure and the
identical residual (its seven holes at frames 6–18, all before *its* arming at 18), so
**R4 has not improved the −40 ppm leg** — 4.71 % against R3S's 4.48 %, and those two
numbers are the same byte-exact count under two different denominators, not a measured
equality. The lock latency,
not the arming rule, is the binding constraint there. Stated plainly: **the gate is
failed as written and reported failed.**

## 4. Skip / hole / loss alignment — the measurement that carries the verdict

`t11_align.py` (Task 11's, unmodified), −10 ppm:

| | `b_m10` baseline | **`r4_m10`** |
|---|---|---|
| holes in the scored window | **21** at frames 259, 267, …, 421 | **0** |
| holes in acquisition | 34 | 23 |
| skips | 0 | **29** at frames 195, 203, …, 422 (mean spacing 8.11) |
| lost frames | 46 | **2** (seq 133, 134) |
| losses within ±1 of a **hole** | 42 / 46 (91.3 %), offset −3 | — (no holes) |
| **losses within ±1 of a SKIP** | — | **0 of 29 skips** |
| lost frames per event | **2.00 per hole** | **0.00 per skip** |

**The falsifier did not fire, and it fired less than it did for R3S.** R3S had one skip
with a loss beside it — the skip immediately after its un-pre-empted arming hole. R4
has no arming hole and therefore **no skip anywhere in the run has a loss within ±1**.

`tref` at each event (`Peak_Search.timing_Reference`, mod 12,333) — the direct evidence
that every steered slot lands in the inter-frame guard:

* `b_m10` holes: **5167, 6560, 7820, 9350, 10527, 12030, 1020, 2224, 3585, …, 7186** —
  walking straight through the 12,320-symbol payload window.
* `r4_m10` skips: **21, all 29 of them.**
* `r4_m40` skips: **12296 (194 of 210), 12295 (15), 7026 (1)** — the same window on the
  other side of the wrap.
* `r4_tm10` skips: **28, all 13.** `r4_p000` skips: **12322 (7), 12323 (1).**

Per-leg operating point after acquisition, measured:

| leg | ring trajectory | edges touched in the scored window |
|---|---|---|
| `r4_p000` | 1/2 → **9/10**, flat from frame 21 | EMPTY never, FULL never |
| `r4_m10` | 31/32 (acq burst) → drains to **8/9** by frame 200, flat after | EMPTY never, FULL never |
| `r4_m40` | 0/1 → **8/9** from frame 19, flat after | EMPTY 7× (frames 6–18, pre-steering), FULL never |
| `r4_tm10` | **16 → 8**, envelope 8..16 | **EMPTY never, FULL never** (`score_sro2.py`) |

## 5. The +10 ppm leg — the FULL-edge problem R4 does not address

Report only, not a pass/fail condition. **The Task 12b baseline `b_p10` is NOT
available**: `t12b_bp10.service` was still running when this leg was scored and no
`b_p10_res.txt` exists, so every number below is R4-only and is *not* a comparison.

`r4_p10`: LOSS **6.41 %** (27 of 421), `rh_push_on_full = 27`, `occTrue_end = 32`.
The ring climbs 0 → 32 and reaches the FULL edge at **air frame 210**, after which one
push is deleted every ~8 frames (frames 210, 218, 226, 235, 243, …).

**The losses are the deletions.** Aligning the 27 lost seq to the 27 `push_on_full`
frames: best constant offset **−2**, **27/27 losses within ±1 (100 %)**, 24 of 27
deletion events have a loss beside them, **1.12 lost frames per deletion**. (The brief
expected ~2; measured 1.12.) A `push_on_full` **deletes a symbol** — unlike a
`pop_on_empty`, which only skips a slot — so this is a different failure mode from the
comb R4 fixes, and R4 has nothing on the FULL side by design.

**The skip-only steering is mildly counter-productive here, and that should be said.**
R4 took **6 skips at air frames 13–18**, while the ring was still below 8 on its way up.
Each skip adds an entry to a ring that is already filling, so they bring the FULL edge
**~49 frames closer** (6 entries ÷ 0.123 entries/frame). Small, but the sign is wrong,
and it is an argument for gating the skip on a *falling* occupancy trend if positive SRO
is ever in scope.

### The 167 `pop_on_empty` on `r4_p10`, explained

They are **entirely an acquisition artifact and have nothing to do with positive SRO**:
23 in air frame 0, **48 in frame 1, 96 in frame 2, and zero from frame 3 onward**. The
first delivered seq is 5, so **not one of them is in the scored window**. During
acquisition the symbol-timing loop has not pulled in and the interpolator strobe rate is
far from nominal; on this stimulus it under-produces for two frames, so the rigid mod-4
pop drains the ring and pops into it empty. Every leg shows the same 23-event signature
in frame 0 (it is the pre-fill/drain), and `r4_p10` simply has a longer transient.
`r4_locked` is not true until frame 13, so no steering rule could have pre-empted them.
The positive-SRO signature is **not** these 167 events — it is the 27 `push_on_full`
deletions after frame 210.

## 6. Rails, tests and provenance

* Task 7's `wrap_byte_sro.v`, `sim_sro.cpp`, `build_sro.sh` and Task 11's
  `wrap_byte_sro3s.v` were **not modified**, and no banked baseline or `s_*` result was
  re-run. The Task 12 harness is a **new file**, `wrap_byte_sro4.v`, keeping the module
  name so `sim_sro.cpp` links unmodified. **Three** files now declare
  `module wrap_byte_sro`, so it prints `WRAP4_FILE`/`WRAP4_DEFINE` at time 0 and
  `build_sro_rxfix4.sh` greps the verilate log for **both** of the other two (G11).
* Injector tests **96 green** (74 pre-existing + **22 new `TestR4`**). Mutual exclusion
  is now **symmetric and per-file**: R4 refuses R3/R3S and R3/R3S refuse R4 on all seven
  files, both directions asserted. Before Task 12 only `Rate_Handle` failed loudly in
  that direction and the other six would have half-applied first.
* **W1 + R4 combined application, the Task 13 deliverable, is proven** (`test_94`,
  `test_95`, `test_96`): both orders, both lineages, all 8 W1 + 7 R4 markers present;
  the two orders differ only in how the inserted lines interleave (**identical sorted
  line multisets on all five shared files**); and `verilator --lint-only` on the
  **combined** tree is error-free on both lineages (64 / 78 warnings, none on an
  `r4_`/`w1` net). Five files are in both sets — `Validate_Input_Push_Pop_block`,
  `FIFO_block`, `Rate_Handle`, `Symbol_Synchronizer`,
  `Frequency_and_Time_Synchronizer` — and W1 never touches the pop expression R4
  redefines (`test_96`).
* `verilator --lint-only` on R4 alone **error-free on both lineages**, logs banked:
  `two_jup/comb/sro_sim/r4_lint_s1_rtl.log` (0 `%Error`, 63 warnings),
  `r4_lint_txfixF3.log` (0 `%Error`, 77 warnings).
* **New scorer, and it exists because of a comparator hazard.** Task 11 compared
  delivered content **row-keyed** (`cut -f2,3,4 | diff`), valid only while both runs
  deliver the same frames in the same order. R4 suppresses pops during pre-fill, so the
  head of the delivered stream can gain or lose a frame and a row-keyed diff would
  report a wholesale mismatch on byte-identical frames. `t12_ident.py` **joins on the
  TGEN seq number**, reports each run's seq set separately, compares only common seq,
  and measures the `sidx` delta **per seq** — which is what turned "constant pre-fill
  latency" into a measured distribution instead of an assumption. Self-tested against
  `b_p000` vs itself.
* **One self-inflicted false alarm, recorded not buried.** The first smoke chain
  reported `T12_SMOKE_FAIL` and launched nothing. Two of its three failures were mine:
  it compared the `r4_prefilled` sentinel against a mis-computed decimal (`0xA5A50001`
  is **2779054081**, which the run had reported correctly all along), and it imported
  gate rows **G2 and G3 into a 25-air-frame smoke** that is almost entirely acquisition.
  The third was Task 11's truncation lesson again: the −49365 `sidx` outlier is one air
  frame of `sidx` freeze, not moved content. Corrected in `t12_chain2.sh` (a new file,
  so what v1 ran stays auditable); smoke is now wrapper provenance + seq-keyed content
  identity only. **The smoke diagnostics were right and they pre-announced G2/G3** —
  §3 above is the same measurement at full length.

## 7. What is NOT claimed

* R4 does **not** remove the epoch slip. `Peak_Search.timing_Reference`,
  `Timing_Adjust.timing_Reference` and `End_Generator`'s counter all count VALIDS, so a
  skipped valid still slips all three epochs by one symbol. R4 bounds *where* the
  deficit is absorbed.
* **The pre-fill is not carrying its weight.** It survives acquisition on exactly one of
  the four legs (the tiled control). Everywhere else the steering builds the operating
  point on its own, and the pre-fill's only measurable effects are +8 symbols of
  latency, 11 fewer acquisition `pop_on_empty` events, and G2/G3 failing. Task 12b has
  already dropped it; nothing in this report argues against that.
* **−40 ppm is not improved over R3S** (4.48 % both). The binding constraint is the
  eight-deframer-frame lock latency, during which the ring is already at the EMPTY edge.
* **The FULL edge / positive SRO is untouched**, and at +10 ppm the skip-only rule
  brings the FULL edge ~49 frames closer. No `b_p10` baseline was available at scoring
  time, so the +10 ppm leg is an observation, not a comparison.
* **No silicon claim.** R4 has not been synthesised; there is no timing, resource or PER
  number from hardware here. Counted from the generated tree, the change adds to
  `Rate_Handle` **two 6-bit comparators** (`r4_occ >= 16` at `:153`, `r4_occ <= 8` at
  `:136`), **one 4-bit counter** (`r4_frames`), **three single-bit flops**
  (`r4_guard_d`, `r4_prefilled`, `r4_skip_done`) and the **32-bit `r4_skips` witness
  counter**, which a silicon build may drop. It is fed from a register
  (`sample_discard_controller.active`), so there is no combinational loop through the
  receive chain — but that is a reading of the RTL, **not** a timing result.
* **R4 fails toward NO OUTPUT, not toward baseline.** If the ring never reaches
  occupancy 16, `r4_prefilled` never sets and no pop is ever taken. There is no timeout.
  R3S's failure mode was strictly safer. This is a further argument for Task 12b's R4B.

## 8. Recommendation

Ship the **steering**, not the pre-fill. The `occ ≤ 8` guard-band skip is what produced
0.48 % at −10 ppm and 0.00 % on the tiled control, and it reaches its operating point
unaided on every leg. The pre-fill costs 8 symbols of latency, fails its own two gate
rows, and introduces a fail-to-silence mode — which is exactly what R4B (Task 12b) has
already concluded. The remaining −40 ppm residual is a **lock-latency** problem, not an
arming problem: seven holes are taken before eight deframer frames have elapsed. If
−40 ppm matters, the next probe is a cheaper lock predicate, not a different skip rule.
