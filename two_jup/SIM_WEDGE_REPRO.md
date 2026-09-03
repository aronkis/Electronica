# SIM_WEDGE_REPRO — short-fill wedge RTL-simulation reproduction attempt (2026-08-18)

Goal: reproduce (or refute) the silicon short-fill wedge — deterministic RX
framesync collapse when the TX byte plane is fed frames whose header `len`
field is <= 47 (frames always full 1528 B on the wire; only byte VALUES change;
fill >= 48 safe; cliff bisected to exactly 47/48 on silicon, see
`two_jup/TGEN_SWEEP.md`) — in pure RTL simulation with full visibility on the
suspected stage (Preamble Detector delay FIFO, `Validate_Input_Push_Pop`,
`pop_on_empty_FIFO`).

## Harness (all sources committed in `jupiter_240k5_byte/rtl_sim/`)

- Netlist: `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/`
  (top `TxRxComposite.v`) — the FLASHED-silicon generation per
  `build_replay_lock.sh`'s lineage audit; drive cadence 2 per
  `two_jup/HARNESS_AB.md`.
- `wrap_byte_tgen.v` — clone of the validated `wrap_byte.v` S1B gate wrapper
  (internal loopback: `rx_input_select=0`, `tx_data_source=1`, TX IQ feeds RX
  inside the composite), plus hierarchical taps:
  - Preamble Detector FIFO: `numEntries`, `pop_on_empty_FIFO`,
    `push_on_full_FIFO`, raw `push`/`pop` (Delay8/Delay10 taps),
  - `Peak_Search` `done`/`success`/`timingOffset`, `Timing_Adjust` armed,
    `Preamble_Detector` syncPulse/validOut,
  - ByteWordBuffer TX-ingestion seam: `state_count`, `readyNext`, `avail`,
    `wordFirst`, `PopEdge`.
- `sim_byte_tgen.cpp` — Verilator driver replicating `qpsk_traffic_gen.v`
  bit-exactly: 1528-byte frames = 12 B header (0x51 0x4B, len LE, seq LE from
  1, CRC-const 0x54474E21 LE) + `fill` PN bytes (xorshift32,
  `x = seq ^ 0x9E3779B9`, 0 -> 0xDEADBEEF; per byte `x^=x<<13; x^=x>>17;
  x^=x<<5`; byte = x & 0xFF) + zero pad; one 64-bit word per handshake beat
  (LSB byte first), `byte_first` on word 0, programmable inter-frame gap,
  `adc_validIn` 1-in-2 (cadence-2 TX pacing, the `sim_byte.cpp` idiom);
  `byte_rx_ready` tied 1.
  Scoring: delivered `byte_rx` frames (framed by `byte_rx_last`) are compared
  content-exact against the generator model (magic+len+seq+CRC-const+PN+pad);
  a framing-agnostic magic-scan over the raw delivered byte stream is the
  cross-check. A 100k-clk timeline logs delivery/pdSync rates and the preamble
  FIFO state (min/max numEntries, cumulative pop-on-empty / push-on-full).
- `build_tgen_wedge.sh` — build script (clone of `build_replay_lock.sh`
  pattern, pinned to the flashed netlist dir).

Geometry measured in-sim: modem frame period = 98,664 clk (matches the
Preamble Detector delay-line length 49,332 rail beats at cadence 2); with the
silicon sweep pacing `gap=100000` the byte plane carries one 1528-B tgen frame
every second modem frame (197,328 clk) — the same ~624 f/s : ~1245 fsync/s
ratio the silicon sweeps show.

## Side finding 1 (harness-blocking until understood): ByteWordBuffer gapped-valid swallow

