# RXFIX_R4E — sim gate PRE-REGISTRATION  [sim, desk only]

Task 21 (brief `task-21-brief.md`, 2026-09-04 night-2 plan). **R4E = R4B unchanged on the
EMPTY side + the FULL side's TRUE mirror of the natural event: a DROPPED PUSH, scheduled
so that the symbol that vanishes is a guard-band symbol.** Committed **before any R4E code
exists** — no injector edit, no wrapper, no build, no leg. Ledger `Task 21:`.
No board contact, no Vivado, no subagents. Every number below is **[sim]**.

---

## 0. Why a dropped push and not another extra pop

The natural FULL-edge event is `Validate_Input_Push_Pop_block.v:129`
`push_on_full_FIFO = Logical_Operator5_out1 & Compare_To_Constant1_y` — a push arriving at
occupancy 32 is **silently discarded**: no RAM write, no `Push_Counter` advance, **and no
change to the pop side at all**. So the observable is: *the popped valid density is
unchanged and one payload symbol has vanished from the stream, at whatever position in the
frame the ring happened to be full.* That deletion lands mid-payload and kills the frame.

R4E does the same deletion **on purpose, at a chosen position**. It is the mirror of the
natural event in *shape*, which R4D's extra pop was not:

| | pops emitted | valid density downstream | ring entry | what moves |
|---|---|---|---|---|
| natural `push_on_full` | unchanged | **unchanged** | −1 | one symbol vanishes, random position |
| R4B skip (EMPTY side) | **−1** | **−1** | +1 | one output slot is not filled |
| R4D extra pop (refuted) | **+1** | **+1** | −1 | one extra valid → PD FIFO `push_on_full` → **framing dies** |
| **R4E drop (this gate)** | unchanged | **unchanged** | −1 | one symbol vanishes, **chosen** position |

### 0.1 Task 14 §3 says this variant will not help. That reasoning is wrong, and here is why

Task 14 §3 declined to cut candidate (b) and added: *"(b) removes an entry from the
**Rate_Handle** ring — a different FIFO two stages upstream. (b) changes which ring is
short, not the 1-in-4 valid density the PD FIFO's tick-indexed pop depends on. Any `+1`/`−1`
at Rate_Handle propagates one-for-one into that density, so (b) faces the same wall from
the other side."*

The last sentence is false for a **push** drop, and the table above is the reason. A `+1`/`−1`
**pop** propagates into the density; a dropped **push** does not touch the pop side. The pop
is `Rate_Handle.v:95` `validIn & (HDL_Counter_out1 == 0)` — a rigid mod-4 beat that knows
nothing about the ring — and `valid_pop = pop & ~pop_on_empty`, so as long as the ring is
non-empty (R4E fires only at occupancy ≥ 24 of 32) **every pop that would have fired still
fires**. `validOut` is bit-for-bit the same sequence of beats; only *which* symbol rides
each beat changes.

So R4E's downstream footprint is **strictly smaller than R4B's**, which removes a valid pop
(density −1) and measured `pdPof = 0` on all seven legs of Task 12b and all seven of Task
14. **K5 is the row that settles it**: `pdPof = 0` and `pdOcc` flat at 12333 on every leg.
If K5 fails, Task 14 §3 was right after all and R4E is refuted with it.

---

## 1. THE DROP-SCHEDULING FORMULA, derived from the pointer arithmetic

Anchors: `FIFO_block.v:120-143` (Push_Counter), `:155-178` (Pop_Counter), `:180-192` (the
32×16 dual-port RAM, `wr_addr = Push_Counter_out1`, `rd_addr = Pop_Counter_out1`);
`Validate_Input_Push_Pop_block.v:103-113` (`Delay_out1`, the registered occupancy),
`:119` (`pop_on_empty`), `:129` (`push_on_full`), `:135/137` (`valid_push`/`valid_pop`);
`MATLAB_Function_block2.v` (the up/down counter behind `Delay_out1`).

**Fact 1 — FIFO order.** `Push_Counter` advances **only** on `valid_push` and
`Pop_Counter` **only** on `valid_pop`, both mod-32, and the RAM is written at the
pre-increment push pointer and read at the pop pointer. Occupancy never exceeds 32 (the
`push_on_full` guard), so no address aliases a live entry. **The symbol pushed as valid
push index `p` is popped as valid pop index `p`.**

