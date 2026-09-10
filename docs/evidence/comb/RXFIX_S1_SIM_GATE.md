> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_S1_SIM_GATE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX_S1 (R4D + R1) — sim gate PRE-REGISTRATION  [sim, desk only]

Task 20, plan T20 (`happy-bubbling-owl.md`), brief
`two_jup/sdd_archive/2026-09-04-rxfix/task-20-brief.md`. **Committed before the R4DR1 tree,
the build script or any leg existed.** Ledger `Task 20:`. Sim only; no board contact; no
Vivado; no subagents. Every number below is **[sim]**.

## 0. The question

Task 14 refuted R4D: the extra pop did exactly what it was designed to do **at the ring**
(`n_p10` `push_on_full` 21 → 28 → **0**, ring parked 22/23, 37 extras at one per 8.1 frames)
and destroyed the receiver **two stages downstream** — 70.3 % loss on `n_p10`, 98.1 % on
`n_m10`, framing dead within three air frames of the first extra, aligned to `pdPof`.

The mechanism named there is the **Preamble_Detector realignment FIFO**: its pop is
**tick-indexed** (`Delay10_reg[49331]`, the symbol valid delayed 49,332 `enb` ticks), so the
FIFO sits **at** its 12,333 full threshold in steady state and one extra valid is one extra
**push into a full FIFO** → `push_on_full` → **the symbol is deleted** on the delayed chain,
which permanently moves the phase between Peak_Search's (undelayed) and Timing_Adjust's
(delayed) valid-counting epoch spaces.

**R1 is the fix for exactly that**, and it is already cut in the injector (Task 6):

```
- assign Delay10_out1 = Delay10_reg[49331];
+ assign Delay10_full = FIFO_numEntries == 14'd12333;
+ assign Delay10_out1 = Delay8_out1 & Delay10_full;
```

Under R1 a push while full **always carries its own pop**, so `valid_pop = 1` and
`push_on_full_FIFO = push & ~valid_pop & full` (Validate_Input_Push_Pop.v:131) can no longer
fire at all — the FIFO deletes nothing **by construction**.

**The question this gate answers.** Was the R4D collapse (a) the FIFO's deletion — fixable,
and then R4DR1 recovers the ring-level win — or (b) the `+1` valid *itself* in the
Peak_Search / Timing_Adjust epoch spaces, which R1 cannot touch? If (b), S1 is dead.

## 1. The composed RTL, with anchors

Two independent patches in two different files; **no anchor overlap**, so the composition is
textual, not semantic:

| | file (`s1_rtl` lineage) | anchor | what changes |
|---|---|---|---|
| **R4D** | `Rate_Handle.v` | `assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;` | replaced by the lock-armed, structural-window steering: `(r4d_pop_nom & ~r4d_skip_en) \| r4d_do_extra`, with `r4d_do_extra = r4d_extra_en & validIn & r4d_phase2` (R4D tree line 161), plus the `r4d_steer_process` register block |
| **R1** | `Preamble_Detector.v` | `wire Delay10_out1;` (line 90) and `assign Delay10_out1 = Delay10_reg[49331];` (line 316) | pop becomes occupancy-indexed: `Delay10_full = (FIFO_numEntries == 14'd12333)`, `Delay10_out1 = Delay8_out1 & Delay10_full` |

`R4D_CORE_FILES` = `Validate_Input_Push_Pop_block.v`, `FIFO_block.v`, `Rate_Handle.v`,
`Symbol_Synchronizer.v`, `Frequency_and_Time_Synchronizer.v`. **`Preamble_Detector.v` is not
among them**, and R1 touches nothing else, so no file is written by both variants.

`_r4d_guard()` (rxfix_inject.py:2338) excludes only `RXFIX_R3`, `RXFIX_R3S`, `RXFIX_R4`,
`RXFIX_R4B` — the four variants that redefine the *same* `Rate_Handle` pop expression. It
does **not** exclude `RXFIX_R1`, and `patch_preamble_detector()` carries no cross-variant
guard, so **no injector edit is required** for this gate. (Checked before cutting, as the
brief instructs. Nothing in `rxfix_inject.py` or its tests is modified by Task 20 — Task 21
is editing that file in parallel.)

**Order:** the tree is `cp -a` of the already-patched R4D tree, then R1 is injected. R1's two
anchors are verified present exactly once in the R4D tree's `Preamble_Detector.v`
(`_sub()` asserts this).

## 2. Harness and provenance

