# Task 14 — RXFIX_R4D: the FULL-side mirror works at the ring and destroys the receiver  [sim, desk only]

Brief: coordinator, Task 14 (2026-09-04). Pre-registration `two_jup/comb/RXFIX_R4D_SIM_GATE.md`,
committed **before any R4D code existed** (`3f33e42`). Ledger `progress.md` (`Task 14:`).
**No board contact, no Vivado, no subagents.** Every number is **[sim]**.

## Verdict

**J4 fired. R4D is refuted, and the mirror argument with it.** The extra pop does exactly
what it was designed to do *at the ring* — on `n_p10` it eliminates the FULL edge
completely (`push_on_full` **21 → 28 → 0**) and parks the ring at 22/23 with 37 extras at
the predicted one-per-8.1-frames — and it **destroys the receiver two stages downstream**.
Framing collapses within three air frames of the first extra on both legs where extras
fire: `n_m10` loses **98.1 %** and `n_p10` **70.3 %** of frames, against R4B's 0.47 % and
6.60 %. The losses are aligned to the extras **and** to `pdPof`, the Preamble_Detector
realignment FIFO's `push_on_full`, which is the deletion that does the damage.

**So the pre-registered symmetry claim is false, and the asymmetry has a location.** A
`−1` valid in the guard band is absorbed; a `+1` is not. It is not the deframer that
cannot take it — it is the **12,333-deep Preamble_Detector realignment FIFO**, whose pop is
**tick-indexed** and which therefore sits *at* its full threshold in steady state.

## 1. The mechanism, and it was already written down

`Preamble_Detector.v` pops its realignment FIFO on `Delay10_reg[49331]` — the symbol valid
delayed **49,332 enb ticks** — which equals 12,333 *valids* only while the valid density is
exactly 1-in-4. The injector's own R1 header says this, for the `−1` direction. R4D
demonstrates the `+1` direction:

* the FIFO's occupancy sits **at** 12,333 (its full threshold) in steady state;
* an extra valid is one extra **push** into a full FIFO → `push_on_full` → **the symbol is
  deleted**;
* Peak_Search counts valids on the **undelayed** chain and Timing_Adjust on the **delayed**
  chain, comparing against Peak_Search's `timingOffset`; a deletion on the delayed chain
  moves the phase between the two epoch spaces **permanently**;
* framing never recovers.

The `−1` case does not delete: the FIFO simply runs one entry short and the tick-scheduled
pop still fires — `pd_pop_on_empty` is **0 on every leg of this gate and of Task 12b**.
That is the whole asymmetry, in one FIFO.

| leg | first extra | `pdPof` (PD-FIFO push_on_full) | last framed frame | true LOSS |
|---|---|---|---|---|
| `r4d_m10` | air frame **11** | frames **11, 13** | **13** | **98.1 %** (416 of 424) |
| `r4d_p10` | air frame **130** | frame **130** | **132** | **70.3 %** (298 of 424) |

`pdPof` is **0 on every other leg of this gate and every leg of Task 12b** — it appears
only, and exactly, where an extra pop fires. One event on `n_p10`, two on `n_m10`; after
the first deletion the FIFO is no longer full, so later extras do not repeat it, but the
epoch damage is already permanent.

## 2. The gate table

| # | leg | criterion | measured | |
|---|---|---|---|---|
| J1 | `n_p10` | LOSS ≤ 1 % | **70.3 %** (framing destroyed; baseline 4.95 %, R4B 6.60 %) | **FAIL** |
| J2 | `n_p10` | `push_on_full` = 0 | **0** (baseline 21, R4B 28) | **PASS** |
| J3 | `n_p10` | ring self-centred from above; extras ≈ one per 8.1 frames | plateau **22/23** (178 of 248 frames); **37 extras** at frames 130, 138, 146 … 422 — spacing **8** | **PASS** |
| **J4** | `n_p10` | **falsifier**: no loss aligned to an extra | **FIRED** — framing dies 3 frames after the first extra, and the `pdPof` deletion is in the same air frame | **FALSIFIER FIRED** |
| J5 | `n_p000` | content identity, `r4d_extras` = 0 | **0 extras**; delivered stream **byte-identical to R4B**; LOSS 0.00 % | **PASS** |
| J6 | `n_m40`, tiled, `n_m10c`, `lol` | byte-identical to R4B, 0 extras | `_deliv.txt` **and** `_seq.txt` **byte-identical** on all four (and on `n_p000`); `r4d_extras` = 0 on all five | **PASS** |
| J7 | `n_m10` | ratchet 31 → 23 by extras after lock | **7 extras**, frames **11–17**, one per frame, occupancy **31 → 24**, every one at window slot 2 | **PASS** (measured 31→24, predicted 31→23) |
| J8 | `n_m10` | LOSS ≤ R4B's 0.47 % | **98.1 %** | **FAIL** |
| J9 | all | events inside `[pcEnd+1, pcEnd+13]`, clustered on modal `tref` | **every skip and every extra** at slot 1–3; `n_m10` extras all slot 2, tref 21/22; `n_p10` extras slot 2 | **PASS** |
| J10 | all | wrapper provenance | `WRAP4D_FILE wrap_byte_sro4d.v t14` + `WRAP4D_DEFINE RXFIX_R4D` on **all seven** legs | **PASS** |
| J11 | injector | W1+R4D kit-shaped, lint | 135 tests green; `verify_zip` green both variants both zips; lint 0 errors on 4 trees | **PASS** |

