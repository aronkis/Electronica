# Task 7 (T2b) — non-repeating SRO stimulus, H-A/H-B verdict, RXFIX_R3  [sim, desk only]

Ledger `two_jup/sdd_archive/2026-09-04-rxfix/progress.md` (`Task 7:` lines) · branch
`per-under-1pct-2026-07`. **No board contact, no Vivado, no subagents, no push.**
Every number below is **[sim]**.

## Deliverables

| # | deliverable | where |
|---|---|---|
| 1 | non-repeating TX stimulus + seq-aware scoring | `jupiter_240k5_byte/rtl_sim/wrap_byte_sro.v` (TGEN v2 behind `tgen_sel`), `sim_sro.cpp` (`txcap2`, `<p>_seq.txt`), `two_jup/comb/sro_sim/gen_sro_stim.py --no-tile`, `score_t7.py`, `runall_t7.sh` |
| 2 | free H-A test on the tiled stimulus | `two_jup/comb/sro_sim/t7_txauto.py` |
| 3 | RXFIX_R3 guard-band steering | `two_jup/skidfix/rxfix_inject.py` (variant `R3`, 7 files), tree `jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R3/`, build `build_sro_rxfix3.sh` |

## 1. The stimulus is genuinely non-repeating, and that was measured

`wrap_byte_sro.v` now instantiates `qpsk_traffic_gen_v2` (TGEN v2: incrementing seq,
PN(seq) payload, fill 1516) behind a `tgen_sel` mux. `tgen_sel = 0` leaves the DUT byte
pins driven by the module ports, so **every rx-mode leg is bit-identical to task 6's
harness**; only the new `txcap2` mode raises it.

**Gap selection was measured, not assumed** (20 air frames each):

| TGEN `gap` (clks) | TGEN frames emitted per 20 air slots | reading |
|---|---|---|
| 90000 | 10 | one frame per **two** air slots — the byte plane back-pressures and the free-running period aliases |
| 60000 | 10 | same |
| **20000** | **20** (seq 1..20) | **exactly one emitted frame per air slot**, byte plane always primed |
| 1000 | 30 | 1.5x overrun = the G4 drop regime |

`gap = 20000` chosen. The `txcap2` sidecar certifies **every** air frame:
`repeat_of_prev = 0` and `allzero = 0` on all of them — no tiling and no all-zero filler
frame anywhere, which is the artefact that would have re-introduced repeating content.

`gen_sro_stim.py --no-tile` drops the frame-periodicity assert and **asserts its
inverse** (no two consecutive 49,332-sample frames int16-identical), and resamples the
whole capture with edge clamping instead of modular indexing, so there is no wrap seam.

`sim_sro.cpp` now reconstructs the expected frame from the seq it reads out of the
delivered header (`t7_expect()`, the TGEN model at `qpsk_traffic_gen_v2.v:61-118`) and
records `sidx,nbytes,magic,seq,nbad,ok` per delivered frame in `<p>_seq.txt` — the
task-6 scorer's "hashes to the modal frame of the s = 0 run" definition is meaningless
on a PN(seq) payload. `score_t7.py` derives MISSING from the seq numbers, so **lost
frames are in the denominator**.

## 2. The free half of H-A, run before any RTL: the TX content carries no 32-symbol structure

Task 6's decisive lead was a consecutive-frame cross-correlation of the receiver's symbol
stream showing ρ = 0.50 at lag 0 **and** ρ = 0.50 at lag ±32, everything else at 0.02,
present in every frame pair. `tx5.iq` — the tiled stimulus itself — was still on disk, so
the same pipeline (decimate to 1 sample/symbol, CFO-invariant differential
`d[n] = s[n]·conj(s[n−1])`, mean removed, normalised, circular correlation) was applied to
one settled TX frame at all four sampling phases:

| phase | ρ(0) | ρ(1) | ρ(16) | ρ(31) | **ρ(32)** | ρ(33) | ρ(64) | top non-zero lags |
|---|---|---|---|---|---|---|---|---|
| 0 | 1.000 | 0.027 | 0.002 | 0.011 | **0.006** | 0.009 | 0.008 | 1, 1844, 1415, 4167 |
| 1 | 1.000 | 0.026 | 0.005 | 0.012 | **0.002** | 0.008 | 0.005 | 1382, 1, 1844, 753 |
| 2 | 1.000 | 0.259 | 0.010 | 0.007 | **0.007** | 0.009 | 0.007 | 1, 2576, 753, 5255 |
| 3 | 1.000 | 0.025 | 0.001 | 0.011 | **0.005** | 0.010 | 0.009 | 5806, 1844, 5556, 5660 |

