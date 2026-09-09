# RXFIX_STATE — RX symbol-rate-handling fix, running state (campaign started 2026-09-04)

Ledger: `two_jup/sdd_archive/2026-09-04-rxfix/progress.md`. Plan: `~/.claude/plans/happy-bubbling-owl.md`.
Background on the "guarded ring" correction: `two_jup/comb/RATE_HANDLE_FIX_SURVEY.md`;
clock-offset-at-source survey: `two_jup/comb/CLOCK_OFFSET_OPTIONS.md`.

## Sign cross-check [inferred]

**Step 1 — the residual, as measured. [silicon]**
`two_jup/bringup_r2r3.sh:15`: on the forward leg, 148's RX LO is programmed plain at
`2000000000` Hz (no deliberate offset) and the measured CFO residual is **−5.15 kHz**. The
forward leg is 146 TX → 148 RX: `LO_B_TX=2000000000` (`bringup_r2r3.sh:55`, 146's TX
synthesizer) into 148's RX LO at the same nominal 2.0 GHz (`:15`).

**Step 2 — which oscillator is fast, and by how many ppm. [inferred]**
Neither board shares a reference (`CLOCK_OFFSET_OPTIONS.md` §1: each ADRV9002 reference is a
board-local fixed XO selected by a GPIO mux, no external ref-in node exists). If 146's actual TX
carrier and 148's actual RX LO are each `2.0 GHz × (1 + ppm_board)` referenced to their own XO,
the residual seen by 148's receiver is
`residual = 2.0e9 × (ppm_146 − ppm_148) = −5150 Hz ⇒ ppm_146 − ppm_148 = −2.575 ppm`.
So **148's oscillator runs ≈2.575 ppm fast relative to 146's** (matches the 2.57–2.58 ppm figure
already used elsewhere in the campaign from the symbol-deletion census — `OVERNIGHT_20260904_SEQBIST.md`
item 5, `CLOCK_OFFSET_OPTIONS.md` §3 table). This is a fixed hardware fact, independent of which
board is transmitting or receiving.

**Step 3 — the SRO sign each leg's receiver sees. [inferred]**
Recall the sim's sign convention (`two_jup/comb/sro_sim/gen_sro_stim.py:72-73`,
`resample_periodic`: `y[n] = x(n·(1+s))`): **negative `s`** means the output index advances through
the source more slowly than 1:1 — the received stream is *stretched* relative to the local sample
clock, i.e. the source (push) rate is slower than the local (pop) rate, and Rate_Handle's ring
**drains toward EMPTY**. Positive `s` is the opposite (ring fills toward FULL).

- **Forward leg (148 is the receiver):** the incoming symbol stream is referenced to 146's XO
  (slow); 148's own Rate_Handle pop cadence is referenced to 148's XO (fast, +2.575 ppm per
  Step 2). Push (slow, 146) vs pop (fast, 148) ⇒ **SRO ≈ −2.575 ppm** at 148's receiver — the
  ring trends toward **EMPTY**.
- **Reverse leg (146 is the receiver):** the incoming symbol stream is now referenced to 148's XO
  (fast); 146's own pop cadence is referenced to 146's XO (slow). Push (fast, 148) vs pop (slow,
  146) ⇒ **SRO ≈ +2.575 ppm** at 146's receiver — the ring trends toward **FULL**.

(The deliberate LO offsets in `bringup_r2r3.sh:13,58` — 146 RX +2.4 kHz, 148 RX +20 kHz in the
shipped defaults — are CFO tuning downstream of each board's own synthesizer; they do not touch
the underlying XO-to-XO ppm relationship derived above.)

**Step 4 — the sim's result at those signs. [sim, already reported]**
`COMB32_SRO_SIM_2p5.md`: **−2.5 ppm → 4.11 % loss** (period 32.375 frames); **+2.5 ppm → 0.00 %
loss** with the same drift period. By the naive Rate_Handle-full-edge-only reading this predicted
the FORWARD leg (SRO ≈ −2.5 ppm) to be the lossy one and the REVERSE leg (SRO ≈ +2.5 ppm) to be
clean — but per the correction above, the −2.5 ppm leg drains toward the ring's EMPTY (benign)
edge, so the sim's 4.11 % loss at that sign is not yet explained by the Rate_Handle guard as read
from the netlist; the true deleting stage is under re-localisation by Task 1.

