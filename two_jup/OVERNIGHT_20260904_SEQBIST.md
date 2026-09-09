# Overnight 2026-09-03/04 — SEQ-BIST + packet-loss fix (autonomous; operator back 07:00 EST)
Authorisation: "Run and fix packet loss and test on hardware as needed. Do not ask for approval." Rails unchanged (full flash rails, keeper hold, one re-run per wedge, positive controls before nulls, [silicon]/[sim] labels).
Ledgers: two_jup/sdd_archive/2026-09-03-seqbist/progress.md (live), two_jup/sdd_archive/2026-09-03-comb/progress.md (closed 20:0x). State files: two_jup/COMB_STATE.md, two_jup/SEQBIST_STATE.md (to be written). Dashboard http://10.0.0.71:8090/pipeline.html.

## Starting point (21:0x) [silicon]
Forward leg a1r2: PER 8.121 % (71,090/875,375, lost in denominator); loss comb period 26.05 ms = 32.44 frames in time, garbage at the demod bit plane, not host-locked, |SRO| ≤ 0.06 ppm; 26.042 ms = 1e6 cycles of the ADRV9002 38.4 MHz device clock → lead = periodic radio process on the receiving board.


## MORNING SUMMARY (final 05:0x; every number is in the timeline below and in two_jup/sdd_archive/2026-09-03-seqbist/task-*-report.md)
**Rig at hand-back (04:46):** both boards on the instrumented images (148 seqbist a1ff3c876d91, 146 seqbist 3378861d30bd; rollbacks f6a8c3ea119c / 6b4744ca73f8 banked on nemo and on-board), plain daemons rebuilt (148 nakstat=4), keeper hold released, sentinel + keeper units running, link healthy (sentinel "ok rate≈1170/s"). Everything is committed and pushed on per-under-1pct-2026-07; dashboard http://10.0.0.71:8090/pipeline.html.

**What was built:** a fabric-only frame-sequence loss instrument on both boards — TGEN v2 (seq in the header, skip/corrupt positive controls) → modem → rx_seq_checker at the decoder pins → 32-slot counter mux; host tools two_jup/seqbist/ (freeze/read, run, score); Verilator full-loop gate; credited on both boards (positive controls pass background-corrected; checker tracks the decoder count to 0.01–0.07 %). Usage facts (sink requirement, slot-quantised TGEN rate, write-only registers, arm-by-effect) are in task-6/8 reports and memory.

**What was found [silicon]:**
1. The forward-link LOSS is reproduced with NO host and NO DMA anywhere: fabric-only forward leg (146 TGEN → 148 checker, 600 s) = 5.3 % gap events + 5.9 % garbage at the decoder pins; the checker on the REAL daemon stream (stage 3h, 400 s) = 5.2 % gap events + 5.7 % garbage + 2.1 % crc_fail (host sees 8.1 %). The defect is between the transmit fabric and the receive decoder pins. FINAL-REVIEW CORRECTION (05:5x): the checker's interval counters do NOT establish the 32-frame period at the pins on RF legs (corrupted-seq contamination 88–93 %; period_est unreliable) — the period is established by the independent DDRCAP symbol-deletion census (item 5), not by the checker; the checker's lost_slots/loss_pct are void on RF legs (tool bug prints ~100 %); control verdicts were hand-scored (background from the clean leg) — the tool's own re-score does not yet reproduce them; the 146 cyclic-sink credit rests on a 120 s leg (below the 150 s window rule).
2. Excluded by measurement: host RX DMA queue depth on either board, ADRV9002 AGC/tracking cals on either board, host payload (whitening on both ends: 8.17 %), host TX starvation (txlog join), CFO (0–20 kHz), TX power, sample-rate offset (≤ 0.06 ppm), the RX byte plane/DMA.
3. Fabric digital loopback alone loses 0.058 % (single slots adjacent to filler frames, content-locked in the sim, no comb) — the comb needs the air/RF path or the two-board timing.
4. Filler (all-zero) frames break OTA frame sync outright (325–391 f/s of 1,246); a fix must keep the modulator from radiating dead-symbol frames or make the receiver tolerate them.
5. ROOT CAUSE (06:3x) [silicon + netlist + sim]: CONFIRMED — the sim at −2.5 ppm reproduces the comb at 32.375 frames with 4.1 % loss and the +2.5 ppm control loses nothing; Rate_Handle's unguarded 32-entry symbol ring drifts 12,333·SRO entries per frame and deletes a symbol each time it hits its edge. Details: the transmitted stream is clean (sel8 desk), and the receiver's valid chain deletes one symbol every ~32 frames — one-sided deletions at 2.5 ppm on two days/two selectors, exactly the comb period, localised between the interpolator output and the correlator (Symbol_Synchronizer / Rate_Handle: push = interpolator strobe, pop = rigid 1-in-4, no full/empty guard). The inter-node sample-rate offset is ≈ 2.5 ppm (the earlier ≤ 0.06 ppm bound counted post-deletion symbols and is retracted); comb period = 1/(12,333 × SRO). Each deleted symbol shifts the bit stream by one symbol inside a frame → garbage header / crc fail / the 32–48-bit-short frames seen at the demod plane. Fix candidates: (a) make the symbol-rate handling elastic (the deletion must be absorbed as a SAMPLE discard inside the interpolator, not a symbol deletion downstream — sample_discard_controller / Rate_Handle), sim-gated at ±2.5 ppm; (b) remove the offset at the source (shared reference or a device-clock trim on one board); (c) Peak_Search re-sync on the true preamble to bound the damage to one frame. Sim confirmation: REPRODUCED at −10 ppm (FIFO underflow edge → one-sided symbol deletions → lag-8 loss comb, +0.67), ±2.5 ppm legs finishing (two_jup/comb/COMB32_SRO_SIM_2p5.md).

   > **CORRECTION (2026-09-04, [netlist], `RATE_HANDLE_FIX_SURVEY.md`):** "unguarded" and "no full/empty
   > guard" above are wrong — `Validate_Input_Push_Pop_block.v:119-137` guards the ring exactly (empty
   > = 0, full = 32, `pop_on_empty_FIFO` / `push_on_full_FIFO`). The empty edge only skips a valid slot
   > (no loss); only the full edge deletes. The reproduced period/loss numbers stand. The deleting stage
   > (Rate_Handle full edge vs the Preamble_Detector realignment FIFO, `Preamble_Detector.v:321-334`) is
   > being re-localised with true occupancy/guard taps, not assumed from this item. *[correction
   > 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]*

