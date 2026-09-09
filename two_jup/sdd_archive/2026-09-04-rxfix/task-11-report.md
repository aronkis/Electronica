# Task 11 — RXFIX_R3S: skip-only, acquisition-safe guard-band steering  [sim, desk only]

Brief `two_jup/sdd_archive/2026-09-04-rxfix/task-11-brief.md` · pre-registration
`two_jup/comb/RXFIX_R3S_SIM_GATE.md` (committed **before** any leg was started, 79e7015)
· ledger `progress.md` (`Task 11:` lines) · branch `per-under-1pct-2026-07`.
**No board contact, no Vivado, no subagents.** Every number below is **[sim]**.

## Verdict in one paragraph

**The falsifier did NOT fire, and that is the finding.** On the certified non-repeating
stimulus at −10 ppm, R3S took **21 steered skips** — one per hole cycle, at exactly the
21 air frames where the baseline took its 21 EMPTY-edge holes — and **not one of those
21 skips cost a frame**. Loss fell from **10.93 % to 0.95 %**, and the four frames that
still die are fully accounted for: two are Task 7's already-recorded losses that belong
to no hole cycle at all (seq 133, 134 — present in the baseline), and two straddle the
**one hole R3S cannot pre-empt**, the hole that arms it. At −40 ppm loss fell **78.07 %
→ 4.48 %**, on the tiled control **22.01 % → 1.89 %**, and at 0 ppm the delivered stream
is **byte-identical** to the baseline. So **where the hole lands is what kills the
frame**: move it into the guard band and the frame survives. **Nine of eleven gates
pass. G4 and G10 FAIL as written**, both for the same measured reason — the arming
hole — and they are reported as failures, not reinterpreted.

## 1. The RTL change, in words, with line anchors

Seven internal modules, **no new TxRxComposite or IP port**; injector variant `R3S` in
`two_jup/skidfix/rxfix_inject.py`, marker `RXFIX_R3S`, structural (paren-balanced)
insertion so both netlist lineages take it. Anchors below are in the generated tree
`jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R3S/`.

| file | change | anchor |
|---|---|---|
| `sample_discard_controller.v` | `output activeOut` = the discard-window state, read-only | `:37` port, `:221` `assign activeOut = active;` |
| `Packet_Controller.v` | `output guardOut = ~sdc_active_r3s` | `:35` port, `:168` pin, `:171` assign |
| `Frequency_and_Time_Synchronizer.v` | wire the guard back into `Symbol_Synchronizer`; **no port added** | `:108` wire, `:125` `.guardIn(...)`, `:198` `.guardOut(...)` |
| `Symbol_Synchronizer.v` | `input guardIn`, passed to `Rate_Handle` | `:34` port, `:47` decl, `:461` pin |
| `FIFO_block.v` | `output [5:0] occOut` | `:35` port, `:114` pin |
| `Validate_Input_Push_Pop_block.v` | `output [5:0] occOut = Delay_out1` | `:32` port, `:146` assign |
| `Rate_Handle.v` | **the steering** | `:34` `guardIn` port, `:111-166` the block, `:181` `.occOut(r3s_occ)` |

The whole change to the data path is one redefined expression. Baseline
(`s1_rtl/.../Rate_Handle.v:95`):

```verilog
assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;
```

R3S (`s1_rtl_rxfix_R3S/Rate_Handle.v:121,133,136`):

```verilog
assign r3s_pop_nom = validIn & Compare_To_Constant_out1;            // :121
assign r3s_do_skip = r3s_armed & guardIn & (r3s_occ <= 6'b000001) &
            ( ~r3s_skip_done) & r3s_pop_nom;                        // :133
assign Logical_Operator_out1 = r3s_pop_nom & ( ~r3s_do_skip);       // :136
```

`r3s_do_skip` is ANDed with `r3s_armed`, so **until the arm fires the pop expression is
literally the baseline expression**. The s = 0 identity is therefore **structural, not
measured** — and it was then measured anyway (§3, G1).

**R3's extra-pop branch is deleted, not fixed.** A test asserts no residue of it
(`r3s_extras`, `r3s_do_extra`, `r3s_high`, `r3s_hi_done`, `6'd30`, `>= 6` all absent).
Task 7 measured `r3_extras = 4` accompanying 100 % loss of framing: an extra pop *emits*
a symbol and slips every valid-counting epoch the opposite way, so it is not the mirror
image of a skipped pop. The FULL edge / positive-SRO case is **out of scope**.

## 2. The arming definition, and why it is derivable with four flops