**The transmitted symbol content has no lag-32 preference at all** (ρ ≈ 0.005 against 1.000
at lag 0, and lag 32 is nowhere near the top of the surface). This also **reconciles the
caveat task 6 recorded and did not resolve**: its "≈0.18 at every integer-symbol lag, no
lag-32 preference" figure was a *within-frame, 4-sps* measurement — a different pipeline.
At the symbol rate under the identical pipeline the answer is the same and much sharper:
no lag-32 structure in the TX.

Consequence for the framing of the task: the ±32 symbol-stream double peak **is not a
property of the tiled payload**, so H-A cannot be carried by "the stimulus is periodic".
See §4 for the verdict as split across the two distinct observables.

## 3. RXFIX_R3 — guard-band steering (cut in parallel, mechanism-agnostic)

R1 (valid-indexed PD FIFO pop) is null and R2 (flywheel) is harmful, and both were cut on
a hypothesis about *why* the frame dies. R3 deliberately does not have one. The
Rate_Handle ring pops on a rigid mod-4 phase and pushes on the interpolator strobe, so
under an SRO the true occupancy drifts by `12333·s` per air frame and eventually hits an
edge: at EMPTY the built-in guard suppresses a pop (one **skipped valid slot**), at FULL it
suppresses a push (one **deleted symbol**). Either way the hole lands at an arbitrary point
inside the 12,320-symbol payload window.

R3 **moves the hole**. `Packet_Controller`'s `sample_discard_controller` is inactive for the
13 symbol slots between `End_Generator`'s `endOut` and the next `startIn`
(`RATE_HANDLE_FIX_SURVEY.md` §2) — a per-frame window in which the deframer consumes
nothing. When the true occupancy is about to reach an edge, R3 pre-empts the edge inside
that window, at most once per window:

* occupancy ≤ 2 (draining toward EMPTY) → **skip one pop** (occupancy +1);
* occupancy ≥ 30 (filling toward FULL) → **take one extra pop** (occupancy −1).

The built-in guard is untouched, so if the steering ever fails to pre-empt, baseline
behaviour still applies: R3 can move holes, it cannot create losses the baseline lacks.
Outside the guard the pop expression reduces to the baseline exactly, and with `guardIn`
tied low R3 is a no-op — which is what makes the `s = 0` bit-identity gate meaningful.

**What R3 does NOT claim.** `Peak_Search.timing_Reference`, `Timing_Adjust.timing_Reference`
and `End_Generator`'s counter all count VALIDS (`RATE_HANDLE_FIX_SURVEY.md` §2), so a
skipped valid still slips all three epochs by one symbol. R3 bounds *where* the hole lands,
not what the epoch counters do with it. **A residual is expected and is reported as
measured, not rounded to 0.00 %.**

**Phase alignment is measured, not assumed.** `Preamble_Detector.Delay10_reg` delays the
valid by 49,332 enb ticks = exactly one air frame, so the guard window seen at
Rate_Handle's beat should sit at the same intra-frame phase as the window the steered
symbol later meets. The harness logs `tref` at every steered event (epoch-trace kinds 4 and
5) so the alignment is a measurement.

### Implementation and rails

Seven internal modules, **no new TxRxComposite/IP port**:

| file | change |
|---|---|
| `sample_discard_controller.v` | `output activeOut` = the discard-window state (read-only) |
| `Packet_Controller.v` | `output guardOut = ~sdc_active` |
| `Frequency_and_Time_Synchronizer.v` | wire `Packet_Controller_guardOut` back into `Symbol_Synchronizer` |
| `Symbol_Synchronizer.v` | `input guardIn`, passed to `Rate_Handle` |
| `Rate_Handle.v` | `input guardIn`, the steered pop, witnesses `r3_skips` / `r3_extras` |
| `FIFO_block.v` | `output occOut` (true occupancy, read-only) |
| `Validate_Input_Push_Pop_block.v` | `output occOut = Delay_out1` |