**Step 5 — does the silicon losing direction match? [silicon + inferred]**
It does not, cleanly. On silicon **both legs lose**: forward (148 RX, SRO ≈ −2.575 ppm)
**8.1–8.4 %**, reverse (146 RX, SRO ≈ +2.575 ppm) **3.7 %** (`COMB_STATE.md` "Packet detections vs
deliveries" table). The sim's asymmetric prediction (loss at one sign only, zero at the other) does
not hold on air — both signs lose, with the nominally "EMPTY-trending" forward leg losing *more*
than the nominally "FULL-trending" reverse leg, the opposite emphasis a one-sided Rate_Handle-only
mechanism would predict if the forward leg is genuinely the benign edge.

**What this implies. [inferred]**
A single one-sided guard (loses only at its FULL edge) cannot by itself explain nonzero loss on
both legs unless the two receivers are not symmetric about the same edge — i.e. unless whichever
guarded ring is actually deleting symbols sits at (or oscillates through) its lossy edge on BOTH
legs, not just one. Two candidate edges per leg:
- **Rate_Handle's own ring** (`Validate_Input_Push_Pop_block.v:119-137`): by sign alone, forward
  trends EMPTY (benign) and reverse trends FULL (lossy) — this explains at most one leg's loss, not
  both, and does not obviously explain the forward leg losing *more*.
- **The Preamble_Detector realignment FIFO** (`Preamble_Detector.v:321-334`, 12,333-deep, popped by
  an enb-tick-cadenced delayed valid rather than a valid-qualified pop): per
  `RATE_HANDLE_FIX_SURVEY.md` §4 it runs **permanently pinned at its own full mark**
  (`Compare_To_Constant1.v:36 = 12333`) regardless of the sign of the sample-rate offset, because
  its pop is time-based, not rate-matched to whichever direction the valid density actually drifts.
  A structure sitting chronically at its own edge is, unlike Rate_Handle, sign-agnostic — it would
  delete on both legs, which is what silicon shows. It is therefore the stronger candidate for
  explaining "both directions lose"; Task 1 (`COMB32_SRO_SIM_TAPS.md`) is instrumenting both
  candidates with true occupancy/guard taps to decide between them rather than resolving it by sign
  argument alone.

**Bottom line [inferred]:** the sign cross-check derives 148's XO running ≈2.575 ppm fast relative
to 146's, giving opposite-sign SRO on the two legs (forward ≈−2.575 ppm toward Rate_Handle's EMPTY
edge, reverse ≈+2.575 ppm toward its FULL edge); the sim's single-sided loss (only negative SRO
loses, in its as-run and not-yet-corrected labeling) does not match silicon, where both legs lose.
That mismatch is evidence against a Rate_Handle-full-edge-only mechanism and for a second,
sign-agnostic stage (most plausibly the Preamble_Detector realignment FIFO, chronically pinned at
its own full mark) being active on at least one leg — consistent with Task 1's mandate to
re-localise between the two candidates with true taps rather than trust the sign argument alone.

## T1 -- the fixctl slack-bit A/B legs on silicon (2026-09-04, Task 5)

**Verdict: the pre-registered falsifier is met. `enSlack` ON changes nothing.** Two credited forward legs (LEG=A, 146 TX -> 148 RX, `capture_r3.sh -d 600`, shipped LOs/RXQ, `deliver_rate_gate_pass=1` and `capture_r3_exit=0` on both, no wedge, no watchdog relaunch, no re-run):

| metric [silicon] | enSlack OFF (`0x208=0x0`) | enSlack ON (`0x208=0x8`) |
|---|---|---|
| host PER (lost frames in the denominator) | 8.351 % (73,003 / 874,137), CP95UL 8.410 | 8.426 % (73,773 / 875,537), CP95UL 8.484 |
| lag-32 autocorr (ALL-LOSS) | +0.3974 | +0.3231 |
| comb period | 31.307 frames = 25.14 ms, `COMB_LINE=present` | 31.250 frames = 25.09 ms, `COMB_LINE=present` |
| checker `gap_events` / emitted (stage 3h, decoder pins on 148) | 35,321 / 663,457 = 5.324 % | 35,758 / 667,671 = 5.356 % |
| checker garbage % / crc_fail % | 5.896 / 2.023 | 5.887 / 2.078 |
| checker int_32 / int_33 / int_other / <30 | 1,277 / 29 / 8,896 / 25,119 | 1,251 / 9 / 9,543 / 24,955 |

The prereg wanted PER toward the ~0.06 % loopback floor and lag-32 < 0.1; neither moved, and leg B is marginally worse on every axis.

**Scope of the bit [netlist].** `enSlack` (fixctl bit 3, `FixCtlDec.v:44`) has exactly one consumer: `QPSK_Rx.v:243/276` -> `Frequency_and_Time_Synchronizer.v:184` -> `Preamble_Detector` -> `FIFO.v:118` -> `Validate_Input_Push_Pop.v:136`, where it gates `push_on_full_FIFO` of the 12,333-deep realignment FIFO. `Rate_Handle.v:118` instantiates `FIFO_block`/`Validate_Input_Push_Pop_block`, which has **no `enSlack` port**. So this null localises specifically: **the deleting stage is not the Preamble_Detector realignment FIFO's push-on-full path.**

**T2 input.** The falsifier's named sub-branch (Rate_Handle FULL edge) is separately disfavoured by T0a [sim] (`push_on_full = 0` on every scored leg; the SRO harness leaves `fixctl` undriven so its `pdPof` tap on the gated net measured the ungated event, also zero). The residual hypothesis is the **pop-on-empty valid-density path** (T0a [sim]: 21 `pop_on_empty` events at -10 ppm, 95 % with a loss within +/-1 frame), not a symbol deletion at either FIFO's full edge. T2 should not be cut against a push-on-full deletion.

**Caveat.** 0x208 is write-only (`TxRxCompo_ip_addr_decoder.v:869-885`: `write_fixctl` only, no read path). Both legs' writes are evidenced by each leg's own `capture_r3.log:29` (`LOOP_POKE on 10.0.0.148: 0x208=0x0` / `0x208=0x8`, fired pre-window on the `wedge verdict:` marker) and by `peer_poke.log` (`146 fixctl write exit=0`), but that the register *held* 0x8 during leg B's window is not verifiable on this image. The Preamble_Detector FIFO witnesses remain `NOT_AVAILABLE` (Task 3: 0x20C/0x210 are DBGCAP registers, `pdWitA`/`pdWitB` are dead nets, `beatobs` is not AXI-lite).

Full report, audit trail and deviations: `two_jup/sdd_archive/2026-09-04-rxfix/task-5-report.md`. Runs: `two_jup/rxfix/runs/20260904_093052_slack0_t1-control`, `two_jup/rxfix/runs/20260904_094543_slack1_t1-slackon`.