Object dir `obj_byte_sro_rxfix4dr1`, variant tree `s1_rtl_rxfix_R4DR1`, build script
`build_sro_rxfix4dr1.sh` = `build_sro_rxfix4d.sh` with the new `VD` and `-Mdir`, the **same**
`+define+RXFIX_R4D`, the **same** wrapper `wrap_byte_sro4d.v` and Task 7's `sim_sro.cpp`
**unmodified**.

Because the wrapper is shared with the seven banked R4D legs, its runtime banner
(`WRAP4D_FILE` / `WRAP4D_DEFINE`) **cannot** distinguish an R4DR1 leg from an R4D leg. Three
independent discriminators are therefore pre-registered:

1. **Build-time (text):** the verilate log must name `s1_rtl_rxfix_R4DR1/` and must **not**
   name `s1_rtl_rxfix_R4D/` (`R4D` is a strict prefix of `R4DR1`, so the trailing slash is
   load-bearing); the tree must carry `RXFIX_R1` in `Preamble_Detector.v` **and** `RXFIX_R4D`
   in `Rate_Handle.v`, must **not** carry `RXFIX_R3`/`R3S`/`R4`/`R4B`, and
   `grep 'Delay10_reg\[49331\]' Preamble_Detector.v` must **fail** (the tick-indexed pop is
   gone).
2. **Launch-time:** the binary path and its md5 are echoed into every leg log before the unit
   starts, and the md5 is asserted **different** from the banked R4D binary's.
3. **Runtime (positive, not just "different"):** `pdOcc`. R4D's banked legs show
   `pdOcc_end=12331` (`r4d_m10`), `12332` (`r4d_p10`) and a per-frame envelope
   `12332..12333` on every skip-bearing leg (`r4d_tm10`). Under R1 the FIFO can never fall
   below full once filled, so **`pdOcc` pinned at 12333 (min = max = end) is a positive
   witness that the R1 text is in the binary**, and it is the quantity `pdPof = 0` only
   *looks* like. See §4.

## 3. Banked reference numbers, on BOTH denominators

Nothing here is re-run. `D1` = seq-keyed `score_t7.py` LOSS = `(expect − OK)/expect`,
`expect = hi − lo + 1`, `T7_NAIR=428`. `D2` = the Task-14 honest denominator = the
**424 air frames fed** = `(424 − t7_ok)/424`. D2 carries a **one-frame acquisition floor**
(`b_p000` scores 423/424 = 0.24 % on D2 and 0.00 % on D1); that floor is not a loss.

| leg | D1 (seq-keyed) | D2 (424 air frames fed) | `rhPF` | `pdPof` | `pdOcc_end` | extras |
|---|---|---|---|---|---|---|
| `b_p000` | **0.00 %** (420/420) | 0.24 % (423/424) | 0 | 0 | 12333 | — |
| `r4d_p000` | **0.00 %** (420/420) | 0.24 % (423/424) | 0 | 0 | 12333 | 0 (8 skips) |
| `b_p10` | **4.99 %** (400/421) | 4.95 % (403/424) | 21 | 0 | 12333 | — |
| `r4b_p10` | **6.65 %** (393/421) | 6.60 % (396/424) | 28 | 0 | 12333 | — |
| `r4d_p10` | *refused* (seq range 123) | **70.28 %** (126/424) | **0** | **1** | **12332** | 37 |
| `b_m10` | **10.93 %** (375/421) | 10.85 % (378/424) | 17 | 0 | 12333 | — |
| `r4b_m10` | **0.48 %** (419/421) | 0.47 % (422/424) | 17 | 0 | 12333 | — |
| `r4d_m10` | *refused* (seq range 5) | **98.11 %** (8/424) | 17 | **2** | **12331** | 7 |
| `tb_m10` tiled | 22.01 % (`score_sro2`, golden `tb_p000`) | — | 0 | 0 | — | — |
| `r4b_tm10` / `r4d_tm10` tiled | **0.00 %** (159/159) | — | 0 | 0 | env 12332..12333 | 0 (24 skips) |

`r4b_*_res.txt` reports `r3_extras=2779054082` — that is R4B's `A5A50002` **lock sentinel**,
not a count. In the R4D lineage the same port **is** a count. The two must not be cross-read.

## 4. The gate

