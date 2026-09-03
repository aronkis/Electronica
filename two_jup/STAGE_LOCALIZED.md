# 119.75 s beat — STAGE LOCALIZED by direct observation (2026-08-19 night)

**Result: the periodic burst corruption is injected at or before the FEC-decoder
INPUT — the QPSK hard-decision demapper / coded-bit formation stage — NOT in the
Viterbi decode, deinterleaver, descrambler, byte plane, FIFO, or DMA.** Every one
of the five prior refuted fixes targeted stages *downstream* of this. That is why
they were refuted by measurement.

---
## 🏁 FIX VERIFIED ON AIR (2026-08-21 night) — ZERO ERRORS THROUGH SIX SCHEDULED SLOTS

Image 198ade9f234a (BEATFIX: Model-7 phase contract + runtime arms, fixctl@0x208,
default 0 = legacy-identical). Verification per BEATFIX_DESIGN.md (beatfixver_20260821_
185935, all legs arm-health-gated 1246-1247 f/s, 3400 samples @100ms, full-dwell
denominators):
- **fixctl=0 control**: canonical bursts at all 3 scheduled slots (293280/215131/
  293183 — exact species) with the 4+3+4 window staircase.
- **fixctl=3 (contract + serializer anchor), TWO legs: biterr_total = 0 over 340 s
  EACH — zero decode errors through six scheduled beat slots — while the stepping
  events STILL FIRE** (cap_in window steps at the exact slot times, same staircase
  cadence, harmless; contract-framing golden = 0xA90B79F1, Model-7-predicted).
  Damage fully decoupled from the (still-unknown-origin) trigger; the trigger stays
  observable. Legs reproduce sample-for-sample.
- **fixctl=4 (grid-pace arm): HARMFUL** — sustained 69,725 err/s, dominant cap_in
  0xAB7A4307 = the Model-6c-a phase-class kill value. The secondary/fallback arm is
  eliminated with on-silicon evidence; the explicit-contract architecture (position
  carried as data, violations countable) is vindicated end-to-end.
- Known instrument bug: viol_count@0x20C miswired (rail-rate counting) — slot-time
  forensics carried by the cap_in stepping instead; one-line consumer-valid fix next
  build.
Chain complete: localized -> mechanism confirmed on silicon -> fix sim-validated on
the confirmed class -> FIX VERIFIED ON AIR. Remaining: trigger origin (now harmless +
observable), counter wiring fix, PER acceptance soaks with fixctl=3.
---
## LIVE-LINK A/B (2026-08-21 late): decode-layer win confirmed; ONE-CONSTANT framing
calibration required before end-to-end PER credit