First control attempts drove the tgen word cadence literally (valid pulsed,
8-clk build bubble per word, i.e. the fabric generator's S_BUILD cadence).
Result: DETERMINISTIC alternate-word swallow — delivered frames carried words
0..6 then only even words (8,10,12,...). Trace (`QSIM_DBGCLKS` seam log):
after the ingestion skid FIFO fills to 7 (ready threshold `newCount<=6`,
DEPTH 16), every Transmitter pop admits TWO source words under the delayed pin
ready (pin = internal ready delayed 9: `ReadyDly` + 8-deep `delayMatch31`,
TxRxComposite.v:1443) while only ONE is stored (push gate = the delayed-8
`state_readyHist[7]` view inside `ByteWordBuffer.v`).
The skid buffer's documented contract ("source-accept and FIFO-store are
identical sets by construction") holds ONLY for a source that keeps `valid`
asserted through the ready-lag window (as the axi_dmac and the `sim_byte.cpp`
BIST source do — continuous valid): then the depth-16 margin absorbs the lag
and nothing is lost (verified: bubble=0 legs are content-clean). A source that
GAPS valid at the 9-11-clk word cadence hits the accept/store mismatch every
stall-resume, one swallow per pop.
Consequence for the harness: control legs drive continuous valid within a
frame (`QSIM_TGEN_BUBBLE=0`); the tgen-literal bubble cadence is kept as an
env knob. Consequence for silicon: this seam is a named, sim-reproducible
accept/store divergence mechanism at the TX byte-ingestion seam — structurally
adjacent to the silicon "overrun swallow" / TX-seam singles classes (silicon
tgen must present an effectively-continuous valid, or its physical seam
differs from the netlist pin contract; the netlist pin contract itself is
provably lossy for gapped-valid masters).

## Runs

All legs: fresh reset, gap=100000 (the silicon sweep pacing), bubble=0,
`byte_rx_ready=1`, scored content-exact. RX warm-up from reset costs the
first ~4 modem frames (the first offered frame lands before RX sync; expected,
also seen in the 8-frame shakedown where seq 2..7 all delivered OK).

### Round 1 — control + the silicon cliff pair (fresh reset per leg)

| leg | frames offered | content-exact delivered | mid-run losses | fsync-stall episodes | preamble-FIFO |
|---|---|---|---|---|---|
| fill=1516 (control) | 50 | **49** (seq1 = reset warm-up) | 0 | 0 | pinned 12333, pope=ponf=0 |
| fill=47 | 210 | **206** (seq1-4 warm-up) | 0 | 0 | pinned 12333, pope=ponf=0 |
| fill=48 | 210 | **203** (seq1-4 warm-up + 48,49,104) | 3 (singles-class transients; one 80-entry FIFO dip + one merged 3048-B rx frame at ~20.6M clk, self-recovered) | 0 | min 12253, pope=ponf=0 |

The exact commands (one per leg, fresh process = fresh reset):
`QSIM_TGEN_BUBBLE=0 ./obj_tgen_wedge_flashed/Vwrap_byte_tgen <fill> <nframes> 100000 wedge_repro/leg_<tag> <max_Mclk> 700000`.
Denominator discipline: "content-exact delivered" counts only frames whose
full 1528 B match the generator model; every offered frame not so delivered is
a loss (warm-up losses itemized separately). Positive control passes: at
fill=1516 every steady-state frame is delivered bit-exact under real
`byte_ready` backpressure.

The silicon 47/48 cliff did NOT reproduce at 210 frames from reset: both legs
clean, no fsync degradation, `pop_on_empty_FIFO`/`push_on_full_FIFO` never
asserted, preamble-FIFO `numEntries` pinned at FULL (12333 = its steady state;
empty-compare constant is 0, full-compare 12333).

### Round 2 — pushing down the fill axis (210 frames each, fresh reset)

| leg | offered | content-exact | rx `last` frames seen | frame starts (fsync ctr) | dead 100k-clk windows (pdSync=0) | fsync-stall episodes (>=0.3M clk) | FIFO min |
|---|---|---|---|---|---|---|---|
| fill=16 | 210 | **181** | 391 (of 424 expected) | 399 | 26 | 3 (0.5, 0.5, 0.6M clk) | 11848 |
| fill=1 | 210 | **104** | 278 | 291 | **133** | **11**, longest **5.0M clk = 50 modem frames** | 11510 |

**The RX framesync-collapse class REPRODUCES from reset, content-dependent and
graded** — at fill<=16, exactly where silicon wedges within the first second.
In sim the collapse is TRANSIENT (always re-locks); on silicon it is
persistent until PL reprogram.

### Mechanism (per-event sync log, fill=1 leg)

Healthy cadence = one `Peak_Search` done(success=1) + one syncPulse per modem
frame (98,664 clk), `timingOffset` near-constant. At fill=1:

1. `timingOffset` WALKS frame-to-frame even while detection still succeeds
   (12323 -> 12275 -> 12227 -> ... monotone-ish drift): the near-all-zero
   unscrambled payload starves the timing/carrier loops of transitions, so
   the symbol clock walks.
2. Collapse onset: `Peak_Search.done` fires with **success=0** (correlation
   peak below threshold) for tens of consecutive frames; `timingOffset`
   freezes at its last value; **syncPulse stops** -> `cnt_frame_start`
   freezes (this is the silicon 0x104 collapse signature); the done-cadence
   itself stretches (98.7k -> ~104k clk) as the un-disciplined loops drift.
3. During the outage, occasional success=1 one-shots at bogus offsets
   (386, 9047, 7739 ...) re-anchor for a single frame and immediately fail
   again — marginal/false detections inside the zero-run.
4. The preamble delay FIFO `numEntries` wanders DOWN from its pinned-full
   12333 (min 11510) and back — a SYMPTOM of the stalled/irregular pop
   cadence, not the cause: `pop_on_empty_FIFO` and `push_on_full_FIFO`
   never assert in ANY leg (cumulative 0 everywhere).
5. Eventually a real preamble catches (success=1 at a sane offset), syncPulse
   resumes, FIFO re-pins at 12333, delivery resumes bit-exact.

So the working hypothesis is HALF-confirmed: the collapse is real,
content-driven, and lives in the preamble/sync path — but the failure mode is
**detection starvation + timing-loop walk** (success=0 runs, false one-shot
re-anchors), NOT a push/pop-guard FIFO desync; the `Validate_Input_Push_Pop`
guards stay silent throughout.

A fill-independent benign periodic event also exists: one extra syncPulse
every ~7.4M clk (75 modem frames) in every leg incl. control — a slow drift
beat that re-syncs harmlessly; noted so nobody mistakes it for the wedge.

### Round 3 — 600-frame dwell: THE 47/48 CLIFF REPRODUCES

| leg | offered | content-exact | outcome |
|---|---|---|---|
| fill=1516, 210 fr | 210 | **208** | clean (seq1 warm-up + 1 singles-class transient, 1 merged frame, self-recovered) |
| fill=48, 600 fr | 600 | **592** | **clean to the end**: zero pdSync-dead windows, FIFO pinned 12333 the whole run (4 warm-up + ~4 singles-class losses) |
| fill=47, 600 fr | 600 | **282** | **clean for 288 frames, then PERMANENT collapse at ~57.0M clk (frame ~289)**: ok frozen at 282 for the remaining **61.7M clk (~620 modem frames) with NO recovery** through end of sim |

Post-collapse state of the fill=47 leg (sync event log): peak search runs
`done` with **success=0 459 times vs 48 sporadic success=1 one-shots** that
never stick; `timingOffset` frozen at 7965; preamble FIFO `numEntries` drifts
12333 -> 9346 and stays wandering; pdSync-dead runs become near-back-to-back
(3.2M, 4.4M, 2.2M clk ...). TX keeps consuming (txsent reaches 600, fsync
counter keeps ticking on filler) — delivery is dead, exactly the silicon
signature (0x104 collapse with the DUT transmitting filler).

Commands: `QSIM_TGEN_BUBBLE=0 ./obj_tgen_wedge_flashed/Vwrap_byte_tgen {47|48}
600 100000 wedge_repro/leg_f4{7|8}x 125 700000`; 600 offered frames each;
every offered frame not delivered content-exact counts as lost.

### Offset-walk comparison (successful detections only; f47 pre-collapse span)

`timingOffset` step between consecutive successful peak-searches — the
timing-loop walk induced by the low-transition (unscrambled zero-run) payload:

| leg | n | nonzero steps | stddev (LSB) |
|---|---|---|---|
| fill=1516 | 422 | 2 (0.5%) | 3.3 |
| fill=48 | 1202 | 11 (0.9%) | 4.2 |
| fill=47 (pre-collapse) | 566 | 8 (1.4%) | 4.4 |
| fill=16 | 392 | 26 (6.6%) | 14.2 |
| fill=1 | 269 | 52 (19.3%) | 24.5 |

Monotone in the zero-run length: the more zero payload, the harder the symbol
clock walks between detections. fill 47 vs 48 differ only marginally in walk
statistics — the cliff is a threshold-proximity effect (the 47 leg happened to
walk past the point of no return at frame ~289; 48 stayed on the safe side for
600 frames), consistent with silicon's dwell-scoped cliff (fill=48 also
degraded at 60 s dwell on silicon, TGEN_SWEEP addendum item 3).