**Not done / defects:** reverse fabric-only leg uninformative (146's cyclic sink dead once RF-armed, D-8-1; daemon-as-sink halves 146's own frame sync); 30-min soak not run; RX gain toggle mid-leg not run; stage 2 self-reception uninformative (half-rate detection of any byte-plane stream); the checker's lost_slots counter is void on RF legs (corrupted seq field) — bound the seq step in the next revision.

**Recommended next:** (a) desk: sel8 TX-vs-air verdict, then a receiver-side fix candidate in Peak_Search/Packet_Controller (window re-arm on the true preamble / argmax hysteresis / filler-tolerant timing) sim-gated on the new full-loop harness; (b) rig: judge any fix by the checker at the decoder pins (stage 3h geometry) AND capture_r3 PER with lost frames in the denominator.

## Timeline (appended by the agents and the controller)
- 22:2x 148 seqbist image built: md5 a1ff3c876d91f1a0330254cf10902748, routed WNS +0.112 (TNS 0), +1,836 LUT / +1,156 FF vs txfixF3, banked boot_known_good/BOOT.BIN.148.seqbist.a1ff3c876d91 — flash held for the Task 3 sim gate and the rig (radio probes running). 146 (vendh) build started.
- 22:5x Radio probes on 148 (forward leg, existing images) [silicon, wedge-truncated 540/516 s]: P-A RX gain control manual (AGC was sitting at index 255 = max-gain rail, never moving) → PER 8.41 %, 26 ms line survives (25.47 ms, lag32 +0.64) = NULL; P-B all five RX tracking cals off → PER 8.33 %, lag32 +0.74 = NULL. The 26 ms process is not 148's RX AGC tick nor its RX tracking calibrations. P-C (both) running. Next discriminator: SEQ-BIST stage 2 (148 self-reception with 146 silent) → radio-of-148 vs needs-146; candidate P-D = 146 TX tracking cals (TX LO leakage / TX QEC / closed-loop gain) off.
- 23:1x 146 seqbist image built: md5 3378861d30bd3d85663b31cfdd9c6296, WNS +0.166, +2,725 LUT / +2,596 FF vs txfixF3vendh, banked boot_known_good/BOOT.BIN.146.seqbist.3378861d30bd — not flashed.
- 23:2x Radio knob facts [silicon] (two_jup/comb/RADIO_KNOBS_148.md / _146.md): on BOTH boards initial_calibrations=off, all TX tracking cals = 0, RX AGC in automatic but parked at hardwaregain 34.0 dB (= max-gain rail, never moving), RX tracking cals on (agc/bbdc/rfdc/rssi/quadrature_fic). P-C (both RX knobs) wedged twice; P-D on 146 TX is null by construction (nothing left to turn off). Conclusion so far: no ADRV9002 tracking/AGC knob removes the 26 ms comb; the 38.4 MHz-derived period is still unexplained. Stage 2 (148 self-reception, 146 silent) is the next discriminator.

## Task 8a — radio-process probes on the forward leg (2026-09-03 22:0x–23:2x) [silicon]

Report: `two_jup/sdd_archive/2026-09-03-seqbist/task-8a-report.md`.
Pre-registration: `two_jup/comb/RADIO_PROBES_PREREG.md` (committed before any leg ran).
Knobs: `two_jup/comb/RADIO_KNOBS_148.md`, `two_jup/comb/RADIO_KNOBS_146.md`.

**Verdict: the T3 lead is FALSIFIED. No periodic radio process that the ADRV9002 driver
exposes — on either board — is the 26 ms comb.**

| probe | knob | verdict | PER | 26 ms line |
|---|---|---|---|---|
| baseline a1r2 (T3) | — | — | 8.121 % | 26.055 ms, R 0.174, lag32 +0.526 |
| **P-A** | 148 RX gain control `automatic`→`spi`, gain frozen | **NULL** | **8.410 %** (CP95UL 8.469) | **survives** 25.466 ms, R 0.148, lag32 **+0.639** |
| **P-B** | 148 RX tracking cals ×5 → 0 | **NULL** | **8.325 %** | **survives** 25.821 ms, R 0.109, lag32 **+0.742** |
| P-C | both on 148 | UNINFORMATIVE (2 wedges) | — | — |
| **P-D** | 146 TX tracking cals → 0 | **NULL BY CONSTRUCTION** — all five already 0, `initial_calibrations=off` | n/a | n/a |
| P-D (RX reinterpretation) | 146 RX knob set | UNINFORMATIVE (wedge + bring-up fail); not re-run per coordinator | — | — |

Both probes landed inside the pre-registered null band (7.6–8.6 %) and nowhere near the
4–5 % hit target; the comb did not weaken — its integer lag-32 **strengthened** on both.

**Three findings worth more than the nulls:**
1. **Both receivers are pinned at maximum gain.** RX `hardwaregain` = `34.000000 dB` on 148
   *and* 146 on every read; with `maxGainIndex 255` / `minGainIndex 187` (68 steps) and
   34.000/68 = exactly 0.5 dB/step, that is **gain index 255, the AGC's max-gain rail**
   [inferred]. The AGC never moved once all night. No gain headroom on a 92 %-CRC link.