The brief allowed either "first Preamble_Detector sync" or "≥ N = 8 frames after the
acquisition burst". The definition used is the second, realised **without routing
`syncPulse` down two levels of hierarchy**:

**Lock.** `guardOut = ~sample_discard_controller.active`, and `active` can only be set by
`startIn`, which comes from `Preamble_Detector`'s `synchronizedPulse`. So before the
deframer frames its first packet `guardIn` is **constant 1 and never falls**. Every
**falling edge of `guardIn` is therefore one deframer frame start**, and
(`Rate_Handle.v:131,143-145`):

```verilog
assign r3s_locked = r3s_frames == 4'b1000;                 // eight deframer frames
...
if (r3s_guard_d && ( ~guardIn) && ( ~r3s_locked)) r3s_frames <= r3s_frames + 4'b0001;
```

**Arm.** `r3s_armed` is a sticky flop set only by a **post-lock** EMPTY edge
(`Rate_Handle.v:146-148`), where the edge is reconstructed inside `Rate_Handle` rather
than routed out (`:127`):

```verilog
assign r3s_pop_empty = (r3s_occ == 6'b000000) & Logical_Operator_out1;
```

This is **bit-exact `pop_on_empty_FIFO`**, not an approximation:
`Validate_Input_Push_Pop_block.v:119` is `pop_on_empty_FIFO = Compare_To_Constant_y & pop`,
`occOut` **is** `Delay_out1` (`:146`, the same net `:110` registers), and
`Compare_To_Constant_block.v:36,38` compares that net against `6'b000000`. Verified in a
test that reads the real compare block rather than trusting the name.

**Skip.** While armed, the first nominal pop inside a guard window at occupancy ≤ 1 is
suppressed, at most once per window (`r3s_skip_done`, cleared on `~guardIn`).

**Why this makes 0 ppm inert, checked on banked data before the build.** On Task 7's
`b_p000` the first deframer frame mark is at air frame **5.006** and **all 34**
acquisition holes are in air frame **0**. Lock cannot be true at any hole on that leg, so
R3S can never arm at 0 ppm **by construction**.

**Failure mode, stated.** If lock is lost after arming, `guardIn` sticks at 1,
`r3s_skip_done` latches after one skip and is never cleared: steering stops and the
built-in guard resumes. R3S **fails toward baseline** — it can move holes, it cannot
create losses the baseline lacks.

## 3. The pre-registered gate table, filled with raw numbers

Binary `obj_byte_sro_rxfix3s/Vwrap_byte_sro` = the R3S tree + **Task 7's `sim_sro.cpp`,
unmodified**. All four legs used the same `nsamp` as the banked baselines (21,114,096 /
8,139,780, verified before launch). Baselines were **not re-run**.

| # | leg | quantity | PASS criterion | **measured** | |
|---|---|---|---|---|---|
| G1 | `s_p000` | delivered stream vs `b_p000` | md5 equal | `b9510cbc2d038909dbe17de23dcc06de` **both**, 424 frames, `diff` empty | **PASS** |
| G2 | `s_p000` | `r3s_armed` | 0 throughout | `r3_extras = 0`; **no kind-5 record** | **PASS** |
| G3 | `s_p000` | `r3s_skips` | exactly 0 | **0** | **PASS** |
| G4 | `s_m10` | LOSS (seq denominator) | ≤ 0.5 % | **0.95 %** (4 of 421; baseline 10.93 %) | **FAIL** |
| G5 | `s_m10` | `r3s_skips` | 15–35 | **21** | **PASS** |
| G6 | `s_m10` | `rh_pop_on_empty` in the scored window | ≤ 2 | **1** (35 total = 34 acquisition + 1; baseline 21) | **PASS** |
| G7 | `s_m10` | losses NOT aligned to skips | falsifier must not fire | **0.095 lost frames per skip** vs baseline **2.00 per hole**; 20 of 21 skips have no loss within ±1 | **PASS** |
| G8 | `s_m40` | LOSS | < 5 % | **4.48 %** (405 of 424 byte-exact; baseline **78.07 %**) | **PASS** |
| G9 | `s_m40` | `r3s_skips` | 150–260 | **203** | **PASS** |
| G10 | `s_tm10` | LOSS (`score_sro2.py`) | ≤ 0.5 % | **1.89 %** (3 of 159; baseline **22.01 %**) | **FAIL** |
| G11 | all | wrapper provenance | both lines present | `WRAP3S_FILE wrap_byte_sro3s.v e7c1` + `WRAP3S_DEFINE RXFIX_R3S` on **all four** legs | **PASS** |

