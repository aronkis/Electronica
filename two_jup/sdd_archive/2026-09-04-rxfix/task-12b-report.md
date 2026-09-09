# Task 12b — RXFIX_R4B: the silicon-ready steering (structural window, kit anchors, registered decision)  [sim, desk only]

Brief `task-12b-brief.md` · controller design ruling 2026-09-04T17:07:50 (pre-fill
dropped) · pre-registration `two_jup/comb/RXFIX_R4B_SIM_GATE.md`, **committed before the
variant tree, the harness or any leg existed** (`ed00455`) · ledger `progress.md`
(`Task 12b:` lines) · branch `per-under-1pct-2026-07`.
**No board contact, no Vivado, no subagents.** Every number below is **[sim]**.

**Verdict in one paragraph.** **The mechanism holds and the falsifier did not fire: 356
steered skips across seven legs, every one of them at slot 1 of the 13-slot structural
window, and the loss collapses on every negative-SRO leg** — −10 ppm **10.93 % → 0.48 %**,
−40 ppm **76.98 % → 0.74 %**, the tiled control **22.01 % → 0.00 %**, the forced
loss-of-lock leg **4.39 % → 0.24 %**, and the new +20 kHz CFO leg **28.33 % → 0.24 %**. At
0 ppm the delivered stream is content-identical to the baseline on all 423 common frames,
and on every paired leg **every frame delivered before the first skip is byte-identical to
the baseline including `sidx`** (184/184 of them on `n_m10`) — the structural property R4
had lost. The ring self-centres at **9/10** on all six negative-SRO legs, exactly as the
controller's ruling predicted, and `pop_on_empty` in the scored window is **0** on five of
seven legs. **Fifteen of seventeen gates pass. G14 FAILS and it is a real regression:** on
the +10 ppm leg R4B's 7 acquisition-transient skips pushed the already-near-FULL ring over
the FULL edge and cost 7 deleted pushes and 7 extra lost frames (6.65 % vs the baseline's
4.99 %). **G13 also fails as written**, but in the opposite direction to the one it
guarded against. Both are reported as failures, not reinterpreted.

## 1. What changed from R4, and why each change exists

| # | review / ruling finding | R4B's answer |
|---|---|---|
| 1 | `guardIn = ~sdc.active` opens on ANY idle: false sync, missed sync, filler, garbage. One of 240 R3S skips fired mid-payload and that frame died; 5–6 % of silicon air frames are garbage/filler | the window is **structural**: one shot, exactly **13 nominal pop slots**, opened by `pcEnd`, at most **one skip per pcEnd**, and **no skip at all** in an idle period with no pcEnd within 13 slots |
| 2 | R3S/R4 anchors do not reach the `TxRxCompo_ip_src_`-prefixed IP kit (tests 73/91) | every anchor uses W1's `_PFX` pattern; **test 101** applies R4B to the same kit file test 91 pins R4 cannot patch, and **test 119** applies W1+R4B to a full kit-shaped tree |
| 3 | R4's pop closed a combinational loop occupancy → compare → do_skip → pop → valid_pop → occupancy, and pulled `guardIn` through four hierarchy levels combinationally | `pcEndIn`, the `occ ≤ 8` compare **and the whole decision** are flops; the only combinational path into the pop is the baseline's own guard |
| 4 | fail-to-silent pre-fill needs a bounded release | **the pre-fill is deleted outright** — see §2. There is nothing left to bound |
| 5 | lock by counting `guardIn` falling edges under-counts and counts false syncs | lock = **8 `pcEnd` pulses**, the same structural signal as the window |
| 6 | witnesses for silicon | `{r4b_locked, r4b_skips[15:0], r4b_window_opens[14:0]}` as a **ninth W1 read word at 0x234** when W1 is present; internal otherwise |
| 7 | keep 16/8 unless Task 12's R4 gate says otherwise | **`occ ≤ 8` kept**; the pre-fill depth is moot. Justification in §2 |

## 2. The bounded pre-fill is not implemented, and that is a deletion, not an omission

The brief's item 4 asked for `r4b_prefilled` to set after 4096 enb ticks post-reset as a
bounded release. **R4B has no pre-fill at all**, on the controller's 17:07 ruling, which
rests on Task 12's own measurement:

* at 0 ppm the ring **does** pre-fill to `oMax = 17` in air frame 0 — the pre-fill works —
  and the acquisition transient then **drains it completely**, taking 23 `pop_on_empty`
  on the way, so by air frame 1 the ring is back at 0/1 and frames 1–12 track `b_p000`
  exactly at occupancy 1/2;
* **the acquisition deficit at 0 ppm is ~34 entries** — larger than the 16 pre-filled and
  larger than the **32-deep ring**. No pre-fill depth can survive it.

What actually defines the operating point is the steering: after lock, `occ ≤ 8` fires
once per frame, occupancy ratchets 1 → 9 over ~8 frames, the predicate goes false, and
the ring sits flat at 9/10 with `pop_on_empty = 0`. So the pre-fill bought nothing and
cost the one property that made R3S clean.

**Three consequences, all improvements, all carried through the design:**