2. **The two radios are configured identically** — a full diff of every non-signal phy
   attribute between 148 and 146 returns nothing. The 8.4 % vs 3.7 % directional asymmetry is
   therefore **not** an ADRV9002 configuration difference.
3. **The period may not be crystal-stable**: 26.055 / 25.466 / 25.821 ms across three forward
   legs, a ±1.2 % run-to-run spread. A process clocked off a 38.4 MHz crystal repeats to ppm,
   not to 1 % — which would **weaken the "1e6 cycles of the device clock" reading** that
   motivated these probes. Where T4 should look next — but note this is a **one-instrument
   result** (all three numbers from the tool built tonight, calibrated against one reference
   point); the spread could be estimator variance on a ~700 s window. Worth a second
   instrument before it is treated as established.

**New tooling:** `two_jup/comb/comb_period_ms.py` — the fractional-period instrument for a
host-only leg (no DDRCAP needed). Calibrated at the desk against T3's a1r2: recovers
26.0548 ms vs the independent DDRCAP sel9 value 26.0489 ms (0.02 % agreement), R at exactly
P=32.000 = 0.0008. Also `radioprobe_go.sh`, `radio_knobs_probe.sh`, `score_probe.sh`, and
additive default-off `RX_ATTR_POKE` / `PEER_ATTR_POKE` hooks in `capture_r3.sh`.