**G1 is stronger than it had to be.** Not only `_deliv.txt` but `_seq.txt`, `_frames.txt`
and `_ep.txt` are byte-identical between `s_p000` and `b_p000`
(`b2337afec9cc4cb8379a7d0e3a7c3e38`, `b3a37d7bc1b9be2fabed9c74a09cbfed`), and
`capout = a037d28a`, `packets = 424`, `rhPE = 34`, `rhPF = 0` all match. The 0 ppm leg is
the same simulation.

### G4 and G10 fail. Here is exactly what is left.

`s_m10`, the **complete** list of lost frames — 4 of 421:

| lost seq | what it is |
|---|---|
| **133, 134** | Task 7 recorded these as **unexplained and not hole-aligned** (nearest hole 126 frames later). They are lost in the **baseline too**. R3S neither causes nor cures them. |
| **255, 257** | The two frames straddling air frame **259** — the **arming hole**, the one EMPTY edge that must happen before `r3s_armed` can be set. |

So `2/421 = 0.475 %` of the residual is inherited, and `2/421 = 0.475 %` is the arming
hole. `s_tm10`'s three losses are `38, 39, 40` — the frames around **its** arming hole at
frame 40 — and there is **not one loss in the 119 frames after it**. `s_m40`'s residual
is the seven holes at frames 6–18, all **before** arming at frame 18.

**The gate is failed as written and is reported failed.** What the decomposition adds is
that the residual is one specific, identified event per leg, not a diffuse remainder.

## 4. Hole / skip / loss alignment — the measurement that carries the verdict

`t11_align.py` (new; reproduces Task 7's headline on `b_m10` exactly: offset −3,
**42/46** losses within ±1 of a hole, **21/21** holes with a loss).

| | `b_m10` baseline | `s_m10` R3S |
|---|---|---|
| holes in the scored window | **21** at frames 259,267,…,421 | **1**, frame 259 (the arming hole) |
| skips | 0 | **21** at frames 260,268,…,422 |
| lost frames | 46 | **4** |
| losses within ±1 of a **hole** | 42 / 46 (91.3 %), offset −3 | 2 / 4, offset −3 — and both belong to that one hole |
| **losses within ±1 of a SKIP** | — | **1 of 21 skips**, and that skip is the one immediately after the un-pre-empted arming hole |
| lost frames per event | **2.00 per hole** | **0.095 per skip** (2 losses / 21 skips) |

*(Definition, stated so it is not confused with Task 7's: 2.00 here is
`aligned losses / aligned events` = 42/21. Task 7's 2.10 is
`post-edge losses / holes` = 44/21. Both are quoted from the same run.)*

**The direct evidence that the hole moved into the guard band** — the `tref` at each
event (`tref` is `Peak_Search.timing_Reference`, mod 12,333):

* `b_m10` holes: **5167, 6560, 7820, 9350, 10527, 12030, 1020, 2224, 3585, 4808, 6155,
  7324, 9034, 10136, 11487, 533, 2000, 3045, 4594, 5941, 7186** — walking straight
  through the 12,320-symbol payload window, ~1200 slots per cycle.
* `s_m10` skips: **52, then 21 nineteen times, 28 once** — every one within 52 slots of
  the epoch boundary, i.e. **inside the inter-frame guard**.
* `s_m40` skips: **12296 (201 of 203), 12295, 7026** — the same window, on the other side
  of the wrap. `s_tm10` skips: **59, then 28 fifteen times.**

**And the ring reached the new operating point that was pre-registered as the mechanism.**
`s_m10` per-frame occupancy envelope: `oMin/oMax = 0/1` up to frame 258, `0/2` at the
arming hole 259, and **`1/2` from frame 260 to the end of the run**, with
`pop_on_empty = 0` on **every** frame after 259. That is §0 of the pre-registration
happening: steering lifts the ring off the EMPTY edge instead of merely relocating the
edge.

## 5. Per-stage dump around one skip

Run even though the falsifier did not fire, because G4/G10 failed:
`sim_stagewin` (`jupiter_240k5_byte/rtl_sim/sim_stagewin.cpp`, built by
`build_stagewin3s.sh` **before** the legs ran) dumps every `enb_1_2_0` beat for ±64 beats
around a skip at Rate_Handle out, CFC, Carrier_Synchronizer, the Preamble_Detector
correlator / Peak_Search / Timing_Adjust, and Packet_Controller — **plus the matched
±64-beat window one air frame earlier at the same intra-frame phase**, a frame with no
skip. Two events were captured on each of two legs (`t11_stagewin_m10.txt`,
`t11_stagewin_tm10.txt`; 2 events x 2 windows x 129 beats each).

