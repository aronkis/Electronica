# DDRCAP-v2: joint timing-plane DDR capture — design + PRE-REGISTRATION

Date: 2026-09-02. Branch `per-under-1pct-2026-07`. Operator-approved layout: **Option A** (64-bit record,
existing packer and DMA untouched). Boards: **148 only, 146 untouched**, full flash rails.
Status: **PRE-REGISTERED — written before any RTL is patched or built.** Predictions and falsifiers in §6
are frozen; nothing below §6 may be reinterpreted after data exists.

## 1. Purpose
Settle marker-versus-data for the 120.2 s beat by observing, on ONE time base in EVERY record: the tap
I/Q (from which per-frame data displacement is scored), the Peak_Search `timingOffset` latch at full
width, both frame markers, and a correlator-plane sidecar — plus dedicated full-rate taps on the upstream
blocks (correlator magnitude, interpolator phase accumulator, interpolator buffer, Rate_Handle FIFO).
What this buys (called out per operator): (a) **joint observation** — whether the offset moves before,
with, or after the data displaces, resolved to one beat; (b) **coverage** — the whole ~1 s displacement in
one 512 MB capture instead of 0.5 %; (c) **frame ordinality for free** — record index + the sidecar
frame-reference counter give absolute frame count, which is the ROM's modulo-frame-length blind spot.

## 2. Record layout (Option A) — four 16-bit channels, unchanged packer (`util_adc_2_pack`, 4 ch) and
`axi_adrv9001_rx2_dma` (DMA_DATA_WIDTH_SRC=64), unchanged host loader (`np.fromfile('<i2').reshape(-1,4)`)

| ch | bits | content | source (exact) |
|---|---|---|---|
| 0 | [15:0] | I of selected tap | existing `ddrcap_mux_i` (sel 0–11) + new sel 12–15 |
| 1 | [15:0] | Q of selected tap | existing `ddrcap_mux_q` + new |
| 2 | [15] | demod frame marker, sticky latch (unchanged semantics) | `QPSK_Demodulator_startOut` latch (existing) |
| 2 | [14] | TX frame marker, sticky latch (TXMARK source retained) | `Transmitter_txFrameStart` latch (existing) |
| 2 | [13:0] | **`timingOffset`, full 14 bits, every captured beat** | `Preamble_Detector.Peak_Search_timingOffset` (= `Peak_Search.Unit_Delay_Enabled_Synchronous_out1`, ufix14, `Peak_Search.v:68/148`) — NOT PdTelemetry's 11-bit `tOff` |
| 3 | [15:14] | sidecar slot id, free-running 0→1→2→3 per captured beat | new 2-bit counter, resets with `ddrcap_sel_r` |
| 3 | [13:0] | slot 0: `heldTs[13:0]` — winning-peak timestamp, low bits | `Peak_Search.Unit_Delay_Enabled_Synchronous1_out1` (uint32, `:74/215`) |
| 3 | [13:0] | slot 1: `timing_Reference_out1[13:0]` — free-running frame-position counter, mod 12333 | `Peak_Search.v:58/97-107` |
| 3 | [13:0] | slot 2: `runMax[31:18]` — running best correlation magnitude, top 14 bits | `Peak_Search.Unit_Delay_Enabled_Resettable_Synchronous_out1` (sfix32_En26, `:66/199`) |
| 3 | [13:0] | slot 3: `Correlator.threshold[31:18]` — adaptive threshold, top 14 bits | `Correlator.Delay5_out1` (sfix32_En28, `Correlator.v:58/177`) |

Rationale for the sidecar contents: the *position* of the winning peak IS `timingOffset` (ch2, every
beat). The sidecar carries the slow correlator-plane state that explains *why* a peak won: its
timestamp, the window position, the running max, and the threshold. The instantaneous correlator
magnitude is NOT in the sidecar (a 4-beat cycle would miss a ~1-symbol-wide peak) — it gets its own
full-rate tap, sel 12. `ddrcap_valid` stays the selected tap's own valid, so ch2/ch3 are sampled on the
tap's beats (sample-domain taps: ~49,332/frame; symbol-domain: 12,333/frame).

## 3. New selectors (the four free codes; existing 0–11 untouched, sel 7 stays dead, sel 10 stays a dup)
| sel | tap | I | Q | valid | operator priority |
|---|---|---|---|---|---|
| 12 | **correlator magnitude** (the value Peak_Search argmaxes) | `Correlator.dataOut[31:16]` | `Correlator.dataOut[15:0]` | `Correlator.validOut` | #1 (autocorrelation) |
| 13 | **interpolator phase accumulator** | `{underflow_sticky, 4'b0, Interpolation_Control.countReg[10:0]}` | `{5'b0, Interpolation_Control.mu[10:0]}` (the `mu` output port) | `enb_1_2_0_gated` | #2 (phase structure, NOT the loop) |
| 14 | **interpolator buffer** (the sample the TED sees) | `Symbol_Synchronizer.Delay8_out1_re[18:3]` | `Symbol_Synchronizer.Delay8_out1_im[18:3]` | `enb_1_2_0_gated` | #2 (surrounding buffer) |
| 15 | **Rate_Handle FIFO** (symbol-rate output buffer) | `{Rate_Handle.beatobsRhCtr[7:0], beatobsPush[4:0], 3'b0}` | `{beatobsPop[4:0], 11'b0}` | `enb_1_2_0` | #2 (buffer, §66's 32-deep FIFO) |