**Rig handover:** no unit running; every probed attribute on **both** boards verified back at
its original value by a fresh read-only enumeration after all rig work (`knobs148-final`,
`knobs146-final`); keeper hold + `SENTINEL_STOP` + `RIG_LOCK` untouched and in place; boards
armed-ROM, no daemons/traffic/watchdogs. ⚠ **148's arm quality collapsed on the last attempt**
(1242–1246 f/s all night → 764–830 f/s at 23:13, failing 6/6 gate tries; 146 steady at
1247 f/s). The flash task should expect to re-arm 148 and must not read a first failed arm as
a consequence of the flash.
- 23:2x Task 8a closed (two_jup/sdd_archive/2026-09-03-seqbist/task-8a-report.md): the "periodic radio process" lead is FALSIFIED for every ADRV9002 knob the driver exposes on either board. Both receivers pinned at the AGC max-gain rail (34.0 dB, index 255) all night; 148 and 146 radio configs identical (the 8.4 % vs 3.7 % directional asymmetry is not a config difference); period may drift 25.5–26.1 ms across legs (one-instrument observation). New desk instrument two_jup/comb/comb_period_ms.py (fractional period from a host-only leg; calibrated 26.0548 vs DDRCAP 26.0489 ms). 148's arm quality collapsed to 764–830 f/s on the last attempt (146 steady 1247).
- 23:2x Task 6/7 rig driver dispatched: PHASE A (flash DRY, SEQBIST_STATE.md pre-registrations, arm148_rf_self.sh) now; PHASE B (real flash → stage 1 → stage 2) on GO after the Task 3 sim gate.
- 00:0x GO for the 148 flash (sim gates G2–G4 PASS; G1's lone gap=0 loss = generator over-supply).
- 00:10 148 FLASHED with the seqbist image a1ff3c876d91 (pre-arm 1248 f/s golden; readback verified; two-pass gate PASS, unit exit 0; rollback f6a8c3ea119c banked and untouched). Stage 1 next.
- 00:16 seqbist-s1-ctrlA died with a bash syntax error 3 min in: the driver edited seqbist_run.sh (adding SINK) while the unit was executing it. launch_rig_unit.sh now runs a frozen same-directory snapshot (20f14f3). Rig state to be verified (TGEN off, tgen_rx bit0 clear) before the re-run.
- 00:33 SEQ-BIST first live silicon [silicon]: ctrlA-r3 (180 s, GAP=0, SINK=tgenrx) — chk_frames 230,468 tracks 0x104 (235,816), acc_beats 0, ByteRxFifo ovf constant 0 → the fabric-only path (TGEN → mod → demod → checker, no DMA) works. At GAP=0 the generator over-supplies exactly as the sim predicted (seq +1.5 per received frame, garbage 50 %, gap2-dominant), so GAP=0 is characterisation only; all stage-1 legs move to the mission gap (~1,200 f/s). Lessons tonight: write-only modem regs (0x158/0x114/0x118/0x10C) read const_0; never edit a live unit's script (launcher now snapshots).
- 00:5x First fabric-only loss number [silicon]: at GAP=73384 (TGEN ≈ 623 f/s, filler 50 % as predicted by 1 − r_tgen/r_air), lost_slots 26 in ~40k emitted = 0.067 %, spread over the window (not a start transient), gap1-dominant, int_last scattered (no 32/33) — a steady loss with no DMA, host or radio in the path. Discriminator inserted: gap sweep 1,000/1,200/1,240 f/s (silence 200/30/3 µs) + TX-pin checker counts → TX byte-in starvation vs rate-independent.
- 00:5x HYPOTHESIS (content-dependent false frame sync) [inferred from sim + silicon]: Task 3's fabric-loopback framing slip is content-locked (same seq every run, ~1 per 500 emitted; 2,400-byte delivered frame + one garbled frame); the TX scrambler is hard-disabled and host whitening is OFF on this link, so payload bytes reach the air un-randomised; qpsk_perf's periodic payload (35 × 1400 B ≈ 32.4 air frames ≈ 26 ms) would re-align a fatal byte pattern with the frame boundary at exactly the measured comb period, identically on both legs and independent of every DMA/radio knob. Fix candidate = host whitening ON (QPSK_WHITEN=1 both daemons, no build). Pre-registered leg legrun-whiten-A (forward, 600 s): PER 8.1 % → ≲ 1 % and the 26 ms line gone; falsifier: unchanged. Sim Task 3b: characterise the slip's byte pattern vs the sync word and its seed dependence.
- 00:5x Stage-1 positive control PASS [silicon] (ctrlA-m, SKIP_EVERY=1000 at GAP=73384): emitted 110,208, expected 110 events, observed 164 − background 64 = 100 (tol 31), gap1 151/164, int_last at 1001 in 9/17 samples. Scorer false positives fixed (0f63cb3); TX-pin witness + gap sweep (5f21512); whitening leg prepared with three guards (sink off, /proc environ check on both boards, watchdog relaunch carries QPSK_WHITEN).
- 00:55 Gap sweep [silicon]: GAP 31,894/20,471/18,629 all saturate at the consumption rate (≈1,250 f/s emitted), so inter-frame silence was not varied — UNINFORMATIVE for starvation. Established: TX pins clean (tx_seam_checker d_bit_errors = 0 on all legs); at saturation loss = 0.064 % gap2-dominant (over-supply signature), while the under-supplied GAP=73,384 leg lost 0.065 % gap1-dominant — two mechanisms; only the gap1 one is a fabric-loss candidate. Next: whitening leg (fix candidate), then an empirical knee search (GAP 45k/60k) to set the mission gap clearly under saturation.
- 01:11 Whitening leg (legrun-whiten-A, 600 s, capture_r3 exit 0, healthy crc 92 %, rate 952 f/s < gate) — controller quick score [silicon, pending the driver's /proc environ verification of QPSK_WHITEN=1 on both boards]: PER 8.170 % (70,368/861,325) vs a1r2 8.154 %; lag32 +0.68 → NULL if verified. Content-dependent false-sync via payload whitening is then falsified; RTL grep for 400,000-symbol / 1.6 M-sample constants: none.
- 01:1x Sim Task 3b [sim]: the loopback framing slip is CONTENT-LOCKED (marginal) — needs both a payload pattern in bytes ~100–1200 of seq 134 and a sub-frame TX/RX phase; it is a lost frame-start mark (872 B filler + the whole frame inside one 2,400 B delivery, no user mark) consistent with a FALSE PREAMBLE DETECTION (Barker-13, 26 bits, un-scrambled stream) swallowing the next real preamble. Consequence: fabric-loopback loss claims need a start-phase-shifted repeat; TGEN and mission traffic are not interchangeable evidence. On air the whitening null (pending verification) says the host payload is not the trigger → remaining candidates: fabric-generated content (filler/idle frames, coded-stream structure) and the receiver's sync logic. Reprioritised: knee → ctrlB → clean 600 s → STAGE 2 self-reception → 146 flash + stage 3 → soak last.
- 01:2x WHITENING LEG = NULL, credited [silicon]: QPSK_WHITEN=1 verified in /proc environ on both boards mid-leg, 0 relaunches, healthy; PER 8.170 %, lag32 +0.68. Host payload exonerated as the comb trigger. Note: legrun's deliver_rate ≥ 1000 f/s gate is systematically unmeetable since 22:17 (arms at ~950 f/s) — re-baseline pending. Knee trials running (boards quiesced first).
- 02:17 Knee trials rc=6 (checker never advanced at GAP 45k/60k) — cause: after the whitening leg capture_r3's quiesce zeroed the modem enable / RX input select, and seqbist_run.sh's loopback "arm" (0x158/0x118/0x114 only) is not a full arm. Ruling: a full arm148_mode1.sh unit precedes any SEQ-BIST leg that follows a daemon leg or quiesce; seqbist_run.sh gains a NEEDS_ARM diagnosis. Driver heartbeat gap 01:02→02:16 noted (stall detector did not flag it — checked).
- 02:2x Knee trials (armed) [silicon]: GAP 45,000 → TGEN fills every air slot (saturated; loss 0.03 % gap2-only = over-supply); GAP 60,000 → exactly every other slot (filler 50 %; loss 0.065 % gap1-dominant). The TGEN rate is slot-quantised, so stage 1 runs at GAP=60,000 (filler-interleaved, where the candidate fabric loss is measurable) with GAP=45,000 as the no-filler control. KEY OBSERVATION: single-slot fabric losses occur ONLY when filler frames are interleaved with data — matching the sim's false-preamble-in-filler slip. On the RF link filler is inserted whenever the host TX queue runs dry (inter-submit gap > 802.9 µs). Desk test dispatched (FILLER_ADJACENCY_DESK.md): do lost RX slots follow host TX submit gaps > 1 frame on the daemon legs, and does the TX gap series itself carry the 26 ms period (the never-run T2 drain-budget question)?
- 02:40 STAGE 1 VERDICT [silicon]: fabric loopback at GAP=60,000 (filler every other slot), 600 s: emitted 377,161, lost_slots 217 = 0.058 % (gap1 143 / gap2 37), crc_fail 0, int_last series with NO 32/33-frame intervals → no 26 ms comb in the fabric alone. ctrlB (CORRUPT_EVERY=1000) PASS on the seq axis (background-corrected 121 vs 116 expected, int_last = 1000). The on-air 8 % is not a fabric-loopback property; the fabric's own floor is a filler-adjacent single-slot loss of ~0.06 %. Stage 2 (148 self-reception, 146 keyed off) launching.
- 02:45 STAGE 2 first attempt = a FINDING [silicon]: 148 self-reception over the air with 146 keyed off (verified 'calibrated', restored 'rf_enabled'): ROM stream self-couples perfectly (arm-quality 1,246 f/s at 0x114=0; self-coupling 1,246 f/s at 0x114=1), but the half-rate TGEN stream (filler every other slot) collapses frame sync to 391 f/s (0x124) / 329 f/s (checker) — the same stream decoded at full rate in digital loopback. FILLER FRAMES BREAK THE RECEIVER ONLY OVER RF: an all-zero frame = constant-symbol carrier with no timing transitions → the timing/AGC loops free-run through it and the following real frames are lost. On the mission link the fabric inserts such a filler whenever the host TX queue runs dry → host TX starvation → dead-symbol carrier → lost frames: the host TX cadence is back as the comb candidate (desk filler-adjacency test in flight). Stage 2 rerun at the filler-free point GAP=45,000.
- 02:48 Stage 2 filler-free (GAP=45,000) ALSO fails the bring-up gate [silicon]: 0x124 493 f/s, checker 368 f/s vs ROM self-coupling 1,246 f/s. So the TGEN (PN payload) stream breaks frame sync over the air but not in digital loopback. Difference ROM↔TGEN = payload entropy; difference loopback↔air = CFO (+20 kHz in the self arm), noise, AGC. Leading reading: the preamble detector is not robust to payload-induced false detections once CFO degrades the true peak — consistent with the mission link (random payload, deliberate +20/+40 kHz LO offsets, 8 %) and the whitening null. Gate-only probes ordered: CFO 0 / +5 k / ±20 k with FILL=1516, and FILL=100 (low-entropy) at +20 k.
- 02:5x Stage-2 probes [silicon]: P1 (CFO 0, FILL 1516) FAIL 617 f/s with ~233 carrier-sync resets/s (sync acquired and torn down, not never acquired); the CFO≈0 dead-zone rule does not hold for self-reception. Mission legs had rstcs ≈ 0, so this self-reception failure has a different signature — RX overload (own TX at 0 dB into an RX at the AGC rail) is the new candidate; TX-attenuation probes P7 (−20 dB) / P8 (−40 dB) appended; P5 (low-entropy payload) still decides entropy.
- 03:0x Desk FILLER_ADJACENCY (two_jup/comb/FILLER_ADJACENCY_DESK.md) = CONTRADICTS [silicon]: the host TX queue runs dry only 1–5 times per 600 s leg (the wedge); losses are ~70,000× too many to be filler-adjacent; NEVER_SENT = 0 on every joinable leg; the host submit cadence carries a 25.69 ms line on 3/6 legs but the RX loss comb is present on all six and strongest where the cadence line is absent → the comb is NOT host-cadence-made; reverse legs starve more yet lose half; the whitening leg starved 19× less with the same PER. Host TX starvation is excluded as the comb source. Residual not visible to the host log: fabric-level TX starvation (ByteWordBuffer) — T1 loopback with the daemon was clean, so unlikely.
- 03:00 Stage-2 probe sweep [silicon] (148 self-reception, 146 keyed off, gate-only 30 s): P1 CFO 0 → 617 f/s; P2 +5 k → 622; P3 +20 k → 462; P6 +20 k control → 618 (run-to-run spread ≈ 150); P5 FILL=100 (low entropy) → 209 (WORSE). Entropy hypothesis falsified in the opposite direction (zeros starve the timing loop); CFO excluded across 0–20 kHz. Every byte-plane (TGEN) stream fails self-reception while the ROM path self-couples at 1,246 f/s. Next: TX attenuation probes P7 −20 dB / P8 −40 dB (+ P9 ROM at −20 dB control) → overload vs intrinsic; if unchanged, stage 2 is UNINFORMATIVE and the two-board fabric-only legs (146 flash + stage 3) decide.
- 03:07 TX-power probes [silicon]: P7 −20 dB → 0x124 626 f/s (no recovery; checker not armed in the patched gate = instrument fault), in-gate rstcs delta 1 → NO reset storms (the earlier 233/s figure was an arm artefact, retracted); P8 −40 dB → self-coupling lost (31 f/s); P9 ROM −20 dB → 1247/1246 (attenuation does not break ROM). STAGE 2 VERDICT: UNINFORMATIVE — in self-reception every byte-plane stream is detected at ~half the frame rate with stable sync regardless of CFO / payload / TX power, while the ROM path is received fully; digital loopback receives the same stream fully. Desk RTL check dispatched: is the RX frame window gated by the TX frame start (loopback-design coupling)? Rig next: 146 flash + stage 3 (two-board fabric-only legs).

## Task 6/7 — flash 148 + stage 1 + stage 2 (rig driver, 2026-09-04 00:00–03:10)

**Flash: SUCCESS.** 148 runs `a1ff3c876d91f1a0330254cf10902748`; readback verified, two-pass
gate passed, no rollback, sel-6 witness decoded, keeper hold untouched. The task-8a arm
collapse (764–830 f/s) had not persisted — pre-flash probe gave ARM_OK 1248 f/s first try.

**Stage 1 (fabric loopback): the fabric is not the comb.** Loss floor **0.058 %** of emitted
frames at the operating point (GAP=60000, 622.7 f/s), gap1 family, **no 26 ms structure** in
the `int_last` series, `crc_fail = 0`, TX byte pins clean (`tx_bit_errors = 0`). Both positive
controls pass background-corrected. The 1800 s soak was not run.

**Stage 2 (OTA self-reception): UNINFORMATIVE, but with a hard fact.** ROM self-couples at
1246 f/s; *no* byte-plane stream can be received in self-reception (209–626 f/s) regardless of
CFO (no effect), payload entropy (low entropy is worse) or TX power (attenuation does not
help, and −40 dB kills the coupling). In-gate rstcs 0–1 — sync is stable, not storming. So the
failure is half-rate detection with stable sync, consistent with the sim's framing slip; but
self-reception is not the mission geometry, and stage 3 is the decisive test.

**Host whitening: NULL.** PER 8.170 %, lag32 +0.68, whitening verified on both boards from
`/proc/<pid>/environ`, zero watchdog relaunches. The host payload is exonerated as the comb
trigger; the remaining candidates are fabric-generated content and the receiver's sync logic.

**Three things the next driver must not re-learn:** `tgen_mode` (0x9D410000 bit5) is set by
nothing and every TGEN frame counts as `crc_fail` without it; `SINK=tgenrx` is mandatory or
the seam stalls and every counter reads 0; and `0x158`/`0x114`/`0x118` are **write-only** —
verify the arm by effect, never by read-back. Also: `legrun_go.sh`'s `deliver_rate ≥ 1000 f/s`
gate is now unmeetable on this rig (952 f/s) and should be re-baselined.

Rig handed over quiesced and verified: 148 txgain 0 dB / TGEN off / sink disarmed, 146
`rf_enabled`, no daemons on either board, hold in place.
- 03:2x Desk RTL (two_jup/comb/RX_WINDOW_RTL.md) [netlist]: the TX-gated-window hypothesis is FALSIFIED — the only Transmitter→Receiver crossing is the I/Q mux. The receiver IS windowed: Peak_Search runs a free-running mod-12,333 epoch (one air frame) anchored only at reset and reports ONE winner-take-all argmax per epoch (Peak_Search.v:83-176), applied an epoch later through a 4-epoch delay line; a detected start opens a 12,320-of-12,333 window re-armed only by itself (End_Generator.v:107-131, sample_discard_controller.v:170-196), so a false peak's window runs over the next true preamble which the argmax then cannot report = the sim's 2,400-byte delivery with a lost user mark. Surviving mechanism [inferred]: payload-induced false-peak ARGMAX THEFT — the only candidate passing the ROM-works-over-air filter (both paths share Message_Generator framing, only bit content differs); CFO/attenuation independence follows from the correlator sitting post-carrier-sync with a running-energy threshold. Not yet explained: the stable ~50 % in self-reception, and the 32.4-frame comb (candidate: a limit cycle of the epoch-delayed Timing_Adjust feedback). Cheapest silicon test: DDRCAP dc_heldts/dc_runmax/dc_corrthr on the same TGEN stream at 0x114=0 vs 1 (needs the dc_* selector lineage — check the flashed image).
- 03:35 146 FLASHED with the seqbist image 3378861d30bd (t8-flash146 exit 0: readback verified, arm gate pass try 1, health gate pass fsync 1259; rollback txfixF3vendh 6b4744ca73f8 banked on nemo and on-board). Next: SINK=cyclic credit on 146 in loopback, then stage 3.
- 03:46 Stage 3 [silicon]: 146 instrument credited in loopback (SINK=cyclic first silicon use; SKIP_EVERY=1000 control PASS background-corrected: 70 vs 72 expected). bringup_fabric_only.sh armed both boards RF first try (mission LOs, SSI verified). Forward fabric-only leg at GAP=60,000 FAILED its gate: 148 receives 146's filler-interleaved TGEN stream at 325 f/s (0x124) — the same OTA collapse as stage 2, now across the mission link. Ruling: forward at GAP=45,000 (no filler) next; then STAGE 3h = daemons up (legrun LEG=A) with 148's checker in host-frame mode reading the mission stream at the decoder pins (SINK=none, the daemon drains) — the comb measured upstream of the RX DMA/host on the very stream that loses 8 % at the host.
- 03:49 Stage 3 forward at GAP=45,000 (no filler): bring-up gate PASS over the mission link [silicon] — 0x124 1242.8 f/s, checker 1241.6 (dev 0.09 %): the byte-plane TGEN stream IS received fully by 148 across the air, so stage 2's collapse was self-reception-specific (overload/self-coupling), and filler frames are what break OTA sync. The leg then refused on a read-back of write-only 0x114 (same bug class as the 0x158 check; fixed) — relaunching the 600 s leg.
- 04:03 STAGE 3 FORWARD, FABRIC-ONLY OVER THE MISSION LINK [silicon] (146 TGEN GAP=45,000 → 148 checker, SINK=tgenrx, no daemons/DMA anywhere, 600 s): emitted 796,084; received 744,463; good 656,990; garbage (bad magic) 43,889 = 5.9 % of received; crc_fail 3,342; gap_events 39,541 = 5.0 % of emitted (gap1 28,028 / gap2 8,457 / gap3+ 3,056); dup_or_reorder 2,893; lost_slots counter wrapped (good-magic frames with a corrupted seq field inject huge spurious gaps — scoring caveat; a future checker must bound the seq step). HEADLINE: the mission-link loss is reproduced with NO host or DMA in the path — the defect is in the fabric/RF chain (transmit fabric → air → receive fabric up to the decoder pins). Interval structure: int_last samples cluster at 7–9 and 23–25 emitted frames (and 31–33): an 8-frame (6.4 ms) base under the host's 32-frame comb [inferred]; int_32 2,458 / int_33 440 / lt30 29,355 / other 7,287.
- 04:19 STAGE 3h [silicon]: 148's checker in host-frame mode on the REAL daemon stream (legrun LEG=A, 400 s window, run 20260904_040718_seqbist_s3h): chk_frames 482,166 vs 0x104/0x124 482,287 (0.025 %); garbage 5.66 %; crc_fail 2.12 %; gap_events 5.23 % of emitted; int_32 2,235 + int_33 708 → period 32.24 emitted frames = THE 26 ms COMB, present at the fabric decoder pins; int_hist_lt30 carries the 8-frame base. Together with the fabric-only forward leg: the entire loss and its comb sit between the transmit fabric and the receive decoder pins; host, DMA and payload are out.
- 04:22 Reverse fabric-only leg gate FAIL: 146 receives 148's TGEN at 1,247.5 f/s (0x124) but its checker sees 0 — the cyclic S2MM sink is not draining the seam in the RF-armed state (it worked in 146 loopback). One diagnosis (DMAC state, byte re-arm ordering) then a re-run or the 146-daemon-as-sink fallback; sel8 TX capture on 148 still planned; rig experiments stop 05:45, restore/release by 06:15.
- 04:28 Reverse leg r2 (cyclic sink re-armed after the byte re-arm) still 0 checker frames with 146 0x124 at 1,246 f/s and byte_fifo_ovf climbing (22.9 M) — the cyclic ring does not drain the seam in the RF-armed state; SINK=cyclic is credited only in loopback. Fallback per ruling: 146's own daemon as the downstream sink (checker stays in tgen_mode).
- 04:31 Reverse leg with 146's daemon as sink: the checker counts (389 f/s) but 146's own frame sync halves to 532 f/s (0x124) when its daemon runs — a third failure mode (echoes the self-reception half rate). Reverse fabric-only leg UNINFORMATIVE tonight; ruling: no more attempts; one standalone TX-side DDRCAP sel8 capture on 148 (TGEN GAP=45,000) for the morning desk, then close-out (plain daemons, hold release, sentinel).
- 04:39 TX-side DDRCAP sel8 on 148 credited (512 MiB, PC structural gates pass) while transmitting the TGEN stream at GAP=45,000; desk analysis dispatched (TX_SEL8_DESK.md). Close-out (plain daemons, hold release, sentinel) in progress.

## Task 8 — flash 146 + stage 3 fabric-only RF legs (2026-09-04 03:2x–04:4x) [silicon]

Report: `two_jup/sdd_archive/2026-09-03-seqbist/task-8-report.md`. State: `SEQBIST_STATE.md` §7.

- 00:28–00:35 **146 flashed** with the seqbist image `3378861d30bd` (readback verified, NAK rail
  `nakstat=4`, 148-side health gate PASS first pass `fsync=1259 wcnt=1259`, **no rollback**).
  The A0 gate would have FATALed on the chain's default `ROLLBACK_BANK` (`ec414d2df8bc`); the
  banked `6b4744ca73f8` was passed explicitly.
- **SINK=cyclic exercised on silicon for the first time** and credited on 146 in loopback
  (ovf constant, chk tracks 0x104 to 0.02 %, crc_fail 0, filler 50.017 % vs 50.0 % predicted,
  loss 0.0305 %), with a background-corrected `SKIP_EVERY=1000` control **PASS**.
- **Stage 3 forward, GAP=45,000, 600 s, no daemon / no DMA / no host anywhere:** garbage
  **5.894 %**, crc_fail 0.449 %, gap_events **5.31 %** (gap1 70.9 %), 0x104/0x124/chk agreement
  0.07 %, `period_est` **32.15** emitted frames.
- **Stage 3h, the checker on the REAL daemon stream** (host-frame mode, `tgen_mode=0`,
  `SINK=none`), 400 s: garbage **5.661 %**, crc_fail 2.118 %, gap_events **5.225 %**,
  agreement 0.025 %, `period_est` **32.24** frames = **the 26 ms comb, at the decoder pins**.
- **PREREG RESOLVED: the defect is in the fabric/RF chain; the host and the RX DMA are
  exonerated.** Two independent traffic sources, one with no host in the path at all, give the
  same ~5–6 % damage and the same comb, against a fabric loopback floor of 0.058 % / 0.031 %.
- **Filler frames are lethal over RF only**: GAP=60,000 (all-zero frame every other slot)
  collapses 148's frame sync to 325 f/s where GAP=45,000 decodes at 1252 f/s. That also retires
  stage 2's verdict — filler-free works in the real geometry, so the self-reception collapse was
  self-reception-specific. A concrete fix lead independent of the comb.
- An **~8-frame (6.4 ms) structure** sits under the 32-frame comb in both instruments [inferred].
- Reverse fabric-only leg **UNINFORMATIVE** after three configurations; **D-8-1**: `SINK=cyclic`
  drains in loopback and not in the RF-armed state. A live daemon on the *receiving* board halves
  its own detection rate (531.9 vs 1246 f/s) — the stage-2 half-rate shape again.
- TX-side **DDRCAP sel8 on 148 credited** (512 MiB, exit 0); `ddrcap2_pc.py --sel 8` TIER2 FAIL on
  `toff_range_steady` only (d0 = 489), all other gates PASS.
- Instrument corrections: `lost_slots` is **VOID on an RF leg** (corrupted-seq artefact, 3.96e10
  and 25 wraps — a checker revision should reject a seq that is not `last_seq + k`, k ≤ 64); the
  `0x114` read-back gate was **false** (write-only) and refused a leg whose own gate had passed;
  the drain must be armed before any traffic exists; `arm_guard` is too wide for an in-leg reader.
- 04:37–04:41 **close-out**: both boards quiesced, plain daemons rebuilt and running via
  `capture_r3.sh`'s own build line (`nakstat = 4` verified on 148), watchdogs up, reverse LO back
  at the shipped 1900040000; **keeper hold released**, sentinel relaunched
  (`sentinelkeeper-044058`) and logging `ok rate=1166/s`. Both boards stay on the seqbist images;
  rollbacks `f6a8c3ea119c` (148) and `6b4744ca73f8` (146) remain banked on nemo and on the boards.
- 04:5x Sim 8d (two_jup/comb/COMB32_RXLOOP_SIM.md) [sim]: NO COMB at any operating point of a new closed-loop harness (TGEN → TX RTL → CFO/AWGN → full RX with Peak_Search/Timing_Adjust taps; 8 legs, 257–449 epochs): |ρ@32| ≤ 0.10 vs null95 0.2–0.27. Instead every impaired leg shows a MONOTONE argmax ramp (timing offset −8.6 to −15.7 samples/epoch, lag-1 autocorr 0.99) and loses 35–45 % — far above silicon — so the harness's impairment path is not yet realistic; the clean control reproduces the known content-locked slip (0.74 %). Verdict bounded: "no comb at these operating points", not "no comb ever". The 32.4-frame period remains unexplained by the RTL sim.
- 05:2x TX-SIDE DESK (two_jup/comb/TX_SEL8_DESK.md) [silicon]: TX CLEAN — Barker-13 preamble bit-perfect on 1,312/1,312 frames, power/EVM/preamble amplitude flat, no 8/32-frame payload repeat; any TX frame-length anomaly < 1 per 144 frames. AND THE MECHANISM: the receiver's valid chain DELETES ONE SYMBOL, strictly one-sided, at 2.57 ppm = one per 31.5 frames (09-04 sel8) and 2.51 ppm = one per 32.35 frames (09-03 sel13 legA) — two days, two selectors, 3 % agreement, both on the comb's 32.24 frames; lag-32 autocorr +0.82 vs null 0.14. Localised downstream of the interpolator (its own strobe is balanced) in Symbol_Synchronizer.validOut → … → Correlator.validOut. Reconciliation: the "|SRO| ≤ 0.06 ppm" bound counted post-deletion valid symbols (which the deletion keeps at exactly 12,333 per frame) and is RETRACTED — the inter-node sample-rate offset is ≈ 2.5 ppm and the comb period = 1/(12,333 × SRO). Prediction: the comb period tracks the clock offset. Sim test dispatched: the SRO harness at ±2.5 ppm for 400 frames (Rate_Handle occupancy drifts one entry per 32.4 frames at 2.5 ppm).
- 05:4x Negative control (two_jup/comb/DTREF_CENSUS_CONTROLS.md) [silicon]: digital-loopback sel13 captures (09-02, mid + onset) show 0 deletions / 0 insertions / 0.000 ppm — the symbol deletion exists only with two boards, as the SRO reading predicts. (sel6/sel9 are not census-able: different valid domains.)
- 06:1x SIM CAUSAL PROOF (two_jup/comb/COMB32_SRO_SIM_2p5.md, in progress) [sim]: at −10 ppm the Rate_Handle FIFO reaches its underflow edge at frame 34 (predicted 41), the first frame is lost at 38, the loss comb sits at lag 8 with autocorr +0.67 (null 0.22; predicted period 8.1), loss 23 %, and the valid-chain census is strictly one-sided (deficit 21, surplus 0) identically at Symbol_Synchronizer.validOut → CFC → CS → Preamble_Detector → Correlator.validOut — the exact TX_SEL8_DESK signature. Mechanism: sample-rate offset → Rate_Handle push/pop mismatch → FIFO underflow → one symbol deleted per 1/(12,333·SRO) frames → one frame lost per deletion. The −2.5 ppm leg (predicted edge ~frame 162, period 32.4) and the +2.5 ppm control (no edge inside 420 frames) are finishing. Open point: the sim's deficit originates at the interpolator strobe while the silicon sel8 census saw the strobe balanced (sensitivity-limited); noted, not smoothed over.
- 06:2x TX_SEL8_DESK follow-up corrections [silicon]: (a) the 09-02 sel13 files (digital loopback) have 0 deletions — SRO_SEL13_DESK's bound was right for loopback; 2.5 ppm is the ordinary inter-node clock offset, the defect is how the receiver absorbs it; (b) the interpolator-strobe census had a DMA-boundary artefact; corrected, the interpolator reads 0.0 ± 1.3 ppm vs 2.5 — "disfavoured, not excluded" as the deletion origin, which is COMPATIBLE with the sim (deficit originates at the strobe); (c) the agent's remark that the 09-02 loopback run "had ~8 % loss" rests on errps (0x108, the 120-bit BIST comparator during the beat era) — not a frame-loss measure; tonight's stage-1 loopback measured 0.058 % frame loss, so loopback has no bulk loss and the deletion mechanism remains the candidate for the bulk on-air loss (≈2–3 damaged frames per deletion event: gap1 71 % / gap2 21 % / gap3+ 8 % plus garbage).
- 06:3x ROOT CAUSE CONFIRMED IN SIM (two_jup/comb/COMB32_SRO_SIM_2p5.md, commit c367cfb) [sim]: −2.5 ppm → loss 4.11 %, comb period 32.375 frames (silicon 31.5/32.35), FIFO occupancy 5→0 with the first edge at frame 137, loss groups every 32/33 frames, lag-32 +0.45 (null 0.21), Correlator valid chain strictly one-sided (8 deletions / 0 insertions, 8/8 phase-locked to a loss group); +2.5 ppm control → 0.00 % loss with the identical drift period (occupancy walks away from the edge, 5→18); −10 ppm → period 8.10 vs 8.11 predicted; periods scale as 1/|SRO| to 0.1 %. Mechanism: Rate_Handle's unguarded 32-entry ring (FIFO_block.v:113,148; reset tied off at Rate_Handle.v:97,106) — occupancy drifts 12,333·SRO entries per frame and AT AN EDGE the ring deletes a symbol one-sidedly and a frame dies; comb period = 1/(12,333·SRO). Open: the sim's deficit originates at the interpolator strobe whereas the silicon strobe census reads 0.0 ± 1.3 ppm (sensitivity-limited).

  > **CORRECTION (2026-09-04, [netlist], `RATE_HANDLE_FIX_SURVEY.md`):** the ring is not
  > unguarded — `Validate_Input_Push_Pop_block.v:119-137` guards it exactly at 0 and 32. The
  > −2.5 ppm stimulus used here drains the ring toward EMPTY (`gen_sro_stim.py:72-73`), which
  > is the benign edge (skipped valid slot, no loss), so "the ring deletes a symbol AT AN EDGE"
  > is not established by this leg alone; the harness's occupancy metric
  > (`sim_sro.cpp:115`, `(pushPtr−popPtr)&31`) cannot distinguish empty from full. The
  > period/loss numbers above are unaffected. The deleting stage is being re-localised with
  > true occupancy/guard taps (Task 1, `COMB32_SRO_SIM_TAPS.md`) between the Rate_Handle full
  > edge and the Preamble_Detector realignment FIFO. *[correction 2026-09-04,
  > RATE_HANDLE_FIX_SURVEY.md]*
- 06:4x Boundary on the claim: the sim's −2.5 ppm loss is 4.1 % vs 5–8 % on air — the ring-edge deletion accounts for the comb and the larger part of the bulk loss on these numbers; the remainder (more frames damaged per deletion under noise, or a second component) is not yet apportioned. (The sim agent's '09-02 control had ~8 % loss with zero deletions' rests on the 120-bit BIST errps counter, not a frame-loss measure — see 06:2x.)
