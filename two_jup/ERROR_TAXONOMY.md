# ERROR TAXONOMY — two-Jupiter K5 link (loss-proof -S campaign, 2026-07-11/12)

The definitive error-source attribution for the deployed link (pifix image,
quiet pair 2.00/1.90 GHz, gain-pinned), built from: loss-proof `-S` sequence
accounting (every transmitted frame ends OK/BITERR/LOST exactly once),
error-triggered IQ ring captures replayed through the ideal float receiver
(`decode_seq_k5`) and the bit-true fixed netlist (`replay_capture` +
`score_rxw_seq`), raw errored-frame dumps, and 5 Hz scalar telemetry
(rstcs/cfc/rssi). Method: `FLOAT_FIXED_CAMPAIGN.md`; tools: `seq_census.sh`,
`error_hunt.sh`, `episode_stats.py`.

## Baseline census (10 min, both directions)

| Direction | OK | BITERR | LOST | JUNK | BER(ok+biterr) |
|---|---|---|---|---|---|
| FWD 146→148 | 97.3% | 936 (avg ~102 bits) | 2447 (1.93%, 861 gaps) | 1643 | 7.5e-4 |
| REV 148→146 | 99.2% | 370 (avg ~72 bits) | 632 (0.50%, 248 gaps) | 336 | 2.1e-4 |

(-B had silently under-run the air rate by ~1.2% — the same losses, invisible
to its bucket accounting.)

## Class 1 — PERIODIC ~1.57 s DEVICE-TICK EPISODES (~95% of all errored frames)

(Originally attributed to the ADRV9002 tracking cals; that theory was KILLED by
the 600 s all-cals-off endurance run — evidence chain and correction below.)

**Signature:** error episodes (2–8 consecutive frames of BITERR burst + junk
+ outright loss) at a razor-sharp **~1.57 s period** (median spacing 333/332
frames on FWD/REV respectively; both boards, independent phases).

**Evidence chain:**
1. Ring-captured trigger frames decode PERFECTLY in float AND bit-true fixed
   replay (ev4: live 163 errs → both legs 0; ev5: live 331 → both 0) — the
   air samples are clean; the modem numerics are clean.
2. rstcs = 0 across entire runs (no carrier resets); rssi/cfc stable.
3. RT + core pinning of the host daemon: NO effect (host scheduling out).
4. **Disabling the ADRV9002 background tracking cals post-lock eliminated the
   periodicity**: FWD BER → 1.8e-5, REV → 6.5e-6 while the link lived.
   (Full disable also kills the link in ~32 s — bbdc/agc are load-bearing —
   so the deployable fix is the minimal guilty subset.)
5. Bisect (each individually disabled, others on): `rssi` — periodicity
   remains; `agc` (both gains pinned) — remains; `txclg` — remains;
   `bbdc` — remains (and reverse degrades without it); **only-bbdc-enabled**
   — remains. ⇒ **no single cal is the offender: ANY enabled tracking cal's
   execution window disturbs reception on the common ~1.57 s scheduler tick.**
   The full disable was clean because the tick had no cal to run.

**Mechanism (CORRECTED after the 600 s endurance run):** the tracking-cal
theory is DEAD — with ALL cals disabled (writes verified applied and
persistent), reverse still pulsed at 1.581 s for the full 600 s (318
episodes). The two early "clean" windows were short-lived dying-radio
artifacts, not fixes. (Also learned: disabling agc AND bbdc together kills
148's Rx at the write moment; any single one stays alive — never fully
disable both on 148.)

**Precision fingerprint (baseline census, both directions alive):** common
period 1.570 s; episode-fold jitter only 16–27 ms; reverse phase drifts
6 ms/5 min, forward 76 ms/5 min ⇒ **two independent per-board sources with
identical nominal period, each on its own device clock** — the signature of
ADRV9002 firmware housekeeping (per-device ARM/DEVCLK tick), not kernel
timers (which would tick identically on both boards) and not RF/external
(phases independent).

**FINAL ATTRIBUTION (2026-07-12, dual-DMA tap campaign): LIVE-LOOP STATE
DISTURBANCE, clock/fabric-domain entry.** Episodes captured with simultaneous
receiver-input (rx-lpc) and live-constellation (rx2-lpc, mux 3) windows in
BOTH directions; verdict **11/11 covered events LIVE-DIRTY** — forward 6/6
(hunt 20260712_062648), reverse 5/5 (hunt 20260712_065712; its ev1 fell in
pre-lock acquisition, not covered) (`hunt_verdict_k5`):

1. AIR CLEAN: the receiver-input window float-decodes with **0 bit errors
   through every episode** (6/6, `decode_seq_k5`).
2. LIVE DIRTY: the FPGA's own constellation output in the same instants
   carries 21–867 bit errors and drops 10–14 frames per window
   (`decode_con_k5`).
3. INGEST VALID CADENCE PERFECT: AdcForensic 0x15C high-water marks read
   maxGap=1 / maxBurst=1 across whole sessions — the modem's input valid
   pattern never glitched once.
4. NO RF FEATURE AT TRIGGERS: per-frame phase/amplitude/timing trajectories
   of the input windows show no repeatable anomaly at trigger frames
   (`tick_localize_k5`: |z|<2 in 5/6; one 10%-amp coincidence).
5. MANIFESTATION (tap stream anatomy, ev6): during an episode the FTS skips
   symbol strobes (16-beat holds = one missed strobe), aborts segments
   mid-frame, merges frames (missed Barker boundaries), and drops out for
   ~exactly one frame (9174-beat gap = 110 + 9064); between episodes the
   cadence is beat-exact (683 gaps of 110, segments of 8954).

Deterministic logic fed bit-identical data + a perfect valid pattern cannot
diverge from replay — so the disturbance enters through the one path the
captures cannot represent: **the clock/fabric domain**. At each ADRV9002
device tick, the receiver's deep recursive state (symbol-timing loop first —
the same element that wedges in Class 4) takes a transient hit, the FTS
stumbles for 1–3 frames, then recovers. Consistent with an SSI/DEVCLK
retiming or internal-housekeeping event briefly eroding fabric timing
margins; the samples (feed-forward path, self-flushing) survive, the loops
(recursive state) do not.