`guardOut` is sourced from a register (`sample_discard_controller.active`), so the feedback
adds **no combinational loop** through the receive chain.

Injector rails: `rxfix_inject.py` variant `R3`, same shape as R1/R2 (exactly-once anchors,
per-file `RXFIX_R3` markers, idempotent, 3 loose mirrors + both `TxRxCompo_ip_v1_0.zip`
members + `verify_zip`, `--sim-tree` mode). The two netlist lineages have **different port
lists** on five of these seven files (the flashed txfixF3 tree carries `bfGridEn` /
`beatobs*`), so the port and pin insertions are **structural** (paren-balanced span
helpers) rather than verbatim-block matches. Verified: R3 patches cleanly and
`verilator --lint-only` is **error-free on both** the `s1_rtl` sim lineage and the flashed
`s1_rtl_txfix_F3` lineage. `test_rxfix_inject.py` 39 tests green.

## 4. The +32 is one Rate_Handle ring lap, taken at the pop_on_empty beat

Before any new simulation finished, task 6's own per-beat dump `h_m10_ring.txt` was
re-analysed. Three findings, in order:

**(a) Segmentation is not the artefact.** Segmenting the `Rate_Handle.validOut` symbols by
VALID COUNT (12,333/frame, the epoch the receiver actually uses) and by INPUT SAMPLE
(`sidx // 49332`) give the same answer (`t7_segcheck.py`), so the ρ(0)=0.50 / ρ(±32)=0.50
split is not a framing choice.

**(b) It is not an ambiguity — it is a sharp, localised STEP.** Quarter by quarter, the
correlation of consecutive frames is:

| pair | q0 | q1 | q2 | q3 |
|---|---|---|---|---|
| 37→38 | lag 0 (1.00) | lag 0 (0.92) | **lag +32 (0.94)** | **lag +32 (0.99)** |
| 38→39 | **lag +32 (0.99)** | **lag +32 (0.92)** | lag 0 (0.95) | lag 0 (1.00) |
| 39→40 | lag 0 (1.00) | lag 0 (0.95) | **lag −32 (0.99)** | **lag −32 (0.99)** |
| 40→41 | **lag −32 (0.99)** | **lag −32 (0.94)** | lag 0 (1.00) | lag 0 (1.00) |

The losing lag is at 0.00–0.05 in every cell, and exactly ONE of ±32 is ever active. The
ρ = 0.50 "double peak" task 6 reported was the whole-frame average of this: half the frame
at one alignment, half at the other. **Task 6's reading — "a 32-symbol alignment ambiguity
is present in the symbol stream at ALL times" — is retracted.**

**(c) The step beat is the pop_on_empty beat.** Per-symbol, the 39→40 switch happens
between symbol index 6013 (`sidx` 1,997,334) and 6014 (`sidx` 1,997,342). A full lag scan
over −64…+64 of the mean |b[i] − a[i+L]| isolates it:

| region | best lag | mean abs diff | next-best lag | its mean abs diff |
|---|---|---|---|---|
| before the step (i = 5500…5700) | **0** | 364 | 13 | 18,379 |
| after the step (i = 6100…6300) | **+32** | 482 | 22 | 18,465 |

and the beat between the two, `sidx = 1,997,338`, is
`strobe=1, pop=1, vout=0, occ=0, popEmpty=1, tref=5976` — **the Rate_Handle EMPTY-edge
event itself**.

So the displacement needs no separate mechanism and no separate stimulus argument: it is a
step of exactly **one lap of the 32-entry Rate_Handle ring**, taken at the instant the
guard suppresses a pop.

### The read path, named  [netlist]

| what | where |
|---|---|
| the ring: **32 entries** — the same 32 that is measured | `FIFO_block.v:184-196`, `SimpleDualPortRAM_generic #(.AddrWidth(5), .DataWidth(16))` |
| `wr_addr = Push_Counter_out1`, `wr_en = valid_push`, `rd_addr = Pop_Counter_out1` | `FIFO_block.v:191,192,193` |
| pointers advance **only on the validated events** — a suppressed pop does not move the read pointer, which is why task 6's pointer census looked clean | `FIFO_block.v:127-129`, `:161-163` |
| the read is **registered**, in the same `always` block as the write, with **nonblocking** assignment ⇒ **read-before-write** at a coincident address | `SimpleDualPortRAM_generic.v:57-66` |
| `out_re/out_im = data_int` (one enb tick behind the pointer) while `validPop = valid_pop` is **combinational** (not delayed) | `FIFO_block.v:198-202` |