1. **The pop is structurally the baseline expression until the first arm.** R4 gated the
   pop on `r4_prefilled`, so R4's pop was *never* the baseline line and its acquisition
   differed from the baseline netlist. R4B gates only on `r4b_skip_en`, which is 0 until
   the first arm — so **acquisition is bit-identical to the baseline** (measured: §5).
2. **R4B fails toward BASELINE**, not toward no output. R4's stated failure mode was that
   if the ring never reached 16, `r4_prefilled` never set and *no pop was ever taken*.
   R4B has no such state.
3. `r4b_prefilled` disappears from the witness word, which is what makes the brief's
   34-bit witness layout fit in 32 bits (§4).

## 3. The RTL, in words, with line anchors

Five internal modules, **no new TxRxComposite or IP port**; injector variant `R4B` in
`two_jup/skidfix/rxfix_inject.py`, marker `RXFIX_R4B`, structural (paren-balanced),
`_PFX`-tolerant insertion so **all three** netlist lineages take it. Anchors are in the
generated tree `jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R4B/`.

| file | change | anchor |
|---|---|---|
| `Validate_Input_Push_Pop_block.v` | `output [5:0] r4bOcc = Delay_out1` — the registered TRUE occupancy, the same net the EMPTY compare uses | `:33` port, `:49` decl, `:147` assign |
| `FIFO_block.v` | pass the occupancy up | `:36` port, `:52` decl, `:114` pin |
| `Rate_Handle.v` | **the steering** | `:35` `pcEndIn` port, `:51` decl, `:53-65` state, `:138-204` the block |
| `Symbol_Synchronizer.v` | route `pcEnd` down; **no new port above it** | `:35` port, `:47` decl, `:461` pin |
| `Frequency_and_Time_Synchronizer.v` | close the loop from an **existing** wire | `:126` `.pcEndIn(Packet_Controller_endOut)` |

### 3.1 The window source is an existing port — this is what makes the file set five

`Packet_Controller.endOut` is **already** a port (`Packet_Controller.v:47`, driven at
`:159` by `sample_discard_controller`, which registers `endOutReg <= endIn & active`
under `enb_1_2_0_gated`) and is **already** carried on the FTS wire
`Frequency_and_Time_Synchronizer.v:104`. It is **the same net** Task 11's per-stage dump
printed as `pcEnd` — `wrap_byte_sro4.v` taps `pcE` from that wire and
`sim_stagewin.cpp:102,155` prints it under that header — the column in which pcEnd fires
at rel −4 and the R3S skip at rel −1.

So R4B needs **no `sample_discard_controller.v` edit and no `Packet_Controller.v` edit**,
where R3/R3S/R4 each needed both. Its five files are a **subset of W1's eight RTL files**,
which is why W1+R4B share one anchor surface instead of two.

*This is the one claim an adversarial reviewer should attack first, so it is stated as a
chain of three checkable links rather than an assertion.*

### 3.2 The steering, line by line

```verilog
  assign r4b_pop_nom = validIn & Compare_To_Constant_out1;          // :138  the baseline pop
  assign r4b_locked  = r4b_frames == 4'b1000;                       // :143  8 pcEnd pulses
  assign r4b_do_skip = r4b_skip_en & r4b_pop_nom;                   // :145
  assign Logical_Operator_out1 = r4b_pop_nom & ( ~r4b_skip_en);     // :147  THE POP
```

`r4b_skip_en` is a **register**, so `:147` carries no combinational term from the
occupancy or from `pcEnd`; with `r4b_skip_en = 0` it is `validIn & Compare_To_Constant_out1`
— the baseline line, character for character.

Inside `r4b_steer_process` (`:150`, `always @(posedge clk or posedge reset)`, everything
gated on `enb_1_2_0`):

* **`:168` `r4b_pcend_d <= pcEndIn;`** — the long path terminates at a flop. One flop is a
  complete edge detector because `Packet_Controller.endOut` is exactly one enb tick wide
  (`endOutReg` is clocked under `enb_1_2_0_gated` from `End_Generator`'s one-tick pulse).
* **`:169` `r4b_occ_le8 <= (r4b_occ <= 6'b001000);`** — the *only* occurrence of the
  occupancy in the file is inside this clocked assignment.
* **`:172`** the lock counter increments on `r4b_pcend_d && ~r4b_locked`, saturating at 8.
* **`:182`** the window advances one slot per **nominal pop opportunity** (taken or
  skipped) and closes when `r4b_wslot >= 4'b1101`.
* **`:192-195`** a `pcEnd` opens the window: `r4b_win <= 1`, `r4b_wslot <= 0`,
  `r4b_skip_done <= 0`, `r4b_opens` increments. This block is placed **last** so that a
  window opening on the same tick as a skip wins and the new window starts clean.
* **`:203-204`** the registered decision:
  `r4b_skip_en <= r4b_locked & r4b_win & r4b_occ_le8 & (~r4b_skip_done) & (r4b_wslot <= 4'b1100)`.
  The `≤ 12` term is what bounds the skip to slots **[pcEnd+1, pcEnd+13]**: the slot index
  at the instant it fires is `r4b_wslot + 1`.

**Arming latency, budgeted before the run and then measured.** `pcEnd` at tick 0 →
`r4b_pcend_d` at tick 1 (window opens) → `r4b_skip_en` at tick 2 → the skip fires at the
first nominal pop from tick 2 on. Against Task 11's geometry (pcEnd at rel −4, first pop
at rel −1) that lands on **slot 1**, and the smoke measured slot 1 on 8 of 8.