**Fact 2 — the occupancy net is exact, not stale.** `Delay_out1 <= count` under
`enb_1_2_0_gated`, and `count` is `MATLAB_Function_block2`'s `countReg_temp` — the
*combinational next state*, which already includes the current tick's
`valid_push ^ valid_pop`. Hence `Delay_out1 == countReg` at all times and

> **`O(t) := Delay_out1(t) = P(<t) − Q(<t)`**, where `P(<t)`/`Q(<t)` are the validated
> pushes/pops at ticks **strictly before** `t`.

**Fact 3 — where a dropped push shows up in the output.** Suppress the push at tick `t`.
It would have been valid push index `P(<t)`, hence valid pop index `P(<t)` — and the pops
at ticks `≥ t` are indexed `Q(<t), Q(<t)+1, …`. So the vanished symbol would have been
emitted on the

> **`(P(<t) − Q(<t) + 1) = (O(t) + 1)`-th validated pop at ticks ≥ t.**

**Fact 4 — the landing slot.** Let `T` be the tick of the `Packet_Controller.endOut`
pulse that opens the structural window, and let

> **`m` := the number of validated pops in the closed interval `[t, T]`.**

The window's slot `k` is the `k`-th pop opportunity after `T` (R4B's convention; `k = 1` is
the first, at `dt_enb = 3`). The slot-`k` pop is therefore the `(m + k)`-th pop from `t`,
and equating with Fact 3:

> ## `k = O(t) + 1 − m`      ⇔      `m = O(t) + 1 − k`
>
> **A push dropped at tick `t` vanishes from window slot `k = O(t) + 1 − m`.**
> **In-window (`1 ≤ k ≤ 13`) requires `O(t) − 12 ≤ m ≤ O(t)`.**

### 1.1 Corollary: the decision CANNOT be taken at pcEnd — this is why a period register exists

Read Fact 4 the other way. At the pcEnd tick itself (`m = 0`), the symbol that will be
popped at slot `k` was pushed `O − k` **pushes ago**:

> at pcEnd, slot `k`'s symbol is the one pushed `(O − k)` pushes back —
> **not** `(O − 1 + k)` as the brief's sketch has it.

With the FULL-side predicate `O ≥ 24` and `k ∈ [1,13]` that is **11 to 23 pushes in the
past**. There is nothing left to drop. The drop must be taken `m = O + 1 − k` **validated
pops before a pcEnd that has not happened yet**, i.e. **12 to 31 pops (≈ 48–124 enb ticks)
ahead of it** — so R4E must *predict* the next pcEnd.

No structural signal sits ~24 pops before `pcEnd`: `Packet_Controller.startOut` is at the
far end of the packet (~12,320 pops earlier) and `pcEnd` is the only once-per-packet pulse
in the receive chain. The prediction therefore has to come from the **frame period**, and
the only honest source for that is **measurement**:

> `r4e_period` := the number of validated pops between the last two `pcEnd` pulses,
> latched at each `pcEnd`; `r4e_pcnt` := validated pops since the last `pcEnd`.
> Predicted `m` at any tick is `m̂ = r4e_period − r4e_pcnt`, and
> **`k̂ = O + 1 − r4e_period + r4e_pcnt`.**

Both counters are in **validated pops**, the unit Facts 1–4 are in.

### 1.2 The arm condition, with its asymmetric margin stated in advance

`k̂` **increases** with time (`r4e_pcnt` increases). Every source of staleness therefore
pushes the realised `k` **upward**, never down:

* the compare is registered (1 tick), the decision is registered (1 more tick) — up to 2
  enb ticks, i.e. up to 1 validated pop, between the sampled `r4e_pcnt` and the fire;
* the drop fires on the **first strobe** at or after the arm, and strobes come ~1 per 4 enb
  ticks — up to ~1 further pop;
* a push landing in that gap raises `O` by 1.

So the arm band is **deliberately asymmetric**, centred low:

> **arm ⇔ `r4e_pcnt + O ≥ r4e_period + 6` **and** `r4e_pcnt + O ≤ r4e_period + 10`**
> i.e. **`k̂ ∈ [7, 11]`**, realised `k` predicted in **[7, 13]**, hard requirement **[1, 13]**.