## Localisation (sim true taps, interim 10:16) [sim]
- Taps confirmed genuine (self-check PASS). r_p000: no edge, no loss, ring occupancy pinned 5–6, realignment FIFO pinned at 12,333. q_m10 (−10 ppm): 21 Rate_Handle pop_on_empty events, first EMPTY edge at f=34, push_on_full = 0, pdPof = 0, pd_pop_on_empty = 0; 20/21 events have a lost frame within ±1 (losses → events 89 % at a constant −1 frame offset). q_m2p5 (−2.5 ppm): 8 pop_on_empty events at f=161,194,226,259,291,324,356,389 (period 32.6), 7/8 land exactly on a lost frame; a second loss comb sits ~7 frames earlier (under trace).
- Consequence: the deleting mechanism is the EMPTY-edge VALID-DENSITY HOLE (a skipped valid slot), not a symbol overwrite; Preamble_Detector's push-on-full path never fires (pdPof = 0 on every leg), which PREDICTS the silicon null of enSlack (T1). Prime suspect for the hole → frame-death step [netlist]: Preamble_Detector mixes tick-based (Delay10_reg 49,332-tick valid delay as the FIFO pop, :321-334) and valid-based (Peak_Search/Timing_Adjust epochs) timing, so one skipped valid mis-places the applied timingOffset by one symbol.
- Ruling: Task 1 traces the death path around each event and prototypes the fix in a variant sim tree (occupancy-driven pop: the realignment FIFO as an exact 12,333-VALID delay line), gate = 0.00 % loss at −2.5/−10 ppm and bit-identical s=0; the T2 silicon injector follows the sim result.

## Death path (sim trace, 11:3x) [sim] — competing correlation peak, not the FIFO
Peak_Search's per-epoch argmax takes only two values, 30 and 62 (Δ = 32 symbols). Steady state 30; at each Rate_Handle pop_on_empty frame the epoch's argmax latches 62, Timing_Adjust fires the sync 32 symbols late, and one or two frames later it returns to 30 — the +32/−31-symbol frame-start jumps seen in the demod marks; the two transition frames are the lost frames. The Preamble_Detector tick-vs-valid divergence is real (exactly one symbol for one epoch) but is not the death path — R1 (valid-indexed pop) removes it and changes nothing. Ruling: R2 = a frame-sync flywheel in Peak_Search/Timing_Adjust (adopt a new argmax only within ±2 symbols of the applied offset, or after N = 2 consecutive epochs; reject-counter witness; acquisition unchanged), sim-gated at 0/−2.5/−10/+2.5 ppm plus acquisition and re-lock controls. Open: why a correlation peak exists 32 symbols from the true one (structural sidelobe of the preamble/header?) — magnitude to be recorded.

## Correction (11:5x) [sim] — the stream itself is displaced by 32 symbols
The correlator dump shows exactly one threshold crossing per epoch whose magnitude runs smoothly through the excursion: the SAME preamble arrives 32 symbols late for one sample-slip period and 31 early on the way back (spacing 49,332 ×8, then 49,460, then 49,208). Peak_Search and Timing_Adjust behave correctly; the +32-symbol displacement is born UPSTREAM of the correlator — 32 = the Rate_Handle ring depth, so a lap replay at the EMPTY edge is the prime suspect. R2 (flywheel) refuses to apply the round trip but cannot restore displaced content. Ruling: per-beat dump across an event to locate the displacement (ring pointers/RAM read path vs the realignment FIFO), then R3 at the ring (clean single-slot hole with no lap replay, or pre-fill to mid occupancy + re-centre within [8, 24] with a witness), gate as before.

## Ring exonerated (per-beat dump, 12:1x) [sim]
At the EMPTY edge the guard does exactly what Validate_Input_Push_Pop_block.v:119-137 says: pop suppressed (one skipped output valid slot), push taken; pointers advance by 0 or 1 only, occupancy 0..2, no lap, no repeat; the wrap branches are never taken; the interpolator's modulo-1 counter shows the ordinary one-sample slip. The +128-sample (32-symbol) displacement seen at the correlator is NOT born in the ring and remains unlocalised. R2 (flywheel) passes the s=0 identity gate; its −2.5/−10 legs decide whether holding the offset helps or hurts (if the DATA is displaced, holding makes it worse). Ruling: bisect the valid-qualified symbol stream stage by stage around an event (preamble position vs each stage's own valid count) to find where the 32-symbol shift is born, and verify the crossing-index bookkeeping of the trace tools across a suppressed valid slot; check whether the delivered frames' bytes are intact (sync displacement) or shifted (data displacement).

## Bisection (12:2x) [sim] — no symbol inserted anywhere; the true peak drops below threshold
Every stage delivers exactly 12,333 symbols per local frame (12,332 on the 8 hole frames; 12,365 never), yet the correlator crossing advances +32 valids into the excursion: the winning crossing is a DIFFERENT correlation event 32 symbols from the true preamble and the true peak falls below threshold for one sample-slip period ("same peak displaced" retracted). The "excursion frames decode correctly at +32" observation is very likely an artefact of the tiled (identical-frame) stimulus. Ruling: (1) regenerate the −2.5 ppm stimulus from a non-repeating TX stream and re-run baseline; (2) dump the correlator magnitude at the true preamble position and the threshold it is compared against through an excursion (Correlator.v:110-177 running-energy + ThresholdLimiter: tick- or valid-indexed?); (3) cut R3 in the threshold path. R2 (flywheel) cannot fix a peak that is below threshold (its loss-of-lock escape adopts the +32 peak after 3 epochs); its legs are the control.