**SHADOW-LOOP MEASUREMENT (canary image `a498d76d…`, first instrumented hunt
20260712_190124): the timing LOOP FILTER is NOT corrupted during episodes.**
An exact shadow copy of the hardened loop filter (fed the TED error one beat
late; alignment invariant RTL-proven, `tb_shadow_align`: 100k beats, 0
mismatches) ran live through ~300 episodes (1190 error events, 2250 poll
samples): divergence counters pdiv/idiv NEVER left zero. If episodes flipped
random loop-state bits, the shadowed set (~6% of Rx loop-state bits) should
have caught ~18 hits — zero observed REJECTS the random-register-corruption
model. Surviving candidates: (i) margin-selective corruption — a clock-margin
event fails the LONGEST paths first (Farrow interpolator, RRC MAC bank, CFC
estimator, carrier DDS/CORDIC), and the loop filter's short MAC paths may
simply be too fast to be victims; (ii) no fabric corruption at all — the
divergence enters via a still-unmeasured dimension, with the un-shadowed
recursive state (IC counter, CFC accumulators, carrier DDS phase) as the
remaining functional suspects. NEXT INSTRUMENTS: a critical-path-replica
canary (deliberately minimal-slack delay chain + upset counter — detects
margin erosion regardless of which functional circuit fails) and shadow
extension to IC/CFC/carrier state. Also noted: the strobe-forensic field
0x184 is rate-miscalibrated (identical readings locked vs wedged) — recount
in the enb domain against the measured nominal.

**Fix directions:** (a) timing-loop state hardening — **IMPLEMENTED 2026-07-12**
(`timing_hardening_overlay.m`, image `6ed649ba…`): IC Delta clamp ±127/1024 +
loop-filter IntegClamp ±0.06 + saturating output conversion. RTL-proven to
make the permanent wedge impossible (tb_timing_wedge WEDGED→RECOVERED), all
gates bit-identical. **HW RESULT: Class-1 episode severity UNCHANGED**
(600 s census: fwd 1069 biterr/2663 lost vs 1051/2160 baseline; rev
449/812 vs 411/734 — within run variability). Interpretation: the clamps
bound the state EXCURSION (killing the Class-4 deadlock), but tick-glitch
corruption *within* the clamped band still costs the same few re-convergence
frames per episode. (b) fabric clock isolation (MMCM-filtered dclk + elastic
buffer) — the remaining Class-1 candidate, heavier build change; (c) identify
and disable the ADRV9002 tick source via ADI API/firmware knobs (tracking
cals already excluded; candidate: internal temperature/PLL housekeeping).

## Class 2 — residual scatter (between episodes)

SCATTER-FEW structures (≤12 bits, 1–3 words) at low rate; the projected
post-fix floor is ~1e-5–1e-4 class (first no-cal windows measured FWD 1.8e-5 /
REV 6.5e-6). To be re-measured in the final acceptance.

## Class 3 — air-level frame mangling (rare)

ev5's window: 3 isolated single-frame losses + 4 float-irrecoverable junk
frames in 694 — frames genuinely absent/mangled in the IQ stream. Some or all
may be ring-capture-side sample drops during Class-1 episodes (the iio stream
stalls with everything else); to be re-quantified once Class 1 is fixed.

## Class 4 — acquisition failures (bring-up, not steady-state)

~1/3 of arms need the verified-lock retry (documented in BRINGUP §3); once
locked, steady-state is Classes 1–3.

**ROOT-CAUSE EVIDENCE (2026-07-12, ch2 A/B campaign):** the ch2 image's
reverse leg (148 TX2 → 146 RX2) reproduces the failure on ~9/10 arms, and the
debug tap dissected it live:
- receiver INPUT capture: float-decodes 114/115 frames, 0 bit errors — the
  arriving waveform is perfect;
- tap mode 0 (AGC out): flowing, clean, correct +5.2 kHz CFO;
- tap mode 1 (postSymbolSync): **FROZEN at one constant value** (magCV
  exactly 0 over 0.55 s) — the symbol synchronizer emits nothing;
- tap mode 3 (constellation): all zeros (FTS never produces output);
- `rstcs` accumulates (CFO-step detector fires) but the rstCS pulse does NOT
  clear the stall — only a full IP re-arm (0x000 toggle) can, and then only
  sometimes.

⇒ Class 4 = **symbol-timing-loop wedge at acquisition**: the Gardner loop
enters a state where its output strobe never fires; carrier-sync resets can't
reach it. The same-design ch1 legs hit this at the historical ~1/3-arm rate;
ch2-reverse's conditions made it nearly deterministic.

**MECHANISM SIM-PROVEN + FIX DEPLOYED (2026-07-12):** the Loop Filter
integrator wraps (no saturation) and the v=[23:13] output slice wraps; any
poison driving Delta <= -0.125 makes the Rice mod-1 counter's underflow
condition unreachable forever (tb_timing_wedge.v: WEDGED on the shipping
netlist). Fix `timing_hardening_overlay.m` (image `6ed649ba…`, both boards):
IC Delta clamp +-127/1024 + IntegClamp +-0.06 + saturating conversion — the
permanent wedge is impossible by construction (TB: RECOVERED), normal
operation bit-identical (all gates). HW wedge-testbed proof on ch2-reverse
was BLOCKED by the mid-day RX2 SSI degradation (see PROVENANCE `a34233c5…`
row); post-hardening ch1 arms have locked first-try 4/4 so far (historical
~2/3) — natural evidence accumulates with every future session.

## Instrumentation campaign verdict — T8.5 → T8.6.3 (2026-07-12/13)