**Declared branch, written before the smoke is read:** if the smoke landing histogram
(§4.1) shows **any** `k ≥ 13`, the target is re-centred to `k̂ ∈ [5, 9]` (`+4 … +8` instead
of `+6 … +10`) and the smoke is re-run before the sweep. That is a declared adjustment,
not a silent tune, and the report will say which band the sweep ran with.

### 1.3 The landing slot is MEASURED, not assumed

The witness does not report `k̂`. At the drop, `r4e_land_a <= r4e_pcnt` and
`r4e_land_occ <= r4e_occ`; at the **next** `pcEnd`, `m = r4e_pcnt − r4e_land_a` (the pops
actually taken in `[t, T]`, since `r4e_pcnt` is cleared at `pcEnd` and read before the
clear) and the witness records **`k = r4e_land_occ + 1 − m`**, clamped to 4 bits, with
out-of-`[1,13]` events counted separately. `wrap_byte_sro4e.v` recomputes the same quantity
from taps that share **no net** with the R4E logic (§3.1).

---

## 2. The RTL, in words (to be written only after this file is committed)

Five core files, exactly R4B's set, plus R4B's conditional witness carry chain:
`Validate_Input_Push_Pop_block.v`, `FIFO_block.v`, `Rate_Handle.v`,
`Symbol_Synchronizer.v`, `Frequency_and_Time_Synchronizer.v` (+ `QPSK_Rx.v`, `Receiver.v`,
`TxRxComposite.v`, `TxRxCompo_ip*` when `RXFIX_W1` is present). **No new IP port**;
`_PFX`-tolerant anchors so all three lineages take it.

**R4E CONTAINS R4B.** The variant is a **clone** of R4B, not a stack: the EMPTY-side skip
block (`r4e_pop_nom`, `r4e_locked`, `r4e_win`, `r4e_wslot`, `r4e_skip_done`, `r4e_skip_en`,
`r4e_skips`, `r4e_opens`) is R4B's text with the prefix changed, so the skip side is
provably unchanged and K1/K6 are predictions about the RTL text. `_r4e_guard` refuses
R3/R3S/R4/**R4B**/R4D and all five of those gain `MARKER_R4E`.

Added on the FULL side, all inside the same `enb_1_2_0`-gated, async-reset process:

* `r4e_pop_val = FIFO_validPop` — the ring's **own** validated pop (an existing wire).
* `r4e_pcnt[13:0]`, saturating at `14'h3FFF`: `+1` per validated pop, reloaded at
  `r4e_pcend_d` with the current tick's pop.
* `r4e_period[13:0]`, `r4e_per_ok`: latched at `r4e_pcend_d`; `per_ok` iff the measured
  period is in `[64, 16382]` (a missed `pcEnd` saturates `pcnt`, which both fails `per_ok`
  next frame and can never satisfy the arm band).
* `r4e_occ_ge24 <= (r4e_occ >= 6'd24)` — registered, like R4B's `occ_le8`.
* `r4e_sched_lo/_hi` — the two registered 15-bit compares of §1.2.
* `r4e_drop_en` — **registered decision**: `locked & per_ok & occ_ge24 & ~drop_done &
  sched_lo & sched_hi`, cleared by the drop itself; `drop_done` cleared at `pcEnd`, so
  **at most one drop per pcEnd**.
* the drop itself: `r4e_do_drop = r4e_drop_en & strobe`, and the FIFO is instantiated with
  **`.push(strobe & ~r4e_drop_en)`** — structurally `strobe` until the first arm, exactly as
  R4B's pop is structurally the baseline expression until its first arm. **R4E fails toward
  BASELINE.**
* landing measurement (§1.3) and the witness counters.

Nothing combinational is added to the pop: `Logical_Operator_out1` is R4B's line verbatim.
The only new combinational term on the push is `~r4e_drop_en`, a flop output.

### 2.1 The TENTH read word, 0x238 — and its stated deviation

