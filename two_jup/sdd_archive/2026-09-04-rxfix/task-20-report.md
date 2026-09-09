# Task 20 — S1 = RXFIX_R4D + RXFIX_R1: the FULL-side mirror works, end to end  [sim, desk only]

Brief: coordinator, Task 20 (2026-09-05), `task-20-brief.md`. Pre-registration
`two_jup/comb/RXFIX_S1_SIM_GATE.md`, committed **before the R4DR1 tree, the build script or
any leg existed** (`7ed4430`). Ledger `progress.md` (`Task 20:`). **No board contact, no
Vivado, no subagents.** Every number is **[sim]**.

## Verdict

**S1 PASSES on every gate row and the falsifier does not fire.** R4D's collapse was the
Preamble_Detector realignment FIFO's deletion, exactly as Task 14 diagnosed, and R1 removes
it. On the leg the variant exists for, `n_p10` (+10 ppm, the FULL edge):

| | `b_p10` baseline | `r4b_p10` (shipped) | `r4d_p10` (Task 14) | **`r4dr1_p10`** |
|---|---|---|---|---|
| LOSS, seq-keyed (D1) | 4.99 % (400/421) | 6.65 % (393/421) | *scorer refuses* | **0.00 % (421/421)** |
| LOSS, air frames fed (D2) | 4.95 % (403/424) | 6.60 % (396/424) | 70.28 % (126/424) | **0.00 % (424/424)** |
| `rh_push_on_full` | 21 | 28 | **0** | **0** |
| `pd_push_on_full` (`pdPof`) | 0 | 0 | **1** | 0 |
| `pdOcc` envelope, frames ≥ 4 | 12333..12333 | 12333..12333 | **12332**..12333 | **12333..12333** |
| extras | — | — | 37 | 37 |

**Not one frame is lost on `n_p10`, with all 37 extra pops firing.** The `+1` valid in the
guard band is harmless once the FIFO downstream of it stops deleting: it was the deletion,
not the `+1`. The answer to the brief's question is **(a)**.

R4DR1 also **recovers frames the baseline itself loses**: all 21 seq the baseline drops on
`n_p10` are delivered, and seq **289** and **362**, which arrive *corrupt* in both `b_p10`
(nbad 73 and 241 bytes) and `r4b_p10`, arrive **byte-perfect** (`ok=1, nbad=0`).

## 1. The composed RTL, in words, with anchors

Two patches, two files, **no shared anchor**, so the composition is textual:

* **R4D** — `Rate_Handle.v`, anchor `assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;`
  → `assign Logical_Operator_out1 = (r4d_pop_nom & (~r4d_skip_en)) | r4d_do_extra;`
  (R4DR1 tree line 161), with `r4d_do_extra = r4d_extra_en & validIn & r4d_phase2` (line 159)
  and the `r4d_steer_process` register block. Lock = 8 `pcEnd` pulses; the window is the 13
  nominal pop slots after `pcEnd`; the skip arms on `occ ≤ 8` and the extra on `occ ≥ 24`, at
  most one of each per window, every decision registered.
* **R1** — `Preamble_Detector.v`, anchors `wire Delay10_out1;` (line 90) and
  `assign Delay10_out1 = Delay10_reg[49331];` (line 316) →
  `assign Delay10_full = FIFO_numEntries == 14'd12333;` (line 331) and
  `assign Delay10_out1 = Delay8_out1 & Delay10_full;` (line 333). The 12,333-deep realignment
  FIFO's pop stops being **tick-indexed** (the symbol valid delayed 49,332 `enb` ticks, which
  equals 12,333 valids only at exactly 1-in-4 density) and becomes **occupancy-indexed**.

Consequence, and it is structural rather than statistical: under R1 a push while full always
carries its own pop, so `valid_pop = 1` and
`push_on_full_FIFO = Logical_Operator5_out1 & Compare_To_Constant1_y`
(`Validate_Input_Push_Pop.v:131`) can never fire. **The FIFO deletes nothing by
construction** — which is why §4 below insists `pdPof = 0` is a tautology and nominates a
different witness.

`R4D_CORE_FILES` does not contain `Preamble_Detector.v`, and `_r4d_guard()`
(`rxfix_inject.py:2338`) excludes only `RXFIX_R3/R3S/R4/R4B` — the four variants that
redefine the *same* pop expression. **No injector edit was needed**, so `rxfix_inject.py`
and its tests are untouched (Task 21 owns that file tonight).