## Priority insert (2026-08-18): the "periodic double-syncPulse" and the counter-aliasing question

Requested: characterize the periodic double-syncPulse seen in every leg's
timeline; find the counter pair; extrapolate vs the silicon 119.75 s 0x108
burst period.

### 1. The double-syncPulse is an INSTRUMENTATION MOIRE, not a DUT event

The per-event sync logs (exact clk of every syncPulse) show **zero** double
pulses in healthy legs: the control's 229/229 S-intervals are **exactly 98,664
clk** (no jitter, no precession over the whole 22.7M-clk span). The timeline's
"pdsync=2 windows" are the beat of my 100,000-clk reporting window against the
98,664-clk sync period: a window catches two pulses every
98664/(100000-98664) = 73.85 windows = **7,385,329 clk = 74.85 frames** —
matching the observed 7.5/14.9/22.3/29.6/37.0M grid in every leg. The biterr
"spikes" (80-108 vs mean 53.3/window) sit on the same grid: windows containing
two frames count two frames' worth. Lesson for silicon: any fixed-period
sampler over a 1245.44 Hz process aliases exactly like this; audit 0x104/0x108
collection windows before calling a burst periodic.

### 2. Counter survey + measured phase slips (taps `egCount/tarefCount/dbfWrCount/dbfRdCount`, run `wedge_repro/beat30`)