At the EMPTY edge `Pop_Counter == Push_Counter`, so a coincident push and suppressed pop hit
the **same address**, and the registered read latches the word from the previous lap rather
than the word being written. Mod-32, a lap-stale read and a lap-ahead read are the same
displacement — which is why the measurement cannot, and does not, distinguish +32 from −32.

**Labelling, kept honest.** The line-level localisation in the table is **[netlist]** and
certain. The cycle-level claim that this coincidence is what emits the lap-old word is
**[inferred] and NOT proven**: a behavioural replay of the RAM from `h_m10_ring.txt` did not
converge inside this task's budget because that dump does not carry every enb beat. The
falsifiable probe for the next task is stated in the ledger: dump `in_re/in_im`, `wr_addr`,
`rd_addr`, `valid_push`, `valid_pop` and `out_re/out_im` on **every** enb beat for ±64 beats
around a `pop_on_empty`, and check whether the emitted word is the ring content from the
previous lap. **No R4 was cut on the inferred half** — that is the mistake R1 and R2 already
paid for.

### 4a. CORRECTION — the ring-lap mechanism is refuted by its own probe

The probe named above was built and run (`sim_sro ramwin` on `s_m10.iq`, 2 `pop_on_empty`
windows, ±64 enb beats each, `t7_ram_m10.txt`), and it **refutes the [inferred] half of
§4**:

* `(wr − rd) mod 32` **equals** the true occupancy at every beat in both windows (identical
  histograms: `{0:49, 1:72, 2:8}` and `{0:49, 1:64, 2:16}`). There is **no pointer/occupancy
  desync** — the ring is never holding 32 entries while reporting 0.
* Replaying the RAM behaviourally, the **lap distance of every emitted word is 0 or 1 pushes
  ago, never 32**, under both the read-before-write and the read-after-write model.

So the ring emits current data, and "the +32 is a lap-stale read at the coincident address"
is **withdrawn**. It was labelled `[inferred]`, nothing was built on it, and the two fixes
that *were* cut on unproven mechanisms (R1, R2) are the reason it was labelled that way.

*Caveat on the probe, stated rather than buried:* the replay model mismatches the emitted
word on 14 of 30 `validOut` beats in each window because it does not reproduce the exact
pipeline phase, so the **model** is not validated. The two readings above do not depend on
that phase — they are direct.

**What survives:** the measurement. The +32-symbol content step is real, one beat wide, and
its beat is the `pop_on_empty` beat (`sidx` 1,997,338, `tref` 5976, `occ` 0, `wr = rd = 29`;
the second window is `sidx` 2,398,218, `tref` 7531, `occ` 0, `wr = rd = 24`).

**What is open again:** what converts one suppressed valid slot into a 32-symbol content
displacement. No further mechanism is proposed from this desk.

## 5. RXFIX_R3 — gated and REJECTED

The controller's ruling (ledger 13:19:57) is recorded: **R3 is rejected on the gate result;
no build.** The gate evidence, in full:

| leg | stimulus | loss | witnesses |
|---|---|---|---|
| `sm_b_p000` baseline, s = 0 | non-repeating, 60 fr | **0.00 %** (52/52 by seq) | `pe` 46, `pf` 0 |
| `sm_r_p000` **R3**, s = 0 | non-repeating, 60 fr | 0.00 % (52/52) — but **NOT byte-identical** | `r3_skips` 4, `pe` 42 |
| `sm_b_m10` baseline, −10 ppm | non-repeating, 60 fr | 0.00 % (53/53) | `pe` 34, `pf` 17 (all in frames 0–2) |
| `sm_r_m10` **R3**, −10 ppm | non-repeating, 60 fr | **100 %** (`t7_ok` 0 of 58; `capout` a037d28a → 90db9a5e) | **`r3_extras` 4**, `r3_skips` 1 |