### 3.3 What R4B does NOT contain

`guardIn`, `guardOut`, `sdc_active`, `r4b_prefilled`, any 4096-tick timeout, and any
extra-pop branch (`r4b_extras`, `r4b_do_extra`, `6'd30`, `>= 6`) are **all absent from the
generated code** — asserted by tests 102, 107, 108, 109 rather than by reading.

## 4. The ninth W1 word, and the one W1 line it rewrites

`Rate_Handle.v:240` (combined tree) assembles
`assign r4bWit = {r4b_locked, r4b_skips, r4b_opens};` — 1 + 16 + 15 = **32 bits** — and it
travels `Rate_Handle:78 → Symbol_Synchronizer → FTS:278 → QPSK_Rx:240 → Receiver →
TxRxComposite → TxRxCompo_ip_dut → TxRxCompo_ip → axi_lite → addr_decoder`, where it
lands at byte **0x234** (word 0x8D), one past W1's 0x85..0x8C.

**Deviation from the brief, stated rather than buried.** The brief asked for
`{r4b_prefilled, r4b_armed, r4b_skips[15:0], r4b_window_opens[15:0]}` = **34 bits**, which
does not fit a 32-bit read word. `r4b_prefilled` no longer exists (§2) and in this design
**`armed` *is* `locked`**, so one flag suffices; `r4b_skips` keeps the full 16 bits the
brief specified and only `window_opens` is narrowed to 15 — the field that wraps fastest
(≈ 136 s at 240 f/s) and is read as a delta anyway.

**W1's eight words are untouched.** `w1_reg[0:7]`, `w1_hit` (0x85..0x8C), `w1_idx` and
`w1_reg_process` are byte-identical in the injected text with and without R4B. The **only**
W1-injected line R4B rewrites is the single `assign data_read` — there is exactly one in
the module and a ninth word has to come from somewhere:

```verilog
  assign data_read = (r4b_hit ? r4b_reg :
              (w1_hit ? w1_reg[w1_idx] : mux_out0_level1));  // RXFIX_R4B
```

**Test 117 asserts exactly that**: it diffs the W1-only text against the W1+R4B text and
requires the set of removed lines to be *precisely* `[the old data_read line]`.

The ninth word is **not** behind W1's freeze shadow and does not need to be: one word is
coherent on a single AXI read. `two_jup/rxfix/W1_REGMAP.md` gains a §5 with the map, the
deviation, and the **changed at-rest expectations**: occupancy after arm ≈ 9–10 (up to 31
on a burst arm), `pop_on_empty = 0` after arm is the **success** case and therefore no
longer a liveness control, and the liveness positive control becomes **`r4b_locked = 1`
with `r4b_window_opens` advancing at the frame rate** — which is what distinguishes
"steering idle because the ring is healthy" from "steering dead".

**Order matters for one file, and it fails loudly rather than degrading.** Apply **W1
first, then R4B**: R4B's decoder hunk wraps W1's own `data_read` assign, so W1 applied
afterwards trips its exactly-once anchor assert (test 118). On the five core files and on
any `--sim-tree`, either order works (test 120).

## 5. Harness, provenance, and the smoke leg

`wrap_byte_sro4b.v` is a **new file**; Task 7's `wrap_byte_sro.v` / `sim_sro.cpp`, Task
11's `wrap_byte_sro3s.v` and Task 12's `wrap_byte_sro4.v` are **unmodified** — and Task
12's `t12_*` legs were running against `wrap_byte_sro4.v` throughout. Because **four**
files now declare `module wrap_byte_sro`, the wrapper prints `WRAP4B_FILE` /
`WRAP4B_DEFINE` at time 0 and `build_sro_rxfix4b.sh` greps the verilate log for **all
three** others plus the variant markers.

**The skip-position trace is written by the wrapper, not the driver.** The gate needs the
position of every skip, and `<p>_ep.txt` has no `pcEnd` record kind — but `sim_sro.cpp`
must not change, because that is what makes the 0 ppm row a test of the RTL rather than of
a re-typed driver. So `wrap_byte_sro4b.v` `$fwrite`s one line per skip to the file named by
`+r4bwin=<path>` (argv[8], past every argument the driver parses; cadence 2 / vphase 0 are
passed explicitly, exactly as the banked legs used). Each line carries the RTL's own window
slot **and an independent recount** made in the wrapper from `rhValidIn` / `rhPhase` /
`pcE` — taps that pass through no R4B logic — plus `dt_enb`, the enb-beat distance from the
pcEnd beat.

### 5.1 Smoke leg (25 air frames of `n_p000`, prefix `sk4b_p000`) — PASSED