**P0 FINAL: no monitored fabric state diverges during Class-1 episodes.**
Definitive session `hunt/20260713_202258_fwd` on image `58429a44…` (all
instruments zero-assert-proven post-lock, including the compensated IC shadow
— the two prior images carried a lying IC instrument from the shadow's
leading-beat offset, fixed by `countReg` init 0.125 + `tb_ic_align`):

| instrument (AXI) | monitors | result over 600 s / 2,561 polls |
|---|---|---|
| pdiv/idiv 0x170/0x178 | timing LF P-path + integrator (shadow copy, 1-beat offset) | **0 everywhere** |
| icdiv 0x190/0x194 | Interpolation Control mu/underflow (compensated shadow) | **0 everywhere** |
| csdiv 0x198/0x19C | carrier LF P-hold + integrator (shadow copy) | **0 everywhere** |
| path 0x18C | 4 graduated critical-path canaries (N=2..5 chains) | **0 everywhere** |

Episode load during the session was normal (fwd: 1,083 biterr + 2,619 lost of
126,917; rev: 291 + 179 of 126,697) — the errors happened while every shadow
stayed aligned. Combined with the LIVE-DIRTY attribution (air clean, valid
cadence perfect, constellation corrupt), the corruption source space reduces
to: **(a) un-instrumented state** — NCO phase accumulators (library-locked),
CFC estimator, frame-sync/preamble/timing-adjust decision registers (see
`P1B_TAP_MAP.md`) — **or (b) no fabric corruption at all** (an input
dimension the taps don't represent). The T8.7 state-injected replay protocol
(telemetry image + `t87_protocol.sh`) discriminates (a) vs (b) per event.


## T8.7 state-injected replay verdicts (2026-07-14, session 20260714_024112)

Telemetry image `d06f6741…`, 6 events, telemetry+input rings. Findings:

1. **Ring-save displacement discovered**: the two ring copies are sequential,
   so tap-ring and input-ring windows are offset by the copy latency
   (~1.3 s, event-dependent). Alignment recovered per event by FFT
   cross-correlation of the carrier-integrator trajectory (r = 0.7-1.15,
   unambiguous). All prior tap-vs-input pointer math carried this bug.
2. **Cold-sim register comparison is impossible in principle**: quantized
   loops from different initial state never re-converge bit-exactly (<=3/200
   anchors at ANY offset). Register-level compare requires full-state
   injection; 22-register partial injection cannot warm-start a receiver.
3. **Input timing-wobble bursts, reproduced in sim**: the input samples carry
   ~25-40 ms timing disturbances that whip the SS loop +-0.3-0.4 symbol; the
   sim mu trajectory reproduces the live bursts beat-for-beat (same frames,
   magnitudes, signs) -- the modem RTL is functionally healthy under them.
4. **The bursts are 5.3 Hz, not 1.57 s**: onset spacing ~0.185-0.192 s with
   33/155 ms substructure = the hunt POLLER cadence (5 Hz; RSSI reads hit the
   ADRV9002 over SPI). Measurement-environment artifact: real, in-data,
   mostly harmless (sim decodes through all of them: <=1 lost frame per 485
   vs live 10-14 per episode; plain BER runs without the poller still show
   the 1.57-s error floor).
5. **Live decode collapse remains live-only**: identical input + identical
   RTL decodes the trigger frames cleanly in sim while live biterr/lost them.
   With loops/IC/AGC proven RTL-faithful (shadows + telemetry) and the input
   exonerated (sim decode), the corruption is cornered in the un-monitored
   FTS datapath (RRC/Farrow/CFC/frame-sync arithmetic + decisions) or the
   byte/DMA plane -- tick-synchronized, constellation-corrupting (0713
   LIVE-DIRTY decode_con evidence), register-invisible.

Next discriminators: TAPMODE=5 hunt (CFC-out bisect, image deployed);
poller-free A/B session (wobble source confirmation); fabric frame counters
vs host accounting (byte/DMA-plane drop test).


## Mode-5/Mode-2 bisect: THE 2-STROBE SUPPRESSION (2026-07-14 morning)

Two 600 s bisect sessions on the telemetry image (normal episode load,
~1,100 biterr + 2,000-2,700 lost each):

- **Mode 5 (CFC output)**: sample values pristine (s^4 spectral line stable,
  no 1.5-s structure) AND cadence intact (change-census deficit never
  exceeds binning noise; the 4-change signature of 2 eaten symbols is
  absent at all 12 in-ring tick events).
- **Mode 2 (CS output)**: per-frame valid census is metronome-1133
  everywhere EXCEPT exactly two frames per 3.28-s ring, spaced at the tick
  period (1.49-1.52 s), each reading 1131 = **EXACTLY 2 symbol strobes
  missing**. Sample values that do arrive stay phase-coherent (C4 ~0.87,
  no periodic dips).

**Class-1 mechanism, final form**: at each device tick the receive chain
eats EXACTLY 2 symbol strobes strictly inside the CFC->CS hop (8.3 us of
paused symbol flow); the frame sync downstream converts the 2-symbol slip
into a 10-14-frame Barker re-hunt = the episode. The air stream carries
the symbols (float decode 0 errors), every monitored register is
RTL-faithful, and no reset fires: **rstcs = 1 per session** (initial
acquisition only) across ~800 tick events -- the CFO-step-detector/reset
path is exonerated (the 2-deep valid-pipe flush theory died with it).

**Surviving suspect**: the CS's library DDS/NCO block (dsphdlsigops2, own
internal valid pipeline, never instrumentable -- the same block flagged by
the Class-4 NCO-reset asymmetry). A single-cycle enable/valid upset there
at the tick eats its pipeline depth (2) in strobes, corrupts nothing else,
and is invisible to every register instrument by construction.

**Next instruments/fixes**:
1. canary4 valid-census counters (CS validIn / NCO validOut / CS validOut,
   per-episode latched) -> name the eater beat-exactly. Small overlay.
2. Robustness fix independent of naming: frame-sync coast-through for
   <=2-symbol slips (TimingAdjust/lookback extension) -- converts episodes
   from 10-14 lost frames to ~1-2 biterr frames even if the eater stays.