**Correction (2026-09-02, Task 4 sim gate):** `beatobsRhCtr` is BfGridPace's beat-fix grid pacer
output (`BfGridPace.v`), not FIFO occupancy -- at `fixctl=0` (this driver's baseline) `bfGridEn`
is deasserted so `beatobsRhCtr` only ever reflects Rate_Handle's own 2-bit mod-4 `HDL_Counter`
(values 0..3); the actual FIFO occupancy witnesses are `beatobsPush[4:0]`/`beatobsPop[4:0]`
(`u_FIFO.Push_Counter_out1`/`Pop_Counter_out1`), packed into I[7:3]/Q[15:11].

RRC → symbol-sync: **no tap needed** — `Symbol_Synchronizer.dataIn` is `RRC_Receive_Filter_out1` with
no block between (`Frequency_and_Time_Synchronizer.v:135-138`); sel 2 already is the synchroniser input,
at 2 samples/symbol (`enb_1_2_0`).

**Correction (2026-09-02, Task 4 sim gate review re-run):** the `enb_1_2_0`/`enb_1_2_0_gated`-valid
taps (sel13/14/15) capture at **4 records/symbol**, not 2 -- confirmed by the sel15 FIFO push
counter advancing +1 exactly every 4th captured record, and matching the sample-domain golden
streams at 49,332 = 4x12,333 records/frame. sel13's underflow-sticky bit (1 pulse/symbol at
4 records/symbol) therefore averages 0.25, not 0.5.
sel0/sel2 anchor: **provided by ch2 `timingOffset` + sidecar `timing_Reference`** present in every record of
ANY selector — a receiver-own frame-phase anchor synchronous with each sample, i.e. self-referential by
construction, which is exactly what both failed sample-domain instruments (§75, §77) lacked.

## 4. Positive controls — EVERY channel, before it may report a null (the §0 rule; the DBGCAP-zeros rule)
Two tiers, both required. A channel failing either tier is DEAD and reports nothing (the sel1/sel7 rule).

**Tier 1, sim (Verilator flat build of the PATCHED netlist, `--public-flat-rw`, the §76 force harness
extended; extends `sim_ddrcap.cpp` PART A/B):**
| channel | forced non-null | unforced liveness/geometry |
|---|---|---|
| ch2 tOff | force `Peak_Search.Unit_Delay_Enabled_Synchronous_out1 = 14'h2ABC` at frame K → ch2[13:0] reads 0x2ABC next captured beat, exact | steady nonzero d0 ∈ [0,12332] after acquisition |
| ch2 markers | (existing PART A) | exactly 1 demod + 1 TX marker per frame |
| ch3 slots | force heldTs/tref/runMax/threshold each to a distinct constant → the matching slot reads it, exact | slot id cycles 0,1,2,3,0… every captured beat; tref slot increments mod 12333 |
| sel12 corrMag | force `Correlator.Delay2_out1 = 32'h0123_4567` → I/Q read 0x0123/0x4567 | one dominant peak per frame, period 12,333 beats, coincident (±latency) with the tOff-latching beat |
| sel13 interp phase | force `muReg` → Q reads it | countReg sweeps its modulo range every symbol (not constant, not a period-≠-symbol ramp); underflow bit 1/symbol |
| sel14 interp buffer | PART B: golden vs perturbed TX word files → I/Q differ | not constant, not a ramp |
| sel15 Rate_Handle | force `u_FIFO.Push_Counter_out1 = 5'h15` → I[7:3] reads it (`(I & 8'hF8) == (5'h15 << 3)`); RhCtr[15:8] is BfGridPace's grid pacer (0..3 at fixctl=0, unforced) | push counter advances (not constant); RhCtr cycles 0..3 |
Gate = ALL rows PASS byte-exact, or the build does not start.

**Tier 2, silicon (one arm on 148 after flash, BEFORE any burst is interpreted):** five 512 MB captures on
the same arm — sel 6 (carries ch2/ch3 controls for tOff/markers/sidecar), then sel 12, 13, 14, 15 — each
scored by a generalised `ddrcap_pc_large.py` (not-constant, not-a-counter, markers/frame, plus the
per-channel geometry column above). The silicon non-null for tOff is the **arm-settle transient**: tOff
must be seen leaving its reset value and settling to d0 (if it is already at d0 in every record of the
first capture, the arm's post-reset settle is re-captured within 2 s of the 0x000 pulse on the next arm;
a tOff that has never been seen to change may not report "held steady").
Control burden: 10 channels; Tier 1 = one gate binary run (~30 min flat sim); Tier 2 = one arm, five
captures (~15 min). Not large. No channel is skipped to fit more in.