**Counted three ways on every leg** — trace lines by `kind`, `r3_skips`/`r3_extras` in
`_res.txt`, and kind-4/kind-5 records in `_ep.txt` — all agree:

| leg | skips | extras |
|---|---|---|
| `r4d_p000` | 8 | **0** |
| `r4d_m10` | 37 | **7** |
| `r4d_m40` | 210 | **0** |
| `r4d_tm10` | 24 | **0** |
| `r4d_m10c` | 60 | **0** |
| `r4d_p10` | 7 | **37** |
| `r4d_lol` | 17 | **0** |

### 2.1 J6 is the pre-registration's structural prediction, confirmed exactly

§1 of the pre-registration measured, from banked Task 12b data, that the `≥ 24` predicate
can never be true after lock on five of the seven legs (max `oMax` = 10 on each). Those
five legs came back **byte-identical to R4B in both `_deliv.txt` and `_seq.txt`** — 424,
424, 164, 425 and 414 lines respectively, `cmp` clean. The RTL text predicted the bytes.

### 2.2 A scoring trap, named

`score_t7.py` **refuses to score** `r4d_m10` and `r4d_p10` ("SEQ RANGE IMPLAUSIBLE") and a
naive bounded rescore reports **LOSS = 0.00 %** on both — because once framing collapses
the delivered frames carry **no TGEN magic at all**, so they vanish from the seq-keyed
denominator instead of counting as losses. The honest denominator is the **424 air frames
fed**: `t7_ok` = 8 of 424 on `n_m10` and 126 of 424 on `n_p10`. Anyone reading only the
bounded rescore would conclude R4D was perfect on exactly the two legs it destroyed.

## 3. Candidate (b) is NOT cut, and should not be

The pre-registration's fallback was (b): drop a **push** instead of adding a pop, scheduled
to land in the next window. **It is not cut**, per the coordinator's instruction, and the
evidence says it would not help: the damage is a deletion in the **PD realignment FIFO**,
and (b) removes an entry from the **Rate_Handle** ring — a different FIFO two stages
upstream. (b) changes which ring is short, not the 1-in-4 valid density the PD FIFO's
tick-indexed pop depends on. Any `+1`/`−1` at Rate_Handle propagates one-for-one into that
density (Task 11 §5 measured exactly that), so (b) faces the same wall from the other side.

## 4. The right fix is `enSlack` — and it does not exist in the sim lineage

The coordinator identified it precisely: the PD FIFO's existing **slack** path, `enSlack`
= `fixctl` bit 3 (register 0x208), which makes the FIFO **tolerate one extra entry instead
of dropping a push**. That is aimed exactly at the deletion measured above.

**Blocker, stated precisely.** The lineage this entire gate runs on — `s1_rtl` — **has no
slack path and no `fixctl` port at all**:

```
s1_rtl   Validate_Input_Push_Pop.v:131  assign push_on_full_FIFO = Logical_Operator5_out1 & Compare_To_Constant1_y;
F3       Validate_Input_Push_Pop.v:136  assign push_on_full_FIFO = Logical_Operator5_out1 & Compare_To_Constant1_y & ( ~ enSlack);
```

`enSlack` appears in **0** files of `s1_rtl` and in **6** of `s1_rtl_txfix_F3`
(`FIFO.v`, `FixCtlDec.v`, `Preamble_Detector.v`, `Frequency_and_Time_Synchronizer.v`,
`Validate_Input_Push_Pop.v`, `QPSK_Rx.v`). F3's `TxRxComposite` also carries eight ports
`s1_rtl` lacks (`fixctl`, `ddrcap_*`, `beatfix_*`).

So "drive `fixctl[3] = 1` in the wrapper" cannot be done on the tree in use. The experiment
is runnable, but it is **not the two ≤ 70-min legs budgeted**; it needs:

1. a **new wrapper** driving `.fixctl(32'h8)` (the current one is shared with the seven
   s1_rtl legs and must not move);
2. the **first-ever F3 sim build** — F3 has only ever been linted, never simulated, and its
   eight extra top-level ports need sensible tie-offs;
3. its **own control**, an F3 + R4D leg with `fixctl[3] = 0`, because **no F3 baseline
   exists** — every baseline in this gate (`b_p10`, `b_m10`, `b_p000` …) is `s1_rtl`, so an
   F3 number is not comparable to any of them;
4. therefore **four legs**, not two, plus a build.

**Not launched.** Substituting a different lineage and a doubled leg count for the
authorised experiment without saying so is exactly the kind of silent switch that produced
the withdrawn R4C proposal. It is pre-registered here and ready to launch on a word.

## 5. What R4D did establish, and what it costs

* **The FULL edge is controllable from Rate_Handle.** `push_on_full` went to **zero** on
  the leg that has a FULL-edge comb, and the ring parked where it was aimed. If the PD-FIFO
  deletion is fixed (`enSlack`), the mirror is the right shape.
* **The structural window is sound in both directions.** Every one of the 44 extras landed
  inside `[pcEnd+1, pcEnd+13]`, at slot 2, clustered on the leg's modal `tref` — the window
  machinery did its job; it is the *stage downstream* that cannot take the `+1`.
* **R4B remains the only shippable steering**, forward-only, exactly as Task 12b concluded
  and as the controller's 148-only GO already assumes. R4D must **not** be flashed to 146:
  it is far worse than doing nothing.

## 6. Rails

Sim only; no board contact; **no 146 flash**. R4B, Task 12's R4, R3S and Task 7's
`sim_sro.cpp` untouched. Commits: `3f33e42` (pre-registration, before any code), `023ae70`
(variant + legs), the witness-width fix, and this report.
