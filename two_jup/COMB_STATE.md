# COMB campaign state — residual singles/doubles loss (started 2026-09-03)
Ledger: two_jup/sdd_archive/2026-09-03-comb/progress.md · plan: ~/.claude/plans/happy-bubbling-owl.md · dashboard http://10.0.0.71:8090/pipeline.html

## T0 (desk) — complete
- Daemon instrumentation (fail_class, failed-header ring, TX per-frame log; README two_jup/comb/README_hostlog.md), analysis tools (two_jup/comb/*.py, 19 tests), rig scripts (two_jup/comb/*_go.sh, 34 tests). bringup_r2r3.sh gained per-board RXM_A/RXM_B + DAEMON_ENV_A/DAEMON_ENV_B (A=148, B=146; byte-identical launch line when unset), watchdog relaunch string carries them, legrun_go.sh fails the gate on any watchdog relaunch.
- Baseline comb facts from the 09-03 ballpark captures [silicon, accept_analyze + comb_autocorr]: ALL-LOSS lag-32 autocorrelation +0.70 on fwd, fwd_after and rev2 (lag units = transmitted-frame slots). fwd and rev2 harmonics at exactly k×32; fwd_after (146 on txfixF3vendh) at k×32+1 (33/65/97) — a +1 slip, not a period change.

## T1 — 148 internal loopback floor, instrumented daemon, 600 s [silicon] — COMPLETE, INFORMATIVE
Command: `two_jup/launch_rig_unit.sh loopfloor-T1 /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/loopfloor_go.sh DRY=0 DUR=600` (after `deploy148-T1r` = deploy_daemon_go.sh BOARD=148, nakstat gate 4/4, daemon md5 f2c33f9b1b784d3c91a85c2d9383030d, image f6a8c3ea119c). Run dir two_jup/comb/runs/20260903_172902_loopfloor, report two_jup/sdd_archive/2026-09-03-comb/t1-run-report.md.
| quantity | value |
|---|---|
| fabric frames (0x104 delta) | 816,963 in 600 s (1,361.6 f/s) |
| magic_bad (fabric checker) | 1 → 0.00012 %; Poisson 95 % upper bound ≲ 0.0006 % |
| worst 10 s window | 0.0074 %; 0 of 60 windows ≥ 3 % |
| txgap > 20 µs | 1 (the 962 µs close-boundary gap); steady-state dumps 0 over 9,795 transfers |
| re-arms in window | 0 |
PREREG verdict: prediction 0.2–0.35 % per window NOT met — missed LOW by ~300×; falsifier (≥ 3 %) not tripped; beat fix holds on this path. Conclusion: on the txfixF3 image the TX byte-in plane's loopback floor is ≲ 0.0006 % [silicon]; the 08-28 "0.22–0.31 % floor" belonged to the now-fixed beat defect. T5b (TX witness build) is disqualified. Extension to the on-air residual is [inferred] through the P2 argument (an ALIGNLOSS corrupts the air frame identically on air and in loopback).
Caveats: the host RX ring in the Test-A loopback is not a receiver (frames.bin holds 1,576 records over a 26 s live window, all failed; census reports UNUSABLE) — host-side fail classes are only meaningful on RF legs (T2/T3). Script defects open: uninformative parser reads hex pkts as decimal (d104 shows 0); loopfloor scp's txlog.bin before the atexit dump; txgap fetched with tail -3.

## T2 — host-cadence probes on the reverse leg (148 TX → 146 RX), capture_r3.sh B -d 600, instrumented daemons — PRE-REGISTERED 2026-09-03 17:5x, not yet run
Legs (each `two_jup/launch_rig_unit.sh legrun-T2-<tag> /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/legrun_go.sh DRY=0 LEG=B DUR=600 <knobs>`; gate deliver_rate ≥ 1000 f/s pre/post and zero watchdog relaunches; one re-run on a wedge, then UNINFORMATIVE):
1. m16: RXM_148=16 (baseline; also DRAIN=4 default)
2. m8:  RXM_148=8
3. d1:  QPSK_RX_DRAIN_BUDGET on 148 = 1 (DRAIN_148=1)
4. d0:  DRAIN_148=0
P1 prediction: the ALL-LOSS autocorrelation's dominant comb family follows 148's own -M: m8 → k×16 (± the +1 slip), m16 → k×32. Falsifier: m8 still peaks at k×32 → the comb is not locked to the transmitting board's RX cadence.
P2 prediction: comb amplitude (lag-family peak) is monotone in the drain budget (d1 < d4 < d0, or the reverse). Falsifier: flat within ±0.1 → the trigger is not the RX drain.
Scoring: comb_autocorr.py (top-5 lags + harmonic family), comb_census.py (fail-class census with the class-4 split), both legs' failhdr; lag units = transmitted-frame slots. UNINFORMATIVE checklist per leg: 0x104 delta ≈ 0, window < 150 s, re-arm in window, capTAP not golden, watchdog relaunch.

### T2 interim (18:4x) and P1b addendum — pre-registered before the leg runs
P1 verdict [silicon, wedge-truncated windows 718 s and 519 s]: FALSIFIED. m16 → k×32 (+1 slip), m8 (148 at -M 8) → k×32 (slip 0), lag16 ≈ −0.03 on both; PER 3.74 % vs 3.71 %. The comb period is not locked to the transmitting board's RX queue depth; -M moved only the phase slip.
P1b (added 18:4x, before its leg): the receiver's queue depth. Leg m8rx: `RXM_146=8` (148 at default 16), LEG=B DUR=600. Prediction if the comb is the RECEIVING board's host back-pressure cadence: family moves to k×16 (lags 16/48/80 rise above the −0.03 floor). Falsifier: family stays k×32 → the comb is not host-queue-locked on either board → an air/RX-DSP mechanism with a ~32-frame (25.7 ms) period; T3/T4 then look for a 25.7 ms process in the receiver (timing-loop / AGC / carrier-tracking cadence, DMA S2MM transfer boundaries are already excluded by RXQ evidence).
Order after m8-r2: m8rx, then d1, d0 (P2 kept, lower priority now).

### T2 verdicts (18:5x) and the surviving hypothesis
- P1 FALSIFIED (148 -M 8: fundamental 32, lag16 −0.03, two windows). P1b FALSIFIED (146 -M 8: fundamental 32 with harmonics 64/96/128 at +0.75/+0.71/+0.67/+0.63, lag16 −0.036) [silicon, wedge-truncated 420–720 s windows]. PER flat across every knob: 3.74 / 3.71 / 3.79 / 3.67 %. MAGIC share of failures 83.5–83.8 % on every leg; never_sent = 0 on every leg (100 % of lost frames were submitted by 148). 148's TX ran flat through every wedge (5/5).
- Ruling: the comb is not host-queue-locked on either board. P2 (drain budget on the TX board, legs d1/d0) is dropped — it probes the same host cadence family that P1/P1b just excluded and every reverse leg costs a wedge; cost if wrong: one untested host knob, re-runnable later.
- Surviving hypothesis [inferred]: a receiver-side process with period 32 frames = 394,656 symbols = 25.72 ms, identical on the forward and reverse legs (both legs share the same two oscillators) and independent of host knobs. A sample-rate offset (SRO) between the boards' converter clocks of ~0.63 ppm produces exactly one whole-sample slip per 25.7 ms (1 sample in 4×394,656); if the symbol-timing interpolator mishandles the slip (mu/countReg wrap), one frame (sometimes two) is lost per wrap — the singles/doubles signature. This is the 08-26 "receiver SRO defect" reading, now with the host alternatives excluded by measurement. The +1 harmonic slip between runs would be the ppm drifting slightly.

### T3/T4 pre-registration (before any capture)
Forward leg (146 TX → 148 RX, LEG=A) with the instrumented daemons; at +120 s fire `ddrcap2_capture.sh 13` (interpolator countReg/mu, 512 MB) on 148 and, in a second leg, sel 9 (demod hard bits + frame markers). Index records by in-record tref (full-rate taps drop 20–40 % at the rx2 DMA). Positive control: `ddrcap2_pc.py --sel 13` PASS and a visible mu sawtooth. Prediction: mu/countReg shows a sawtooth whose wrap period is 25.7 ms ± 5 % (32 frames), and every wrap coincides (within one frame) with a lost-frame onset in 148's frames.bin/failhdr; the comb phase mod 32 of the losses is locked to the wrap phase. Falsifier: wrap period ≠ 32 frames, or wraps without losses / losses without wraps at > 20 % → the SRO reading is wrong and T4 moves to sel5/sel14 (carrier sync, interpolated samples) at the loss onsets.

### Where are the frames dropped? — status 2026-09-03 19:2x
Established [silicon]: every lost frame was submitted by the transmitting host (TX log join, 100 % on 5 legs); the receiving host sees ~84 % of them arrive as frames with a garbage header and ~15 % with a bad CRC, none as zero-tail; the loss is a comb of period exactly 32 frames on both legs; it is unchanged by either board's RX DMA queue depth (-M 8 vs 16); the 148 digital loopback is clean at the fabric checker (1 in 817 k); the board-to-board sample-rate offset is < 0.066 ppm (no sample-slip mechanism). Excluded: TX host plane, TX byte-in (ByteWordBuffer) plane, host RX DMA transfer boundaries, host back-pressure on either board, receiver SRO. Remaining: the RF path plus the receiver's own DSP chain (AGC/carrier/timing) — and, if the demod hard-bit tap shows those frames intact, the fabric delivery plane between the decoder and the host (the 08-27 reading), which the RXQ evidence made unlikely but which the -M null did not test directly. Pending: sel9 capture on the forward leg (intact vs garbage at the demod bit plane, and the comb phase there), the sel6 desk test for a 32-frame disturbance at the demod input, the RTL/profile hunt for a 32-frame counter.

### 19:4x — correction: the 09-02 DDRCAP captures were 148 self-reception
COMB32_SEL6_DESK.md found mark_demod − mark_fec = exactly 61 symbols on ~5,441/5,446 frames with zero drift over 4.38 s: the 09-02 sel6/sel13 captures (arm148_mode1, 146 untouched that day) recorded 148 demodulating its own transmitter. Consequences: the "|SRO| < 0.066 ppm" bound in SRO_SEL13_DESK.md is WITHDRAWN (it measured 148 against itself); the "analog domain clean" result applies to loopback only; the SRO sample-slip hypothesis (period = 1/SRO ≈ 25.7 ms at 0.63 ppm; each ±1 symbol strobe costs the deframer one frame → garbage header, the 84 % magic-bad share) is restored as the lead. Supporting [netlist] (COMB32_RTL_HUNT.md): the only mod-32 structure in the design is the unguarded 32-entry strobe FIFO in Rate_Handle (Symbol_Synchronizer; push = interpolator strobe, pop = rigid 1-in-4, never flushed); no host period is 32 and the DMAC bursts give 16, not 32. First on-air tap = sel9c (a1r2, credited on bytes; PC pending): the air-frame spacing in local samples across it measures the SRO directly (prediction: 1 sample per ~32 frames). A2 = sel13 on air (strobe census). Desk causal test dispatched: receiver RTL sim with ±0.63 ppm SRO (prediction: one lost frame per slip, period 32; SRO 0 → none; 1.26 ppm → period 16).

### How lost packets are counted (reference)
1. Receiving host: qpsk_tun logs a 48 B record per frame pulled off the RX DMA ring (t_mono/t_real, host_seq, crc_ok, 0x104/0x108/0x150/0x154/0x15C) to frames.bin; since T0a each failed frame also carries fail_class (1 magic-bad, 2 len-bad, 3 crc-bad, 4 zero-tail) and a 32 B failed-header record (magic bytes, first-zero offset) in failhdr.bin.
2. Loss axis (accept_analyze.py, two_jup/comb/common.py loss_slot_trains): take the crc_ok frames' header seq numbers in arrival order; every gap d>1 between consecutive good seqs = d−1 lost slots. Denominator = span of seq = sent slots; PER = lost/span. Frames that arrived corrupt log a garbage seq and are NOT used as an axis point — they land inside a gap, so "lost" = corrupt-at-host + never-delivered together; the fail-class census separates them (corrupt frames are counted in failhdr; a gap slot with no failhdr record was never delivered).
3. TX side: since T0a the transmitting host logs seq + submit/complete time per frame (txlog.bin); comb_census.py joins each lost slot's seq against the TX log: absent → never sent, present → sent-not-decoded. Hand control: decoded seqs must also be present (100 % on every leg so far).
4. Comb: comb_autocorr.py autocorrelates the loss indicator on the reconstructed TX-slot axis (lags 1–128, permutation null) — the period is in transmitted-frame slots.
5. Fabric-side (loopback only): 0x104 frame counter deltas and the fabric checker's magic_bad — used for T1, not for RF legs.
6. Credit gates per leg: capture_r3.sh two-pass health (crc, deliver_rate), MID_CAPTURE_WEDGE detector (delivery flatlined 12 s → leg not credited for PER, pre-wedge window still scored for the comb, labelled), watchdog relaunches = 0, settle window excluded.
Limits: a frame the fabric drops before the DMA ring and a frame corrupted on air both appear as a gap; only the on-air taps (sel9 bits, sel6 IQ) can tell them apart, which is what T3 is for.

### Packet detections vs deliveries (desk, 19:5x) [silicon]
Per-frame 0x104 (decoder packets_out) from the host logs, live window (30 s settle, wedge tail cut):
| leg | host records | of which failed | seq span | lost slots | PER | Δ0x104 |
|---|---|---|---|---|---|---|
| a1r2 fwd (148 RX, credited) | 854,321 | 67,066 | 857,146 | 69,893 | 8.154 % | 854,729 |
| m16r2 rev (146 RX) | 859,461 | 32,001 | 859,655 | 32,205 | 3.746 % | 877,224 |
| m8rx rev (146 RX) | 662,013 | 41,215 | 644,600 | 23,808 | 3.693 % | 659,024 |
Reading: the decoder emits a frame for ~99.7 % of sequence slots and the host logs one record per emitted frame (Δ0x104 ≈ records within 0.05 % on the credited leg); each lost slot carries ~1 failed record (gap=1 → 0.98 failed records, gap=2 → 1.90). So the losses are frames that were DETECTED, DECODED and DELIVERED as garbage, not frames that went undetected or undelivered (≤ 0.3 % of slots have no record at all). The receiver's frame timing never drops a slot; the payload/header of the affected frame is wrong. What is NOT logged per frame: the framesync / preamble start-pulse counters (0x124/0x128 exist in the image) — adding them to frame_rec would say whether the corrupt frame's preamble was actually detected or the packet controller flywheeled through it. (Per-gap Δ0x104 is inflated by DMA batching — registers are sampled at host decode time — so only window totals are used.)

### T3 verdicts (19:4x) [silicon] and the 38.4 MHz observation
- SRO FALSIFIED on air: |SRO| ≤ 0.06 ppm (demod marker spacing 12,333.000x local symbols per air frame over 43,581 frames); no mu/countReg sawtooth exists.
- The period survives in TIME: 26.049 ms (demod marker anomalies, R=0.87) and 25.984 ms (sel13 ±1-strobe bursts, R=0.99) = 32.36–32.44 frames; exact 32.000 excluded (R=0.010) → Rate_Handle's mod-32 FIFO is not it (the sim agrees: 0 losses at ±0.63/1.26/10 ppm).
- At the demod bit plane 3.1 % of frames arrive short by 32/48 bits with the host loss train's harmonic → garbage before the byte plane: SUPPORTS air/RX-DSP, FALSIFIES the delivery plane.
- 26.042 ms = 1,000,000 cycles of the ADRV9002 38.4 MHz device clock = 32.433 frames (measured 32.443, within 0.03 %) [inferred]: a periodic radio process (tracking calibration / AGC / DC-offset update) is the leading candidate. Probes (no build): RX gain-control mode manual vs automatic, tracking cals off, watched with the fabric SEQ-BIST (next campaign).

### 2026-09-04 00:5x — new lead: content-dependent frame sync (see two_jup/OVERNIGHT_20260904_SEQBIST.md)
Fabric-only SEQ-BIST on 148: the checker path works (chk_frames tracks 0x104 to 0.01 %); pure fabric loopback loses ~0.067 % of TGEN frames (steady, gap1-dominant, no comb) [silicon], and the Verilator sim loses ~1/500 by a content-locked byte-plane framing slip [sim]. With the scrambler hard-disabled and host whitening off, a data-dependent false frame sync would produce exactly the on-air comb (qpsk_perf payload period ≈ 32.4 air frames = 26 ms) on both legs independent of DMA/radio knobs. Test in flight: WHITEN=1 forward leg.

### 2026-09-04 03:2x — receiver frame-window mechanism (see two_jup/comb/RX_WINDOW_RTL.md)
Peak_Search: free-running mod-12,333 epoch, one argmax per epoch, applied one epoch later; a start opens a 12,320-sample window that can swallow the next true preamble. Loss = payload-induced false-peak argmax theft [inferred]; consistent with: loopback floor 0.058 % (content-locked in sim), ROM immune, whitening/CFO/AGC/attenuation independence, garbage-at-demod-plane. Open: the 32.4-frame comb (limit cycle of the epoch-delayed timing adjust?) and the 50 % self-reception rate.

### 2026-09-04 04:03 — the loss is reproduced with no host/DMA [silicon]
Fabric-only forward leg over the mission link (146 TGEN → 148 checker, no daemons): 5.0 % gap events + 5.9 % garbage at the decoder pins vs 8.1 % at the host (a1r2). Host, DMA engines and payload are exonerated; the defect lives between the transmit fabric and the receive decoder pins. (Final review: the checker's interval counters are contaminated by corrupted-seq frames on RF legs — the period claim rests on the DDRCAP symbol-deletion census below, not on the checker.) Mechanism candidate: Peak_Search false-peak argmax theft (two_jup/comb/RX_WINDOW_RTL.md).

### 2026-09-04 05:2x — MECHANISM: one-sided symbol deletion in the RX valid chain at the inter-node SRO (≈2.5 ppm) [silicon]
TX_SEL8_DESK.md: TX clean; the receiver deletes one symbol per ~32 frames (2.57 ppm on 09-04 sel8, 2.51 ppm on 09-03 sel13), downstream of the interpolator (Symbol_Synchronizer → Correlator valid chain), lag-32 +0.82. The ≤ 0.06 ppm SRO bound is retracted (it counted post-deletion symbols). Comb period = 1/(12,333 × SRO). Fix: elastic symbol-rate handling (sample discard, not symbol deletion) or remove the clock offset; judge by the checker at the decoder pins + capture_r3 PER.

> **CORRECTION (2026-09-04, [netlist], `RATE_HANDLE_FIX_SURVEY.md`):** the 05:2x/06:3x entries in
> this file and in `OVERNIGHT_20260904_SEQBIST.md` describe Rate_Handle's 32-entry ring as
> "unguarded" and say the deletion happens "at an edge" without distinguishing which edge.
> `Validate_Input_Push_Pop_block.v:119-137` shows the ring IS guarded exactly at occupancy 0
> (empty) and 32 (full): the empty edge only skips a valid slot (no loss); only the full edge
> deletes a symbol. The one-sided deletion rate, period, and comb-period arithmetic above are
> unchanged — what changes is that "the ring deletes a symbol at its edge" is not yet established
> from the netlist; the deleting stage is being re-localised (Task 1, true occupancy/guard taps)
> between the Rate_Handle full edge and the Preamble_Detector realignment FIFO
> (`Preamble_Detector.v:321-334`, held permanently at its own full mark by an enb-tick-cadenced
> pop). *[correction 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]*