Tree: `cp -a s1_rtl_rxfix_R4D s1_rtl_rxfix_R4DR1`, then
`rxfix_inject.py <tree> R1 --sim-tree` → `loose=1 missing=[]`; `verilator --lint-only` on
`TxRxComposite` = **0 errors**.

## 2. The pre-registered gate table, with raw numbers on both denominators

`D1` = seq-keyed `score_t7.py` LOSS = `(expect − OK)/expect`, `T7_NAIR=428`.
`D2` = Task 14's honest denominator = `(424 − t7_ok)/424`, the 424 air frames fed.
D2 carries a **one-frame acquisition floor** (`b_p000` = 423/424 = 0.24 % on D2, 0.00 % on
D1) and it **saturates**: `r4dr1_p10`'s `t7_ok = 424` is the whole denominator. Against all
**428** air frames actually fed, including the 4-frame acquisition transient, the same leg
reads 4/428 = **0.93 %** (baseline 25/428 = 5.84 %, R4B 32/428 = 7.48 %, R4D 302/428 =
70.56 %). No reading of the denominator changes any verdict.

| # | leg | criterion | measured | |
|---|---|---|---|---|
| **S1** | `r4dr1_p000` | LOSS 0.00 % D1, 423/424 D2; 0 extras; 8 skips | **0.00 % (420/420)**; **423/424 = 0.24 %**, exactly the floor; `r3_extras=0`, `r3_skips=8` | **PASS** |
| **S1b** | `r4dr1_p000` | byte identity vs `r4d_p000` — *diagnostic disjunction* | **branch two**: differs, `t12_ident` **PASS** (content equal on **423/423** common seq, same seq set), `sidx` delta 0 on 415 frames and **+4 (one symbol) on 8** | **as pre-interpreted** |
| **S2** | `r4dr1_p10` | LOSS ≤ 1 % on both denominators | **0.00 % D1 (421/421)** and **0.00 % D2 (424/424)** — vs 4.99/4.95 baseline, 6.65/6.60 R4B, 70.28 R4D | **PASS** |
| **S3** | `r4dr1_p10` | `rh_push_on_full` = 0 after lock | **0** (baseline 21, R4B 28) | **PASS** |
| **S4** | `r4dr1_p10` | `pdPof` = 0 **and** `pdOcc` pinned | `pdPof` **0**; `pdOcc` per-frame envelope **12333..12333**, `pdOcc_end` **12333**, and `pdOcc` = **12333 at every one of the 37 extras** (R4D: 12332/12333) | **PASS** |
| **S5** | `r4dr1_p10` | ring parked 22/23; extras one per ~8.1 frames | plateau `oS/oE` **22/22** (120 frames), **23/23** (115), **23/22** (75); `oMax` 23 (232 frames) / 24 (76); **37 extras** at frames 130,138,…,422, spacing mean **8.11** (8:32, 9:4) | **PASS** |
| **S6** | `r4dr1_p10` | **FALSIFIER**: no loss within ±1 of an extra | **DOES NOT FIRE — there are no lost frames at all** (`OK=421`, `CORRUPT=0`, `MISSING=0`); the aligner reports "alignment is vacuous" | **PASS** |
| **S7** | `r4dr1_m10` | LOSS ≤ R4B's 0.48 %; the ratchet harmless | **0.48 % D1 (419/421)**, **0.47 % D2 (422/424)** — R4B's number to the digit; 7 extras at frames **11–17** ratchet the ring **31 → 22/23** and framing is alive through all of them (R4D died at frame 13) | **PASS** |
| **S8** | `r4dr1_tm10` | tiled control 0.00 % | **0.00 % (159/159)**, `pdOcc` **12333..12333** (R4D 12332..12333) | **PASS** |
| **S9** | all seven | provenance | build assertions all green; binary md5 `59cfc174…` ≠ R4D `56ca2e50…`; `pdOcc` pinned at 12333 on **all seven** legs (R4D: 12332 on five of them) | **PASS** |
| **S10** | `m40`, `m10c`, `lol` | diagnostics, never gating | all three **branch two** of §4.1: differ from R4D, seq-keyed content equal, **LOSS identical to R4D's** (4.48/4.48, 0.47/0.47, 0.24/0.24) | **as pre-interpreted** |

### 2.1 LOSS, every leg, both denominators