Two separate failures, and the witnesses say which branch caused which:

1. **The extra-pop branch is refuted outright.** `r3_extras = 4` accompanies total loss of
   framing. Skipping a pop and taking an extra pop are **not symmetric**: an extra pop emits
   an additional symbol and slips every valid-counting epoch (`Peak_Search`,
   `Timing_Adjust`, `End_Generator`) in the opposite direction. Do not ship it.
2. **The s = 0 bit-identity gate fails**, and the cause is a measured property of the
   stimulus rather than of the steering: on the TGEN stream the ring's operating point is
   occupancy ≈ 1 during acquisition and ≈ 28 after it — not the 5 the tiled legs sit at — so
   `occ ≤ 2` is true at s = 0 as well and R3 steers when it should be inert. An
   occupancy-threshold predicate cannot be made inert across both operating points.

R3 is not carried forward. The seven-file injector, its structural anchors and the
both-lineage lint result are kept in the tree as reusable rails, marked rejected.

## 6. The silicon instrument that would localise the deleting stage directly

Per the controller's ruling: if H-A stands, **no R4 is proposed from the sim**. What follows
is the on-silicon instrument instead. The headline is that **most of it is already in the
flashed image** — what is missing is a free read-back address pair, not the logic.

### 6.1 What already exists in the flashed txfixF3 lineage  [netlist]

| signal | where | reaches |
|---|---|---|
| `Rate_Handle` mod-4 pop phase (`beatobsRhCtr`) | `Symbol_Synchronizer.v` → `Frequency_and_Time_Synchronizer.v:263` | `QPSK_Rx.v:650` `BoDtc5_out1` |
| ring **push pointer** (`beatobsPush`, 5-bit) | same path, `:265` | `QPSK_Rx.v:652` `BoDtc6_out1` |
| ring **pop pointer** (`beatobsPop`, 5-bit) | same path, `:267` | `QPSK_Rx.v:654` `BoDtc7_out1` |
| all three consumed by an existing witness block | `QPSK_Rx.v:656-665` `BeatObs u_BeatObs` | `dbgI1/dbgQ1` → `beatobsI1/Q1` |

and the in-tree comment at `QPSK_Rx.v:676-678` records what the read-back was:

> `witA = {2'b0, numEntries, push-pop delta, 2'b0}`; `witB = {push_on_full_count[31:16],
> delta_change_count[15:0]}` at **0x20C / 0x210**.

**The blocker is an address collision, not missing logic.** `QPSK_Rx.v:681-690` shows DBGCAP
(2026-08-30) re-purposed **0x20C and 0x210** for its per-stage decision capture
(`dcap` / `dcmm`). So on the flashed md5 those two words almost certainly report DBGCAP, not
the ring. **First action, and it costs nothing: confirm ownership of 0x20C/0x210 on the
flashed md5 before assuming either.** If the ring witness still owns them, the whole
instrument below is readable **today with no rebuild**.

### 6.2 What to add if the addresses are taken (small, off the critical path)

1. **Two free read-back words** for `witA`/`witB` as specified above — the counters already
   exist; only the address decode moves.
2. **`ddrcap_sel = 12`** (sels 0–11 are used, `TxRxComposite.v:2011-2033`; 12–15 are free)
   carrying `{occupancy, push_ptr}` / `{pop_ptr, pop_on_empty|push_on_full}` as the I/Q pair
   at `enb_1_2_0` rate. That gives a full-rate time series of the ring occupancy, which is
   what times the hole events against the PER comb.