**The dump gave a free control.** Event 0's reference window is one air frame before the
*first* skip — which is the **arming-hole frame itself** (m10: skip at air frame 260.010,
reference 259.010; tiled: 41.008 vs 40.008). So event 0 compares *a frame containing a
HOLE* against *a frame containing a SKIP*, and event 1 (m10 268.008 vs 267.008; tiled
49.006 vs 48.006) compares *a clean frame* against *a frame containing a SKIP*.

### Where the skipped slot lands

Beat-for-beat around the event, **identical on both legs**:

| rel | reference: `sdcAct` `guard` `pcV` `pcEnd` `rhValidOut` | skip window: same |
|---|---|---|
| −5 | 1 0 1 0 **1** | 1 0 1 0 **1** |
| −4 | 0 1 0 **1** 0 | 0 1 0 **1** 0 |
| −3 … −2 | 0 1 0 0 0 | 0 1 0 0 0 |
| **−1** | 0 1 0 0 **1** | 0 1 0 0 **0** ← the suppressed pop |
| 0 … +2 | 0 1 0 0 0 | 0 1 0 0 0 |
| +3 | 0 1 0 0 1 | 0 1 0 0 1 |

`End_Generator` fires at rel −4 (`pcEnd = 1`), `sdcAct` drops and `guard` rises, and the
pop that R3S suppresses is **three beats inside the guard band**, with `sdcAct = 0` and
`pcV = 0` — the deframer is consuming nothing at that instant. The whole
`guard`/`sdcAct`/`pcStart`/`pcEnd` sequence is **identical** between the two windows;
`popEmpty` is 0 on every beat of both. Ring occupancy goes 1 → 2 at the skip and the
window range moves from 1..2 (reference) to 1..2 (skip) in steady state, and from 0..1 to
1..2 across the arming transition.

### Does anything downstream of Rate_Handle react?

Valid counts over the 129-beat window, **event 1 (clean reference), identical on both legs**:

| stage | reference | skip window | Δ |
|---|---|---|---|
| `Rate_Handle.validOut` | 32 | 31 | **−1** |
| `Coarse_Frequency_Compensator.validOut` | 32 | 31 | **−1** |
| `Carrier_Synchronizer.validOut` | 32 | 31 | **−1** |
| `Correlator.validOut` | 32 | 31 | **−1** |
| `Preamble_Detector.validOut` | 33 | 33 | 0 |
| `Packet_Controller.validOut` | 19 | 19 | **0** |

**Nothing reacts.** The deficit propagates one-for-one — one skipped time slot in, one
fewer valid at each stage — and **no stage deletes or inserts a symbol of its own**.
`Preamble_Detector.validOut` is unchanged because it is the *tick*-delayed pop
(`Delay10_reg`, 49,332 enb ticks), which is the known tick-vs-valid divergence and not a
reaction to the skip. The deframer's output valid count is unchanged.

Control signals over the same window, event 1: `taRef` (17..49), `taAcc` (23), `psToff`
(23), `toffVal` (0), `taArmed`, `taSync`, `pcStart`, `pcEnd`, `sdcAct`, `guard` — **every
one identical in the reference and the skip window**. The only movements are
(a) `psTref`, whose window top is exactly **one lower** (5..37 → 5..36) — the one-symbol
epoch slip §7 explicitly does *not* claim to remove — and (b) `Correlator.threshold` /
`Peak_Search.p1c_runmax` / `cfcEst`, which are running content-dependent statistics and
differ between any two frames of a non-repeating stimulus.

**Event 0 is the contrast that matters.** Against the *hole* frame, the same comparison
does show differences — `psToff` 55 → 23, `psNewpk` collapsing to 0, `pcEnd` and `pcV`
moving, and `sdcAct` stuck at 0 across the whole reference window — but those belong to
the **hole**, not to the skip: the reference there is the one frame R3S could not
pre-empt. Put beside event 1, this is the mechanism in a single picture: a hole in the
payload window disturbs Peak_Search and the deframer; a skip in the guard band disturbs
nothing.

**So the first stage whose behaviour differs across a steered skip is: none.** No stage
downstream of `Rate_Handle` behaves differently beyond consuming one fewer valid slot.

*Available to Task 12 at one command and ~6 minutes, not run here:* the same tool with
`arm = hole` on `s_m10.iq` captures the matched **hole** window in this same build
(the arming hole at tiled frame 40), which would make the hole-vs-skip contrast direct
rather than incidental.