| leg | `t7_ok` | D1 (seq-keyed) | D2 (`t7_ok`/424) | R4D's D2 | baseline D2 |
|---|---|---|---|---|---|
| `r4dr1_p000` | 423 | 0.00 % (420/420) | 0.24 % | 0.24 % | 0.24 % |
| `r4dr1_p10` | **424** | **0.00 % (421/421)** | **0.00 %** | 70.28 % | 4.95 % |
| `r4dr1_m10` | 422 | 0.48 % (419/421) | 0.47 % | 98.11 % | 10.85 % |
| `r4dr1_m40` | 405 | *refused* (as `b_m40` is) | 4.48 % | 4.48 % | 78.07 % |
| `r4dr1_m10c` | 422 | 0.24 % (419/420) | 0.47 % | 0.47 % | 28.30 % |
| `r4dr1_tm10` | tiled | 0.00 % (159/159) | — | 0.00 % | 22.01 % (`tb_m10`) |
| `r4dr1_lol` | tiled | 0.24 % (409/410) | — | 0.24 % | 4.39 % (`t_lol`) |

`score_t7.py` refuses `n_m40` on **every** variant including the baseline (a corrupt header
seq widens the range to 15.7 M); D2 is the honest number there, and it is R4D's to the digit.

### 2.2 Two places where a reader could see an unexplained residual, and neither is one

**`m10c` reads 0.24 % on D1 and 0.47 % on D2.** That is the acquisition floor, which is
leg-specific: `n_m10c` delivers **3** no-magic frames where `n_p000` delivers 1, and D2's
fixed 424 denominator charges all of them while D1's seq span (5..424, `expect=420`) starts
after them. The comparison that matters is like-for-like on **both** denominators, and it is
exact: `r4d_m10c` **0.24 % D1 (419/420, lost seq 6) / 0.47 % D2**, `r4b_m10c` **0.24 % D1
(419/420, lost seq 6)** — the same single lost seq, the same numbers, on both denominators.
The S10 "identical to R4D" claim holds on D1 and D2, not just one of them.

**`r4dr1_p10` reads 0.00 % with `nomagic_frames=3`.** Those three are acquisition and nothing
else: rows **2, 3, 4** of `_seq.txt`, at `sidx` **197741, 246817, 296021** — byte-for-byte the
same three rows, at the same sidx, as the **baseline's** first three. `b_p10` has **22** such
frames and `r4b_p10` **27**; the other 19 and 24 are scattered through the run (rows 260, 268,
…) and are their losses. R4DR1 keeps only the three that every leg has, including `n_p000`.
So "0.00 % with 3 no-magic frames" is "the acquisition transient, and nothing after it".

## 3. Extra / loss alignment — the falsifier, and why its non-firing is the strong kind

Task 14's J4 fired because framing died three air frames after the first extra. Here:

* **`r4dr1_p10`: 37 extras, 0 losses.** `t11_align.py` prints *"no lost frames — alignment is
  vacuous"*. There is no residual to attribute. That is the strongest possible non-firing:
  not "the losses are elsewhere", but "there are none".
* **`r4dr1_m10`: 7 extras (frames 11–17), 2 losses (seq 133, 134).** They align to the
  **skips**, not the extras: best constant offset **−8**, **2/2 losses within ±1**, 1 of 37
  skip events with a loss beside it, 2.00 lost frames per aligned event. The extras get no
  alignment at all — they are 116 frames away from the losses. R4B loses the same 2 frames
  (0.48 %), so this residual is **R4B's, inherited, not created by the mirror**.
* `r4dr1_m10c`'s single loss (seq 6) aligns to the one scored-window `pop_on_empty` at frame
  8 (offset −3, 1/1), which is the baseline hole class, not a steered event.
* Kind 5 in this lineage **is** the extra pop. `t11_align.py`'s legend still said
  `r3s_armed` (R3S/R4B put a lock sentinel on that port); the label was corrected — the
  arithmetic already ran over every `KIND` key and was not touched.

## 4. `pdPof` / `pdOcc` per leg — and why only one of them is evidence

**`pdPof = 0` is a tautology under R1** and was pre-registered as one: a push-while-full
always carries its own pop, so the signal is unreachable whatever happens downstream. The
non-circular witness is `pdOcc`, the PD FIFO's own occupancy.