Legs: the same seven as Task 14, same stimuli, same `nsamp`, same scorers. Four are **gate**
legs (`p000`, `p10`, `m10`, tiled `tm10`); three (`m40`, `m10c`, `lol`) are **diagnostics** —
they carry 210 / 60 / 17 skips and **zero** extras, so they isolate "does R1 *alone* perturb
anything?" with no `+1` in play. A diagnostic cannot fail the gate; both outcomes are
pre-interpreted in §4.1.

| # | leg | quantity | PASS criterion |
|---|---|---|---|
| **S1** | `r4dr1_p000` | LOSS | **0.00 % on D1** (420/420) and **423/424 on D2** — i.e. no loss beyond the one-frame acquisition floor; `r4d_extras` = 0; `r3_skips` = 8 |
| **S1b** | `r4dr1_p000` | byte-identity vs `r4d_p000` (`_deliv.txt`, `_seq.txt`) | **DIAGNOSTIC, both outcomes admissible — see §4.2.** Not a pass/fail row |
| **S2** | `r4dr1_p10` | LOSS | **≤ 1 % on BOTH denominators** (D1 vs `b_p10` 4.99 % / `r4b_p10` 6.65 % / `r4d_p10` refused; D2 vs 4.95 % / 6.60 % / **70.28 %**) |
| **S3** | `r4dr1_p10` | `rh_push_on_full` | **0** after lock (baseline 21, R4B 28, R4D 0) |
| **S4** | `r4dr1_p10` | PD FIFO | `pdPof` = **0** *(tautological under R1 — see below)* **and** `pdOcc` pinned: per-frame min = max = **12333** on every frame after fill, `pdOcc_end` = 12333 (R4D: 12332) |
| **S5** | `r4dr1_p10` | ring + extras | ring parked at **22/23**; `r4d_extras` ≈ **37**, first ≈ air frame 130, spacing **8** (one per ~8.1 frames) |
| **S6** | `r4dr1_p10` | **FALSIFIER** | **0 losses within ±1 of an extra** (`t11_align.py`, ep kind 5, best constant offset searched as Task 11 did) |
| **S7** | `r4dr1_m10` | LOSS | **≤ R4B's 0.48 % (D1) / 0.47 % (D2)**; the 7-extra 31 → 24 ratchet at frames 11–17 present and **harmless** (framing alive past frame 17, no loss aligned to those extras) |
| **S8** | `r4dr1_tm10` | tiled control | loss **0.00 %** (`score_sro2.py`, golden `tb_p000`, 159/159) |
| **S9** | all | provenance | the three discriminators of §2, on every leg |
| **S10** | `m40`, `m10c`, `lol` | diagnostics | reported, never gating; see §4.1 |

**Why `pdPof = 0` is stated as a tautology.** R1 makes every push-while-full carry its own
pop, so `push_on_full_FIFO` is unreachable *by construction*, whether or not R1 fixed
anything downstream. Presenting `pdPof = 0` as evidence that the deletion mechanism is gone
would be circular. The non-circular quantities are **S2/S6/S7** (does framing survive the
`+1`?) and **S4's `pdOcc` pin** (did the FIFO stay full, i.e. is the R1 text actually in the
binary?).

### 4.1 Diagnostics `m40`, `m10c`, `lol` — both outcomes pre-interpreted

Under R4D these three were **byte-identical to R4B** with zero extras. R1 changes the PD
FIFO's pop on **every** leg, including these, and each carries many skips (210 / 60 / 17),
each of which punches the valid-density hole R1 exists to absorb.

* **Byte-identical to `r4d_*` as well** ⇒ the density holes those skips punch never left the
  FIFO non-full at a push instant, so R1 is inert there. Consistent with Task 6's "R1 has NO
  EFFECT" on the baseline comb.
* **Differs, with LOSS no worse than R4D's** ⇒ R1's occupancy pop repaired the post-skip
  epoch phase. That is R1 working as designed, **not** a build error.
* **Differs, with LOSS worse than R4D's** ⇒ R1 is not neutral on skip-only legs; that is a
  finding against the composition and must be reported as such, even though these rows do
  not gate.

### 4.2 The `p000` identity row is a disjunction, not a pass criterion

`r4d_p000` shows `r3_skips=8`: **R4D is not a no-op on `n_p000`.** Each skip suppresses a pop
and punches exactly the valid-density hole R1's rationale is about, so under R4D the PD delay
is 12,332 valids for one epoch per hole, while under R4DR1 it is 12,333 for ever. **The two
runs are different by construction**, so a byte difference on `p000` would mean R1 is
*working*, not that the build is broken. Both branches, decided in advance:

* **`r4dr1_p000` byte-identical to `r4d_p000`** ⇒ the 8 skips never left the FIFO non-full at
  a push instant on this leg. S1 passes on its own terms.
* **`r4dr1_p000` differs but LOSS is 0.00 % on D1 and 423/424 on D2, with `pdOcc` pinned at
  12333** ⇒ R1 repaired the post-skip epoch phase. **S1 still passes**; the difference is
  reported as R1's signature and quantified (how many seq differ, and whether any is a loss).
* **`r4dr1_p000` LOSS > 0** ⇒ **S1 FAILS**, whatever the byte diff says.

Task 6 gated R1 as "s = 0 byte-identical to **baseline**" — a leg with *no* skips in play —
and on the SRO legs only as **loss-identical frame-for-frame**, never byte-identical. Byte
identity is therefore not inherited here as a pass criterion.

The **smoke leg** (`sk4dr1_p000`, `nsamp=1233300`, 25 air frames) is a free 2.5-minute
pre-test of exactly this row: all **8** of `p000`'s skips fall inside that window
(`sk4d_p000_res.txt`: `r3_skips=8`). Its outcome is compared to the banked `sk4d_p000` and
reported **against the disjunction above**; it does not edit this gate.

## 5. Predictions, stated before the run

* `r4dr1_p10`: extras begin at air frame ~130 and run one per 8 frames to ~422 (**~37**);
  `push_on_full` **0**; `pdPof` **0**; `pdOcc` **pinned at 12333**; and — the whole point —
  framing **survives** every extra, so LOSS lands at the baseline's non-FULL residual,
  predicted **≤ 1 %** on both denominators. If instead the `+1` valid itself is fatal, LOSS
  stays in the tens of percent with `pdPof = 0`, and **S6 fires**.
* `r4dr1_m10`: 7 extras at frames 11–17 ratchet occupancy 31 → 24, then skips take over;
  LOSS ≤ 0.48 % (D1).
* `r4dr1_p000`, `r4dr1_tm10`: zero extras, LOSS 0.00 %; byte-identity to `r4d_*` per §4.2.
* `m40`, `m10c`, `lol`: zero extras, LOSS no worse than R4D's.

## 6. Falsifier and what follows it

**S6 fires** iff losses on `r4dr1_p10` (or `r4dr1_m10`) are aligned to the **extras**
(ep kind 5, ±1 air frame at the best constant offset) while `pdPof = 0` and `pdOcc` is pinned
at 12333. That means the deletion is gone and framing still dies ⇒ **the `+1` valid itself
breaks framing in the Peak_Search / Timing_Adjust epoch spaces**, R1 cannot reach it, and
**S1 is dead** — the FULL-side mirror is not recoverable this way and the reverse leg needs a
different cut (candidate (b)/R4E push-drop, or a lineage with `enSlack`).

If it fires, the report must carry the **per-stage `stagewin` dump around one extra**, built
as Task 11 built `obj_stagewin3s` (`build_stagewin4dr1.sh`, `sim_stagewin.cpp` unmodified,
same wrapper), **naming the first stage whose valid stream or control differs** —
`Peak_Search` epoch vs `Timing_Adjust` — rather than asserting the epoch story.

**A tautology trap is pre-named**, from Task 14 §2.2: `score_t7.py` **refuses** to score a leg
whose framing has collapsed ("SEQ RANGE IMPLAUSIBLE") and a naive bounded rescore reports
**LOSS = 0.00 %**, because unframed deliveries carry no TGEN magic and vanish from the
seq-keyed denominator instead of counting as losses. **Every LOSS in the report is quoted on
both denominators**, and D2 (`t7_ok` / 424) is the one that cannot be gamed this way.

## 7. Rails

Sim only; no board contact; no Vivado; no subagents. `rxfix_inject.py` and its tests are
**not modified** (Task 21 owns that file tonight). `wrap_byte_sro4d.v`, `sim_sro.cpp`,
`sim_stagewin.cpp`, the R4B/R4D trees and every banked baseline are **untouched and not
re-run**. `t11_align.py` gets a **label-only** change (its `KIND[5]` legend says
`r3s_armed`; in the R4D/R4DR1 lineage kind 5 is the **extra pop** — the arithmetic is already
correct and is not touched). Legs run as `systemd-run --user` units `t20_<leg>`; heartbeat
unit `t20hb`. Marker composition `RXFIX_R4D` + `RXFIX_R1`.
