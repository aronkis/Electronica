# SIMGEN_SYMSYNC — symbol-sync resonance candidate: sim instrumentation + confirm-or-kill

Staged task 2026-08-13 (operator-approved ~01:40). Candidate under test: an
internal ~156 Hz (~6.4 ms, ~8-frame) periodic disturbance of the RX
symbol-sync loop produces the air-singles class (HANDOFF_20260813.md class B).

**VERDICT: KILLED.** Details and implications at the bottom.

## Target signature (measured, banked hardware logs)

- single-frame CRC failures (+~25% two-frame doubles) at ~4% of frames
- collapsed-event inter-arrival intervals on an ~8-frame lattice: modes hard
  at 8 and 24/25 (=3x8), interval 16 SUPPRESSED, CV~1.5
- absolute phase drifting: k mod 8 uniform
- corruption at ByteSerializer output (delivered 191-word frames failing CRC);
  same samples decode clean undisturbed

## Stage 1 — instrumentation (Jul-25 netlist wrapper ONLY)

All on the KNOWN-GOOD Jul-25 f1536 tap netlist
(`.claude/worktrees/txmux-localize/jupiter_240k5_byte/s1_rtl_f1536/hdlsrc`);
the current-model regen is a known regression and was not used.

| piece | file | what |
|---|---|---|
| loop-state taps | `jupiter_240k5_byte/rtl_sim/wrap_byte_lock.v` | wrap_byte_taps.v idiom + hierarchical Verilator refs to `u_Symbol_Synchronizer.Gardner_TED_e` (sfix40_En24), SS `Loop_Filter_stateP/stateI` (sfix30_En23), `u_Carrier_Synchronizer.Phase_Error_Detector_PhaseError` (sfix13_En10), CS `Loop_Filter_stateP` (sfix29_En29) / `stateI` (sfix39_En39). No RTL edits. |
| per-frame framestat mirror | `jupiter_240k5_byte/rtl_sim/sim_byte_lock.cpp` | one line per delivered frame: {frame#, clk, nwords, 16-bit byte checksum, cfc_est, symbol-sync error RMS, carrier error RMS, SS/CS integrator values at the frame boundary, pdSync count} + `_rxw.txt` for offline CRC + optional ss/cs/con stage streams (`dumptaps=1`). Binary: `rtl_sim/obj_byte_lock_f1536_jul25/Vwrap_byte_lock`. |
| injection hook (sample boundary) | `jupiter_240k5_byte/rtl_sim/iq_dither.py` | parameterized {timing-phase dither (periodic fractional delay via chunked 32-tap Kaiser-windowed-sinc), fractional resample offset, phase dither, amplitude dither} x {cadence_hz, amp, phi0, phase_drift}. fs=61.44 MS/s, frame=49332 samples. Selftested (0.5-sample delay and PM depth verified <0.1%). |
| first-divergent-stage comparator | `two_jup/simgen_symsync/stage_diverge.py` | clean-vs-injected per-frame per-stage quality ratio (RMS distance to nearest QPSK point per stage stream) + per-frame TED-error burst detection. Continuous dither perturbs every sample, so word-level lockstep diffing is dominated by benign symbol-index drift; the per-frame stage-quality + TED-burst view is the honest divergence instrument. |
| verdict + fingerprint | `two_jup/simgen_symsync/score_lock.py` | per-frame CRC (QK header + crc32 + 191-word rule, same as singles_replay), event collapse, interval lattice, k mod 8, CV, single:double. |

Drive identical to the validated tap_replay_study campaign: cadence=4,
vphase=0, rstcs_end=8400, skip=0. Instrument note: `Gardner_TED_e` and
`PhaseError` are strobe-gated in the netlist, so their per-frame RMS reads 0
in normal tracking and goes nonzero only on slip bursts — which turned out to
be exactly the event marker needed (see below). Constellation-quality per
stage comes from the dumped streams.

## Stage 2 — sweep (input: `two_jup/r3cap/evm_swap_A/pair.iq`, 162 healthy frames)

**Baseline (uninjected)**: 162 packets detected, 161 delivered, 155 scored
(k>=6). 151/155 CRC-good. The 4 fails (k = 111, 114, 142, 146) are
capture-position-locked whole-frame randomizations (headers destroyed,
constellation clean, neighbors pristine) — the replay noise floor for this
capture; injected runs are scored as EXCESS vs this per-k set.

### Sweep table (timing dither, f x A; bad = CRC-fail frames of 155 scored)

| point | bad | rate | new-vs-baseline k | healed baseline k |
|---|---|---|---|---|
| baseline       | 4 | 2.6% | — | — |
| f130 A=0.05    | 4 | 2.6% | 112 | 111 |
| f130 A=0.15    | 7 | 4.5% | 110,115,141,147,148 | 142,146 |
| f130 A=0.30    | 4 | 2.6% | 110,112,140,147 | all 4 |
| f156 A=0.05    | 6 | 3.9% | 110,115,147 | 114 |
| f156 A=0.15    | 6 | 3.9% | 109,110,115,141,147 | 111,114,146 |
| f156 A=0.30    | 9 | 5.8% | 109,110,112,113,115,140,147,148 | 111,142,146 |
| f180 A=0.05    | 7 | 4.5% | 112,143,147 | — |
| f180 A=0.15    | 5 | 3.2% | 112,147,148 | 111,146 |
| f180 A=0.30    | 6 | 3.9% | 108,109,110,113,114 (subset) | 111,146 |
| f156 A=1.0 (bracket) | 2 | 1.3% | 108,140 | all 4 |
| f156 A=3.0 (bracket) | 6 | 3.9% | 93,124,125,156,157,158 | all 4 |

Key observations:

1. **In the specified amplitude range (0.01–0.3 samples peak) the dither
   causes NO events of its own.** Every failure at every in-spec point lies
   inside the same two baseline-weak windows (k 108–115 and 140–148); the
   dither merely re-shuffles which marginal frames tip over (some baseline
   fails even HEAL). Zero failures anywhere else in the capture at any
   in-spec point. The SS loop integrator (`ssIntI` sampled per frame) shows
   no amplitude-dependent response at all (sd 555 baseline vs 475–519
   injected). Physical read: 0.3 samples peak at 156 Hz is a ~5e-6
   samples/sample instantaneous rate error — the loop tracks it trivially.
2. **Forced failures (bracket points at 3–10x spec amplitude) have the wrong
   structure.** At A=3.0 samples (0.75 symbol!) genuine symbol-sync slips
   appear: TED error bursts of 1.0–2.3e6 LSB at exactly the corrupt frames
   (zero elsewhere), whole-frame randomization downstream — the correct
   MORPHOLOGY (delivered-but-corrupt 191-word frames) — but the events lock
   to the dither: intervals {31, 32} = 4 dither periods, CV = 0.02, k mod 8
   concentrated at {4,5}. At in-spec points the corrupt frames show NO TED
   burst (ss quality ratio 1.000 +- 0.005) — those are not symbol-sync events
   at all.

### Fingerprint table (sim best case vs measured target, per criterion)

| criterion | target (hardware) | sim (in-spec A<=0.3) | sim (bracket A=3.0) | match |
|---|---|---|---|---|
| event rate ~4% | 4% | 2.6–5.8% but NOT dither-caused (baseline class) | 3.9% dither-caused | superficial only |
| single:double ~4:1 | 4:1 | 4:0 -> 1:3 (baseline-class shuffle) | 1:1:1 (n=3) | NO |
| interval modes 8 & 24/25 | yes | n/a (no dither events) | single mode at 31/32 (=4 periods) | NO |
| interval 16 suppressed | yes | n/a | all intervals except 31/32 absent (trivially) | NO |
| CV ~1.5 | 1.5 | n/a | 0.02 (strictly periodic) | NO |
| k mod 8 uniform (drifting phase) | yes | n/a | concentrated at {4,5} (locked phase) | NO |
| sync-error dip/spike at event frames | expected | none (no TED burst at corrupt frames) | yes (TED burst 1e6+ LSB) | only at 10x amplitude |
| first divergent stage = symbol sync | expected | downstream (baseline class, not SS) | SS (TED burst -> whole-frame slip) | only at 10x amplitude |
| ByteSerializer-output corruption | yes | yes (191 delivered words, CRC fail) | yes | yes (morphology only) |

## VERDICT: KILLED

A periodic timing-loop perturbation at 130–190 Hz does not reproduce the
air-singles class:

- At every amplitude in the specified sweep range the symbol-sync loop
  rejects the disturbance completely — no loop response, no events.
- At the amplitudes where events CAN be forced (>= ~1–3 samples peak, i.e.
  0.25–0.75 symbol of timing wobble — not physical for a shared-clock rig),
  the event process is strictly periodic and phase-locked to the disturbance
  (CV 0.02, one interval mode at 4 periods, k mod 8 concentrated). The target
  lattice — modes at 1x and 3x the quantum with 2x SUPPRESSED, CV 1.5,
  uniform drifting phase — did not emerge from the loop dynamics at any
  operating point, and no amplitude/frequency combination can plausibly
  produce it: a deterministic resonance cannot generate super-Poisson (CV
  1.5) renewal statistics with a suppressed harmonic.

### What this implies for the remaining candidates

1. The ~8-frame quantum with drifting phase and suppressed-16 needs a
   DISCRETE internal process with a random per-tick gate (a tick that only
   sometimes corrupts), not a continuous/analog sample-domain disturbance
   entering the demod loops. This is consistent with N1's cyclic A/B
   localization (corruptor upstream in 148's byte plane with its own
   ~8-frame cycle) — the byte-plane / control-plane tick family is now the
   only family left standing for the air singles.
2. The corruption morphology (whole-frame randomization behind an intact
   191-word delivery) is reproducible via ANY single-symbol slip upstream of
   the descrambler — it does not discriminate mechanism; the interval
   statistics do. Future candidates should be tested against the interval
   fingerprint first.
3. Sample-domain injection infrastructure (Stage 1) is built, validated, and
   cheap to rerun for any remaining sample-domain candidate (phase/amp/CFO
   dither at other cadences), but the class-B evidence now points away from
   the sample domain entirely.

### Side findings

- **Uninjected long-run replay produces the singles morphology on its own:**
  4/155 frames (2.6%) whole-frame-randomized in a continuous 162-frame
  replay of a healthy capture, at capture-locked positions (k 111, 114, 142,
  146 — note 111->142 = 31, 114->146 = 32, the same 31/32-frame spacing the
  forced-slip class shows). The chunked-replay campaign (70-frame chunks,
  8-frame warm-up, rstCS re-armed per chunk) scored the same captures ~all
  good, so this is either a long-run drive artifact of the continuous replay
  protocol (rstCS armed once at clk 400–8400 only) or a genuine
  slow-accumulating slip mechanism that the chunk protocol resets away.
  Worth a targeted look before it contaminates any future sim-vs-hardware
  comparison at the per-frame level.
- The strobe-gated TED-error tap is a clean slip detector: exactly zero
  during tracking, 1e6+ LSB bursts on slip frames. Cheap to port to a
  hardware witness if a fabric-side slip counter is ever wanted.

## QUICK-LOOK 2026-08-13: gated byte/control-plane tick — drift-vs-lock

Operator-approved quick-look (single operating point, no campaign). Mechanism:
harness-side eat-valid at the ByteSerializer output (the byte_rx interface of
the Jul-25 netlist replay) — driver
`jupiter_240k5_byte/rtl_sim/sim_byte_qtick.cpp`
(binary `rtl_sim/obj_byte_qtick_f1536_jul25/Vwrap_byte_lock`), tick period
8.04 frames (1,586,517.12 clk fractional accumulator), gate p=0.35
(xorshift32, per-shard seed, every tick logged {clk, gated}), tick size 3
words. Input: `two_jup/r3cap/hunt_auto_20260731_211829/pair.iq` (810-frame
healthy capture), 8 parallel shards of ~100 scored frames each with 8-frame
warmup (`run_qtick.sh`), 782 frames scored. Attribution is exact: each frame
line carries the count of words eaten inside it; a CRC-fail frame is
injected-attributed iff it or a +/-1 neighbor has eaten>0
(`score_qtick.py`).

Results:

1. **Tagged event count: 31** injected-attributed CRC-fail frames from 32
   gated ticks (103 ticks total, gate rate 0.311) — every gated 3-word eat
   corrupts exactly one frame; all 31 are SINGLES (no doubles).
   Baseline-coincident (untagged) fails: 2 (k=300, 330; reported
   separately, no baseline run needed).
2. **Interval CV (within-shard, n=23): 0.76**, intervals
   [8 x8, 9 x3, 16 x4, 17, 24 x2, 32, 40, 41, 49, 57] — a clean ~8-frame
   lattice with geometric skip weights. The measured CV matches the
   intrinsic Bernoulli-gate value sqrt(1-p) = 0.83 at the measured gate
   rate; CV > 1 is not reachable from memoryless gating.
3. **k mod 8 of tagged events: [0,0,7,7,0,0,11,6]** — 4 of 8 bins occupied.
   WITHIN each shard the phase visibly walks (e.g. shard 0: events at mod-8
   phase 6,6,6,6,6,7,7,7 — the designed 0.04-frame/tick drift); across
   shards the phase is re-anchored by the per-shard tick generator restart,
   and 100-frame shards only sample ~0.5 frame of drift each — so the
   global histogram is shard-quantized, an instrument-geometry artifact,
   not evidence of locking.

**Verdict: DRIFT (qualified).** The event phase is not locked — it walks
exactly as an 8.04-frame free-running tick should, and the intervals sit on
the 8-lattice with modes at 8, 16, 24 — but the two literal DRIFT thresholds
are not met for structural reasons at this operating point: CV = 0.76 < 1
because memoryless (Bernoulli) gating intrinsically caps CV at sqrt(1-p),
and the phase histogram is not flat because 100-frame shards each sample
only ~0.5 frame of the drift. Neither is evidence of LOCK. Two findings that
matter for the full-campaign design: (a) reproducing the measured CV~1.5
requires a gate with memory (bursty/refractory), not a plain Bernoulli
gate; (b) reproducing the measured 16-SUPPRESSED lattice cannot come from
memoryless gating either (16 shows up here with weight 4/23) — both point
at a gated tick process with recovery/refractory dynamics. Verifying that
is the campaign question; stopping here per the quick-look scope.

Files: `two_jup/simgen_symsync/{run_qtick.sh, score_qtick.py, q_*_*}`,
`jupiter_240k5_byte/rtl_sim/sim_byte_qtick.cpp`.

## Files

- `two_jup/simgen_symsync/` — runs (`base_A_*`, `t_f{130,156,180}_a*`),
  `score_lock.py`, `stage_diverge.py`, `run_sweep.sh`, `run_highamp.sh`,
  per-run `*_verdict.csv`.
- `jupiter_240k5_byte/rtl_sim/{wrap_byte_lock.v, sim_byte_lock.cpp,
  iq_dither.py}`, binary in `rtl_sim/obj_byte_lock_f1536_jul25/`.