| leg | `pdPof` | `pdOcc` envelope (frames ≥ 4) | `pdOcc_end` | R4D's envelope | R4D's `pdOcc_end` |
|---|---|---|---|---|---|
| `r4dr1_p000` | 0 | **12333..12333** | 12333 | 12332..12333 | 12333 |
| `r4dr1_m10` | 0 | **12333..12333** | 12333 | 12332..12333 | **12331** |
| `r4dr1_m40` | 0 | **12333..12333** | 12333 | 12332..12333 | 12333 |
| `r4dr1_tm10` | 0 | **12333..12333** | 12333 | 12332..12333 | 12333 |
| `r4dr1_m10c` | 0 | **12333..12333** | 12333 | 12332..12333 | 12333 |
| `r4dr1_p10` | 0 | **12333..12333** | 12333 | 12332..12333 | **12332** |
| `r4dr1_lol` | 0 | **12333..12333** | 12333 | 12332..12333 | 12333 |

The FIFO never leaves its full mark on any leg, at any air frame, under any steering. That
is R1's entire content, measured, and it is also the runtime provenance the shared wrapper
could not give (§6).

## 5. The clean decomposition: R4D owns the ring, R1 owns the framing

Three independent comparisons, all seven legs:

* **The ring's per-frame state is bit-identical to R4D.** `_frames.txt` columns 21–26
  (`occTS, occTE, occTmin, occTmax, rhPopEmpty, rhPushFull`) md5-match on **7 of 7** legs.
* **Every steered decision is identical to R4D.** `_skipwin.txt` columns
  `n, slot_rtl, slot_harness, dt_enb, occ, locked, kind` md5-match on **7 of 7**; the
  `(kind, air frame)` stream of `_ep.txt` kinds 4/5 matches on **7 of 7**. Same 37 extras at
  the same frames on `p10`, same 7 at frames 11–17 on `m10`, same 8/210/24/60/17 skips.
* **The only `_ep.txt` column that moves is `pdOcc` at the event**: 12332/12333 under R4D,
  **12333 always** under R4DR1.

So R1 changes nothing upstream of the Preamble_Detector — it cannot, it is two stages
downstream of the ring — and the FULL-edge win (`push_on_full` 21 → 0, ring parked 22/23) is
**entirely R4D's**, while framing survival is **entirely R1's**. The two effects are exactly
separable and were measured separately.

### 5.1 What R1 does to the delivered stream: it moves *when*, not *what*

On every leg where R4D takes skips but no extras, R4DR1's delivered **content** is equal to
R4D's and only the `sidx` annotation moves, by exactly **+4 input samples = one symbol**, on
the frames that follow a skip:

| leg | `t12_ident` | content equal | `sidx` delta distribution |
|---|---|---|---|
| `p000` | **PASS** | 423/423 | 0:415, **+4:8** (8 skips) |
| `m10c` | **PASS** | 422/422 | 0:362, **+4:60** (60 skips) |
| `m40` | **PASS** | 407/407 | 0:200, **+4:207** (210 skips) |
| `tm10`, `lol` | row-keyed `(nwords,hash,user)` md5 equal | all frames | — |

Mechanism, and it is R1's own rationale read forwards: under R4D a skip punches a
valid-density hole, the tick-scheduled pop fires anyway, and the frame completes one symbol
early; under R1 the FIFO stays full and the frame completes on its true 12,333rd valid.
**Nothing about the payload changes.** That is why Task 6 measured R1 as "no effect" on loss
and why it is nonetheless the thing that saves R4D.

## 6. Provenance — the wrapper cannot tell these legs apart, so three other things do

`build_sro_rxfix4dr1.sh` reuses `wrap_byte_sro4d.v` and Task 7's `sim_sro.cpp`
**unmodified**, with the same `+define+RXFIX_R4D` — which is what makes the comparisons
tests of the RTL and not of a re-typed driver, but also means every R4DR1 leg prints exactly
the R4D banner (`WRAP4D_FILE wrap_byte_sro4d.v t14`). Three discriminators, all pre-registered:

1. **Build-time.** Verilate log names `s1_rtl_rxfix_R4DR1/` and **not** `s1_rtl_rxfix_R4D/`
   (the trailing slash is load-bearing: `R4D` is a strict prefix of `R4DR1`); `RXFIX_R4D` in
   `Rate_Handle.v` and `RXFIX_R1` in `Preamble_Detector.v`; no `R3/R3S/R4/R4B`; and the sharp
   one — `assign Delay10_out1 = Delay10_reg[49331];` must be **gone** and
   `assign Delay10_out1 = Delay8_out1 & Delay10_full;` present. (The tick-indexed expression
   is quoted inside R1's own patch comment, so only the *assign* form is a valid test — a
   naive `grep Delay10_reg[49331]` passes on a correctly patched file.)