`r4eWit` is **64 bits**, R4D's shape: word 0x234 = `{r4e_locked, r4e_skips[15:0],
r4e_opens[14:0]}` (R4B's layout, unchanged) and word **0x238** =

| bits | field | meaning |
|---|---|---|
| 15:0 | `r4e_drops[15:0]` | dropped pushes since reset |
| 19:16 | `r4e_land_last[3:0]` | landing slot of the most recent drop |
| 23:20 | `r4e_land_min[3:0]` | smallest landing slot seen (init 15) |
| 27:24 | `r4e_land_max[3:0]` | largest landing slot seen (init 0) |
| 31:28 | `r4e_land_out[3:0]` | saturating count of drops landing outside [1,13] |

**Deviation, stated not buried.** The brief asks for a `r4e_land_slot` **histogram** in one
32-bit word. A 13-bin histogram does not fit beside a 16-bit counter, so the on-silicon
form is the **order statistic**: last / min / max / out-of-window count. `land_out ≠ 0` is
the silicon falsifier and `min ≥ 1, max ≤ 13` is the silicon pass; the full 13-bin
histogram is produced in sim by the wrapper trace (§3.1), where it is affordable. Slot 0
encodes "landed at or before the pcEnd" and 15 encodes "≥ 15"; both are counted in
`land_out`. `W1_REGMAP.md` gains a **§6** with this map, the deviation and the changed
at-rest expectations.

---

## 3. Harness

`wrap_byte_sro4e.v`, **cloned from `wrap_byte_sro4d.v`** — a **sixth** file declaring
`module wrap_byte_sro`, so it prints `WRAP4E_FILE` / `WRAP4E_DEFINE` at time 0 and
`build_sro_rxfix4e.sh` greps the verilate log for the **other five**. `sim_sro.cpp` links
**unmodified** (that is what makes the content-identity rows a test of the RTL and not of a
re-typed driver). Object dir `obj_byte_sro_rxfix4e`. Witnesses on Task 7's three ports:
`r3Skips = r4e_skips`, `r3Extras = r4e_drops` (so `<p>_ep.txt` **kind 5** timestamps every
drop), `r3Guard = Packet_Controller_endOut`.

### 3.1 The trace, and what makes the recount independent

`+r4ewin=<path>` (argv[8], past everything `sim_sro.cpp` parses) receives one line per
event:

```
n,sidx,beat,slot_rtl,slot_harness,dt_enb,occ,tref,locked,opens,kind[,land_rtl,land_harness,m,occ_at_drop]
```

`kind 0` = steered **skip** (R4B side, unchanged columns), `kind 1` = steered **drop**.

The drop's landing slot is recomputed in the wrapper from **`fifoPush`/`fifoPop`,
`fifoVPop` and `pcE`** — occupancy as **`(fifoPush − fifoPop) mod 32`**, which is
unambiguous over `[24,31]` where drops fire and which shares **no net** with `r4eOcc`
(`Delay_out1`). That is the difference from a naive recount: Task 12b's 356/356 agreement
row used `rhValidIn`/`rhPhase`/`pcE`, and reusing `occTrue` here would have shared the
RTL's own occupancy source.

### 3.2 A measured precondition, not an assumption: the pcEnd period

The whole schedule rests on the pcEnd-to-pcEnd interval in **validated pops** being stable
to a few counts. That is inferred (12,333 pops/frame; `dt_enb = 4·slot − 1` on 356 R4B
skips) but **has never been measured**. `wrap_byte_sro4e.v` therefore emits, to
`<p>_period.txt`, one line per `pcEnd` carrying the interval in validated pops, and the
**smoke leg is not passed until** the interval's spread (max − min, after lock) is
**≤ 6**. If it is wider than 6 the landing slot walks out of `[1,13]` for reasons that have
nothing to do with the mechanism, and the schedule needs a different predictor — that would
be reported as a blocking finding, not worked around.

---

## 4. Legs, and the two gated preconditions before the sweep

Seven legs, the Task 12b/14 set, stimuli already on disk, **no baseline re-run**
(`b_p000`/`b_m10`/`b_m40`/`tb_m10` Task 7, `t_lol` Task 6, `b_m10c`/`b_p10` Task 12b, and
R4B's own `r4b_*` streams are the identity references):

| tag | stimulus | nsamp | prefix |
|---|---|---|---|
| p000 | `n_p000.iq` | 21,114,096 | `r4e_p000` |
| m10 | `n_m10.iq` | 21,114,096 | `r4e_m10` |
| m40 | `n_m40.iq` | 21,114,096 | `r4e_m40` |
| tm10 | `s_m10.iq` | 8,139,780 | `r4e_tm10` |
| m10c | `n_m10c.iq` | 21,114,096 | `r4e_m10c` |
| p10 | `n_p10.iq` | 21,114,096 | `r4e_p10` |
| lol | `s_m2p5_lol.iq` | 20,519,440 | `r4e_lol` |

Units `t21_<leg>` via `systemd-run --user`; heartbeat `t21hb`.

### 4.1 Precondition A — the smoke leg is `n_m10`, not `n_p000`

At 0 ppm the ring never reaches 24 after lock (§4.2), so an `n_p000` smoke exercises
**zero drops** and would prove nothing about the drop path. `n_p10` reaches 24 only at
frame ~129. **`n_m10` sits at `oMax = 31` from lock (frame 11) through frame 73**, so a
~25-air-frame `n_m10` smoke hits the 31→23 ratchet immediately. The smoke must show:

1. `WRAP4E_FILE`/`WRAP4E_DEFINE` provenance;
2. period spread ≤ 6 after lock (§3.2);
3. every landing slot in `[1,13]` on **both** counters, and the `k ≥ 13` branch of §1.2
   applied if not;
4. drops counted three ways (trace lines of kind 1, `r3_extras` in `_res.txt`, kind-5
   records in `_ep.txt`).

### 4.2 Which legs can differ from R4B at all — measured from banked data, before the run

Maximum ring occupancy **after lock**, recomputed from the banked Task 12b `_frames.txt`
(cols 23/24 = `oMin`/`oMax`):

| leg | lock frame | max `oMax` after lock | frames with `oMax ≥ 24` | R4E vs R4B |
|---|---|---|---|---|
| `n_p000` | 13 | **10** | 0 | **cannot differ** |
| `n_m40` | 19 | **10** | 0 | **cannot differ** |
| `s_m10` tiled | 10 | **10** | 0 | **cannot differ** |
| `n_m10c` | 13 | **10** | 0 | **cannot differ** |
| `s_m2p5_lol` | 10 | **10** | 0 | **cannot differ** |
| `n_m10` | 11 | **31** | 63 (frames 11–73) | short ratchet, then a shifted skip side |
| `n_p10` | 13 | **32** | 300 (frames 129–428) | **the leg the variant is for** |

On five of seven legs the `≥ 24` predicate is never true after lock, so R4E ≡ R4B
**structurally** and byte-identity there is a prediction about the RTL text.

---

## 5. The gate

| # | leg | quantity | PASS criterion |
|---|---|---|---|
| **K1** | `n_p000` | content identity with **R4B** | `_deliv.txt` **and** `_seq.txt` byte-identical to `r4b_p000`; `r4e_drops = 0`; occupancy never ≥ 24 after lock |
| **K2** | `n_p10` | LOSS | **≤ 1 %** on **both** denominators — the seq-keyed one (`score_t7.py`, `T7_NAIR=428`) **and** air-frames-fed (`t7_ok / 428`), raw counts quoted. Baseline `b_p10` **4.99 %**, R4B **6.65 %** |
| **K3** | `n_p10` | `push_on_full` after lock | **0** (baseline 21, R4B 28) |
| **K4** | `n_p10` | drops | **~37**, one per **~8.1** frames; **every** drop's measured landing slot in **[1,13]** on both counters (histogram reported); occupancy plateau **22/23** |
| **K5** | all | PD realignment FIFO | **`pdPof = 0`** and `pdOcc` flat at **12333** on **every** leg — the row that answers Task 14 §3 |
| **K6** | `n_m10`, `n_m40`, tiled, `n_m10c`, `lol` | vs **R4B** | byte-identical (`_deliv.txt` and `_seq.txt`) wherever the ring never reaches 24 after lock (m40/tm10/m10c/lol); on `n_m10`, a short **31 → 23** ratchet by drops in frames 11–19 and then the same steering, with LOSS **≤ R4B's 0.48 %** |
| **K7** | all | three-way witness agreement | trace lines by `kind` = `r3_skips`/`r3_extras` in `_res.txt` = kind-4/kind-5 records in `_ep.txt`, on every leg |
| **K8** | all | **FALSIFIER** | **fires** if any lost frame is within ±1 air frame of a drop beyond R4B's own losses, **or** if K2 > 3 % while K3 and K4 pass. Either means a guard-band push drop still kills the frame ⇒ per-stage `sim_stagewin` dump around one drop, and R4E is refuted |
| K9 | all | wrapper provenance | `WRAP4E_FILE wrap_byte_sro4e.v t21` + `WRAP4E_DEFINE RXFIX_R4E` on every R4E leg, and no other `wrap_byte_sro` file in the verilate log |
| K10 | all | the two edges never collide | **no air frame carries both a skip and a drop.** `occ ≤ 8` and `occ ≥ 24` in one frame needs a 16-entry swing; post-lock the ring moves at 0.1233 entries/frame, so this is structurally impossible and `r4e_period` cannot be contaminated by a skipped pop |
| K11 | injector | W1+R4E kit-shaped | `verify_zip` green for **both** variants on **both** zips of a kit-shaped tree; `RXFIX_W1` **and** `RXFIX_R4E` present; the prefix hazard (`RXFIX_R4`/`RXFIX_R4B` vs `RXFIX_R4E`) tested as test 113 tested R4B's |
| K12 | injector | lint | `verilator --lint-only`: **0 errors** on R4E alone and W1+R4E, on **both** lineages (`s1_rtl`, `s1_rtl_txfix_F3`), 0 warnings on any `r4e_` net; four logs banked |

---

## 6. Predictions, stated before the run

* **`n_p10`** — drops begin once the ring first reaches 24 after lock (**frame ~129** by the
  banked trajectory), then one per **8.1** frames to the end → **~37 drops**;
  `push_on_full` → **0**; occupancy parks at **22/23**; LOSS → the baseline's non-FULL
  residual, **≤ 1 %** on both denominators. Landing slots clustered at **7–11**.
* **`n_m10`** — **~8 drops** in frames 11–19 ratcheting 31 → 23, then none until the ring
  drains below 24 (it does not: it keeps draining). The ring then reaches the skip
  threshold **~58 frames earlier** than R4B, so skips start ~frame **133** instead of 191
  and there are **~36** of them (R4B: 30). LOSS unchanged at ~**0.48 %**.
* **`n_p000`, `n_m40`, `s_m10`, `n_m10c`, `s_m2p5_lol`** — **zero drops**, byte-identical
  to R4B in both `_deliv.txt` and `_seq.txt`.
* **`pdPof = 0` on all seven legs**, and `pdPopEmpty` unchanged from R4B.
* The pcEnd period in validated pops: **12,333** modally, spread ≤ 6 after lock.

---

## 7. Scoring conventions, fixed in advance

* **`T7_NAIR=428` is exported in the scoring script.** `score_t7.py` does
  `nair = int(os.environ.get('T7_NAIR','0')) or None` — **unset, the "SEQ RANGE
  IMPLAUSIBLE" refusal never runs** and a collapsed leg scores as a plausible number. That
  is the trap Task 14 §2.2 named, and it is a silent-pass hazard, not a preference.
* Every LOSS row is reported as **raw counts on both conventions**: the seq-keyed span
  (`expect`, `ok`, `corrupt`, `missing`) and the air-frames-fed one (`t7_ok` of **428**).
  Not two percentages.
* `n_m40`'s seq range is bounded to the 432 frames the TGEN emitted, as Task 12b §6.3 did,
  and both numbers are quoted.
* A `kind` caveat, recorded now so it is not rediscovered as a bug: `sim_sro.cpp:331-336`
  assigns **one** kind per beat with priority `rhPopEmpty(0) → skip(4) → extras(5)`, so a
  drop coinciding with a skip or a `pop_on_empty` loses its kind-5 record. K10 says the
  first cannot happen and the FULL side excludes the second; if K7 mismatches by **exactly**
  the coincidence count, this is the reason.

---

## 8. Rails

Sim only; **no board contact**, no Vivado, no subagents. R4B, R4D, R4, R3S, Task 7's
`sim_sro.cpp` and every wrapper before `wrap_byte_sro4e.v` are untouched. `rxfix_inject.py`
is shared with Task 20 (R1 on an R4D tree): commit early, rebase on conflict, never
force-push, never `git add` a directory. Commits are `-s` with the session trailer; ledger
lines are `Task 21:`. Report: `two_jup/sdd_archive/2026-09-04-rxfix/task-21-report.md`.