## Threshold path decisive (12:2x) [sim] — the correlation pattern itself is displaced by 32 symbols
Through the excursion the correlator threshold is flat (≈208 M at both positions) while the magnitude at the true position collapses ×157 (277.6 M → 1.77 M) and the identical magnitude appears at +32 symbols; the symbol count per frame is unchanged. So the receiver's sampling phase jumps by 32 symbols = 128 input samples for one slip period: the interpolator reads its symbols from samples 128 later. 128 samples = 512 quarter-sample steps = half of countReg's 10-bit field → suspect: the modulo-1 NCO arithmetic in Interpolation_Control.v:138-158 (+ the T8.4 clamp :128-137) at the wrap that coincides with the ring hole (every 4th wrap). (A normal frame also shows a genuine sub-threshold sidelobe at +32 symbols ≈ 29 % of the peak.) Ruling: per-beat dump of countReg/counter/Delta/Underflow/mu and the delay-line read index across a hole-coincident wrap vs an ordinary wrap; R3 = the arithmetic fix (exact +1.0 wrap, basepoint +1 sample), gated on a non-repeating stimulus at 0/−2.5/−10/+2.5 ppm.

## NCO/basepoint refuted (12:3x) [sim]; next probe = displacement measured in the data
Strobe spacing across the whole excursion is uniform (3/4/5 input samples, 12,332.6 strobes per frame): no 128-sample jump in strobe timing, Interpolation_Control.v:138-158 and the T8.4 clamp are excluded as the source. All structural mechanisms proposed so far are excluded by direct measurement (ring, insertion/deletion, realignment FIFO guards, correlator threshold, strobe placement); the +32-symbol displacement of the correlation pattern stands. Ruling: measure the displacement in the DATA — cross-correlate the interpolator/Rate_Handle output symbols against the input samples at the recorded strobe positions (best lag per frame: +128 during the excursion ⇒ the interpolator reads from the wrong sample-buffer address — find the address arithmetic; lag 0 with rotated/scaled symbols ⇒ a content transient in CFC/CS/AGC at the hole), plus the frame-38-vs-39 symbol cross-correlation as a cross-check; R3 cut at whichever it is.

## Task 6 stopped (12:5x) [sim]; Task 7 dispatched
Data probe: no content transient (mean |y| and phase flat through the excursion); consecutive-frame cross-correlation shows TWO equal peaks (ρ = 0.50 at lag 0 and at ±32) in EVERY frame pair, transition or not — a 32-symbol alignment ambiguity present at all times, which the SRO only selects between. The SRO harness stimulus is one TILED frame (identical frames), so this may be a stimulus artefact (H-A) rather than a receiver property (H-B). No R3 cut blind. Task 7: rebuild the SRO stimulus from a NON-repeating TX stream (TGEN v2 with incrementing seq), settle H-A vs H-B, and cut/gate R3 = guard-band steering of the ring hole (pre-empt the edge by skipping/adding one pop only inside the 13-symbol inter-frame guard, so the hole lands where the deframer discards symbols) — mechanism-agnostic.

## Campaign brief for the operator (2026-09-04 13:45; written from the record, nothing new run)

### 1. Hypothesis — the defect and the mechanism
**Defect [silicon]:** on the air legs the receiver's valid chain loses one symbol slot per ~32 frames, one-sided, and each event kills the frame(s) straddling it → a steady loss comb (lag-32 autocorrelation +0.70, period ≈ 26 ms) worth roughly 6 pp of forward PER. The transmitted stream is clean (sel8), the loss reproduces with no host and no DMA in the path (fabric-only SEQ-BIST, 5.3 % gap events at the decoder pins), and it vanishes in digital loopback (0 deletions, 0.058 % floor).

**Mechanism, in one breath:** 146's transmit symbol clock and 148's receive sample clock come from different crystals, 2.575 ppm apart. The receiver's symbol synchroniser tracks the true symbol rate, so it produces a strobe every 4.00001 receive samples rather than every 4; Rate_Handle, however, pops its 32-entry ring rigidly once every 4th receive sample. Pushes therefore arrive 2.575 ppm slower than pops, the ring drains by one entry every ~32 frames, and at the EMPTY edge the guard suppresses one pop → one output valid slot goes missing. Every block downstream counts valids to find frame boundaries (Peak_Search epoch of 12,333 valids, Timing_Adjust, End_Generator), so the frame straddling the missing slot, and often the next, fail framing. On the reverse leg the sign flips: the ring fills, the FULL edge deletes a symbol outright.

**Labels, honestly:** the 2.575 ppm offset and the once-per-~32-frame one-sided symbol deletion in the receiver valid chain are **proven on silicon** (DDRCAP census on two days / two selectors; CFO residual gives the same ppm). That the Rate_Handle ring edge is *the* deleting stage and that a single missing slot is *why* the frames die is **reproduced in sim only on a tiled stimulus** (−2.5 ppm → 4.11 % loss, period 32.375, every loss phase-locked to a pop_on_empty) and is now **inferred at best**: the tiled stimulus is under suspicion (Task 7), the ring-lap explanation of the sim's 32-symbol content jump was withdrawn by its own probe, and three sim-derived fixes (R1 valid-indexed PD pop, R2 frame-sync flywheel, R3 guard-band steering) were null, harmful, and catastrophic respectively.

