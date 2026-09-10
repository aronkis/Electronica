> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_R4_SIM_GATE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX_R4 — pre-registered sim gate  [sim, desk only]

Task 12, brief `two_jup/sdd_archive/2026-09-04-rxfix/task-12-brief.md`, ledger
`two_jup/sdd_archive/2026-09-04-rxfix/progress.md` (`Task 12:` lines), branch
`per-under-1pct-2026-07`.

**Written and committed BEFORE any Task 12 leg was started.** Every number in §2 is a
criterion taken **verbatim from the brief**; every number in §3 is my own prediction,
also written before any leg ran, so neither can be argued after the fact. The measured
column is filled in `task-12-report.md` and nowhere else. No board contact, no Vivado,
no subagents.

## 0. What is being tested

R4 = R3S's skip-only guard-band steering with two changes:

1. **Pre-fill.** After reset every Rate_Handle pop is suppressed until the registered
   ring occupancy has reached 16 once (`r4_prefilled`, a sticky flop). Cost: a
   constant ~16 symbols of latency.
2. **Steering armed by `r4_prefilled` and lock**, not by the first post-lock hole:
   while pre-filled and locked, the first nominal pop inside the deframer's
   inter-frame guard window at **occupancy ≤ 8** is suppressed, at most once per
   window. Nothing on the FULL side.

**The mechanism under test, stated so it can fail.** R3S's *entire* residual loss on
every SRO leg — beyond Task 7's already-recorded seq 133/134 pair — was the two frames
straddling the one EMPTY-edge hole that had to happen before `r3s_armed` could be set.
If R4's operating point and threshold are right, that hole never happens: the ring is
steered off the EMPTY edge *before* it reaches it, `rh_pop_on_empty` in the scored
window is **0** (not merely small), and the straddling-frame losses disappear.

**What pre-fill is for, corrected against Task 7's banked data — see §3.** The brief
says pre-fill makes "the steady-state occupancy ~16 regardless of the acquisition
transient". That is **false on `b_m10`** and I say so before running rather than after.
Pre-fill's real job is to lift the **s = 0** operating point from occupancy 1/2 to
16/17, which is what makes a bare `occ ≤ 8` predicate inert at zero SRO — precisely
the property R3's bare occupancy predicate lacked, and the reason R3S needed an arming
event at all. The `occ ≤ 8` threshold then does the steering *wherever acquisition
happens to leave the ring*.

## 1. Legs, binaries and stimuli

Binary for every leg: `jupiter_240k5_byte/rtl_sim/obj_byte_sro_rxfix4/Vwrap_byte_sro`
= the R4 tree (`s1_rtl_rxfix_R4`) + Task 11's per-stage-tap wrapper re-cut as
`wrap_byte_sro4.v` + **Task 7's `sim_sro.cpp`, unmodified**. Command shape:
`Vwrap_byte_sro rx <iq> <nsamp> 8400 <pfx> 2 0`, one transient
`systemd-run --user` unit each (`t12_<leg>`) with
`WorkingDirectory=two_jup/comb/sro_sim`.

| leg | prefix | stimulus | nsamp | scorer | banked baseline |
|---|---|---|---|---|---|
| 0 ppm | `r4_p000` | `n_p000.iq` (non-repeating) | 21,114,096 (428 fr) | `t12_ident.py` (seq-keyed) + `score_t7.py` | `b_p000` LOSS 0.00 % |
| −10 ppm | `r4_m10` | `n_m10.iq` | 21,114,096 | `score_t7.py`, `t11_align.py` | `b_m10` LOSS **10.93 %** |
| −40 ppm | `r4_m40` | `n_m40.iq` | 21,114,096 | honest delivered/byte-exact count | `b_m40` LOSS **78.07 %** |
| tiled −10 ppm | `r4_tm10` | `s_m10.iq` (TILED control) | 8,139,780 (165 fr) | `score_sro2.py` (Task 6 definition) | `tb_m10` LOSS **22.01 %** |
| **+10 ppm** | `r4_p10` | `n_p10.iq` (**new**, `gen_sro_stim.py tx432.iq n_p10.iq --ppm 10 --no-tile --frames 428`) | 21,114,096 | report only | none |