3. NCO re-implementation outside the library block (replica already
   validated in the T8.6 recon) with an explicitly hardened valid path.


## Corrected loss ledger + byte-plane exoneration (2026-07-15)

Three acceptance sessions on the rxfifo image (1ef28800: lean + 64-deep
drop-oldest byte-rx FIFO + CDC constraint fix) with legacy and -M 32
multi-slot host RX: ok/biterr/lost/junk statistically IDENTICAL across all
host/byte-path variants (ok ~123.2k, biterr ~1.04k, lost ~2.7k, junk ~1.8k).

**The ledger was misread.** rxw counts words regardless of content (garbage
words from corrupted decodes count like good ones), and junk frames ARE the
lost seqs' bodies (CRC-failed frames with unrecoverable seq bytes land as
junk while their seqs count as gap losses). Reconciled per session:
~1,000 frames never frame-sync (fstart deficit) + ~1,800 sync but decode
garbage (junk, seqs counted lost) + ~1,050 biterr = ALL of the damage,
entirely at the MODEM level. **The byte/DMA/host plane is exonerated.**

Kept anyway (real improvements, wrong battle): drop-oldest byte-rx FIFO
(0x1B0 ovf counter measured the tick's 10-40 ms host/bus stalls: ~25
bursts/session, ~140 words each), -M 32 tick-proof multi-slot -S RX, the
CDC exception XDC (permanent; the MATLAB IP packaging emits ADI constraint
files as stub .txt -- placement was a lottery until now), and the LEAN
build flag (full instrumentation + FIFO exceeds the ZU3EG).

**The standing suspect set returns to the un-instrumented FTS decision/
datapath state at ticks**: Peak Search, Timing Adjust, Packet Controller,
Phase Ambiguity (constellation-level corruption per the 0713 LIVE-DIRTY
decode_con evidence; all loop registers proven RTL-faithful). Next
instrument: P1B decision-register taps (P1B_TAP_MAP.md, recon complete).


## CLASS-1 NAMED: Timing Adjust sync-generation (P1B census, 2026-07-15)

Session 20260715_203950 (P1B image, decision census 0x1B4-0x1C8, normal
episode load 1,083 biterr / 2,024 lost):

| stage | rate | deficit bins | overlap w/ fstart deficits |
|---|---|---|---|
| Peak Search done | 211.83/s FULL | 1 | 0 |
| **Timing Adjust sync** | 210.07/s | **223 (-807)** | **171/213** |
| Packet Controller start/pend | 210.07/s | 233/208 | 169/168 |

Peak Search NEVER misses -- the Barker is found every frame through every
episode. But ps_off_last (the reported peak offset) JUMPS in 534 bins
(median 32 samples): at ticks the received symbol stream's frame alignment
is physically displaced. Timing Adjust arms on the reported offset and
fires sync only when its frame-position counter EQUALS the accepted offset
-- a displaced offset misses the compare for 1-3 frames per event, no sync
fires, and everything downstream starves. This is the Class-1 frame-loss
mechanism, named at register level.

FIX TARGET: Timing Adjust offset-jump tolerance (fire on late-arrival /
windowed compare instead of equality; re-accept a fresh offset mid-window).
Small, sim-testable via the fault-injection harness before building.


## 2026-07-16: TX exonerated; the fork hypothesis (the last span)

- DDS tone through 3 tick periods/board: sampled RF stream CONTINUOUS
  (zero discontinuities at sub-sample sensitivity) -- no samples dropped,
  inserted, or shifted anywhere in the transport.
- TX per-frame DMA queue deepened 8x (tx_send_batch, 8 frames/transfer,
  ~75 ms queued air): losses UNCHANGED -- TX host feed exonerated.
- Float-decoder blind spot found: certain seq payloads (e.g. 1194) are
  undecodable by decode_seq_k5 in ANY session (Barker-alias class) --
  historical air-absent/air-clean claims soft-qualified.
- THE DECISIVE THREE-WAY (session 090804, lost burst 1375-1378):
  host-LOST frames are ON THE AIR, BIT-PERFECT (ideal decode errs=0).
  Transmission flawless; live RX failed them; ta_sync census shows the
  live FTS really did not sync them.

Constraint set now: input identical+perfect, transport continuous, every
monitored register RTL-faithful, state+input determinism proven -- yet
live output differs, time-periodically (~1.54-1.57 s/board). The ONLY
never-instrumented span: the FORK between the capture branch (everything
"proven about the input" was proven about the captured copy) and the
consumed branch feeding the AGC. If the tick corrupts the consumed branch
after the fork, every observation fits simultaneously.

NEXT INSTRUMENT: in-fabric fork-compare (block checksums of both branches
+ divergence counter). Link-goal alternative regardless of root cause:
ARQ (~2% retransmission absorbs the loss class entirely).


## The closing measurement (2026-07-16): the air is metronomic through the episode

Float-decoded frame positions across the lost burst (session 090804, seqs
1367-1385 incl. host-lost 1375-1378): spacing EXACTLY 1133.0 symbols,
frame after frame, no wobble, no displacement -- while the live receiver's
Peak Search reported ~32-sample position jumps and Timing Adjust missed
syncs for those very frames. The displacement exists ONLY inside the live
receiver's frame of reference. Combined with every register being proven
RTL-faithful, the transient shift must live in the un-monitored linkage:
the input-net fork (capture vs consumed branch) or sub-RTL enable/clock
physics at the device tick. The fork-compare overlay is the designed
discriminator; ARQ closes the link goal independently.

## Status

- [x] Class 1 periodicity fingerprinted: 1.570 s, per-board independent phase,
      device-clock domain (host RT/pinning, kernel timers, SPI poller, and ALL
      tracking-cal configurations excluded)
- [x] Tracking-cal theory killed (600 s verified-all-off endurance still pulsed)
- [ ] Class 1 mechanism localization via the TAP IMAGE (live constellation on
      voltage1 + state-pair regs at episode instants): live-con dirty ⇒ loop
      state/RF transient; live-con clean ⇒ post-constellation (byte-DMA/host)