**Why a steady comb and not a burst:** the drift is a constant rate (fixed ppm × fixed frame length), there is no latch or threshold that accumulates, so one event lands every constant interval and costs 1–2 frames each. The 120.2 s beat was the opposite shape: a latch cleared by a slow RAM-occupancy drift, holding a bad state for ~1 s several times per burst.

### 2. Evidence, and what would still falsify it
For: fabric-only reproduction (no host/DMA); TX clean; loopback lossless; deletion census period ≈ 32 frames at 2.5 ppm; comb period 32.24 emitted frames on the daemon stream and 25.1 ms on the T1 legs; CFO residual −5.15 kHz @ 2.0 GHz = 2.575 ppm (same XO feeds LO and sample clock); sim comb at 32.375 frames phase-locked to the ring's empty edge.
Against / unexplained: (a) forward leg (EMPTY edge, which the guard should make benign — a skipped slot, no data loss) loses MORE (8.1–8.4 %) than the reverse leg (FULL edge, a real deletion, 3.7 %) — a Rate_Handle-only one-sided story does not fit cleanly [inferred, sign cross-check §above]; (b) sim +2.5 ppm (FULL edge) loses nothing over 920 frames; (c) enSlack (PD realignment FIFO slack) null on silicon → that FIFO is not the stage; (d) the sim's death path (a 32-symbol content displacement at the hole beat) has no RTL mechanism after the ring was cleared; (e) the non-repeating stimulus has not yet reached an edge in a scored window.
**Strongest falsifiers:** on silicon with the W1 instrument, (i) every per-stage valid count exact (no stage short by the deletion count) while frames still die at the comb period → the loss is not a symbol deletion in the symbol-rate path at all; (ii) rh_pop_on_empty stays 0 across several comb periods on 148 → the ring is not where the hole is and every edge-directed fix is aimed wrong. In sim, (iii) the −10 ppm non-repeating leg losing ~0 % while hole events are present → the sim never modelled the silicon death and all its localisation is void.

### 3. Where "once per 32.4 frames" comes from
Frame = 12,333 symbol slots (26 preamble bits/2 = 13 + 12,320 data symbols; the 13-slot inter-frame guard makes up the count). Per frame the ring occupancy moves by 12,333 × SRO entries:
| SRO (ppm) | entries/frame | frames per edge event | period (× 802.93 µs) |
|---|---|---|---|
| 2.500 | 0.03083 | 32.43 | 26.0 ms |
| 2.575 | 0.03176 | 31.5 | 25.3 ms |
| measured (T1 legs) | — | 31.3 (25.1 ms) | ⇒ 2.59 ppm |
The ppm is measured two independent ways: the RX-LO residual (−5.15 kHz at 2.0 GHz ⇒ 2.575 ppm, valid because the ADRV9002 device clock feeds both the PLLs and the sample clock) and the DDRCAP deletion census (2.57 / 2.51 ppm on two days). **Caution for the pre-registration:** the period is not an independent prediction of the census — it is the census re-expressed. What IS independent in Task 9/10's prediction is that a *specific counter* (the ring's pop_on_empty) increments at that rate and that the stage census goes short by exactly that count from Rate_Handle downstream and not upstream.

### 4. Tasks 7, 9, 10 and the critical path
- **Task 7** (opus, sim): replace the tiled stimulus with a non-repeating TGEN-v2 stream to settle whether the sim's loss was a stimulus artefact (H-A) or real (H-B); also gated R3 (rejected: 100 % loss at −10 ppm, bit-identity broken at 0). State: 432-frame capture ~75 % done; tiled control legs running; then p000/m2p5/m10/m40 non-repeating legs. −10 ppm is the primary test (ring settles at occupancy ≈28 on this stream, edge at ~frame 230, ~25 hole cycles); −2.5 cannot reach an edge in 430 frames (vacuous); −40 is an accelerated supporting leg. Ring-lap mechanism retracted. Informs, does not gate, the silicon path.
- **Task 9** (opus, desk + build, NO flash): W1 instrument — re-expose the ring's true occupancy/pointers and pop_on_empty/push_on_full counters at two free AXI addresses (0x20C/0x210 confirmed DBGCAP-owned on the flashed image), plus a per-stage valid census (symbol-sync strobe → Rate_Handle → CFC → carrier sync → preamble detector → packet controller) on free cnt_mux32 slots with the existing freeze discipline; sim gate (0 ppm byte-identical; witness words = harness taps on a −10 ppm tiled leg with edge events present); kit on the SEQ-BIST tree; hdl-dev-2 build with the routed-WNS gate; bank + register map + 10-s reader. State: ownership check done, injector in progress. ETA: sim gate + ~1 h build.
- **Task 10** (not yet dispatched): flash 148 under the full rails (rollback a1ff3c876d91 / f6a8c3ea119c banked), then a forward leg reading the witnesses every 10 s with the checker at the pins and capture_r3 PER; prediction and falsifiers as in §2.
- **Critical path to a silicon answer:** Task 9 sim gate → build → Task 10 flash + one 10-min leg ≈ 3–4 h from now, independent of Task 7.
- **Positive controls per new tap (standing rule):** in sim, every W1 word is checked against the harness taps on a leg that has edge events — that is a positive control for occupancy, both edge counters and every census counter. On silicon: the census counters have one (loopback leg: every stage advances exactly 12,333 per frame, and the mux/freeze readout is proven by nonzero reads). **Gap:** the two edge counters have NO independent silicon positive control — no clock trim exists to induce an edge on demand, and a dead counter would read 0 exactly like "no holes". Mitigation to be written into Task 10's brief: (a) the occupancy word (witA) must be seen moving between reads on the air leg (proves the readout path for the same block); (b) the reverse-leg expectation (FULL edge on 146) is not available until 146 gets W1; (c) a zero pop_on_empty on the air leg is reported as "counter did not increment" and is a finding only if witA shows the ring pinned at 0. This gap is stated, not solved.