## 6. What is NOT claimed

* R3S does **not** remove the epoch slip. `Peak_Search.timing_Reference`,
  `Timing_Adjust.timing_Reference` and `End_Generator`'s counter all count VALIDS, so a
  skipped valid still slips all three epochs by one symbol. R3S bounds *where* the hole
  lands. The residual is reported as measured, not rounded.
* The **FULL edge / positive SRO is untouched.** `s_m10` still shows
  `rh_push_on_full = 17`, all in acquisition frame 2, exactly as the baseline.
* **No silicon claim.** R3S has not been synthesised; there is no timing, resource or
  PER number from hardware in this document. The steering adds one 6-bit comparator, one
  4-bit counter and four flops to `Rate_Handle`, fed from a register
  (`sample_discard_controller.active`), so there is no combinational loop through the
  receive chain — but that is a reading of the RTL, **not** a timing result.
* **One skip per guard window bounds the SRO this can absorb.** It supplies at most one
  entry per air frame against a drift of 12,333·|s| entries per frame, so it saturates
  around |s| ≈ 81 ppm. −40 ppm (0.49 entries/frame) is comfortably inside; the on-air
  rig at ≤ 0.06 ppm and the desk at 2.5 ppm are far inside.
* `b_m2p5` was **not** run. Task 7 measured zero hole events in its scored window, so it
  is vacuous for or against any steering variant.

## 7. Rails and provenance

* Task 7's `wrap_byte_sro.v`, `sim_sro.cpp`, `build_sro.sh`, its units and its banked
  results were **not modified**. The Task 11 harness is a **new file**,
  `wrap_byte_sro3s.v`, which keeps the module name so `sim_sro.cpp` links unmodified —
  that is what makes G1 a test of the RTL and not of a re-typed driver. Because two files
  now declare `module wrap_byte_sro`, the new one prints `WRAP3S_FILE`/`WRAP3S_DEFINE` at
  time 0 and `build_sro_rxfix3s.sh` greps the verilate log; a wrong-wrapper pickup would
  otherwise have masqueraded as the G2/G3 **pass** condition (G11).
* Injector tests **74 green** (39 pre-existing + W1 + **18 new** `TestR3S`). One shared
  fix was needed and is tested: `RXFIX_R3` is a **prefix** of `RXFIX_R3S`, so every
  marker check now goes through a word-boundary `_has()`; without it `verify_zip` would
  have certified an R3S kit as an R3 kit. Behaviour on every pre-Task-11 file is
  unchanged (none contains `RXFIX_R3S`).
* `verilator --lint-only` **error-free on both lineages**, logs banked:
  `two_jup/comb/sro_sim/r3s_lint_s1_rtl.log`, `r3s_lint_txfixF3.log` (0 `%Error` each).
* **Documented limitation:** R3S's module-name anchors do not match the packaged Vivado
  IP kit, which renames the modules (`module TxRxCompo_ip_src_FIFO_block`) — the same
  limitation R3 has. It fails **loudly** on the exactly-once assert rather than editing
  the wrong span, and a test asserts that. Task 11 is sim-only and needs no kit.
* **One self-inflicted false alarm, recorded not buried.** The first smoke chain reported
  a delivered-stream mismatch. It was **my comparator**: `sim_sro.cpp`'s `sidx` freezes
  at `nsamp` once the stimulus is exhausted, so a *truncated* 25-frame run annotates its
  last delivered frames differently from the full-length baseline while the bytes are
  identical. Every content column matched on all 21 frames; 19 frames matched line for
  line. Fixed in `t11_chain.sh` (which also had an unconditional "matches" echo that made
  the log self-contradictory). **G1 never depended on this** — the gate leg uses the same
  `nsamp` as the baseline.

## 8. Recommendation

The mechanism is demonstrated: **21 steered skips, 0 losses**. The **entire** remaining
loss on every SRO leg is the single hole that has to occur before `r3s_armed` can be set,
plus two frames Task 7 already recorded as unexplained. The obvious next probe is to arm
on **lock alone** (drop the "post-lock `pop_on_empty`" requirement and let the `occ ≤ 1`
predicate carry it), which would pre-empt the first hole too and, on these numbers, put
`s_m10` at 2/421 = 0.475 % and `s_tm10` at 0.00 %. **That is arithmetic on this run, not
a result** — arming on lock alone re-opens exactly the question R3 failed on (a bare
occupancy predicate that is not inert at s = 0), and it must be gated on the same
n_p000 md5 identity before it is believed. **No R3T is cut here.**