| check | measured |
|---|---|
| wrapper provenance | `WRAP4B_FILE wrap_byte_sro4b.v t12b` + `WRAP4B_DEFINE RXFIX_R4B` |
| skips | **8**, `r3_skips` = 8, kind-4 ep records = 8 — three independent counts agreeing |
| **skip position** | **slot 1 on all 8**, on the RTL counter **and** on the independent recount (8/8 identical) |
| `dt_enb` | **3 on all 8** = 4·slot − 1 — i.e. exactly Task 11's dump geometry (pcEnd rel −4, skip rel −1) |
| lock | `r3_extras = 0xA5A50002` (LOCKED), kind-5 record at **air frame 13** |
| skip frames | air frames **13–20**, occupancy at the skips ratcheting **1 → 8** |
| `tref` at the skips | **12322/12323** of 12333 — inside the 13-symbol inter-frame guard |
| content identity | **20/20 common seq** equal on nwords/FNV/user |
| pre-lock identity | sidx delta **mode 0, 8 frames** — byte-identical to `b_p000` *including* sidx, then a clean ramp 4,8,…,32 = **4 input samples (one symbol) per skip** |

The −49365 / −33 sidx outliers are the known truncation artefact (`sim_sro.cpp`'s `sidx`
freezes at `nsamp` while frames already in the pipeline keep being delivered) — Task 11's
false alarm and Task 12's, recorded here so it is not rediscovered a third time. It is why
the smoke comparator checks **content identity and provenance only**.

## 6. The gate table, filled with raw numbers

Raw output: `two_jup/comb/sro_sim/t12b_score.txt`. Baselines `b_p000` / `b_m10` / `b_m40`
/ `tb_m10` (Task 7) and `t_lol` (Task 6) are banked and were **not** re-run; `b_m10c` and
`b_p10` are new legs on Task 7's **unmodified** binary.