Netlist counter inventory (count-to values): 12332 (=12333 states:
Preamble-FIFO push/pop, Peak_Search, Timing_Adjust), 12319 (=12320:
End_Generator), 49279 (=49280: Data_Bits_FIFO ×2), 24665 (=24666:
Data_Bits_FIFO), 4096, 31, small ones. Frame = 49,332 rail beats = 4 × 12,333
= 2 × 24,666. Measured per-frame phases at each syncPulse (fill=1516):

- `Timing_Adjust.timing_Reference` (12333): **constant** at S (12,333 valid
  beats/frame exactly) — frame-commensurate, no slip.
- `End_Generator` (12320): **sync-slaved** — its rst is the syncPulse-derived
  packet start (Packet_Controller.v:123,144); it counts 12,320 valid beats,
  fires endOut, and is re-anchored every frame. It can only free-run (slip
  13/frame vs the 12,333 frame) **while syncPulse is missing** — i.e. during
  wedge episodes. During the fill<=16 episodes this predicts phantom packet
  ends walking backward 13 beats/frame, which is consistent with the merged/
  odd-length rx frames observed there (12 odd frames in the fill=1 leg).
- `Data_Bits_FIFO` write counter (49280, TX bit domain, 24,666 bit-beats per
  frame): **the one true free-running slip**: phase at S walks
  156 -> 24,822 -> 208 -> 24,874 -> 260 -> ... = **two interleaved branches
  (even/odd frame), each +52 per 2 frames, mod 49,280**. Deterministic and
  reset-seeded: bit-identical across independent runs and across fills for
  the early frames (matches silicon's bursts being phase-locked to arm).
  49,332-49,280 = 52 is the per-2-frame slip; note the control leg's biterr
  floor is ~52-53 counts/frame — consistent with a 52-bit-slot/frame
  structural mismatch on the TX bit plane being visible in the error counter.

### 3. Extrapolation arithmetic — does NOT predict 119.75 s

At 122.88 MHz (98,664 clk = 802.9 us/frame, fsync 1245.44/s — this, not
125 MHz, matches the silicon 803.2 us frame):

| beat | recurrence | period |
|---|---|---|
| dbfw slip (+52/2 frames mod 49280, gcd(24666,49280)=2) | 24,640 frames | 2.431e9 clk = **19.78 s** |
| dbfw wrap-vs-frame near-alignment, per branch (49280/52 = 947.7 wraps) | 1,895.4 frames | **1.522 s** (two branches interleaved -> alternating species at ~0.761 s) |
| 12333 vs 12320 free-run pair (lcm, gcd=1) | 151,942,560 rail beats | **2.473 s** |
| 13/frame slip mod 12320 (eg free-running) | 12,320 frames | **9.893 s** |

119.75 s = 149,141.6 frames — a non-integer frame count and not an integer
multiple of any of the above (6.05× the 24,640-frame cycle; 12.11× the
12,320-frame cycle). **Conclusion: no counter pair inside this netlist beats
at 119.75 s from reset at 122.88 MHz.** What the netlist DOES supply
natively is the **alternating two-species structure** (the even/odd dbfw
branches) — the strongest structural match to the silicon bursts' two
alternating size species — at the wrong base period. Remaining candidates for
the 119.75 s base: an element outside this netlist (host sampler, DMA pacing,
other fabric IP), or the silicon-only detuned regime (fsync 1256/s = ~11
extra syncs/s; extra/missed packet starts let End_Generator free-run, which
changes the arithmetic and which the from-reset sim never enters at healthy
fills). The half-integer frame count of 119.75 s itself suggests the true
super-period is 239.5 s with two alternating half-period species — consistent
with the species alternation silicon sees.

### 4. Co-occurrence and interval sequence in sim

No genuine extra-sync events exist in the sim legs, so no co-occurrence test
is possible on them; biterr is flat (53.3±5/window) outside the moire grid.
The first PREDICTED dbfw wrap/frame-boundary alignment from reset is at
even-branch index j≈945 two-frame pairs -> modem frame ~1,890 ≈ 186.5M clk —
beyond every current leg's span (max 1,200 modem frames). A targeted ~2,000-
modem-frame leg (~4 h wall at current throughput) would put one alignment
event on screen with full taps; flagged as the follow-up experiment.

## Verdict

**REPRODUCED.** On the flashed-generation netlist, from reset, in pure RTL
simulation:

- The silicon 47/48 cliff reproduces at the 600-frame dwell: **fill=47 wedges
  permanently at frame ~289 (282/600 delivered, zero recovery over ~620
  subsequent modem frames); fill=48 delivers 592/600 clean.**
- The graded form reproduces below the cliff: fill=16 (3 transient fsync-stall
  episodes) and fill=1 (11 episodes, longest 5.0M clk) collapse and re-lock;
  severity is monotone in the zero-run length. (Divergence from silicon noted:
  silicon at fill<=16 is persistent-until-reprogram; sim recovers at those
  fills but is persistent at fill=47. Consistent with a threshold-proximity
  process whose escape probability depends on loop state, not with a hard
  combinatorial latch-up.)
- **Stage and mechanism (named):** the Preamble Detector's
  correlation-detection path in the Frequency and Time Synchronizer.
  The unscrambled short-fill frame puts a >=1469-byte zero run on the air;
  the transition-starved payload lets the symbol-timing loop walk
  (offset-walk table above), the correlation peak drops below threshold, and
  `Peak_Search` returns `done && !success` frame after frame — syncPulse
  stops, `cnt_frame_start` (the 0x104 proxy) freezes, delivery dies while TX
  keeps consuming. Sporadic marginal/false one-shot detections inside the
  zero-run (offsets 386/9047/7739/7965...) re-anchor for a single frame and
  fail again; past a walk threshold the loop never re-captures = the wedge.
- **The original FIFO hypothesis is refuted in its specific form:**
  `Validate_Input_Push_Pop`'s `pop_on_empty_FIFO`/`push_on_full_FIFO` never
  assert in any leg, wedged or healthy (cumulative 0 everywhere). The
  preamble FIFO's `numEntries` wander (12333 -> ~9350) is a downstream symptom
  of the stalled pop cadence, not the cause.
- Fix directionality this suggests: scramble/whiten the byte payload (or
  enforce a minimum-transition line code) ahead of modulation, and/or clamp
  the timing-loop's freewheel drift during detection loss; the FIFO guards
  need no change.

Caveats: sim "persistence" is bounded by the run length (61.7M clk observed
wedged; silicon persistence is hours+). The silicon boundary at 20 s dwell
(~12k frames) vs sim 600 frames means the sim cliff position agreeing at
exactly 47/48 has an element of luck in it — the robust, sample-supported
claim is: fill<=47 wedges within hundreds of frames, fill>=48 survives >=600
frames, severity monotone below the cliff.

## Artifacts

- Harness: `jupiter_240k5_byte/rtl_sim/{wrap_byte_tgen.v, sim_byte_tgen.cpp,
  build_tgen_wedge.sh}` (committed; build dirs and run outputs gitignored).
- Run outputs: `jupiter_240k5_byte/rtl_sim/wedge_repro/leg_*` (timeline,
  frames, sync-event, rxbytes, res files per leg) — local only.