### 5. Same defect as the 6 pp steady comb?
Yes — same observable. The 08-29 loss decomposition's "~6 pp steady comb" (needs RF or the far transmitter, absent in loopback, framing loss not bit errors) is the lag-32 / 26 ms comb this campaign chases; the 08-27 reading of it as a delivery-plane ByteRxFifo overflow was superseded when the fabric-only leg reproduced it with no DMA. It is not the whole forward 8.06 %: a non-comb residual of order 2 pp singles (RF-margin-limited, present on the reverse leg too) is a separate item.

## Task 7 verdict (15:11) — H-B: the empty-edge hole IS the death event, on non-repeating content [sim]
| leg (428 frames, certified non-repeating TGEN stream) | OK / expected | loss | pop_on_empty in the scored window |
|---|---|---|---|
| 0 ppm | 420/420 | 0.00 % | 0 (34 in acquisition) |
| −2.5 ppm | 420/420 | 0.00 % VACUOUS (edge ~1000 frames away from occupancy 31) | 0 |
| −10 ppm | 375/421 | 10.93 % (26.0 % after the edge at frame 259; tiled control 22.01 %) | 21, one per 8.1 frames |
| −40 ppm (accelerated) | 93/424 | 78.1 % | 211, one per 2.02 frames |
42 of 46 lost frames sit within ±1 frame of a hole; 2.10 lost frames per hole; loss begins within 4 frames of the first hole. Cadence fidelity [netlist]: validIn is tied to 1 on every enb tick in sim and silicon (TxRxComposite.v:476-481, :721); the 1-in-4 is Rate_Handle's pop counter, so the harness models the tick/valid relationship the downstream stages see. Controller correction: the 15:12 "H-A reading" note (and the same statement made to the operator) misread `packets=` as OK frames and is withdrawn. Consequence: the tiled-stimulus caveat is closed; the sim localisation stands; steering the skip into the inter-frame guard band is back as the candidate fix (Task 11, R3S skip-only, acquisition-safe arming). Unexplained: seq 133/134 lost with no hole nearby.