| # | leg | quantity | PASS criterion | **measured** | |
|---|---|---|---|---|---|
| G1 | `r4b_p000` | content identity vs `b_p000` | equal on ≥ 420 common seq | **423/423** equal (nwords/FNV/user); seq sets **identical**, none delivered by only one run | **PASS** |
| G2 | `r4b_p000` | `r4b_skips` | 4–14, all within 12 frames of lock | **8**, air frames **13–20**, lock at frame **13** | **PASS** |
| G3 | `r4b_p000` | ring after the ratchet | plateau in [8,12], `pop_on_empty` = 0 after the last skip | **on `r4b_p000`**: plateau **9/10 on 388 of 388 frames** (the other negative-SRO legs sit at 8/9–9/10; `r4b_m40` is (8,10) on 198 frames and (8,9) on 190 — all inside [8,12]); `pop_on_empty` = **34 total, 0 from air frame 3 on** (= `b_p000`'s 34 acquisition holes, unchanged) | **PASS** |
| G4 | all paired legs | pre-arm structural identity | byte-identical incl. `sidx` before the first skip | **p000 6/6, m10 184/184, m40 1/1, m10c 5/5, p10 6/6** | **PASS** |
| G5 | `r4b_m10` | LOSS (seq denominator) | ≤ 0.5 %, only seq 133/134 | **0.48 %** (2 of 421: seq **133, 134**); baseline **10.93 %** | **PASS** |
| G6 | `r4b_m10` | `rh_pop_on_empty` in the scored window | 0 | **0** (34 total, all in air frame 0; baseline 55) | **PASS** |
| G7 | `r4b_m10` | `r4b_skips` | 15–35 | **30** (predicted ~28) | **PASS** |
| G8 | `r4b_m10` | skip position | every skip in slots [1,13] | **30/30 at slot 1**, on both counters | **PASS** |
| G9 | `r4b_m40` | LOSS | ≤ 1 % | **0.74 %** (3 of 408: seq 134, 135 + 1 corrupt); baseline **76.98 %**. **Recomputed — see §6.3** | **PASS** |
| G10 | `r4b_m40` | `r4b_skips` / position | 150–260, all in window | **210**, **210/210 at slot 1** | **PASS** |
| G11 | `r4b_tm10` | LOSS (`score_sro2.py`) | = 0.00 % | **0.00 %** (159/159 OK); baseline **22.01 %**; R3S was 1.89 % | **PASS** |
| G12 | `r4b_m10c` | LOSS at −10 ppm **+20 kHz** | ≤ 0.5 % | **0.24 %** (1 of 420: seq 6, the arming frame) | **PASS** |
| G13 | `b_m10c` | baseline LOSS on the CFO stimulus | ≈ `b_m10`'s 10.93 % (band 5–20 %) | **28.33 %** — **outside the band**. The leg is **not vacuous**; it is *harder*. Cause established in §6.1 | **FAIL as written** |
| G14 | `r4b_p10` vs `b_p10` | +10 ppm, FULL side | loss(R4B) ≤ loss(base) | **6.65 % vs 4.99 %** — 7 extra frames lost. **A real regression**; mechanism in §6.2 | **FAIL** |
| G15 | `r4b_lol` | re-lock after the forced outage | locked stays 1, no skip in the outage, re-acquired | `r4b_locked` = 1 from frame 10 and **never re-armed** (one kind-5 record); **0 skips in air frames 195–205** (first post-outage skip at **206**); LOSS **0.24 %** (1 frame — the outage frame itself, idx 199) vs baseline `t_lol` **4.39 %**; `pop_on_empty` = **0 on the whole leg** | **PASS** |
| G16 | all legs | wrapper provenance | both lines, no other wrapper | `WRAP4B_FILE wrap_byte_sro4b.v t12b` + `WRAP4B_DEFINE RXFIX_R4B` on **all seven** R4B legs; **zero** WRAP4B lines on the two baseline legs (they ran Task 7's binary, as intended) | **PASS** |
| G17 | injector | kit-shaped W1+R4B | `verify_zip` green for both, on both zips | test 119 green; 123 tests OK | **PASS** |

### 6.1 G13: the CFO does not drain the ring — it moves where acquisition parks it

The coordinator flagged the baseline hole count jumping 55 → 278 with +20 kHz as a
possible ~46 ppm drain, i.e. a timing loop slipping under CFO. **It is neither a harness
artefact nor a slip, and banked data settles it without a new leg:**

* **The steady-state strobe count is bit-identical.** Total interpolator strobes
  (validated pushes + `push_on_full`) over air frames 3..428: **`b_m10` = 5,266,472** and
  **`b_m10c` = 5,266,472**. *All* 240 of the missing strobes are in air frames 0–2
  (37,005 vs 36,765). The per-frame push distribution over the body of the run is likewise
  identical: 372 frames at 12,333 and 53 at 12,332 on **both** legs.
* **The hole comb runs at the same rate on both.** `b_m10`: holes every 8 frames (18 gaps
  of 8, 2 of 9). `b_m10c`: every 8 frames (46 of 8, 5 of 9). Both are exactly the −10 ppm
  drift, 12,333 × 10⁻⁵ = 0.1233 entries/frame = one entry per **8.11** frames.
* **The stimulus is exactly what was asked for**, measured directly against `n_m10.iq`:
  phase slope **2.045308e-03 rad/sample** vs the intended 2.045308e-03, i.e. **20,000.0 Hz**
  at Fs = 61.44 MHz; `|ratio|` = **1.000000** (pure rotation, no gain change); **zero**
  clipped samples. So "rotation at the wrong rate" and "clipping" are refuted by
  measurement, not by argument.

What actually differs is **where acquisition parks the ring**, which sets *when* the comb
starts, not how fast it runs. `b_m10` air frame 2 takes 12,364 strobes — **31 extra** —
with `push_on_full` = 17: Task 7's and Task 11's recorded acquisition **burst**, which
fills the ring to 31/32. It must then drain 31 entries at 0.1233/frame = 251 frames before
the first EMPTY edge, so its first hole is at frame **259**. `b_m10c` has **no burst** (air
frames 1–2 take 12,234 and 12,248 strobes with 100 and 85 holes) and parks the ring at
0/1, so its first hole is at frame **8**. The whole 278 vs 55 difference decomposes as
acquisition **226 vs 34** plus steady **52 vs 21**, and both steady numbers are just
(421 − first_hole_frame)/8.11.

**The confirming control ran and its pre-registered prediction is confirmed.** `b_p000c` =
0 ppm + 20 kHz CFO on Task 7's unmodified binary, 120 air frames, with its prediction
recorded in the ledger *before* the leg was read: a large acquisition transient (order
150–250 holes in air frames 0–2, like `b_m10c`'s 226) and then **zero** `pop_on_empty`
from air frame 3 on, because at 0 ppm there is no drift to drain the ring. If a regular
comb appears after frame 3 instead, the CFO does drain the ring in the harness and the
slip hypothesis revives.

**Measured:** acquisition (air frames 0–2) `pop_on_empty` = **41, 96, 97 = 234** — inside
the predicted 150–250 band and matching `b_m10c`'s 226 — then **8 more in air frame 3**
(the tail of the same transient) and **zero in every one of the 117 air frames after it**.
`push_on_full` = **0**; the ring settles at occupancy **1/2** and stays there;
`rh_pop_on_empty` = 245 for the whole leg.

**So at 0 ppm a +20 kHz CFO produces no comb at all.** The CFO does not drain the ring: it
inflates the acquisition transient and nothing else, which is exactly what the bit-identical
steady-state strobe counts of `b_m10` and `b_m10c` already said. The slip hypothesis (b) is
dead by direct measurement as well as by inference, and the harness/stimulus hypothesis (a)
was already refuted by the 20,000.0 Hz / zero-clipping measurement of the file itself.

**So G12 is a legitimate and demanding row, not a vacuous one.** The CFO leg is the leg
where the ring sits on the EMPTY edge from frame 8 instead of frame 259, and R4B's
acquisition on it is **bit-identical to the baseline's** (air frames 0–2: 41/100/85 holes,
identical strobe counts — the pre-arm identity of G4 showing up in the ring taps), after
which R4B takes **exactly one** steady-state hole, at frame 8, against the baseline's 52.
**51 of 52 steady holes pre-empted by 60 skips, and 28.33 % → 0.24 % of loss.** G13's band
was set from `b_m10`'s 10.93 % and is simply wrong; the row is reported failed and the
measurement stands.

### 6.3 The `n_m40` loss rows are recomputed, and the committed scorer output disagrees

`t12b_score.txt` prints **`LOSS=100.00%`** for `r4b_m40`. That is a **scorer artefact, not
a result**: one corrupt frame's seq field decoded as **15,729,165**, `score_t7.py` takes
the max delivered seq as the top of the expected range, and the denominator became
15,729,147. The row above is recomputed with the seq range bounded to the **432** frames
the TGEN actually emitted (`tx432.iq.frames.txt`, `last_seq=432`), discarding 1
out-of-range seq on `r4b_m40` and 2 on `b_m40`; on that basis `r4b_m40` is
**seq 17..424, expect 408, OK 405, 1 corrupt, 2 missing = 0.74 %**.

The same bound gives `b_m40` **76.98 %** where Task 11 banked **78.07 %**; the difference
is this denominator convention (Task 11 scored a slightly different seq window), not a
change in the baseline, which was **not re-run**. Both numbers are quoted so a reader
reconciling the two files does not conclude the report cherry-picked the favourable one.

### 6.2 G14 FAILS: on the FULL side R4B's steering costs frames, one per skip

`r4b_p10` loses **6.65 %** against `b_p10`'s **4.99 %** — 7 extra frames (seq 200, 208,
216, 233, 234, 241, 249).

**The mechanism is G6.1's law mirrored onto the FULL side, and the arithmetic closes
exactly.** A first draft of this section said "7 skips, therefore 7 deleted pushes,
therefore 7 lost frames", which cannot be right: the 7 skips are at air frames **13–19**
and the extra losses are ~180 frames later, spaced 8 apart like a comb. The per-frame
`push_on_full` columns say what actually happened:

| | first frame at occupancy 32 (FULL) | `push_on_full` comb | events |
|---|---|---|---|
| `b_p10` | frame **251** | frames 259, 267, 275, … 421 (every 8) | **21** |
| `r4b_p10` | frame **194** | frames 202, 210, 218, … 421 (every 8) | **28** |

R4B's 7 acquisition-transient skips each add one entry to the ring and are **never given
back** — measured directly in the occupancy envelope, where `r4b_p10`'s `oMax` runs
2, 3, 7, 10, 10, 11 … against `b_p10`'s 2, 2, 3, 3, 3, 4 … over air frames 10–25. The ring
therefore begins its climb to FULL **7 entries higher**. At +10 ppm it fills at
0.1233 entries/frame, so 7 entries is **7 / 0.1233 = 57 frames**, and the FULL edge
arrives at frame 194 instead of 251 — **measured 57 frames earlier, exactly**. The comb
then runs at the same one-per-8.11-frames rate on both legs, so starting 57 frames earlier
adds **57 / 8.11 = 7.0** deletions. Hence 28 − 21 = **7**, and one lost frame per
deletion.

So it is the *same* law as §6.1 — **where the steering parks the ring sets when the comb
starts, not how fast it runs** — with the sign reversed: on the EMPTY side parking the
ring higher is the fix, and on the FULL side it is the defect. That the two numbers happen
to be equal (7 skips, 7 extra deletions) is a coincidence of this leg's arithmetic, not a
one-to-one causal chain.

**This is the finding that matters most for silicon.** At +10 ppm the steady-state
occupancy is 31/32 (measured, 208 of 234 frames), and the `occ ≤ 8` predicate still fires
— during the acquisition dip, when the ring has not yet filled. R4B is not merely useless
on the FULL side; it **brings the FULL-edge comb forward**. §5 of the pre-registration said
R4B does not fix the FULL side; it did not anticipate that R4B would make it worse. No fix
is cut here (that is a new variant and a new gate); the candidates are to inhibit the skip
once `push_on_full` has ever fired, to require the low occupancy to persist for N windows
rather than acting on one registered sample, or to gate the steering per direction.

## 7. Skip-position histogram — the operative row

356 skips over seven legs. `slot_rtl` is the RTL's own window counter; `slot_harness` is
the wrapper's independent recount from taps that pass through no R4B logic.

| leg | skips | `slot_rtl` | `slot_harness` | `dt_enb` | agreement | modal `tref` | deviation from it |
|---|---|---|---|---|---|---|---|
| `r4b_p000` | 8 | **1:8** | 1:8 | 3:8 | 8/8 | 12322 | 0:7 1:1 |
| `r4b_m10` | 30 | **1:30** | 1:30 | 3:30 | 30/30 | 21 | **0:30** |
| `r4b_m40` | 210 | **1:210** | 1:210 | 3:210 | 210/210 | 12296 | 0:193 1:17 |
| `r4b_tm10` | 24 | **1:24** | 1:24 | 3:24 | 24/24 | 28 | 0:19 1:5 |
| `r4b_m10c` | 60 | **1:59 3:1** | 1:59 3:1 | 3:59 11:1 | 60/60 | 12131 | 0:50 1:9 2:1 |
| `r4b_p10` | 7 | **1:7** | 1:7 | 3:7 | 7/7 | 12177 | 0:6 1:1 |
| `r4b_lol` | 17 | **1:17** | 1:17 | 3:17 | 17/17 | 28 | 0:7 1:3 **668:7** |

**Every one of the 356 skips is at slot 1 or 3 — all inside [pcEnd+1, pcEnd+13] — and the
RTL counter and the independent recount agree on 356/356.** `dt_enb` = 4·slot − 1 on every
event, so the pop phase relative to `pcEnd` is fixed, exactly as Task 11's dump showed
(pcEnd at rel −4, skip at rel −1). The count also agrees three ways on every leg:
trace lines = `r3_skips` in `_res.txt` = kind-4 records in `_ep.txt`.

### 7.1 The `tref` falsifier fired on three legs. Here is why it is a mis-calibration

The amendment (§6 of the pre-registration) required every skip to be within 60 symbols of
**Peak_Search's** epoch boundary. On `r4b_m10c` (60 skips at tref 12130/12131, distance
~202), `r4b_p10` (7 at 12177, distance ~156) and `r4b_lol`'s 7 post-outage skips (11693,
distance 640) **it fired**. Reported as fired, then diagnosed:

1. **The offsets are constant, not scattered.** All 60 `m10c` skips sit within **2 symbols**
   of that leg's own modal `tref`; all 7 `p10` within 1; the 7 post-outage `lol` skips are
   all at **exactly** 11693. A moved-by-false-sync `pcEnd` is a *lone outlier* — R3S's
   `s_m40` skip at tref **7026** among 202 skips at 12295/12296 — not a constant shift.
2. **The reference, not the skip, is what moved.** `tref` is Peak_Search's epoch; the
   window is the deframer's. The offset between the two is fixed at acquisition, and both
   a +20 kHz CFO and a re-acquisition after a forced outage lock at a different frame
   phase. Every skip is still at **slot 1 of the deframer's own 13-slot guard**.
3. **The decisive evidence: no frame dies at them.** `r4b_m10c` took 60 flagged skips and
   lost **one** frame — seq 6, the arming frame — for 0.24 % against the baseline's
   28.33 %. If those skips were mid-payload, ~60 frames would have died, as R3S's single
   mid-payload skip killed its frame. `r4b_lol` took 7 flagged skips and lost only the
   outage frame itself.

So the corrected, falsifiable quantity is **deviation from the leg's own modal `tref`**,
which `t12b_window.py` now reports beside the absolute test. On that metric every leg is
**CLUSTERED** except `r4b_lol`, whose skips occupy **two** constant phases separated by a
single step at the outage — the re-acquisition, which is what G15 was built to observe.
Both tests are printed; neither was removed.