- [x] ch2 A/B RESOLVED: **ch1 adopted**. ch2 forward locks instantly and runs;
      ch2 reverse hits the Class-4 symbol-sync wedge on ~9/10 arms (one locked
      window ran 1.3e-4 — no improvement over ch1). ch2 image `d32475cb…` +
      `*_ch2.sh` harnesses kept in reserve; boards restored to ch1 `6b1b4409…`.
      (The 1.57 s periodicity-vs-channel question is superseded by the tap
      discriminator on ch1.)
- [ ] Class 2/3 re-quantification once Class 1 is attributed

## 2026-07-16 — CLASS-1 ROOT CAUSE MEASURED (P1C per-symbol PD telemetry)

Image `5d2efdbc` (P1C: 8-word per-symbol Preamble Detector snapshots on the
tap stream, `p1c_pd_telemetry_overlay.m`, parser `k5_240/tel_pd_parse.py`),
hunt `20260716_215923_fwd`, 6 event windows, ~750k symbol records each.

**The mechanism, measured live (identical in all 6 windows):**
at each device tick the Peak Search latched offset steps EXACTLY
101→133 (+32 symbols = 256 samples), holds ~0.165 s (~35 frames — Timing
Adjust re-syncs at 133 and frames decode there), then steps back −32.
heldTs (peak timestamp) deltas form the k·1133±32 family (2298 at onset,
1101 at recovery). Onset costs ~2 frames, recovery ~1 → the 5-8/episode
ledger. PD counters (tRef/tRefLong) never skip a strobe. The inserted 32
symbols are statistically normal (not held, not replayed); preambles
de-correlate ~4 frames at onset then run clean at the displaced position.

**The fork, measured at the data level (same session, same instants):**
- capture branch (voltage0): `decode_seq_k5` → 690/690 frames bit-perfect,
  spacing 9064 samples, 0/687 intervals deviating >8 samples — metronomic
  THROUGH both onsets.
- consumed branch (PD telemetry): frames at +32 for 0.165 s, provably
  (TA syncs and decodes at the displaced offset).
- bit-true netlist replay of the SAME capture (obj_byte_taps, P1C netlist):
  690 packets, ALL 689 inter-sync spacings exactly 1133 — the RTL cannot
  produce the displacement from the captured input.

**Verdict: the displacement enters the consumed data between the fork net
(`Receiver.v: assign debugI1 = dataInI`) and the datapath, invisible to
every RTL-level observation and absent from the captured branch — a
physical/sub-RTL divergence at the ADRV9002 device tick (effective ±256-
sample insertion/removal in the receiver's sample delivery). Vendor-
escalation territory (tick housekeeping vs SSI/valid path); fabric-side
mitigation = tolerate a ±32-symbol frame-position step (TA fast re-accept /
coast) and/or link-layer ARQ.**

Analysis stack: `k5_240/tel_pd_{parse,analyze,deep}.py`,
`k5_240/tel_sim_verdict.py`; splice-injection repro (256-sample insert →
netlist replay) validates the failure is synthesizable in simulation.

## 2026-07-17 — BOARD ASYMMETRY: the ±32 displacement is 148-SPECIFIC

Reverse-side P1C hunt (`20260717_073510_rev`, ring+tap on 146, 6 windows,
~12 tick periods sampled): **146 shows NO ±32 displacement — zero
tOff steps of the 101→133 kind, no k·1133±32 heldTs family, counters
perfect (lockstep divergences 0).** Its episode signature is different in
kind: frequent TRANSIENT FALSE PEAK LATCHES (tOff flips to a random offset
— 448/212/416/606/… — and re-latches the true offset within 1–2 frames;
~8–14 per window vs ~0.5 on 148), occasional missed syncs (2266/3399 =
whole frames, no displacement), biterr bursts (n up to 316), and a slow
−1-symbol baseline walk (793→792→…). Consistent with brief input-quality
degradation at 146's ticks, not a sample-stream displacement.

⇒ The 256-sample consumed-path insertion at device ticks is a property of
BOARD 148's receive path (Rx1 = its documented-marginal path), not of the
design. Sharpen the vendor escalation accordingly: unit-specific,
deterministic 256-sample insert/restore at ARM-tick cadence on one
ADRV9002, absent on the second unit running the identical image.

## 2026-07-17 — LO SWEEP: the 148 displacement is LO-INVARIANT

Three LO pairs (fwd/rev), 180 s P1C hunts on 148:
- **2.0/1.9 GHz (baseline)**: ±32 displacement every tick (101→133→101).
- **0.90/0.95 GHz**: INVALID as tick probe — 148 Rx collapses at this band
  (32% frame loss, continuous re-acquisition; reverse into 146 stays 1.7e-4).
  Yet another marker of 148's marginal Rx path.
- **3.4/3.5 GHz**: displacement PRESENT and IDENTICAL — baseline offset 1114
  steps to 13 = (1114+32) mod 1133 (frame-boundary wrap!), holds ~0.18 s,
  returns; ~1.5 s cadence (e.g. onsets 1.503 s apart); sync-gap family
  2298/1101/1165/3431 = k·1133±32; same per-episode lockstep blips. More
  link noise at this band adds 146-style transient false latches on top
  (BER 5.7e-4 fwd).

⇒ Exactly +32 symbols at ~1.5 s cadence across VCO bands: the insertion is
in 148's DIGITAL sample-delivery path (interface/tick housekeeping), not a
band-dependent cal/VCO interaction. Escalation package: unit-specific,
LO-invariant, deterministic 256-sample insert/restore; second unit clean.
Boards restored to 2.0/1.9 GHz baseline.

## 2026-07-17 — SIMULINK MIRROR CLOSED (P1D image 6feebbf7, hunt 144014)

P1D loss-free telemetry (7-slot, sticky flags, beat field): 786k records,
ZERO lost (P1C: ~17.5k/window). Episode measured completely: 1116→15
(+32 mod 1133), 0.165 s hold, 1.47 s cadence.

**pd_harness_k5 (Simulink PD replay, beat-exact drive from telemetry):
the model reproduces the +32 offset step AT THE SAME RECORD (8000) as the
live hardware** — register-level live-vs-model mirror achieved; the PD's
behavior is fully input-determined, per RTL, through the failure event.

HDL compensation campaign (splice testbench, bit-true): per-transition
damage = exactly 2 frames (straddler + one casualty), content-independent.
Patches tested & NULL: coast-through (A), ±32-triggered CS reset (B, free),
FIFO-drain-matched report delay (C). Exonerated for the second casualty:
sync timing, carrier loop (EVM flat), resolver (transform steady), demod
framing (2240 bits/frame regular). Remaining suspect plane: PC symbol
selection / FEC input alignment — coded-bit shift test pending (patch D
decision). Sync layer proven optimal (wrap-report always fires).

Instrument notes: P1D single-record corruption ~0.5% (6-beat strobe
spacing collides with the 7-slot burst — overwrite mid-emission; filter
len==7 records in the parser; investigate mu excursions at this arm's
SNR). tel_compare: treat tOff/accOff/fifoEnt as phase-relative.

## 2026-07-17 — RX2 ESCAPE TEST (partial): RX2 PATH PRISTINE; derivative image faulted

ch2tap image (8c8ac813, derived from the P1D dualdma build via the bd_ch2
chain) deployed to 148, hybrid arm (146 ch1 / 148 ch2): **RX2 RF+SSI+delivery
ALIVE AND CLEAN** — rssi2 26 dB, raw rx2-lpc capture float-decodes 1057/1059
frames, 0 bit errors (CFO −6 kHz). The 07-12 RX2-SSI outage did NOT recur.
BUT the image's modem never locks: composite adc-valid GAPPY (forensic
maxGap=0xFF vs healthy 1) while the direct DMA path is perfect; tap DMA
(rx-lpc) delivers 0 bytes — the adc_2→composite valid/clock plumbing is
broken in THIS derivation (dualdma-project + ch2-chain interplay; step logs
clean — BD forensics needed). 148 restored to P1D ch1 (6feebbf7) from
.prech2 backup. RX2 tick verdict OUTSTANDING; two completion routes:
(a) debug the derived BD (adc_2 valid path), (b) flash the proven A/B-era
ch2 image (d32475cb, in reserve) and use loss-cadence as the verdict metric.
The RX2-path-clean result upgrades the escape option's prior substantially.