3. **A per-stage valid census**, read through the existing `cnt_mux32` freeze/sweep
   discipline (`sim_byte_seqbist.cpp`'s `freeze_read()` is the host pattern): free-running
   counters on `Symbol_Synchronizer.validOut`, `Coarse_Frequency_Compensator.validOut`,
   `Carrier_Synchronizer.validOut`, `Preamble_Detector.validOut`, `Correlator.validOut`,
   `Phase_Ambiguity…validOut`, `Packet_Controller.validOut`, plus `rh_pop_on_empty`,
   `rh_push_on_full` and `pd_push_on_full`.

### 6.3 What to read, and how

Read all counters inside **one freeze window** at two instants separated by K air frames
(K ≈ 2000). Each stage's delta must be exactly 12,333·K upstream of the deframer and
12,320·K after `sample_discard_controller`. **The first stage whose delta falls short is the
deleting stage.** Run it on both directions of the link with the shipped defaults, alongside
`capture_r3.sh` A/B PER with `frame_taxonomy.py` (lost frames in the denominator).

### 6.4 Prediction and falsifier — pre-registered

**Prediction (the sim law carried to silicon).** With |SRO| ≈ 2.5 ppm measured in
`TX_SEL8_DESK.md`:

* `rh_pop_on_empty` increments once per `1/(12333·|s|)` ≈ **32.4 air frames** — the same
  period as the observed PER comb;
* every stage delta **downstream of `Rate_Handle`** is short by exactly the number of
  `pop_on_empty` events in the window; every stage **upstream** is exact;
* `rh_push_on_full` and `pd_push_on_full` stay at **0** (the EMPTY edge is the one this link
  reaches; the sim's `-2.5 ppm` leg drains).

**Falsifier, and it is a real one.** If the per-stage deltas are **all exact** — no shortfall
anywhere — while frames continue to be lost at the ~32-frame comb period, then the loss is
**not a symbol deletion at all**, and the SRO → `Rate_Handle` → symbol-sync path is
exonerated on silicon exactly as the tiled-vs-non-repeating comparison would exonerate it in
sim. Equally: if `rh_pop_on_empty` stays at 0 over a window that contains several comb
periods, the ring never reaches an edge on silicon and every fix aimed at the edge — R1, R2,
R3 and any successor — is aimed at the wrong place.

**Why this instrument and not another.** It is the only reading that distinguishes
"a symbol is deleted, and here is the stage" from "nothing is deleted and the frames die for
another reason" **without** relying on any of the mechanisms this campaign has already
retracted (the ring lap, the NCO basepoint, the correlator threshold, the PD FIFO guards,
the flywheel).

**Caveats carried forward, not rediscovered.** Full-rate DDRCAP taps drop ~20 % of records at
the rx2 DMA and the record index is **not** a time base on `enb`-domain taps — index by
in-record `tref` (DDRCAP-v2). `0x158/0x114/0x118/0x10C` read `const_0`; verify arms by
effect. Keep register polling at 1 s and never poll during an arm.

## 7. H-A / H-B — the verdict: **H-B**

Four baseline legs, 428 frames each, on the certified non-repeating capture, scored by seq
so lost frames are in the denominator. Matched tiled control on the same harness in brackets.

| leg | expect | OK | CORRUPT | MISSING | **loss** | `rh_pop_on_empty` | `rh_push_on_full` |
|---|---|---|---|---|---|---|---|
| `b_p000` 0 ppm | 420 | 420 | 0 | 0 | **0.00 %** | 34, **all in frame 0**, 0 scored | 0 |
| `b_m2p5` −2.5 ppm | 420 | 420 | 0 | 0 | **0.00 % — VACUOUS** | 34, all frame 0, **0 scored** | 18, all frames 2–3 (acquisition) |
| `b_m10` −10 ppm | 421 | 375 | 8 | 38 | **10.93 %** | **55 = 34 acquisition + 21 scored** | 17, **all frame 2**, 0 scored |
| `b_m40` −40 ppm | 424 delivered | 93 | 29 | — | **78.1 %** | 272 = 61 acq + **211 scored** | 0 |

**`b_m10`'s 55, explicitly.** 34 are acquisition-phase (every one in frame 0) and **21 fall
inside the scored window**, at frames 259, 267, 275, 283, 291, 299, 308, 316, 324, 332, 340,
348, 356, 364, 372, 381, 389, 397, 405, 413, 421 — one per 8.1 frames, the predicted
1/(12333·|s|). The 17 `push_on_full` are **all in frame 2**; none is in the scored window.

**`b_m2p5` is vacuous, as pre-registered.** Zero hole events in the scored window: after
acquisition the ring pins at occupancy 31 and drains 0.031 entries/frame, so the EMPTY edge
is ~1000 frames away. Its 0.00 % is silent on H-A vs H-B and is not counted either way.

### Why this is H-B and not H-A

1. **The loss appears only once the ring reaches the edge.** `b_m10` runs 250 frames at
   0.00 % while occupancy drains 31 → 0; the comb starts within 4 frames of the first hole
   at frame 259 (predicted 31/0.123 = 252).
2. **The holes and the losses are the same events.** At a constant seq↔frame offset of −3,
   **42 of 46 lost frames sit within ±1 of a hole**, and the rate is **2.10 lost frames per
   hole event** — task 6's "two straddling frames die per cycle" law, on content that never
   repeats.
3. **The magnitude is not suppressed.** Post-edge, 44 losses in 169 frames = **26.0 %**,
   against the matched tiled control `tb_m10`'s **22.01 %**.
4. **The accelerated leg lands in the pre-registered H-B band.** `b_m40` = 78.1 % (H-B
   predicted order 80–100 %; H-A predicted ~0 %), with one hole per 2.02 frames against
   2.03 predicted.

**H-A is refuted.** The tiled stimulus was never why the frames died — it only made the ring
reach the edge sooner (occupancy 5 at lock versus 31 on the TGEN stream).

### Recorded honestly, not suppressed

* Two lost frames, **seq 133 and 134, fall in no hole cycle** (nearest hole 126 frames
  later). 44 of 46 losses are hole-aligned; these two are unexplained and are not counted as
  evidence.
* **`b_m40`'s seq-derived denominator was refused** by `score_t7.py`'s plausibility guard
  (seq range 15,729,143 vs 428 air frames — corrupt header seq fields). The honest count is
  used instead: 424 delivered slots, 93 byte-exact. −40 ppm is far outside the silicon range
  (≤ 0.06 ppm on-air, 2.5 ppm on the desk) and its strobe-anomaly count is 14,490 vs 1,899
  at −10 ppm — it is an **acceleration instrument, not an operating point**. Lock is held
  throughout (packets 425, per-frame census 12,332–12,333, `capout` a037d288 vs golden
  a037d28a), so its 78.1 % is frames dying at holes, not loss of lock.
* `b_m10`'s 8 CORRUPT / 38 MISSING split is reported as measured; both count as lost.

### Cadence fidelity — asked before the verdict was finalised  [netlist]

The tick/valid relationship is **not stimulus-dependent**; it is hard-tied.
`TxRxComposite.v:476-481`:

```verilog
assign IntValidConst_out1 = 1'b1;
assign RxValidConst_out1  = 1'b1;
assign MUX_RxValid_out1 = (rx_input_select == 1'b0 ? IntValidConst_out1 : RxValidConst_out1);
```

and `TxRxComposite.v:721` `.validIn(MUX_RxValid_out1)` feeds the Receiver. In **both** input
modes, in sim and on silicon alike, the RX chain's `validIn` is constant 1 on every
`enb_1_2_0` tick; `adc_validIn` never gates the DSP chain.

**Resulting valid density: 1 valid per enb tick = 100 % at the receiver input, in both
cases — not 25 %.** The "1 in 4" lives one stage later and is Rate_Handle's own mod-4 pop
counter (`Rate_Handle.v:112-114`, `pop = validIn & (HDL_Counter_out1 == 0)`) — a counter, not
an enable. The 1-in-4 that `Delay10_reg`'s tick-delayed pop actually depends on is the
Rate_Handle **output** density, and that was **measured in these legs**: the per-frame census
gives `ss = corr = 12,333` per 49,332-tick air frame (12,332 on frames carrying a
`pop_on_empty`) — exactly the condition under which 49,332 ticks ≡ 12,333 valids.

`cadence 2` governs only how often the driver presents a new sample into the rate-adapting
ADC capture register — one per enb tick, what a 4-sps stream does. That this is the right
choice is falsifiable and was falsified the other way (`COMB32_SRO_SIM.md` §5): cadence 2
satisfies the design's own arithmetic (12,333 pushes = 12,333 pops per frame, packets
decode); cadence 4 gave 23,895 pushes/pops per frame and **zero** packets decoded.

So the time-domain consumers see the same tick stream and the same 1-in-4 valid density as
silicon, and the verdict is stated as **"H-B: the death mechanism is real and
content-independent"** — not as the weaker "the harness cannot reproduce the silicon death
on real content".