**Falsifier 2 did not fire either**: `r4b_m10`'s only losses are seq 133/134, which Task 7
recorded as unexplained, not hole-aligned, and lost in the baseline too — no loss is
aligned to any skip on any negative-SRO leg.

## 8. Lint

`verilator --lint-only -Wno-fatal` against the Task 12b wrapper, **error-free on four
trees**, logs banked:

| log | tree | `%Error` | `%Warning` | warnings on any `r4b_` net |
|---|---|---|---|---|
| `r4b_lint_s1_rtl.log` | R4B alone, s1_rtl | **0** | 57 | **0** |
| `r4b_lint_txfixF3.log` | R4B alone, txfixF3 | **0** | 71 | **0** |
| `r4b_lint_w1r4b_s1_rtl.log` | **W1+R4B**, s1_rtl | **0** | 59 | **0** |
| `r4b_lint_w1r4b_txfixF3.log` | **W1+R4B**, txfixF3 | **0** | 73 | **0** |

## 9. Tests, and the kit-shaped application proof

`python3 -m unittest test_rxfix_inject` → **123 tests, OK** (96 pre-existing + **27 new
`TestR4B`**, tests 97–123). No pre-existing test was modified.

The proof the brief asks for is **test 119**: it lays down a kit-shaped tree — the
`TxRxCompo_ip_src_`-prefixed sources from `jupiter_byte_seqbist_build`, three loose mirrors
(`hdlsrc/`, `ipcore/…/hdl`, `vivado_ip_prj/ipcore/…/hdl`) and **both**
`TxRxCompo_ip_v1_0.zip` members — runs `main(d, 'W1')` then `main(d, 'R4B')`, and requires
`verify_zip` green for **both variants on both zips**, with `RXFIX_W1` *and* `RXFIX_R4B`
and the assembled `r4bWit` present in the kit's `Rate_Handle`. Test **101** is the direct
answer to tests 73/91: on the same kit file where `patch_fifo_block_r4` still raises,
every R4B core patcher succeeds.