beatfix_accept_20260821_200812 (alternating forward acceptance, ARQ off, run1
wedged/excluded): LEGACY PER=10.896% (7189/65980, CP95UL 11.14%). FIX ARM (fixctl=3):
link gate healthier (CRC 98% @1942 f/s vs 92% @898) and fabric-clean frame fraction
IMPROVED 88.45% -> 99.73% — the decode-layer fix is working on the live link — BUT
host_seq frozen (uniq=1): the contract frame boundary sits at a constant offset from
the legacy boundary, rotating payload byte alignment; end-to-end seq/IP framing
unreadable. Fix-arm PER therefore NOT measurable this pass (0/0 is a measurement
artifact, not zero loss — stated per the metrics discipline). The offset is a KNOWN
constant (contract golden 0xA90B79F1 = Model-7's +1-beat displacement value): the
correction is a one-constant tag-anchor calibration in beatfix_overlay + rebuild,
then repeat the A/B. Slot-level zero-error verification stands (BIST comparator is
alignment-independent).
---
## ✅ SILICON CONFIRMATION (2026-08-20 ~23:00) — COHERENT SEQUENCE SHIFT, mechanism CONFIRMED

The first BEATOBS on-silicon state-vector capture (beatcap_20260820_221515, verified
in-window cap_in=0x7871AA08) + golden-sequence correlation (m7_readout_correlate.py,
independently re-verified) delivers the final verdict:

**During verified corruption the ILA-visible coded-bit stream is 100.00% (512/512)
VALUE-PERFECT golden ROM bits at a SHIFTED cyclic sequence position** (in-window offset
5917 vs the gap capture's startOut-anchored 11856 @ 99.80% — method positive-control).
Every in-band state is conserved (pacer 0 violations, phase contract 0/2048, Gardner
dither normal, fill {0,1}, serializer decision->dataOut 0.0%/2044): the corruption is a
COHERENT SHIFT — correct values, wrong sequence position — exactly the 6b-relativity
prediction and byte-consistent with the Model-6 Rate_Handle phase-hold class.

**Travis's rate-boundary hypothesis is CONFIRMED ON SILICON.** The "~50% corruption" at
the FEC is the deinterleave/decode of a sequence-shifted (value-clean) coded stream.
The held windows are held sequence offsets; the species are offset classes; per-point
constellation metrics were structurally blind to it throughout.

Fix territory (per Models 6b/6c, now on a confirmed mechanism): the pop/serialization
sequence phase has no valid in-band re-anchor (marker travels with the shift); the
surviving disciplines are enb-grid-anchored pacing (prevention-grade) or an explicit
downstream phase contract. Design work can now proceed on a silicon-confirmed
mechanism with a bit-exact sim reproduction class in hand.

---
## MODEL 7 (2026-08-21) — PRIMARY-FIX POSITIVE CONTROL: VALIDATED against the silicon
fault class; Model-6 pacer holds RECLASSIFIED

CSV-verified verdicts (m7_* in model1_ce/, commit 8b0e6ee):
- **G1 nominal-lock PASS**: patched (tag-derived framing) clean run byte-identical
  golden, viol=0 — the gate that killed 6b and both 6c variants.
- **G2' — the fix claim VALIDATED on the silicon fault class**: a NEW `--shift-marker`
  injection (persistent per-frame marker displacement) reproduces the silicon
  signature in sim FOR THE FIRST TIME — unpatched it holds value-clean cap_in=
  0xA90B79F1 indefinitely, cadence conserved; **patched it decodes GOLDEN every frame**.
- **RECLASSIFICATION (honest correction)**: the correlator applied to Model-6's pacer
  holds shows they are VALUE-CORRUPT (55.8% ~ chance match to golden at any offset) —
  NOT the silicon's 100% value-clean coherent shift. The pacer holds reproduced the
  hold phenomenology, not the silicon class; the marker-shift injection is the true
  silicon-class reproduction. Consequently G2-as-worded FAILED (pacer holds persist on
  the patched netlist: rh0 silent viol=0; ph2/ph3 counted viol=1 delta=+1) — this is
  the design doc's stated residual exposure (value corruption upstream of the attach
  point), now quantified, and it is NOT the fault silicon exhibits.
- **G3 regression PASS** (transients heal; drop-symval counted once, no miscount).
- **G4**: serializer pair-order flip is below tag granularity (holds A129F3D1,
  viol=0) — production fix image should stack the Model-1 serializer re-anchor.
- **Design-doc corrections found by implementation**: attach point = F&TS output
  inside QPSK_Rx (frame decision does not exist upstream of Rate_Handle in this
  generation; no FIFO widening needed, 2-beat tag transport); tag must be a 14-BIT
  BIT-INDEX (12,320 positions — the doc's 13-bit symbol-index was insufficient).

NET: the explicit phase contract has its sim positive control against the CONFIRMED
silicon mechanism (marker/data displacement), plus a working violation counter.
Follow-ups for the fix build: stack the serializer re-anchor (G4), and note the
counter is silent on value-corrupt-upstream faults (not the silicon class).
---
## ⚠ MECHANISM CORRECTION (2026-08-20, RTL-verified) — supersedes the clk_enable/count2/PPM trigger described later in this doc

The LOCALIZATION above is correct and stands. The *trigger* mechanism I wrote up
later (a `clk_enable` glitch flipping `count2` in `TxRxComposite_tc`, driven by an
SSI clock **PPM** beat) is WRONG and is superseded. Verified against the netlist
(Model-2 trace, re-checked by me):

- **`clk_enable` is STATIC, not a pulse train.** It = `write_axi_enable`
  (`TxRxCompo_ip_addr_decoder.v` resets `data_reg_axi_enable_1_1` to `1'b1`, only
  changes on an AXI write that the run never issues). So `count2` in
  `TxRxComposite_tc.v` **free-runs**; `enb_1_2_0`/`enb_1_2_1` are pure clk/2
  phases, never re-anchored, and **cannot be flipped by a `clk_enable` glitch**
  (a count2 flip needs an AXI enable-register write — an aperiodic arm event).
- **The demod valid is const-1.** `MUX_RxValid_out1 = 1'b1` on both mux legs
  (`TxRxComposite.v:476-481`). `adc_validIn` gates ONLY the front ADC-capture
  register (`:611,:667`). So the whole RX chain (RRC decimation → demap →
  Serializer) is paced by the **free-running clk/2 grid**, decoupled from the
  sample valid.
- **PPM is refuted, not just unproven.** `adc_1_clk` is a BUFGCE_DIV/4 of the
  recovered SSI clock with RX valid in the same domain (single coherent clock
  locally); a 120 s PPM beat would need ~5e-4 ppm vs real ±10-20 ppm; and the
  identical corruption appears in single-clock FPGA-internal loopback.

**Corrected mechanism:** a **one-tick phase slip of the ADC-sample cadence vs the
free-running clk/2 grid** shifts the grid-phase-locked coded-bit selection
(`Serializer.v:135`, `HDL_Counter` on `enb_1_2_0`) → sustained ~50% wrong coded
bits with a pristine constellation, held until re-alignment. This is a **digital,
single-clock slip event** (period = a digital slip-event rate, ~149,100 frames,
rate-dependent), NOT an analog clock beat. Candidate slip source: the
`util_valid_regularizer` already in the BD (unguarded 3-bit `fill` over a depth-4
memory → silent drop under input-rate surplus) — it is instantiated in the
beat-ILA build yet the beat persists, so as-placed it does not close the issue.

**Fix implication:** the "clean-enable / elastic-FIFO / single-coherent-clock"
root fix I proposed is NOT the lever (already single-clock; regularizer already
present but flawed). The real fix is **(1) per-frame `startIn` re-anchor of the
serialization/decimation phase** (general — immune to any cadence slip) **+
(2) a full/overflow guard on `util_valid_regularizer`** (closes the identified
slip source). Being validated in sim (Models 1 & 2, tasks #60/#61).

Everything below predates this correction; read it as the investigative trail,
with the trigger claims replaced by the paragraph above.

### UPDATE 2 (2026-08-20, Models 1+2+3 — elimination result)

Three Verilator models (bit-matched netlist) systematically ELIMINATED every
transient trigger and refined the requirement. Sim CONFIRMED it reproduces both
hardware goldens (cap_in 0x5216F3E2, cap_out 0x04922282).
- **Eliminated (all heal / benign, do NOT hold):** front-end `adc_validIn` slips
  (drop 1/4/16/64, insert, periodic 200x — absorbed by per-frame preamble
  re-acquisition); post-demapper symbol drops (`--drop-symval`, heal in <=2
  frames, verified in `model1_ce/m3_dropsymval_*`); `count2` flip and `clk_enable`
  drop (benign uniform re-timings). So the `util_valid_regularizer`-drop-as-source
  idea is REFUTED in sim.
- **Holds but wrong cardinality:** a Serializer `HDL_Counter` (1-bit) phase flip
  HOLDS a constant-wrong cap_in — but only ONE value (0xA129F3D1). Hardware
  species-A has FOUR.
- **`startIn` re-anchor fix does NOT generalize:** it heals the serializer-phase
  flip (validated) but is byte-identical to unpatched on the symbol-drop leg — it
  fixes coded-bit PAIR ORDER only, not symbol framing/phase. **NOT a general fix.**
- **Requirement, proven by elimination:** under identical-ROM loopback cap_in is a
  deterministic function of the receiver's PERSISTENT state; a held 4-value species
  needs a **persistent transformation with state space >=4**. A 1-bit serializer
  gives 1. The structural fit is a **4-fold phase/quadrant resolution state** (or a
  mod-4 phase pointer) — post-frame-sync (constellation stays clean), ~50% when
  wrong, held. **NOT yet injected/confirmed** (the derotation corrector is
  continuous, no clean discrete handle; it re-resolves against the preamble like the
  transient slips). CAVEAT: the earlier cap_in rotation-transform test found no clean
  90/180/270 match (min Hamming ~11/32) — a weak counter-indication to *pure*
  carrier rotation, so the >=4-state element may be a different mod-4 phase, not the
  carrier resolver. Next evidence must inject/observe that specific persistent state
  (sim: find the 4-state register; or hardware: observe it during a window).
Reports: `two_jup/MODEL1_ENABLE_INJECT.md` (Models 1&3), `two_jup/MODEL2_CLKEN_SOURCE.md`.

### UPDATE 3 (2026-08-20, Models 4+5) — RETRACTED IN PART by UPDATE 4: "exonerated" was an overclaim

Model 4 (persistent >=4-state registers: ambiguity latch, carrier NCO, interpolator mu,
compound x serializer) and Model 5 (operator-hypothesized standing valid-train phase
offset vs the free-running grid, via a new mid-run `--delay-valid` train-slip injection
plus initial-vphase controls): **both FALSIFY under pre-stated verdict rules** (every
injection heals or is absorbed with zero dirty frames; verified from CSVs). Model 5's
structural trace closes the search: the RX chain is *valid-phase-blind by construction*
(`Receiver.validIn` const-1; `adc_validIn` exists only at the front AdcCap re-timer,
which resamples onto the enb grid and erases any standing offset; the internal
ROM-loopback path has no adc_valid seam at all) — which is WHY every valid manipulation
across all models was invisible downstream.

**Converged conclusion of the 5-model campaign:** every mechanism expressible in the
bit-matched RTL netlist — transient slips, persistent register states, and standing
cadence/grid phase — is eliminated by measurement. The beat mechanism therefore lives
OUTSIDE the RTL model, in the physical implementation: the synthesized clock/enable
network (consistent with the witness forensic ebbf4eb: the enable/rail network re-hosted
into the AXI addr decoder by synthesis), or a physical effect the noiseless single-clock
sim cannot express. This also retro-explains why both idealized sims never showed the
beat. The ONLY discriminating instrument left is on-silicon observation: the supervised
ILA probing the demapper decision bits, resolution state, serializer phase, and enable
rails DURING a held window — RTL-correct probed state + wrong output = implementation
divergence proven at the exact site.

### UPDATE 4 (2026-08-20, Travis rate-boundary hypothesis) — RTL is NOT exonerated

UPDATE 3's "every mechanism expressible in the RTL is eliminated" was an OVERCLAIM:
the models eliminated every mechanism they INJECTED; the enumeration was incomplete.
Travis's hypothesis (a rate-change boundary where serialization and the enable cadence
can disagree, giving a persistent mod-4 phase state) identifies real, UNTESTED hardware:

**`Rate_Handle` (u_Symbol_Synchronizer, upstream of the demapper), `Rate_Handle.v`:**
a 2-bit `HDL_Counter_out1` wrapping at `2'b11` — a literal MOD-4 pointer — paces pops
from `FIFO_block`; `FIFO.v` has FREE-RUNNING 14-bit `Push_Counter_out1`/
`Pop_Counter_out1` never re-anchored to `startIn`. Push = Gardner symbol strobe
(loop-controlled cadence); pop = grid fraction. A push/pop relative-offset slip is
persistent by construction; mod-4 pop phase x symbol offset gives a multi-species
state space. Models 1-5 never injected these pointers (Model 3's symbol-drop was
DOWNSTREAM of this FIFO).

**Key inference error corrected:** the "datapath clean during corruption" evidence used
PER-POINT constellation metrics (EVM/rotation/spread), which are BLIND to SEQUENCE
errors — a pointer slip repeats/drops a symbol while every sample still lands on a
tight, correctly-placed constellation point. Clean per-point constellation does NOT
exclude a sequence-corrupting mechanism at this FIFO.

**Travis's fixed-enable-count arithmetic, checked honestly:** canonical 119.75 s @
1245 f/s = 149,089 frames = 1.84e9 enb_1_2_0 events (15.36 MHz); degraded 6.7 s @
341 f/s = 2,285 frames = 1.03e8 events. Ratios: seconds 17.9x, frames 65x, rate 3.65x.
NO single fixed count (frames or enable events) predicts both periods — the simple
fixed-count invariant FAILS. But the BEAT form of the same mechanism (period ~
1/|f_push - f_pop|) is hypersensitive to cadence changes — a 3.65x rate change
trivially yields a 17.9x period change — and the degraded datapoint is contaminated
anyway (different anatomy: 68-76k errs, 3.7 s durations, re-acquisition cycling). So
the arithmetic refutes the simple invariant, NOT the mechanism.

**MODEL 6b (fix leg): frame-start re-anchor of the Rate_Handle pacer KILLED — inert.**
Nominal-lock gate passed (patched clean byte-identical golden), but the held injection
persists unchanged on the patched netlist (verified: m6b_rh0 holds ab7a4307 x11).
Mechanism: the FRAME MARKER TRAVELS WITH THE POPPED DATA — a pop-phase slip shifts the
anchor's own reference, so "pacer phase at frame start" is invariant under the fault;
any frame-anchored correction is causally downstream of this element. Surviving fix
class (Model 6c, running): remove the free-running relative phase itself — occupancy-
based popping (pop only when FIFO non-empty) or slaving the pop pacer to the Gardner
push strobe. Model-6 refinement: the holders are POP-EARLY phase advances (3->0,2->0 ->
ab7a4307; 1->0 -> 57b5830b); pop-late/pop-lost/pointer steps heal; serializer-parity
compounds permute rather than extend the species set; staircase not reproduced in sim.

**MODEL 6c: occupancy-pop AND push-slaved pacer BOTH KILLED at nominal-lock — and the
kills complete the mechanism picture.** (a) occupancy-gated pop: the CLEAN run never
reaches golden and settles at ab7a4307 (verified m6c_occ_clean, x16) => **the pop-beat
phase mod 4 is functionally CONSUMED downstream (a hidden contract with the derotation/
demap path): golden = ONE specific phase class, and the Model-6 held species ARE this
phase variable.** (b) push-slaved pacer: chaotic cap churn after warmup (verified) —
the Gardner strobe dithers 3/4/5 beats even in noiseless steady lock; **the FIFO +
free-running pacer IS the dither absorber** and must not follow pushes. Fix-space
characterization (6b+6c product): the pacer phase has NO valid in-band discipline
reference (frame marker moves with the fault; occupancy & push strobe move with
legitimate dither); the only agreeing invariant is the enb grid itself. Minimal
hardening: make the pacer count every enb beat unconditionally (validIn const-1 =>
nominal bit-identical by construction) — prevention-grade vs data-side transients, NOT
SEU-self-healing. The silicon question is therefore sharpened: WHAT steps the phase
class every ~119.75 s — exactly what the BEATOBS capture reads directly.

**MODEL 6 VERDICT (coordinator read of committed CSVs; agent report pending): PARTIAL
— holding-element CLASS CONFIRMED.** Rate_Handle mod-4 state injections HOLD >=10
frames with TWO distinct held species (0xab7a4307 via rh0/ph2, 0x57b5830b via ph3/
compound; compound transits the serializer species 0xa129f3d1 for one frame — the state
spaces compose). Cardinality 2<3 and bit-exact 0/7 => identity NOT established; the
first holding element of the campaign, matching the hardware fingerprint CLASS. The
BEATOBS capture reads the rh counter + FIFO fill directly: an rh-phase step at a window
boundary on silicon names the mechanism regardless of bit-exactness.

**Fit to the window staircase:** successive pointer slips ~1.8 s apart, each stepping
the persistent offset, would produce consecutive ~1 s windows each holding a DIFFERENT
constant cap_in — the observed staircase — with species count = slips per burst (4 vs
3). Model 6 (launched, sim) injects Rate_Handle HDL_Counter states and push/pop offsets
under the standard verdict rule, incl. a two-step staircase leg. BEATILA-3's capture
still discriminates: this mechanism presents as Readout B with a WRONG DECISION
SEQUENCE at clean per-point geometry.
---

## How it was found — zero rebuild

The shipping DUT already contains a purpose-built RX-processor pipeline forensic
harness (`FecCapture`, `FecCounters`, `Capture_Data_Bits`), AXI-readable on the
flashed build-1 beat-ILA image. Register map (base `0x9D000000`,
offset = addr_decoder select<<2; anchors verified against docs:
`bit_errors_out` sel 0x42→`0x108`, `cap_out` sel 0x51→`0x144`):

| reg | off | meaning |
|---|---|---|
| `bit_errors_out` | 0x108 | BIST comparator, cumulative (burst detector) |
| `cnt_frame_start` | 0x124 | frame-start events |
| `cnt_vit_reset` | 0x128 | Viterbi resets (1/frame) |
| `cnt_deint_valid` | 0x12C | deinterleaver valid outputs |
| `cnt_dec_bits` | 0x130 | decoded bits |
| `cnt_bist_start` | 0x134 | BIST frame starts |
| `cap_in` | 0x13C | **per-frame 32-bit hash of the first 32 coded bits at the FEC-wrapper INPUT** |
| `cap_deint` | 0x140 | 32-bit hash after DEINTERLEAVE |
| `cap_out` | 0x144 | 32-bit hash at DECODER OUTPUT (golden `0x04922282`) |

`FecCapture` re-arms each hash at `startIn` (every frame). Under the repeating
in-fabric ROM source every frame's first-32-bits are identical → each cap is a
**constant golden** between bursts; a cap that leaves golden during a burst means
the actual data at that stage changed (these are hashes of data, NOT comparisons —
so divergence cannot be a comparator-reference slip).

Instrument: `two_jup/stage_poll.c` (mmap `0x9D000000`, read-only, monotonic-ms CSV,
10 Hz) driven by `two_jup/layerA_stage_poll.sh` (quiesce → arm BIST ROM →
**arm-health gate ≥1000 f/s, restore×2 retry on the #48 lottery** → 340 s poll →
two-pass restore). Analyzer `two_jup/analyze_stage_poll.py`.
CSV: `two_jup/r3cap/stagepoll_20260819_211415/`.

## The evidence (run 2026-08-19 21:14, arm-health 1247 f/s, 3400 samples @10 Hz)

Three canonical bursts, exact byte-identical species sizes and the 119.75 s law:

```
burst t=81..87s  size=293183   (species A)
burst t=203..207s size=215030  (species B)   interval 122 s
burst t=323..329s size=293183  (species A)   interval 120 s
```

**Discriminator 1 — frame cadence PERFECTLY conserved through every burst:**
```
packets_out / cnt_frame_start / cnt_vit_reset / cnt_bist_start = 1244/s
  baseline AND all three bursts (identical to the part-per-thousand).
cnt_deint_valid ~15.30M/s, cnt_dec_bits ~15.25M/s — steady.
```
No frame slip, no sync loss, no stage stall. This **rules out the frame-alignment /
capture-window-shift artifact**: the capture arming (at a stable `startIn`) is not
moving, so cap divergence is real data change, not a windowing phase shift.

**Discriminator 2 — the three FEC-stage caps diverge TOGETHER, on the same frames,
every time.** Per-sample golden-status pattern inside bursts is `IDO` (all three
deviate) for 100 % of deviating samples — never `..O`, `.D.`, or `I..` alone:
```
burst 81-87s : 61 samples, 32 deviating — ALL 'IDO'
burst 203-207s: 41 samples, 22 deviating — ALL 'IDO'
burst 323-329s: 61 samples, 35 deviating — ALL 'IDO'
```
`cap_in` (FEC-wrapper INPUT) is dirty whenever anything downstream is dirty. The
deinterleaver and Viterbi faithfully propagate already-corrupt input. **The
injection is at or before `cap_in`.**

**Discriminator 3 — deterministic, species-keyed corruption.** The deviating hash
values REPEAT across same-species bursts: @81 s and @323 s (both species A) show the
identical corrupt set at every stage
(`cap_in` ∈ {0x63F21D7D,0x70DF4D74,0x7871AA08,0xF6A4BC60}, etc.); species B (@203 s)
shows a different set. Two discrete species = two frame-number phases of one
deterministic digital event — consistent with byte-identical species across
FPGA-internal loopback, SSI near-end loopback, and board 146.

## Where this puts the fault

Chain (established from the generated netlist,
`.../hdlsrc/commhdlQPSKTxRxLoopback/`):

```
symbol sync (soft IQ)  →  QPSK demapper (soft→coded bits)  →  [cap_in]  →
  deinterleave  →  [cap_deint]  →  Viterbi/ACS decode  →  [cap_out]  →
  descramble  →  byte assembly (ByteWordBuffer/Serializer/RxFifo)  →  DMA
```

- Prior ILA (build-1, timed to a burst): post-symbol-sync **soft constellation
  pristine** (~40 dB EVM, 0/4096 soft-error symbols) → the demapper INPUT is clean.
- This poll: `cap_in` (demapper OUTPUT, the coded bits into FEC) **dirty during the
  burst**.

Clean-in / dirty-out **across the demapper** ⇒ the corruption is injected in the
**QPSK hard-decision demapper / coded-bit formation / FEC-input routing stage** —
the narrow window between the clean soft symbols and the coded bits entering the
FEC decoder. Nothing downstream (Viterbi, deinterleave, descramble, byte plane,
FIFO, DMA) is the origin; they inherit the fault.

## Mechanism hypothesis (from RTL inspection — NOT yet observed on silicon)

The demapper chain (from the netlist) is:
```
Frequency_and_Time_Synchronizer (soft IQ, the CLEAN constellation)
  -> QPSK_Demodulator_Baseband (hard quadrant decision, 2 bits/symbol: u_0,u_1)
  -> Serializer  (2 bits -> 1 serial coded bit, driven by enb_1_2_0)
  -> dataOut = bitsIn -> FEC_Decoder_Wrapper  [cap_in hashes this]
```
`Serializer.v` emits the pair {u_0,u_1} one bit per `enb_1_2_0` cycle, sequenced by a
**1-bit phase counter `HDL_Counter_out1`** (Multiport_Switch: counter==0 -> u_0,
counter==1 -> u_1). That counter free-runs on valid activity
(`Logical_Operator_out1 = Delay1|Delay4`) gated by `enb_1_2_0` — it is **NOT re-synced
to `startIn`/frame boundaries**. A single glitch or metastable sample on `enb_1_2_0`
or `In2` flips the counter phase, so the two coded bits are emitted in swapped order
until something re-aligns it.

### What the burst arithmetic actually says (corrected)

A held phase flip across a 5–8 s window would garble all ~7,000 frames at ~50 % BER
= ~43 M errors. We measure 293,183. So it is **NOT flip-and-hold**. At ~50 % BER per
garbled frame:
```
species A: 293,183 / (12,224 * 0.5) ~= 48 fully-garbled frames per burst
species B: 215,030 / (12,224 * 0.5) ~= 35 fully-garbled frames per burst
```
So each burst is **~40 discrete corruption events** (each ~one garbled frame),
clustered in a 5–8 s window, recurring every 119.75 s — and **something re-aligns the
phase within ~1 frame** (else the 43 M figure). The two species differ by ~13 events
(48 vs 35), a **count-of-events** difference, NOT an even/odd bit-phase difference.

### What is and isn't disturbed (cap_cad closes the timing question)

`cap_cad` (`FecCaptureCadence`: `sCnt | gap<<8 | snv<<16 | vrun<<24`) reads a constant
`0xFF0000FF` through baseline AND all three bursts → `snv`=0 (zero start-without-valid),
`vrun`=255 (uninterrupted valid run). **The valid/start cadence at the FEC input is
completely intact during bursts — no dropped or added valids.** `skip_count` (the
capture-window control) is host-written config with no fabric writer → static. Together
these **rule out the capture-window-slide artifact** and show the corruption is **pure
bit-VALUE at perfectly intact timing**.

### Mechanism class (constrained, still to be confirmed on silicon)

A value corruption at intact cadence, ~40 discrete self-correcting events per burst,
deterministic and byte-identical across three physical paths, invisible to both
idealized-clock sims, beating at 119.75 s. This fits a **periodic value/enable glitch
at the Serializer** (e.g. `HDL_Counter_out1` emitting the wrong bit of the pair, or a
metastable `enb_1_2_0`/`In2` sample, for ~one frame, ~40 times per beat peak) — the
`enb_1_2_0` half-rate enable network being the "SSI clock chain" suspect and the same
network the witness forensic (commit ebbf4eb) found re-hosted into the AXI addr decoder
by synthesis. The RTL is correct given a clean enable; the fault is an implementation/
CDC artifact beating against another clock/counter to give the 119.75 s envelope.

Candidate fixes (design only, unbuilt, NOT valid until mechanism CONFIRMED): (a) re-sync
`HDL_Counter_out1` to `startIn` each frame; (b) harden the `enb_1_2_0`/`In2` capture at
the Serializer (register/CDC discipline); (c) fix the enable-network re-hosting at the
synthesis/constraint level.

## High-rate (1 kHz) structure — CORRECTS the "~40 discrete events" reading

A 1 kHz re-poll (run `stagepoll_20260819_214313`, arm-health 1247 f/s, 214,951 samples,
2 bursts) resolves the intra-burst structure. `cap_in`/`cap_deint`/`cap_out` are RAW
packed coded/decoded bits (bit p = the p-th bit of the frame), so these are exact.

**Each burst = 3–4 HELD-corruption windows of ~1 s each, spaced ~1.83 s** (the
"1.85 s intra-burst beat"). NOT 40 discrete events; not flip-and-hold across the whole
burst either — a staircase of ~1 s holds:
```
species A burst @81s: 4 windows  t=81.40/83.23/85.06/86.88s, each ~1000ms,
   each holding a DIFFERENT constant wrong cap_in (0x7871AA08 / 0x70DF4D74 /
   0xF6A4BC60 / 0x63F21D7D)
species B burst @203s: 3 windows t=203.23/205.06/206.88s (0x4210A27D / 0x917D1E97
   / 0xADC7BFE6)
```
**The two species = the NUMBER of ~1 s windows: 4 (species A) vs 3 (species B).**
293,183 / 215,030 ~= 1.36 ~= 4/3. (Confirms count-of-events, not even/odd bit phase.)
`bit_errors_out`'s 0.3 % was a windowed-comparator UNDERCOUNT; the caps show the true
per-window corruption is ~50 % (err weight 12–20 / 32 coded bits, ~decorrelated).

During each held window the demapper emits a **fixed, deterministic, ~50%-decorrelated
wrong coded word every frame for ~1 s**, then steps to a different one. Ruled out by
direct test on the raw bits:
- NOT a serial-stream shift (best shift match 11–12 / 32 Hamming — no better than chance);
- NOT an adjacent-pair (u_0/u_1) swap;
- NOT a QPSK quadrant / carrier-phase rotation (none of the 8 symbol
  permutation×inversion transforms maps golden→any corrupt word; min 11/32).

Loop telemetry during the held windows (from the same capture) is NORMAL:
- `rstcs_count` = 0 throughout (carrier sync never resets) — **carrier-reset refuted**;
- `cfc_est` ~= -10 ±1 LSB, identical quiet vs corrupt — **CFO-step refuted**;
- frame cadence + `cap_cad` intact (established above).

So: all loops locked and stable, yet a held, deterministic, ~decorrelated demapper
output for ~1 s at a time. This does NOT fit a phase rotation or a loop unlock. The
prior "constellation clean during a burst" ILA (133 µs) most likely landed in a GOLDEN
GAP between the ~1 s windows, so it does not constrain what the constellation looks like
DURING a held window — that is the missing measurement.

## Next — decisive, ZERO build

The ~1 s window width makes the ILA trigger EASY (a 133 µs capture fits inside).
Force the EXISTING build-1 beat-ILA (via XVC) at ~arm+152 s to land inside a held
window and capture the soft constellation (debugI/Q, post-symbol-sync) simultaneously
with a cap_in read. Outcomes:
- constellation TIGHT + correctly placed but coded bits wrong -> pure digital
  demapper/Serializer fault (hard-decision or bit-formation), NOT the analog front;
- constellation ROTATED -> carrier ambiguity after all (despite cfc/rstcs stable);
- constellation SPREAD / wrong sample phase -> symbol-timing (Gardner TED) slip.

## DEFINITIVE: soft constellation is PRISTINE during a verified held window

ILA capture over XVC (build-1 image, `beat_capture_win.sh`, iq_debug_mux=2 =
post-carrier soft symbols), two forced triggers with cap_in read AT the force so the
window state is verified:
```
run1 (force arm+153.1): cap_in=0x5216F3E2 GOLDEN  -> golden-gap capture
run2 (force arm+154.3): cap_in=0x7871AA08 CORRUPT -> IN-WINDOW capture (species-A)
```
Post-carrier soft constellation (probe10/11), gap vs in-window:
```
GAP       : EVM=1.1%  meanRot=+0.02deg  angspread=0.5deg  R=16408  quad balanced
IN-WINDOW : EVM=1.0%  meanRot=+0.02deg  angspread=0.4deg  R=16408  quad balanced
```
**The soft symbols feeding the hard decision are TIGHT, CORRECTLY PLACED, ZERO
rotation, ZERO extra spread — IDENTICAL to golden — while cap_in downstream is ~50 %
wrong.** rx-input (probe8/9) also unchanged (EVM ~31.6 % both, filter/noise floor).

This DEFINITIVELY refutes the remaining analog hypotheses:
- **carrier cycle-slip REFUTED** (meanRot +0.02deg in-window = no rotation);
- **symbol-timing slip REFUTED** (EVM/spread identical to golden = no ISI/mis-sample).

## ROOT CAUSE (by direct observation)

The 119.75 s beat is a **DIGITAL fault in the QPSK hard-decision -> serialization
stage** (`QPSK_Demodulator_Baseband` sign-slice -> `Serializer` 2->1 bit): the entire
analog chain (AGC / RRC / Gardner timing sync / carrier sync) is PROVEN CLEAN during
corruption (1 % EVM soft symbols), yet the coded bits emitted into the FEC are ~50 %
wrong for held ~1 s windows. The `Serializer` is gated by the half-rate `enb_1_2_0`
enable and is NOT re-synced to `startIn`; a periodic disturbance of that enable/its
capture — the SSI-derived enable network the witness forensic (commit ebbf4eb) found
re-hosted into the AXI addr decoder by synthesis — corrupts the 2->1 serialization
every 119.75 s while leaving the datapath (soft symbols) untouched. That enable network
IS the long-sought "SSI clock chain" origin of the beat.

Confidence: HIGH. Chain of direct-observation facts, no inference gaps:
clean soft symbols (ILA, verified in-window) -> wrong coded bits (cap_in, same window)
-> propagated by deinterleave+Viterbi (cap_deint/out) -> windowed comparator + host loss.
All five prior refuted fixes acted downstream of the byte plane; the real fault is at
the demapper's serialization enable.

## Fix candidates (design; require a build + on-air validation, NOT yet built)
1. **Re-sync `Serializer` `HDL_Counter_out1` to `startIn`** every frame so any enable
   glitch self-corrects at the next frame instead of holding for ~1 s. Smallest change.
2. **Register/CDC-harden the `enb_1_2_0` (and `In2`) capture** at the Serializer.
3. **Constrain the enable network in synthesis** to stop the re-hosting into the AXI
   decoder (addresses the root implementation divergence; largest blast radius).
Recommended first build: (1) — local, low-risk, directly targets the observed failure.

## mux=3 (decisions) ALSO pristine in-window — datapath clean through the decision

Second XVC ILA capture (`beat_capture_win.sh MUX=3`), cap_in verified:
run1 gap (cap_in golden), run2 IN-WINDOW (cap_in=0x7871AA08 corrupt).
```
GAP       mux3(decisions): EVM=0.9%  rot=+0.02deg spread=0.4deg
IN-WINDOW mux3(decisions): EVM=1.2%  rot=+0.03deg spread=0.5deg
```
The decision-point constellation is pristine and correctly placed during corruption too.
=> the ENTIRE demod datapath — timing (mux1, prior), carrier (mux2), decisions (mux3) —
is clean in-window; the fault is strictly AFTER the decision, in coded-bit formation.

## Remaining fork (needs an ILA on the FEC-input nets — the one build worth doing)

Two demod-stage DIGITAL sub-hypotheses survive, both consistent with clean datapath +
held-constant ~50%-wrong cap_in:
- **(A) Serializer 2->1 bit-mangling**: `enb_1_2_0` disturbance corrupts the
  `HDL_Counter`/`u`-latch serialization so the emitted coded bits are wrong-valued.
- **(B) startIn frame-sync PHASE shift**: `startIn` fires a few bits off for ~1 s, so
  the FEC (and cap_in) capture CORRECT coded bits at a WRONG offset -> misframed decode.
Both give: clean constellation, held-constant wrong cap_in per window, 4 offsets/states
= 4 windows, deterministic, enable/framing-network-driven. The existing AXI + mux taps
CANNOT split them (cap_in is only 32 bits; no golden beyond that to test an offset).

Splitting A vs B needs one ILA capture of the FEC-input nets during a window:
`startIn`, `validIn`, `bitsIn` (the coded stream), `enb_1_2_0`, and the Serializer
`HDL_Counter_out1`/`u_0`/`u_1`. These are Hierarchy-4 internal nets, so the build must
`mark_debug` them (or expose them as DUT debug ports via a model edit) and probe with a
netlist/`system_ila`. Build design:
- base: the build-1 beat-ILA recipe (proven to build) — `two_jup/skidfix/run_beatila_build.sh`;
- add `(* mark_debug = "true" *)` on: `Serializer` `HDL_Counter_out1`,`dataOut`,`u`(latch);
  `QPSK_Demodulator`/`QPSK_Rx` `enb_1_2_0`, the FEC-wrapper `bitsIn`/`startIn`/`validIn`;
- trigger: the existing `burst_onset_det` soft_force scheduled in-window (arm+154.3s,
  proven to land — cap_in corrupt at that force in both runs tonight);
- capture depth 4096 @ 30.72 MHz = 133 us (fits inside a ~1 s window).
Verdict: if `startIn` phase is steady but `bitsIn` values differ from a clean frame ->
(A) Serializer; if `startIn`/`bitsIn` show a bit-offset slip -> (B) frame-sync.

NOTE (build judgment, this session): NOT launched unattended. The `mark_debug` on
Hierarchy-4 generated nets is an unproven-in-this-repo flow with real net-survival risk;
a failed 3-4 h build wastes the farm and yields nothing by morning. The core root cause
is already delivered by zero-build + the existing ILA. This build (and the fix, which
touches the generated Serializer/framing RTL) are best run WITH the operator's Simulink-
model knowledge. Recipe design above is ready to implement.

## Mux verification (the constellation-clean claim is NOT a mux artifact)

Concern (advisor): 0x10C iq_debug_mux is write-only (reads 0), has a documented
reapply footgun, and mux2 vs mux3 looked near-identical -> could both captures be the
SAME tap, and the "clean" be an artifact? Two controls settle it:
1. **mux takes effect**: forced mux0 (AGC) vs mux2 (post-carrier) captures differ
   materially (different constellation, different points) -> the mux DOES switch taps.
2. **reset-immune re-test**: `beat_capture_win2.sh` sets mux=2 FRESH (0.2 s) right
   before EACH force, cap_in verified: gap (cap_in golden) vs IN-WINDOW
   (cap_in=0x7871AA08 corrupt):
   ```
   GAP       mux2-fresh: R=16408 EVM=0.9% rot=+0.00deg spread=0.4deg
   IN-WINDOW mux2-fresh: R=16402 EVM=1.1% rot=+0.03deg spread=0.5deg
   ```
   Post-carrier soft constellation pristine & identical in-window vs gap, mux confirmed
   live. (`uniq~=511/512` is just a 16-bit soft-symbol tap over 512 samples — normal,
   not a decisions-quantized tap and not a mux failure.)
The "datapath clean through post-carrier during corruption" result is CONFIRMED, not
mux-conditional. (mux2 vs mux3 being similar = decisions and post-carrier-soft are
genuinely similar clean signals, not the same tap.)

## Open (mechanism confirmation, next)

Stage is NAMED; the exact mechanism inside the demapper stage is not yet named.
Deterministic + species-keyed + byte-identical across three physical paths ⇒ a
digital event at a fixed frame phase (period ≈ 149,100 frames ≈ 119.75 s @1245 f/s),
NOT analog clock jitter. Candidate: a periodic counter/pointer collision or CDC
event at the SSI-sample→fabric boundary feeding the demapper. Next: (a) inspect the
demapper / QPSK-Rx RTL for a counter of that period (zero build); (b) an ILA image
probing the demapper input (soft IQ) and coded-bit output simultaneously, triggered
during a burst, for the exact corruption pattern + mechanism.