Baselines `b_p000` / `b_m10` / `b_m40` / `tb_m10` are Task 7's and are **not re-run**;
Task 11's `s_*` results are not re-run either. `b_m2p5` is not a gate leg (Task 7
measured zero hole events in its scored window, so it is vacuous for or against any
steering variant).

Witness mapping (the R4 wrapper carries the witnesses on Task 7's three witness ports
so `sim_sro.cpp` is used **unmodified**):

* `r3_skips` in `<p>_res.txt` **is** `r4_skips` (steered pop SKIPS);
* `r3_extras` in `<p>_res.txt` **is a SENTINEL, not a count**: `0xA5A50001` while
  `r4_prefilled`, else `0`. R4 has no extra-pop branch at all;
* `<p>_ep.txt` kind **4** = one steered skip; kind **5** = the single instant the ring
  finished pre-filling (R3S used kind 5 for its arming instant).

## 2. Gate table — pre-registered, criteria verbatim from the brief

Pass requires **every** row. `r4_p10` is **report only** and is not a pass/fail
condition.

| # | leg | quantity | PASS criterion |
|---|---|---|---|
| G1 | `r4_p000` | delivered stream vs `b_p000` | **CONTENT-identical**: every frame's `nwords` / FNV hash / user flag equal. `sidx` may differ by the constant pre-fill latency, and **the measured constant is stated** |
| G2 | `r4_p000` | `r4_skips` | **exactly 0** |
| G3 | `r4_p000` | occupancy after acquisition | in **[14, 18]** |
| G4 | `r4_m10` | LOSS (seq denominator, lost frames included) | **≤ 0.5 %**, and the only losses allowed are **seq 133 / 134** |
| G5 | `r4_m10` | `r4_skips` | **15–35** (brief's nominal ≈ 21; see §3 for my own prediction), **all** within **≤ 60 slots** of the epoch boundary |
| G6 | `r4_m10` | `rh_pop_on_empty` in the scored window | **= 0** |
| G7 | `r4_m40` | LOSS | **≤ 1 %** |
| G8 | `r4_m40` | `r4_skips` | **150–260** (brief's nominal ≈ 211) |
| G9 | `r4_m40` | `rh_pop_on_empty` in the scored window | **= 0** |
| G10 | `r4_tm10` | LOSS (`score_sro2.py`, Task 6 definition) | **= 0.00 %** |
| G11 | all | wrapper provenance | every run prints `WRAP4_FILE wrap_byte_sro4.v t12a` and `WRAP4_DEFINE RXFIX_R4` |

G11 is not cosmetic. **Three** files now declare `module wrap_byte_sro` (Task 7's,
Task 11's and this one). If Verilator had read either of the others the witnesses
would tie to 0 — and "`r4_skips` = 0" is literally the G2 **pass** condition.

## 3. My predictions, and why they are not the brief's numbers

Measured on Task 7's banked `_frames.txt` (columns 21–26 = `oS,oE,oMin,oMax,pe,pf`,
the TRUE guarded-ring taps) **before** any Task 12 leg ran. Drift is
12,333 · |s| entries per air frame: **0.123/frame at −10 ppm**, **0.493/frame at
−40 ppm**.

| baseline | acquisition | post-acquisition occupancy | consequence for R4 |
|---|---|---|---|
| `b_p000` | `pf = 0` | **1/2**, flat for 428 frames | pre-fill **survives** → 16/17 |
| `b_m10` | **air frame 2: `oS=1 → oE=31`, `pf = 17`** | **31**, draining to 0 by frame ≈ 259 | the acquisition burst fills the ring to FULL and **deletes 17 pushes**; pre-fill is **overwritten** and the operating point is ~31 |
| `b_m40` | `pf = 0` | **0/1** | pre-fill **survives** → 16 |
| `tb_m10` | `pf = 0` | **5/4**, first hole at frame 40 | pre-fill **survives** → 16 |

So the brief's sentence "the steady-state occupancy is ~16 regardless of the
acquisition transient" holds on three of the four legs and **fails on `b_m10`**, the
headline leg. The brief's `≈ 21` skip nominal is a carry-over from R3S's *measured*
count. The criteria in §2 are used **verbatim anyway** — retuning a band to match my
own arithmetic would convert pre-registration into post-diction, and every prediction
below falls inside the brief's bands as written.

**Predicted, before running:**

* `r4_p000`: `r4_skips` = **0** (occupancy 16/17 is never ≤ 8); occupancy **16–17**;
  pre-fill latency **+64 input samples** (16 symbols × 4 sps) on every delivered
  frame's `sidx`. The 34 acquisition `pop_on_empty` events `b_p000` shows in air
  frame 0 will **not occur** under R4 — pops are suppressed while the ring fills, so
  there is no pop-into-empty. That is a genuine change to the acquisition transient
  and is exactly why G1 is content identity with a latency offset and **not** the md5
  identity R3S could claim.
* `r4_m10`: operating point ≈ **31**, so the drain to `occ ≤ 8` takes
  (31 − 8)/0.123 ≈ **187 frames** → first skip ≈ air frame **190**, then one skip per
  ≈ 8.1 frames → **≈ 29 skips** (inside 15–35, **not** ≈ 21). LOSS **0.475 %**
  (seq 133/134 only, 2 of 421) if the mechanism is right.
* `r4_m40`: pre-fill survives → drain to 8 in 8/0.493 ≈ **16 frames** → first skip
  ≈ frame **21**, then one per ≈ 2.03 frames → **≈ 200 skips** (inside 150–260).
* `r4_tm10`: pre-fill survives → first skip ≈ frame **70**, **≈ 12 skips**; the
  baseline's arming hole at frame 40 is pre-empted, so **0.00 %**.
* `r4_p10`: pre-fill to 16 leaves (32 − 16)/0.123 ≈ **130 frames** to the FULL edge,
  then `push_on_full` deletions with ~2 frames lost per event. Reported, not gated.

**Where a skip may fire is bounded in advance.** `r4_do_skip` requires `r4_locked`
(eight guardIn falling edges = eight deframer frames). Pre-fill completes inside air
frame 0 but lock is ~air frame 5, and `guardIn` is stuck at 1 in that gap, so without
the lock term a single stray skip could latch `r4_skip_done` — which clears only on
`~guardIn` — and disable the steering for the whole run. The lock term can only
**remove** skips; on every prediction above the first `occ ≤ 8` crossing is ≥ 20
frames after lock, so it is a no-op on every gate row.

## 4. Falsifier — pre-registered

If `r4_m10` loses frames **at the skips** — the residual losses aligned to the
`r4_skips` events (kind 4) the way the baseline's losses are aligned to its holes
(kind 0) — then **the position of the skipped slot matters after all** in a way R3S's
result did not show, and the deliverable is a per-stage dump, not another variant:
`sim_stagewin` around one skip, plus the matched ±64-beat window one air frame earlier
at the same intra-frame phase, exactly as Task 11 did. The report then names the first
stage whose behaviour differs between the two windows.

## 5. Things that are NOT claimed

* R4 does not remove the epoch slip. `Peak_Search.timing_Reference`,
  `Timing_Adjust.timing_Reference` and `End_Generator`'s counter all count VALIDS, so
  a skipped valid still slips all three epochs by one symbol. R4 bounds *where* the
  deficit is absorbed. **A residual is expected and is reported as measured.**
* The **FULL edge / positive SRO is out of scope.** R3's extra-pop branch stays
  deleted, not fixed. `r4_p10` **documents** the reverse-leg problem; it does not
  address it.
* **The s = 0 identity is measured, not structural.** R3S ANDed its skip with
  `r3s_armed`, so before arming its pop expression was literally the baseline line.
  R4 gates the pop on `r4_prefilled`, so R4's pop expression is *never* the baseline
  expression.
* **R4 fails toward NO OUTPUT, not toward baseline.** If the ring never reaches
  occupancy 16 after reset, `r4_prefilled` never sets and no pop is ever taken. There
  is no timeout. R3S's failure mode was strictly safer.
* **No silicon claim.** R4 has not been synthesised; there is no timing, resource or
  PER number from hardware in this document or in the report.