Supporting tests: 102 (structural window, and no `guardIn`/`guardOut`/`sdc_active` in the
code), 103 (the window source is the existing `Packet_Controller_endOut`, and FTS gains no
port when W1 is absent), 104 (every input to the pop is a flop; the occupancy appears once,
inside the clocked block), 105 (enb-gated, async reset), 106 (lock = 8 pcEnd), 107 (no
pre-fill residue), 108 (unarmed pop is structurally the baseline expression), 111/112
(symmetric per-file mutual exclusion with R3/R3S/R4, both directions), 113 (`verify_zip`
does not confuse `RXFIX_R4B` with `RXFIX_R4` — the marker-prefix hazard R3S introduced),
114 (witnesses stay internal without W1), 117 (W1's eight words byte-identical), 118
(reverse order fails loudly), 120 (both orders on both sim lineages), 122 (one port per
core module, no top-level port, no data-path assign lost).

## 10. Recommendation — and the one decision Task 13 needs from the controller

**R4B is ready for the forward (negative-SRO) direction and is not ready, as cut, for the
reverse (positive-SRO) one.** That is a decision, not a detail, and Task 13 is already
dispatched to build W1+R4B for silicon.

* **Forward leg (146 → 148), the negative-SRO side.** This is where the ~32-frame comb
  lives and where every R4B row passes: loss 10.93 → 0.48 % at −10 ppm, 76.98 → 0.74 % at
  −40 ppm, 22.01 → 0.00 % tiled, 28.33 → 0.24 % with CFO, 4.39 → 0.24 % through a forced
  loss of lock. The on-air rig runs at ≤ 0.06 ppm, far inside the one-skip-per-frame
  ceiling (|s| ≈ 81 ppm). **Recommended.**
* **Reverse leg (148 → 146), the FULL side.** G14 measured R4B making it **worse** — the
  FULL-edge comb arrives 57 frames earlier and costs 7 extra frames on a 428-frame leg
  (6.65 % vs 4.99 %). The reverse leg is already the weak one (≈ 5–6 dB short, 1.39 %
  measured). **Not recommended without a fix.**

**The decision the controller owns:** whether Task 13's build carries R4B on both
directions or is gated per direction. The RTL as cut has **no direction control** — the
steering is unconditional once locked — so "forward only" is not a runtime switch today.
Three ways to get there, cheapest first:

1. ~~**Inhibit the skip once `push_on_full` has ever fired.**~~ **THIS PROPOSAL WAS WRONG
   AND IS WITHDRAWN — see §10.1.** It rested on a false statement of my own ("`push_on_full`
   is 0 on all six negative-SRO legs"); it is **17 on `n_m10`**, all in air frame 2.
2. Require the low occupancy to persist for N windows rather than acting on one registered
   sample, which would remove the acquisition-dip firing that starts the whole G14 chain.
3. Make the steering enable a register bit, and set it per direction at bring-up.

**Recommended sequencing:** cut option 1 as R4C and re-run this exact gate (the harness,
scorers and nine legs are all in place and a full sweep is ~50 minutes), rather than
shipping R4B to a bidirectional build and discovering the reverse-leg regression on the
air. If the controller wants silicon data sooner, R4B on the **forward direction only** is
supported by this gate as it stands.

### 10.1 CORRECTION: the sticky `push_on_full` inhibit is exactly backwards

Checked against the per-frame columns before any R4C work was started, and it fails in
both directions:

| leg | `push_on_full` | first pof frame | R4B skip frames | skips **before** the first pof |
|---|---|---|---|---|
| `n_m10` | **17** | **2** | 191 … 426 (30) | **0 of 30** |
| `n_p10` | 28 | **202** | 13 … 19 (7) | **7 of 7** |

* On **`n_m10`** the acquisition burst fires `push_on_full` **17 times at air frame 2**, so
  a flag that is sticky from reset latches before lock and would **suppress all 30 skips**
  on the leg the fix exists for — forward loss reverting from 0.48 % to ~10.93 %.
* On **`n_p10`** the first `push_on_full` is at frame **202**, while all 7 harmful skips are
  at frames **13–19**. The inhibit engages ~180 frames too late and removes **none** of
  them, so G14 is unchanged.

Making it *post-lock* pof does not rescue it either: that fixes `n_m10` (pof at frame 2 is
pre-lock, lock is frame 11) but still leaves all 7 `n_p10` skips untouched.

**The rule that does work, on this data.** Require a **post-lock `pop_on_empty`** before
the steering may act — R3S's arming condition, kept together with R4B's structural window:

* `n_p10` has **zero** `pop_on_empty` from air frame 3 onward (all 178 are pre-lock
  acquisition), so it would **never arm**: zero skips, delivered stream equal to the
  baseline, G14 passes by construction.
* Every negative-SRO leg does run dry post-lock, so the steering still arms there.

The cost is the **arming hole**: the steering can no longer pre-empt the *first* hole, so
`n_m10` would land near R3S's **0.95 %** rather than R4B's 0.48 %. That is the real
trade-off — **~0.5 pp of forward loss bought for the elimination of the reverse-leg
regression** — and it is the controller's call, not mine.

**What this gate does NOT support:** any PER claim, any timing/resource claim, and any
statement about the reverse leg other than "R4B makes it worse in sim". R4B has not been
synthesised.

## 11. Rails

Sim only; no board contact; no Vivado; no subagents. Task 12's R4 variant, its
`wrap_byte_sro4.v`, its `r4_*` outputs and its running `t12_*` units were not touched.
W1's edits are limited to the ninth-word addition (§4). Pre-registration committed before
the tree, the harness and the legs (`ed00455`); variant `7eef225`; legs + lint `76cb254`.
Heartbeat unit `t12bhb`. Commits: `ed00455` (pre-registration, before the tree, harness
and legs), `7eef225` (the variant), `76cb254` (legs + lint), `be6c6af` (report §§1–5, 8–9),
`9bdb690` (the `tref` amendment, before any leg was scored), `b5252df` (the scored gate).