## 5. Build and flash (unchanged rails)
- RTL: new injector `two_jup/skidfix/ddrcap2_inject.py` (extends `ddrcap_inject.py` idempotently: ch2/ch3
  packing, 2-bit slot counter, sticky underflow latch, sel 12–15, the wide-signal port threading the
  enumeration report notes the injector lacks). Patched netlist `rtl_sim/s1_rtl_ddrcap2` from `s1_rtl_final`.
- **BD unchanged** (that is the point of Option A). `TXMARK=1` retained.
- Sim gate (§4 Tier 1) MUST PASS before `build_ddrcap.sh` (run from nemo → hdl-dev-2, ~50 min).
- Image banked `boot_known_good/BOOT.BIN.148.ddrcap2.<md5>`; restore point = the running
  `BOOT.BIN.148.txmark.1cd0cd752aa6` (already banked, named).
- Flash 148 per `two_jup/skidfix/SKID_BUILD.md`: readback md5 verify, two-pass health gate
  (`arm148_mode1.sh` ARM_OK twice, capTAP golden 0xBCF94856 at low nibble 3 — unaffected by this change),
  auto-rollback on any failure, **no retry loop**. 146 untouched.
- Two-revision cap applies to this instrument.
- Host: `two_jup/ddrcap2_decode.py` — splits ch2/ch3 into tOff, markers, slot fields; existing loaders
  and `t6_score_large.py` (sel 6 word lookup) unchanged.

## 6. PRE-REGISTERED PREDICTIONS AND FALSIFIERS (frozen)
Primary experiment: one burst-spanning 512 MB capture at **sel 6** (demod input — the tap whose per-frame
data displacement is scored by the established injective offset-map lookup, §57/§69) on the golden mode-1
arm, timed to straddle onset (§4.1 of the beat plan: trigger on burst N, capture at T+120.2−1.5 s).
Every record carries: data word (ch0/1 → lookup offset d_data per frame), tOff (ch2), markers, sidecar.

- **P1 — the marker moves (peak-search / correlator plane):** at burst onset `tOff` steps from its steady
  d0 to d0 ± R with R in the rung set {6176, 6240, 6299, 6363, 6432, 6489, 6548} (full 14-bit, no
  aliasing), within **±1 beat** of the first beat at which d_data leaves 0, holds for the burst (~3 s),
  and returns with d_data. → The slip is in symbol-sync's frame-phase plane, localised. Then the sidecar
  decides sub-origin: at the onset beat, `runMax`/`threshold` show a second peak crossing threshold
  (correlator sidelobe won → **correlator origin**) or not (→ **latch origin**).
- **P2 — the marker holds (data plane):** `tOff` stays at d0 (exactly, ±0) through every beat of the burst
  while d_data jumps to a rung. → Peak search and correlator exonerated as the mover; the data itself
  shifted upstream; the same-beat sel13/sel14/sel15 captures (next arms) are then the discriminator.
- **Ordering (the joint payoff):** report the beat index of the tOff change and of the d_data change. P1
  REQUIRES |Δ| ≤ 1 beat. A tOff change that LAGS d_data by many beats is a consequence (re-acquisition),
  not the cause, and is scored as P2-with-lag, not P1.
- **Frame ordinality (the modulo-frame limit, addressed):** frames are counted three ways — record index
  ÷ nominal beats/frame, sidecar `tref` wraps, and marker count. A **whole-frame** displacement (invisible
  to d_data, which is modulo 12,320) shows as a disagreement between the marker count and the tref-wrap /
  record-index count across the onset. Pre-registered check: the three counts agree to ±1 through the
  burst (no whole-frame slip) or they disagree by an integer (whole-frame slip, reported with its sign).
- **Falsifiers:** P1 is falsified by tOff constant through a burst (→P2). P2 is falsified by tOff moving.
  tOff moving to a value that is NOT d0 ± rung is **neither** — reported as "moves, non-rung", no
  localisation claimed. sel12 showing no per-frame peak = dead correlator tap (control fails) → no claim
  from sel12. Any channel whose Tier-1 or Tier-2 control failed contributes nothing, and the report says
  which.
- **Null-guard (operator's rule, restated):** "tOff held steady" may be reported ONLY after the Tier-1
  forced non-null AND the Tier-2 settle transient have been seen on this image.

Secondary experiments (same image, subsequent arms, in operator priority order): sel 12 burst capture
(correlator magnitude through onset — does a secondary peak at ~half a frame exist and cross threshold?),
then sel 13 and sel 14 (interpolator phase/buffer discontinuity at the onset beat), then sel 15.
sel 0 / sel 2 re-attempt using the ch2/ch3 anchor (spec §3) is a separate pre-registration.

Provenance labels on every reported number: [silicon] for captures, [sim] for the gate, [inferred] for
any conclusion drawn across channels.

## 7. Out of scope
On-air bursts; 146; any packer/DMA/BD change (Option B); a third sample-domain scorer (operator hold);
any fix. Reverse-leg work untouched.