## W1 on silicon (Task 10, 2026-09-04 16:40–17:30) — THE MECHANISM IS PROVEN ON THE BOARD [silicon]
Image 148 = rxfixw1 2728dab3979a (F3 + SEQ-BIST + W1), flashed under the rails (GATE_PASS ×2, 1248 f/s, capTAP golden), rollback a1ff3c876d91 banked. Step-2 loopback controls: every tap passed (freeze holds all 8 words 10 s; census advances ~1.68e8/10 s with the five pre-discard stages within ±1; pop_on_empty clears on each arm and re-accumulates that arm's transient, 10 and 44; AXI decode proven by the first read). Forward air leg 146→148, run two_jup/comb/runs/20260904_165420_w1_air, credited (deliver_rate 1900 pre/post, 0 relaunches, wedge healthy), 48 reads at 10.000 s, FIXCTL_BASE=0x0:
| quantity | measured | pre-registered |
|---|---|---|
| ring occupancy | 0 or 1 on every read | pinned at EMPTY (P1) |
| pop_on_empty per 10 s | 394.0 mean (18,519 in 470 s) | 395 ± 60 (P1) |
| push_on_full | 0 | 0 |
| census cSS = cRH = cCFC = cCS = cPD | equal within ±1 (0 of 188 stage-readings short) | no stage short (P2); P2-alt refuted |
| checker gap events per 10 s | 656.2 = 1.67 × pop_on_empty | 1–2 × (P3) |
| PER (capture_r3, lost frames in denominator) | 8.309 % (72,738 / 875,375), CP95 8.367 | 8 ± 1 % |
| comb | lag-32 +0.613 (null 0.004), period 25.3872 ms | present, 25–26 ms |
**Decisive:** the pop_on_empty mean inter-event interval is 25.3793 ms and the PER comb period is 25.3872 ms — agreement 0.031 %, implied SRO 2.565 ppm — from two instruments sharing no code path. The ring's empty-edge suppressed pop and the PER comb are the same event, and the census proves that event deletes nothing (a skipped TIME slot). F2 is the outcome: the death is a framing-window effect of where the skip lands, exactly the sim's picture (Task 11 §6: a skip in the guard band disturbs nothing; a hole in the payload disturbs Peak_Search and the deframer). Unexplained: cPC runs 0.266 % below its designed 12,320/frame (ratio 0.084 to pop_on_empty). Hand-back: first bring-up failed its arm gate 6/6 (148 rx 373–777 f/s), the one re-run passed (1245/1247 f/s) → arm lottery, not the image; W1 stays on 148; sentinel restarted (sentinel-172940); images from readback 148 = 2728dab3979a, 146 = 3378861d30bd.
**Fix status:** guard-band skip steering removes the comb in sim on non-repeating content (R3S 10.93→0.95 %; R4/R4B gating). Silicon pre-registration for the W1+R4B image (Task 13): PER ≤ 3 % on the forward leg (8.3 % − ~6.3 pp hole-aligned = ~2 %), lag-32 < 0.1, no 25 ms comb, pop_on_empty delta 0 in the window, r4b_skips ≈ 394 per 10 s, occupancy 8–10; falsifier: PER unchanged with r4b_skips ≈ 394 → the skip position does not matter on silicon.
**Still open after Task 10, carried from the task-10 report's concerns:** `push_on_full` is unexercised on **silicon as well as in sim** — it read 0 on every reading of every set, and a forward leg cannot reach the FULL edge by construction. So a zero remains consistent with both "no FULL-edge event" and "the counter does not work" (Task 9 concern 2), and **the sign question in §2(a) — the forward leg losing *more* (8.3 %) than the reverse (3.7 %) — is NOT resolved by this leg.** Settling it needs W1 on 146 and a reverse leg. Pre-registered before the Task 10 window and recorded as not firing: occupancy pinned near 32 with `push_on_full` incrementing on a *forward* leg would have been a sign error in the campaign model, not the FULL-edge counter finally working.

## R4B on silicon (Task 13, 2026-09-04 20:05–20:45) — THE FORWARD COMB IS FIXED [silicon]
Image 148 = **rxfixr4b `9f13705d9fb0`** (F3 + SEQ-BIST + W1 + R4B, injector `7eef225`),
built on hdl-dev-2 with `IMPL_STRATEGY=explore` and gated on the **modem-clock intra-clock
post-route WNS = +0.437 ns** (TNS 0, 0 failing endpoints; W1 was 0.169, SEQ-BIST 0.227 — the
overall `TXFIX_ROUTED_WNS` 0.1715 is the vendor IDELAYCTRL path and is not the gate). Flashed
under the rails (GATE_PASS ×2, fps 1248, capTAP golden), rollback `2728dab3979a` banked and
on-board. Step-2 loopback controls: every tap passed, including the four new R4B rows and a
nine-word stuck-at sweep; in loopback `r4b_skips` is **8 and then flat**, the sim's
self-centring picture exactly.

Forward air leg 146→148, run `two_jup/comb/runs/20260904_201814_w1_air`, credited (1038 f/s
pre and post, 0 relaunches, wedge healthy), 48 reads at 10.000 s:

| quantity | W1 `2728dab3979a` (Task 10) | **W1+R4B `9f13705d9fb0`** | pre-registered |
|---|---|---|---|
| ring occupancy | 0 or 1 | **8–10** | 8–10 (P1) |
| `pop_on_empty` per 10 s | 394.0 | **0** on 47/47 | 0, ≤3 (P2) |
| `r4b_skips` per 10 s | — | **391.0** | 394 ± 60 (P3) |
| `push_on_full` | 0 | 0 | 0 (P4) |
| checker gap events per 10 s | 656.2 | **3.1** | < 100 (P5) |
| PER (lost frames in the denominator) | 8.309 % (72,738/875,375) | **0.224 %** (1,956/871,805), CP95UL 0.235 | ≤ 3 % (P6) |
| lag-32 / comb | +0.6130, `COMB_LINE=present` 25.3872 ms | **+0.0182, `COMB_LINE=absent`** | < 0.1, no comb (P7) |

**Decisive:** the event is CONSERVED, not removed — `r4b_skips` 391 per 10 s against the W1
image's `pop_on_empty` 394 per 10 s. Same drift, same rate; only the POSITION moved, from the
ring's EMPTY edge into the 13 slots after `pcEnd`. That is the controlled test of Task 10's F2
localisation (the skip deletes nothing; the death is where it lands), and it passes.
No falsifier fires; F-C is tested by every burst bin falling (singles 37,288→18, doubles
15,731→1, 3–4 500→33, 5–20 220→161), so the 0.224 % residual is the pre-existing burst/RF
class. G14 acquisition check: `push_on_full` 0 cumulative since the arm and zero losses in the
first 1,000 good-frame intervals — no acquisition-dip regression on the negative-SRO side.

**Still open.** (a) **146 has no W1 and this image is 148-ONLY** — the +10 ppm positive-SRO
acquisition-dip skips regressed in the R4B gate (15/17), so the reverse leg and the §2(a) sign
question remain unanswered; the forward leg has now dropped *below* the reverse leg's 1.39 %,
which inverts the comparison without explaining it. (b) `push_on_full` has still never fired
in sim or on silicon. (c) `pop_on_empty`'s own Step-2 liveness control did not fire this
session (44 across the re-arm); its silence is argued from a netlist diff — R4B changes no
line of that counter — not from a measurement.

## SILICON VERDICT (Task 13, 2026-09-04 20:10–20:45) — THE FIX WORKS ON 148 [silicon]
Image 148 = rxfixr4b **9f13705d9fb0** (F3 + SEQ-BIST + W1 + RXFIX_R4B), built from injector commit 7eef225, modem-clock intra-clock routed WNS +0.437 ns (overall +0.172), flashed under the rails (GATE_PASS ×2, rollback 2728dab3979a banked and on-board). Loopback controls: all nine words pass; ninth word 0x234 decodes (locked=1, skips=8 then flat, window_opens at the frame rate); occupancy 8–9 at rest (W1 image: 0–1).
Forward air leg 146→148, run two_jup/comb/runs/20260904_201814_w1_air, credited (deliver_rate 1038 pre/post, 0 relaunches, wedge healthy, 48 reads at 10.0 s, FIXCTL_BASE=0x0, one wedge in the 721 s live window):
| pre-registered | W1 image (Task 10) | W1+R4B image | verdict |
|---|---|---|---|
| occupancy 8–10 | 0–1 | 8/9/10 | HOLDS |
| pop_on_empty per 10 s = 0 | 394 | 0 on all 47 intervals | HOLDS |
| r4b_skips per 10 s ≈ 394 ± 60 | — | 391.0 | HOLDS |
| push_on_full | 0 | 0 | HOLDS |
| checker gap events per 10 s < 100 | 656.2 | 3.1 (garbage 5.81 → 0.028 %, crc_fail 2.04 → 0.022 %; the 5.896/2.023 quoted in task-13-report.md are Task 5 leg-A figures, not Task 10's — review finding) | HOLDS |
| PER ≤ 3 % (lost frames in the denominator) | 8.309 % (72,738/875,375) | **0.224 %** (1,956/871,805, CP95 0.235) | HOLDS |
| lag-32 < 0.1, no 25 ms comb | +0.613, period 25.39 ms | +0.018, COMB_LINE absent | HOLDS |
Conservation: r4b_skips 391 per 10 s ≈ the W1 image's pop_on_empty 394 per 10 s — the same drift event at the same rate, now a deliberate skip in the 13 slots after pcEnd instead of a suppressed pop at the EMPTY edge; only its position changed, as the F2 localisation predicted. No falsifier fires. Every burst bin fell (singles 37,288→18, doubles 15,731→1, 3–4 500→33, 5–20 220→161, 21–100 1→0): the residual 0.22 % is the pre-existing burst/RF class. No acquisition-dip regression (push_on_full 0 since the arm; 0 losses in the first 1,000 good-frame intervals). Hand-back: bring-up passed on try 1 (1246/1247 f/s), sentinel-204437 running; images from readback 148 = 9f13705d9fb0, 146 = 3378861d30bd.
**Scope and open items:** the image is 148-ONLY (negative SRO): at positive SRO the acquisition-dip skips regress the FULL-edge loss (+10 ppm 4.99→6.65 % in sim), and the FULL-side mirror (R4D, extra pop) is refuted — the Preamble_Detector realignment FIFO deletes the +1 valid and desynchronises Timing_Adjust from Peak_Search (98 %/70 % loss in sim). The reverse leg (146 RX, FULL edge, 3.7 %) therefore needs the PD FIFO slack (enSlack, fixctl bit 3; F3 lineage only, never simulated) alongside steering, or a push-side drop scheduled into the next preamble — operator decision. push_on_full has still never been exercised on silicon; pop_on_empty's arm-transient liveness control did not fire this session (same 44 before/after re-arm). For a FRESH pair of boards the SRO sign is unknown, so R4B must not be deployed until the RX-LO residual sign has been measured (a fast RX XO ⇒ EMPTY edge ⇒ R4B applies).

## Day 2 (2026-09-05 morning) — reverse leg measured, forward residual cut by the host resync [silicon]
- **Reverse leg (148 R4B TX → 146 seqbist RX), first credited measurement (Task 16, run two_jup/comb/runs/20260905_064400_legB_rev_before2):** PER 9.644 % (84,437/875,535, CP95 9.706, 718 s live, wedge-truncated), singles/doubles, MAGIC-dominated, receive-side on 146 (never_sent 0). Comb = a lag-25 harmonic family, best line 25.39 FRAMES = 20.39 ms, NO mod-32 line (R@32 = 0.001). All three pre-registered predictions falsified: the reverse defect is not the forward defect's geometry; one event per 25.4 frames does not equal the 2.565 ppm SRO rate. Wedge class: the first attempt wedged at 12 s in a carrier-reset storm (rstcs ~670/s before the window); 4/4 legs this morning were wedge-flagged in BOTH directions (two still creditable).
- **Forward replicate with RSSI (Task 17, run 20260905_075030_w1_air2):** PER 0.183 % (1,611/879,050), comb absent, r4b_skips 398.7/read, gain 34.0 dB on 48/48 reads, no RSSI dip ≥ 3 dB → RF margin excluded; R4B N=2.
- **Forward residual class (Task 23, banked data):** a HOST delivery-path byte-alignment cascade — one decode error at the pins costs ~8.6 host frames (frames displaced inside the 16-slice DMA transfer until resync); events at the pins one-for-one (144 vs 143), host cost 4×; coherent 8.14 s rate line on the event onsets (open lead); "delivery stall" reading withdrawn.
- **Host resync fix (Tasks 26/27, same-binary A/B on 148, fabric 9f13705d9fb0 untouched):** control (fix OFF) PER 0.196 % (1,724/879,794, the session's only fully clean capture, slots/event 9.17, max run 20); fix ON PER **0.079 %** (692/879,018, CP95 0.085, slots/event 1.81, max run 4); difference 0.117 pp; checker events unchanged (3.19/10 s); r4b witnesses unchanged. P1 PASS. F5 FIRES: resync_568 = 0 while 171 re-anchors at OTHER offsets recovered 1,237 frames and 9,757 scans found nothing — the 568-byte phase measured on the banked capture is NOT where the re-anchor fires on this leg; the class description is re-opened (Task 28) though the fix's value is not in doubt. Fixed daemon (md5 0ee566203a97…) left on 148; previous daemon banked at boot_known_good/daemon/qpsk_tun.148.1f834433.
- **Forward leg today: 8.309 % (09-04 morning) → 0.224 % (R4B) → 0.079 % (R4B + host resync).**
- **146 candidates [sim]:** S1 = R4D + R1 passes every row (+10 ppm 0.00 % vs baseline 4.99 %, push_on_full 21 → 0, PD FIFO pinned at 12,333; identical to R4B on negative legs) — the R4D collapse was the PD FIFO deletion, now structurally impossible; Task 22 builds W1+R4D+R1 (bank only). R4E (push drop) gate in progress. The 146 flash (W1 witness first) is blocked by the permission classifier and needs the operator's hand; the witness leg must show the ring's edge-event interval equals the 20.39 ms comb before any fix flash.