PATCH D v1: write-skip mechanism PROVEN (cleanly shifts exactly one window)
but consumed one window late (detector pulse reaches RxDeint between
stale+1 and stale+2 starts) — added a casualty. Retargets: newPk-time
detection, or Delay10 tap-switch (+32 stages) killing the stale gate.
On hold pending the RX2 verdict.

## 2026-07-17 late — RX2 ESCAPE BLOCKED: the 07-12 SSI-valid outage persists

Cadence test with the PROVEN A/B-era ch2 image (a34233c5): identical failure
to the new ch2tap derivative — rssi2 26.76 dB, fstart=0, 0 frames in 300 s.
Two independent images, same symptom ⇒ board-side, NOT image-side (the
2026-07-17 "BD fault" attribution for the ch2tap build is RETRACTED; that
build may be fine). This is the 2026-07-12 RX2-SSI outage, still in effect
5 days and many reboots later, REFINED tonight: the raw ADC2 DATA path is
pristine (rx2 DMA capture float-decodes 1057/1059, 0 biterr) — only the
adc_2 VALID/enable delivery into the modem composite is dead. RX2 worked
before 07-12 midday (ch2 A/B morning golden) ⇒ an interface/firmware state
change, not fundamentally broken silicon — but recovery is its own
investigation (SSI interface forensics/ADI escalation item #2, BOTH boards).

100x路线 standing: RX2 escape blocked pending SSI-valid recovery; remaining
routes = RMA/replace 148 (clean fix, evidence package ready, now citing two
device-level anomalies), vendor escalation (tick insert + RX2-valid outage),
patch D retarget + PS latch hardening (design-bug fixes, both directions).
148 restored to P1D ch1 (6feebbf7); link healthy.

## 2026-07-18 — RX2 UNBLOCKED + TICK VERDICT: the displacement follows the CHIP

**"RX2-SSI outage" SOLVED — it was never a hardware outage.** The fabric
IP's RX2 path is gated by the IIO buffer state (channel enables flip when a
buffer opens; RX1's ch1-BD wiring is independent of them). Probe: fstart
0 -> 194/2s the instant an rx2-lpc buffer opened. Explains the entire 07-12
"outage" (A/B morning ran with captures active; the midday "death" was
bufferless testing; cold-boot-proof because it's a default, not state).
Workaround: hold a dummy buffer; real fix: BD enable tie-off. NOTE: opening
the rx-lpc (4ch) device concurrently DISTURBS the ch2 modem — hold rx2 only.
This also removes the "outage" from the vendor escalation (our semantics).

**RX2 cadence verdict (reserve ch2 image a34233c5, 300 s -S, 62.7k frames):
207 loss episodes, median spacing 1.495 s, 200/206 gaps at EXACTLY one tick
period — the identical metronomic signature as RX1.** The 256-sample tick
displacement is CHIP-LEVEL on unit 148 (both RX paths, LO-invariant,
loopback-clean, absent on 146). No topology change escapes it.

**100x route CLOSED on strategy: replace/RMA 148** (forward -> the design's
demonstrated ~2e-6, 70x) **+ the two design-bug fixes** (patch D retarget,
PS latch hysteresis) for the balance. Escalation package: the tick insert,
now evidenced on both RX paths of one unit. 148 restored to P1D (6feebbf7).

## 2026-07-18 — PATCH D2 (P1E) PROVEN IN THE SPLICE TESTBENCH

The patch-D retarget is closed. Root understanding: the Timing Adjust runs in
the DELAYED (PD-FIFO-output) domain, so the stale window's deint startIn
trails a newPk event by (FIFO transit − 32) symbols + demod latency — an
invariant in both sim (283 sym) and live (~53 sym) clocking. v1's report-time
detector was therefore provably late whenever accOff < ~850 (consumed one
window late — the observed 218-class damage). D2 arms at newPk time in the
Timing Adjust: d = (psTref − accOff) mod 1133 == 32, with freshest-newPk-wins
cancel and a report-delta≠32 backstop clear (set/clr collision → clear).
Consume = v1's proven RxDeint 64-bit head skip, which moves the stale-grid
window's write capture from [0..2175] to [64..2239] = the displaced frame's
coded bits exactly.

Splice battery (hdlD2 netlist, obj_D2, 3M-sample live capture, splice +256
samples at sample 2,000,000):

| run        | v0 (unpatched)   | v1 (patch D)       | D2                       |
|------------|------------------|--------------------|--------------------------|
| nosplice   | —                | —                  | bit-identical, 0 arms    |
| repeat     | lost {355,356}   | lost {355,356,357} | lost {355} only          |
| phase90    | lost {355,356}   | —                  | lost {355} only          |
| noise      | lost {355,356}   | —                  | lost {355}; 356 = 1 bit  |
| noise90    | lost {355,356}   | —                  | lost {355} only          |

Every splice run: exactly one P1E_SET (tref=486 acc=454, delta exactly +32)
confirmed by P1E_REP32 646 symbols later at the wrap — content-independent,
zero spurious arms across 12M+ simulated samples. The stale-grid casualty
class (one frame per insert transition, unconditional) is eliminated; only
the mosaic window containing the physical insertion remains lost
(information-theoretically unrecoverable). The −32 recovery transition never
arms (d = 1101) and is benign in the live census.

Model promotion: jupiter_240k5_byte/p1e_comp_overlay.m (P1eArm MLFB with
registered outputs inside Timing Adjust + fecRxDeint MLFB pend/skip patch),
assemble phase 2.16g. Sandbox: overlay applied clean, pre-synth gates OK,
full update with zero p1e-attributed diagnostics. Netlist evidence:
k5_240/gen_hdlD2.py (the bit-true patch generator), k5_240/score_splice.py
(the seq-differential scorer; seq = rxw word0>>32).

## 2026-07-18 — TICK SOURCE IDENTIFIED: THE BBDC REJECTION TRACKING CAL

Tracking-cal A/B on 148 during a live 780 s forward session
(hunt/20260718_091149_fwd; 180 s segments, each toggle restored before the
next; agc+bbdc never off together):

| segment | toggle              | episode cadence (30 s bins)     | event rate |
|---------|---------------------|---------------------------------|------------|
| SEG1    | baseline            | 20–21 (tick normal)             | ~150/30s   |
| SEG2    | rssi_tracking_en=0  | 18–21 (tick normal)             | ~155/30s   |
| SEG3    | bbdc_tracking_en=0  | **0–2 — THE TICK STOPS**        | ~2400/30s (DC junk storm) |
| SEG4    | agc_tracking_en=0   | 20 (tick normal)                | ~145/30s   |

The metronomic 256-sample insertion on unit 148 is fired by each ~1.5 s BBDC
rejection tracking-cal iteration.  rssi and agc tracking are exonerated.
Disabling bbdc tracking stops the insertion but instantly floods the link
with DC-offset junk (the correction is dropped, not held — the driver's
bbdc_rejection_en accepts only 0/1; the API's PAUSED state is not exposed by
this kernel), so bbdc-off is not a usable workaround as-is.  Unit 146 runs
the identical cal with no insertion — unit-specific silicon/cal interaction,
now a named, one-line reproducible vendor escalation:

  "BBDC rejection tracking cal on this unit inserts exactly 256 samples
   (133 us at 1.92 MSPS) into the consumed RX stream at each cal iteration,
   on both RX channels, at any LO; the capture branch of the same RTL net
   decodes bit-perfect through the event.  Disabling the cal eliminates the
   insertion.  A second unit with identical configuration shows no insertion."

Board temps at test: 148=61C, 146=62C (fan high).

## 2026-07-18 — P1E DEPLOYED: LIVE VERDICT

Image: `jupiter_byte_p1e_build` BOOT.BIN md5 `58a1c1a647388e03c4a1d30d9cd077c0`
(p1e compensation + P1D telemetry + dual-DMA tap + **DDS_DISABLE diet** —
the axi_adrv9001 DAC DDS removed to close a 70-CLB placement shortfall,
freeing 11,173 LUTs (placed 96.4%→80.6%); DAC tone diagnostics unavailable
on this image; PHY LOs and the modem DMA TX path unaffected).  Timing
equals the deployed baseline: the identical pre-existing 4459-endpoint
enable-divided violation population (p1e WNS −11.87 vs p1d's −13.58; zero
new failing endpoints).  Both boards flashed, smoke PASS first try.

Live results (600 s forward hunt, hunt/20260718_135706_fwd):
- Arms fire EXACTLY once per episode at the correct window (telemetry census
  with the corrupted-record filter: 2/2, 2/3, 3/2 arms/accepts across the
  saved event windows; the "extra arms" first seen were burst-collision
  telemetry parse artifacts — field-range filter added to p1e_armcount.py).
- Zero false arms: bit-true replay of a 691-frame live capture through the
  p1e netlist is BIT-IDENTICAL to the unpatched netlist (the insertion is
  invisible in the capture branch — the known fork — so replays cannot
  exercise the episode path; they do prove no-false-arm under real RF).
- No harm: the alarming n=2 gap doubling vs yesterday is DAY DRIFT — the
  same-day P1D control session (calab2, same morning) already shows the
  flipped n=1/n=2 histogram; per-episode normalized, p1e ≤ control on n=2.
- Reverse direction no-regression: lost 476 vs baseline 566, biterr in the
  day band.
- Bounded live gain: today's episode anatomy is BURST-dominated (first gap
  of each episode = 3–6 frames at 70–80%, vs the clean 2-frame splice
  anatomy) — the stale-grid class p1e recovers is ~1 frame of a 3–6 frame
  burst, invisible against ±10-pt day swings in a 10-min session.

Standing conclusion: p1e is deployed, harmless, provably armed at every
episode, and recovers the stale-grid casualty whenever an episode takes the
recoverable shape.  The dominant forward loss is the physically-destroyed
insert burst — information-theoretically unrecoverable at the receiver;
the forward 100x requires removing the fault source (RMA/replace 148, or an
ADI fix for the BBDC-cal insertion — see ESCALATION_ADI.md).

## 2026-07-18 EVENING — P1E MECHANISM RECONCILED (bisect + O0 + fresh-build controls)

The afternoon's "recovery without consume" anomaly is fully resolved; every
run is deterministic and explained:

- The sim consume display was DEAD CODE: on the consume beat the write side
  decrements skipCnt_next 64→63 within the same combinational pass, so the
  `skipCnt_next == 64` condition never fires — consumes happened silently
  (and printed as "PENDCLR" through a second display-condition gap).
- The skip genuinely consumes and recovers the stale-grid frame: stock
  netlist loses {355,356}; D2 loses {355} (confirmed by fresh rebuilds of
  both, a TA/PD/FTS-only bisect that loses both frames, and −O0/−O2
  agreement — no simulator artifact).
- The harm case is real and geometry-dependent: where the Packet
  Controller's 45-symbol discard region absorbs the +32 displacement, the
  window decodes fine WITHOUT the skip, and the skip breaks it (live-capture
  splice: base {389} → D2 {389,390}).
- TTL expiry is the wrong discriminator: both geometries consume at the
  identical ~519-symbol latency (measured); TTL=1000 kills the recovery too.
  The TTL overlay edit was reverted un-shipped.
- Net live effect of the deployed p1e image: neutral (recovery and harm
  cancel; per-episode stats ≈ same-day P1D control), reverse clean, arms
  exactly 1/episode.  The image stays deployed as instrumented-neutral.

v3 direction (discriminator-free): on arm, have the Timing Adjust RE-FIRE a
corrected SyncPulse at accOff+32 — re-anchors the window in both geometries
without counterfactual knowledge; requires a sim check of double-startIn
effects downstream (deint bank double-flip / RxAlign / Viterbi).  6-phase
splice-position sweep vectors staged (spl_sw0..5, 189-symbol steps).

## 2026-07-18 NIGHT — P1E v3 PROVEN: THE ACC-POSITION QUALIFIER

The discriminator between the help and harm geometries is the ACCEPTED
OFFSET'S POSITION IN THE WINDOW, and it closes the domain algebra exactly:
the displaced window's fire occurs at delayed-domain position acc + FIFO
transit (566 sym = Delay10 4532 enb / 8 enb-per-symbol); the +32 report
arrives at the wrap (1132).  For early acc (fire before report) the fire is
stale and the skip is needed; for late acc the freshest-offset fix already
re-anchors the window and the skip is the proven harm.  Qualifier (one
compare in the arm): arm only when accOff <= 530 (margin below the 566
boundary; a missed arm = stock behavior = safe).

Two-capture x 6-phase sweep evidence (24 splice runs + controls):
- acc=454 capture: stock loses 1-2 frames at every phase; D2 and v3 recover
  identically at all 6 phases (2->1, 1->0 losses).
- acc=875 capture: D2 harms at 5/6 phases (kills the freshest-fix-saved
  window); v3 is BIT-IDENTICAL TO STOCK at all 6 phases (arm blocked).
- Controls: nosplice and the raw live capture bit-identical.

v3 = strictly non-harmful, recovering wherever the stale-grid class exists
(~acc<=530 -> ~47% of episode offsets uniformly; the rest fall back to
stock).  Overlay updated (p1e_comp_overlay.m one-line qualifier).

## 2026-07-19 — P1E v3 DEPLOYED + HARDWARE-VERIFIED

Image `jupiter_byte_p1e2_build` BOOT.BIN md5 `0de4d5cba0af409de052b52c7b0e728b`
(v3 acc-position arm qualifier + P1D telemetry + dual-DMA tap + DDS-diet, now
baked into complete_byte_t8.tcl). Both boards flashed, smoke PASS first try.

600 s A/B hunt (hunt/20260719_065300_fwd):
- Forward (into 148): ok=123365 biterr=974 lost=2594; 386 episodes, 6.72
  lost/ep. Between the P1D baseline (403 ep / 6.22, 20260717_144014) and the
  neutral-v2 session (398 ep / 6.80, 20260718_135706) -- day-drift band, as
  the sim anatomy predicted (stale-grid recovery = ~1 frame of a 3-6 frame
  insert burst, invisible at session scale). No harm signature.
- Reverse (into 146): ok=125373 biterr=508 lost=860 -- clean, no regression.
- Arm census (P1D telemetry, all 6 event windows, corrupted-record filtered):
  every +32 tick-accept had accOff in {31,63} -- entirely the EARLY/armable
  class (<=530), so v3 armed and applied the stale-grid recovery on every
  captured episode, ZERO harm-class (accOff>530) accepts, armable_frac=1.00.
  The qualifier's discrimination is proven exhaustively in sim (two-capture
  6-phase sweeps: early-acc 454 arms 6/6 recover, late-acc 875 blocks 6/6
  bit-identical-to-stock); live telemetry confirms the arm condition fires at
  the correct episodes with no regression.

Verdict: the 32-sample tick displacement is COMPENSATED in fabric on 148 --
v3 recovers the stale-grid casualty wherever the episode's accepted offset is
early (armable), and provably never harms the discard-absorbed (late-acc)
class. This is the shipped, hardware-verified HDL fix for the tick. The
forward BER floor remains bounded by the physically-destroyed insert bursts
(the tick source itself -- see ESCALATION_ADI.md: the BBDC tracking cal);
removing that source is the remaining lever, now an ADI-side item.