2. **Launch-time.** `runall_t20.sh` writes `T20_BIN` and
   `T20_MD5 r4dr1=59cfc1743dcbe737e2939e21d8641134 r4d=56ca2e5052eaea790fb0e93fb3acb59f`
   into every leg log and refuses to launch if the two md5s agree.
3. **Runtime.** The `pdOcc` pin of §4, on all seven legs — a *positive* witness that the R1
   text is in the binary, where an md5 only proves "different".

**Smoke leg** (`sk4dr1_p000`, `nsamp=1,233,300`, 25 air frames — the window that holds all 8
of `p000`'s skips) against Task 14's banked `sk4d_p000`: every `_res.txt` scalar identical,
same 8 skips at air frames 13–20, delivered content byte-identical on all 21 frames, zero
losses, and `pdOcc` 12333..12333 against R4D's 12332..12333. Branch two of §4.2, at 2.5
minutes, before the seven 55-minute legs were launched.

## 7. Two traps that were pre-named, and both were real

* **`pdPof = 0` proves nothing** (§4). Under R1 it is unreachable by construction. Had this
  gate quoted it as the fix's confirmation, the strongest-looking row in the table would have
  been the emptiest.
* **The `p000` byte-identity row would have read as a failure** (§4.2 of the
  pre-registration). `r4d_p000` takes 8 skips, so R4D is not a no-op there, and R4DR1
  *differs* from it — content-identical, one symbol later. Pre-registering the disjunction is
  what kept that from being scored as a broken build.
* Task 14's third trap was avoided rather than hit: `score_t7.py` still refuses `n_m40` on
  every variant, and every LOSS above is quoted on both denominators.

**One caveat stated plainly.** `t12b_window.py` was written for R4B, where kind 5 is a lock
sentinel; on the R4D lineage it labels the extras "LOCK" and prints `*** MISMATCH` when it
counts 37 skip records against 44 kind-4/5 records. Its substantive output is still valid and
is the S9 evidence: **44/44 steered events on `m10` and every event on all seven legs sit
inside slots [1,13] on both the RTL counter and the independent harness recount**, with the
same slot histograms as R4D. The `m10c` "mid-payload" flag (`dist=202`) is inherited from
R4D — the event positions are bit-identical — and is not an R1 effect.

## 8. What this does and does not license

* **It licenses the reverse-leg (146) direction, in sim.** The FULL edge is now steerable
  *and* survivable: `push_on_full` 21 → 0 with zero frame loss on +10 ppm, against a shipped
  R4B that makes that leg **worse** (6.65 % vs the baseline's 4.99 %). R4B remains
  forward-only; **R4D+R1 is the first variant that improves the positive-SRO leg.**
* **It does not license a flash.** This is `s1_rtl`, the sim lineage. R1 removes a 49,332-flop
  shift register's only reader and adds a 14-bit comparator — a **resource and timing change
  in the receive path** that has never been through synthesis, and the flashed lineage is
  `s1_rtl_txfix_F3`, not `s1_rtl`. A silicon cut needs the injector's kit path
  (both zips + `verify_zip`), a timing-closed build, and its own on-air gate.
* **`enSlack` is now the second-best option, not the first.** Task 14 §4 pre-registered an
  F3-lineage `enSlack` experiment (fixctl bit 3) as the fix for the same deletion. R1 fixes
  it in the RTL, on the lineage that already simulates, with no new wrapper, no F3 build and
  no missing baseline — and it makes the deletion **structurally impossible** rather than
  merely tolerated. `enSlack` remains available and is not withdrawn.
* **The `−10 ppm` legs are unchanged.** R4DR1 = R4B to the digit on `n_m10` (0.48 %/0.47 %)
  and equals R4D on every skip-only leg. The mirror costs nothing where it does not fire.

## 9. Rails

Sim only; no board contact; no Vivado; no subagents; no 146 or 148 work. `rxfix_inject.py`
and `test_rxfix_inject.py` **not modified** (Task 21 owns them). `wrap_byte_sro4d.v`,
`sim_sro.cpp`, `sim_stagewin.cpp`, the R4B/R4D trees and every banked baseline **untouched
and not re-run**; `t11_align.py` got a label-only change. The falsifier did not fire, so the
per-stage `stagewin` dump reserved for that branch was **not** built. Legs ran as
`systemd-run --user` units `t20_*`; heartbeat `t20hb`. Commits: `7ed4430` (pre-registration,
before any code), `c4a218b` (tree, build, launcher, scorer), `4b825ef` (smoke), and this
report. Raw scoring output: `two_jup/comb/sro_sim/t20_score.txt`.
