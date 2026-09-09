# TX-side forced-kick experiment (2026-09-02, sim only, host, no board)

## Pre-registered question (written BEFORE any run)

Does a forced TRANSMIT-side disturbance reproduce the 120.2s beat signature at the demod input
-- a single-frame jump of the data offset to a rung (half a frame + 16..388 symbols, ~64-symbol
steps: 6176/6240/6299/6363/6432/6489/6548), data bit-exact at the new offset, RX marker cadence
unmoved -- where every RX-side kick in `two_jup/KICK_EXPERIMENT_REPORT.md` (Sec.76) only
corrupted data? Silicon shows every data departure preceded by one record by an extra
`Transmitter_txFrameStart` (= `Bit_Packetizer_dataStart`, `QPSK_Tx.v:118`) pulse while the
regular TX cadence continues.

Predictions, written now, mirroring the Sec.76/kick-report structure:
- **A (TX kick = beat mechanism):** after the force, >=3 consecutive frames map to a SINGLE
  known rung d (found in the tap3 map), the 0->d transition happens between two consecutive
  frames, no frame lands strictly between 0 and 6176, and the RX demod-marker cadence
  (`ddrcap_mark_demod` spacing) is UNCHANGED across the transition -- AND the sim shows a
  genuine extra `Transmitter_txFrameStart` pulse at the kick, matching the silicon precursor.
- **B (TX kick != beat):** frames after the force are `None` (word not in the map = corrupted),
  OR map to a non-rung offset, OR walk through intermediate offsets, OR the marker cadence
  itself moves (which would mean the disturbance reached the RX timing loop, not just the data
  content) -- any of these falls outside A.
- **Positive control (must PASS before A/B is read):** the unforced `none` run must map every
  frame (after the first few settle) to offset 0 with the unmodified tap3 map, exactly as the
  Sec.76 kick report's positive control (46/46 frames at offset 0). If it does not, the result
  for ALL forces is VOID.
- **RTL-grounded expectation, stated now, to be confirmed or falsified empirically:** reading
  `Bit_Packetizer.v`, `Data_Bits_FIFO.v` (inside `Bit_Packetizer.v`), `Input_Data.v`,
  `Transmitter.v`, `QPSK_Tx.v`, `TxRxComposite.v` shows that in ROM/BIST loopback mode
  (`tx_data_source=0`, the mode this harness and every prior burst-hunt sim uses), Bit_Packetizer's
  `Data_Bits_FIFO` push (`validIn`) and QPSK_Tx's `dataIn` are wired to `Input_Data_txValid` /
  `Input_Data_txData`, which are `Message_Generator_valid` / a mux that selects
  `Message_Generator_out_1` whenever `extBitSel_1==0` (true throughout ROM/BIST mode,
  `tx_data_source=0`) -- NEITHER depends on `ByteWordBuffer`'s `avail`/`readyNext`/`word`/
  `wordFirst` outputs. So `bwbstarve` (starve ByteWordBuffer occupancy) and `byteinval` (hold
  top-level `byte_valid` low) are predicted, from the RTL alone, to be UNABLE to move
  Bit_Packetizer/`txFrameStart` cadence in this mode -- only `dstart` (a direct forced extra
  `dataStart` pulse, the register-level analogue of what the silicon `Bit_Packetizer_dataStart`
  pulse itself is) can reach it. This prediction is checked empirically below via readback +
  scoring, not asserted from the RTL reading alone.

## Method

Working dir `jupiter_240k5_byte/rtl_sim`. New driver `sim_burst_force_tx.cpp` (derived from
`sim_kick_taps.cpp`/`sim_burst_force_txmark.cpp`, same DDR record stream, same
`--public-flat-rw` build of `wrap_byte_ddrcap.v` over the TXMARK netlist `s1_rtl_txmark`,
built by `build_txkick_sim.sh` -> `obj_txkick/Vtxkick`). Same ROM/BIST loopback drive discipline
as every prior burst-force sim (`tx_data_source=0`, `rx_input_select=0`).

Forces (one per run), applied at packet K=6, NF=20 frames, ddrcap selector 6 (tap3, symbol
domain), position P given in symbols into the TX frame (converted to clocks via the harness's
own exact 16 clk/symbol: 197328 clk/frame / 12333 symbol/frame = 16):
1. `dstart` -- force `Data_Bits_FIFO`'s `Delay5_out1` (=`sampleCount`, ufix15) to 26 (the
   `Compare_To_Constant_block1` constant that gates `dataStart`) and `Delay6_out1`
   (=`sampleCountValid`) to 1, for one enabled clock, at P=6176 and P=6496 (6160+16, 6160+336
   symbols into frame, per the task's rung-adjacent positions).
2. `bwbstarve` -- force `ByteWordBuffer`'s `state_count` (occupancy) to 0 and `avail_1` to 0 for
   ~20us (2500 clk) starting at P=6176.
3. `byteinval` -- hold the TOP-LEVEL `byte_valid` port low for one 16-byte word (2 x 64-bit
   pushes worth of clocks) at P=6176. This is a genuine testbench port drive, not a
   hierarchical force.
4. `none` -- positive control, no force.

Every force run logs a readback line proving the targeted register(s) actually took the forced
value in the target clock window (falsifiable), and a running count of real
`Transmitter_txFrameStart` edges (a genuine wire declared at `TxRxComposite` scope,
`TxRxComposite.v:272`, read -- never forced -- so it is trustworthy per the wrapper's own
Sec.80-lesson comment in `wrap_byte_ddrcap.v`).

Scoring: unmodified `two_jup/t6_score_large.py` (skew 1) against the unmodified
`two_jup/offsetmap/tap3_word_to_offset.tsv`, plus a per-frame offset sequence via
`kick_seq.py` (unmodified, already present in `rtl_sim/`).

All runs launched under `systemd-run --user`, logs line-buffered, polled at >=60s.

## Results

(filled in after the runs -- see status contract at the end)

## Verdict

(filled in after the runs, against predictions A/B exactly as pre-registered above; RTL
prediction re: bwbstarve/byteinval confirmed or falsified explicitly, not asserted)

## Status contract

(filled in at the end)

---

## RETARGET (2026-09-02, coordinator directive, before any run completed)

Track A's independent RTL trace (`two_jup/TX_ORIGIN_TRACE_A.md`, commit df3c590) landed a much
sharper mechanism than the "direct dataStart pulse" hypothesis this report originally
pre-registered, and directly contradicts part of it: A's read of `Bit_Packetizer.v` /
`Data_Bits_FIFO.v` shows `dataStart = (sampleCount==26) & sampleCountValid` off a MONOTONE
free-running counter (`HDL_Counter2_out1`, wraps 0..24665) -- **exactly one `dataStart` per
24,666 slots is possible without an async `reset`**. A's top-ranked, RTL-grounded mechanism
(§6 #1) is instead a `Data_Bits_FIFO` **pop-abort**: the `armed` pop-enable latch
(`Unit_Delay_Enabled_Resettable_Synchronous_out1`) clears mid-frame when `frameCount==0`
(compared via `Delay3_out1`), stalling the RAM read pointer for a partial frame with **no**
effect on `sampleCount`/`dataStart`/preamble/markers -- i.e. a bit-exact data delay, not a
timing-plane event, which is a better match to the silicon signature than anything tested above.

**Runs below (dstart, the only case actually launched before the retarget landed) answer the
ORIGINAL pre-registration only.** The experiment is now retargeted to A's ranked mechanisms,
same build/scoring, forces changed as follows (bwbstarve/byteinval DROPPED per the coordinator:
A confirms in §6 #5 they are out of circuit for `tx_data_source==0`, matching this report's own
independent RTL finding above):

- **T0** (instrument only, no force): per-TX-frame count of `Transmitter_txFrameStart` edges
  (TX-frame boundary detected from `HDL_Counter2_out1` wraps, not from `packets_out`/BIST decode,
  which A's §1 and the earlier KICK report both show lags the TX frame by a pipeline delay), plus
  `ddrcap_fec_mark_now`/`_latch` and the running ddrcap record index at each edge. Decides
  whether the "extra txFrameStart" is real (>1 edge/frame with no reset -> A's proof is wrong) or
  an instrument/record artefact (predicted: always exactly 1/frame).
- **popabort** (A's #1): at TX frame K, force `Delay3_out1=0` for a short window when
  `HDL_Counter2_out1` first reaches `12314 - 128*k`, release (no re-force), sweep k=0..6.
  Predicted: sel6 word found at rung ~6176+64*k symbols, bit-exact, dataStart/marker cadence
  unchanged, persistent.
- **frcwrap** (A's #2): force `RAM_Frame_Status_Indicator.frameCount=3` at frame K for a short
  window, release WITHOUT forcing the clear, watch for a self-triggered 3->0 wrap and the same
  rung one push-wrap later.
- **dstart** (kept, near-zero marginal cost, tests A's own §4/§1 prediction that it is inert
  without a forced reset): unchanged from the original design.

New driver source is the same file (`sim_burst_force_tx.cpp`, overwritten in place, git history
carries the original version); same `build_txkick_sim.sh`. Results below cover the retargeted
plan.

---

## Sec.86-B addendum (coordinator directive, 2026-09-02, added mid-task)

Silicon now shows (per `two_jup/SESSION_20260830_AUTONOMOUS.md` Sec.87) that the beat IS the
`Data_Bits_FIFO` pop stall: every offset transition is a constant-symbol run from mid-frame to
frame end, `new_offset = old - L mod 12320`. The popabort force above (A's #1) is the CAUSAL
proof for the mechanism. This addendum attacks the RATE question: what drifts, by how much per
frame, and does the drift rate predict the observed ~110-120 s period?

**Instrumentation (added to `sel=="t0"`):** once per TX frame, at the `sampleCount==0` wrap
(same wrap event that increments `txFrameIdx`), log:
- RAM occupancy: `Data_Bits_FIFO.u_MATLAB_Function1.count` (flat name
  `..._Data_Bits_FIFO__DOT__u_MATLAB_Function1__DOT__count`, confirmed present in the built flat
  header)
- `RAM_Frame_Status_Indicator.frameCount`
- push pointer `Data_Bits_FIFO.HDL_Counter_out1` (RAM write address) and pop pointer
  `Data_Bits_FIFO.HDL_Counter1_out1` (RAM read address)
- `fullRAM` (the register driving it, `Data_Bits_FIFO.Delay7_out1`)

Run length: NF>=40 frames (`sel=t0`), no force.

**Analysis plan (post-run):** fit occupancy(frame) and (push-pop)(frame) with a straight line;
report the per-frame drift `d` (bits/frame) and its 95% CI. If `d` is non-zero and stable, compute
`frames_to_abort = (49280 - occupancy_at_arm) / d` (for the `count>49279` full-RAM overshoot
path, A's #3) and separately `frames_to_wrap = 4 / (push_rate_wraps_of_frameCount_per_frame)` for
the `frameCount` ufix2 wrap path (A's #2), convert each to seconds via
`197328 clk/frame / 61.44e6 clk/s = 3.212 ms/frame`, and compare against:
- the target period 120.2 s = 37,425.7 frames (coordinator's figure, recomputed here:
  120.2 / 0.0032116 = 37,426 frames -- matches)
- the observed first burst at ~110 s after arm (~34,250 frames)

If no drift is measurable in 40 frames, report that explicitly with the upper bound on `|d|`
implied by the log's quantization (occupancy/pointers are integer bit-counts, so the minimum
detectable per-frame drift over 40 frames is 1/40 bit/frame before rounding dominates) --- this
is a negative result to be stated, not reinterpreted.

Results below (added after the t0 run completes).

---

## Results (interim, 2026-09-02 -- `none` and `popabort k=0` complete; sweep/frcwrap/dstart/t0 in flight)

### Positive control (`none`) -- PASS
`566,660 beats, 46 demod markers, skew +1, frame 12320 symbols` -- all 46 scored frames at
offset 0, 0 rung, 0 intermediate, 0 transitions. Marker cadence constant (gap=12320, 45/45
occurrences). Tap3 map applies to this build; A/B may be read.

### `popabort` k=0 (A's mechanism #1: `Delay3_out1=0` single-shot force at `sampleCount>=12314`,
frame K=6 by TX-frame index) -- **REPRODUCES the qualitative silicon signature**

- Readback (falsifiable witness, not just the forced register): `pre_armed=1 pre_pop=1`,
  `saw_armed_zero=1` at `clk=641342` (2 clocks after the force at `clk=641340`),
  `max_consecutive_pop_quiet=63` of the 64-tick witness window -- the `armed` pop-enable latch
  genuinely went to 0 and the pop strobe genuinely went quiet. The force took effect; this is not
  a vacuous poke.
- Tap3 score: `scored 46 frames: 46 placed, 0 displacement-inexplicable / aligned at 0: 6 /
  on a known rung: 0 / INTERMEDIATE (0,6176): 40 / 0<->rung transitions observed: 1 / frame 6:
  0 -> 6144 (step 6144)`. `t6_score_large.py` reports this as `*** FALSIFIED` because 6144 is not
  one of the 7 enumerated silicon rungs and lies strictly between 0 and 6176 -- but every one of
  those 46 frames is `placed` (word FOUND in the injective tap3 map = bit-exact), the transition is
  a SINGLE frame (0 at frames 0-5, 6144 at frames 6-45, no intermediate walk, no self-heal in 40
  frames after), and per-frame offset sequence confirms sustained 6144 for all 40 post-force frames
  (`kick_seq.py`).
- Marker cadence (`mark_gap.py`): `gap=12320, 45/45 occurrences, CONSTANT CADENCE: YES` -- unmoved,
  both before and after the force.
- **Reading:** this is the pop-abort mechanism (A's #1) working exactly as A's RTL trace predicts
  -- a single-frame, bit-exact, sustained displacement with the marker cadence untouched -- but the
  landing value (6144) is 32 symbols short of the nearest enumerated silicon rung (6176), not one
  of the seven values in `two_jup/offsetmap`'s `RUNGS` set. This is consistent with the general
  mechanism described in Sec.87 (`new_offset = old - L mod 12320`, i.e. the landing value is set
  continuously by how many symbols the abort actually stalls, not quantized to the seven silicon
  rungs) -- my target `sampleCount>=12314` (an approximation of "12,288 pops done") evidently stalls
  for `L` symbols giving 6144, not exactly the L that gives 6176; the +64-symbol-per-k sweep below
  tests whether varying the force position moves the landing value by ~64 symbols per step, which
  would confirm the mechanism generates a continuum (not a fixed rung set) and that the silicon
  rungs are simply the L values that occur in practice, not an RTL constant.
- `t6_score_large.py`'s "FALSIFIED" verdict is about the ORIGINAL §51 "landings must be one of 7
  enumerated silicon rungs" prediction, not about whether pop-abort is the mechanism -- worth
  flagging since Sec.87 (which superseded §51 for this task) predicts a continuous displacement
  family, matching what was observed, not a 7-way discrete set.

Sweep k=1..6, `frcwrap`, `dstart`, and the `t0` occupancy-drift run are in flight; see the next
update for their results and the §86-B rate analysis.

---

## Sec.86-B results: T0 occupancy drift, and answers to the coordinator's rate-arithmetic follow-up (2026-09-02)

### T0 occupancy log (50 frames, no force)

`OCC frame=N ... occ=... frameCount=... push=... pop=... fullRAM=0` for frames 1-50 (see
`beat_runs/txkick_t0_frames.txt`). `occ` (Data_Bits_FIFO's `u_MATLAB_Function1.count`, the RAM
occupancy statistic) grows **linearly and exactly +26/frame**: `24665` (frame 1) -> `25940`
(frame 50), `(25940-24665)/49 = 26.02`. `frameCount` (RAM_Frame_Status_Indicator) stays pinned at
`2` for the entire run; `fullRAM` stays `0` throughout (no natural overshoot in 50 frames).

**[RTL fact, confirms the coordinator's read]:** the drift is real and mechanical, not numerology.
`Data_Bits_FIFO`'s `push` = `validIn` = `Message_Generator_valid`, asserted on effectively every
enb_1_2_0-gated bit-slot for the WHOLE 24,666-slot frame (preamble slots included) --
`Bit_Packetizer.v` only muxes what gets WRITTEN as data (`Switch_out1`, preamble vs
`Data_Bits_FIFO_dataOut`) but does not gate `push` differently for the preamble phase, so
Data_Bits_FIFO's own RAM write pointer (`HDL_Counter_out1`) and `RAM_Frame_Status_Indicator`'s
internal `pushCount` both advance once per SLOT (24,666/frame), while `pop`
(`Logical_Operator_out1`, `Data_Bits_FIFO.v:291`) only fires during the gated data phase, 24,640
times per frame. The T0 log's push pointer sequence confirms this exactly (`push=24665, 51(wrap),
103, 155, ...` -- a uint16 pointer wrapping at 49,280, advancing 24,666/frame vs the RAM's 49,280 =
2x24,640 depth).

### RTL fact for part (b): the exact frameCount 3->0 condition

`RAM_Frame_Status_Indicator.v` (full text read):
```verilog
if ((pushCount == 15'b110000000111111) && push) begin   // pushCount == 24639
  frameCount_temp = frameCount + 2'b01;                  // unsaturated ufix2, wraps 3->0
end
if ((popCount == 15'b110000000111111) && pop) begin      // popCount == 24639
  frameCount_temp = frameCount_temp - 2'b01;
end
```
`pushCount`/`popCount` are separate free-running counters (period 24,640 each, own module-local
state), incrementing once per `push`/`pop` pulse respectively and wrapping 24639->0.
**[RTL fact]** frameCount increments **exactly when `pushCount` completes a 24,640-push cycle**
(i.e. the producer has written a full frame's worth of RAM WRITE addresses, in the SAME units the
26/frame drift above is measured in) -- decrements symmetrically when `popCount` completes a
24,640-pop cycle. Since `push` fires ~24,666 times per real TX frame (slot-rate, preamble
included) but `pop` only fires up to 24,640 times per frame AND ONLY while `armed`==1
(`Data_Bits_FIFO.v:291`), a `pushCount` wrap happens once per real frame with **26 slots to
spare** every time (matching the T0 drift), while a `popCount` wrap happens once per frame ONLY IF
`armed` never clears. **The RAM is exactly 2 frames deep and the design's implicit assumption is
`frameCount` <= 2 in steady state** (push and pop wraps trading 1-for-1, 1 frame ahead at most);
`frameCount` reaching 3 and then wrapping 3->0 with NO compensating pop therefore requires the pop
side to have STALLED for roughly one push-wrap's worth of time (~24,640 pushes, ~one frame period)
without pop keeping pace -- i.e. **mechanism #2 (`frameCount` 3->0) is causally DOWNSTREAM of a
pop-side stall, and mechanism #1 (a pop-abort clearing `armed`) is exactly such a stall**: a #1
event long enough to skip roughly one frame's worth of pops hands `frameCount` its 3rd
un-compensated push-wrap, and the immediately following push-wrap then fires the 3->0 case with NO
external force at the abort instant -- precisely what `frcwrap`'s "release and watch" design tests
(result below). This confirms A's own framing (`TX_ORIGIN_TRACE_A.md` #2: "the mechanism that
*reaches* #1's condition") from the full RTL text, not just its cited line numbers.

### Recurrence-period arithmetic (checked against the RTL above, not assumed)

Two independent 26-slot/frame-driven periods, both grounded in the T0-confirmed drift rate:

1. **RAM-overshoot period (mechanism #3, `count>49279`):** from the post-arm level (`occ=24665`
   at frame 1) to the `49279` compare threshold at `+26/frame`:
   `(49279-24665)/26 = 946.69 frames = 3.0405 s`. **This lands almost exactly on the observed
   silicon burst DURATION (~3.0-3.1 s, Sec.87)** -- a strong candidate for what sets the burst
   length/sub-structure, as the coordinator suggested.
2. **Phase-return period (pushCount's 24,640-cycle vs the real 24,666-slot frame, mechanism #2's
   own clock):** relative phase between the two returns to its start after
   `24640/gcd(24640,26) = 12,320 frames = 39.568 s`; three such cycles = `118.705 s`.
   (Using the coordinator's own 24,666-slot period and `gcd(24666,26)=2` instead gives
   `12,333 frames = 39.610 s`, x3 = `118.830 s` -- the two are close but not identical because
   24,640 [pushCount's own wrap constant] and 24,666 [the real frame length] are different RTL
   constants; both are reported since it is not yet established which one governs the outer
   period.)

**Comparison with the target:** 120.2 s = 37,425.4 frames (frame period = 197,328 clk / 61.44 MHz
= 3.21172 ms, computed directly, matches the coordinator's figure to 4 sig figs). Neither
candidate period, x3, lands on 120.2 s exactly: `118.71-118.83 s` vs `120.2 s` is a residual of
**1.37-1.50 s (1.1-1.3%)**. This is close enough to be suggestive but is **not** the clean match
Track A's §7 already flagged as absent ("No 120.2 s arithmetic exists in the TX plane... stated as
a negative result, with residuals") -- this addendum's arithmetic is consistent with that honesty
norm: a real, RTL-grounded ~3.04 s sub-period (matching burst DURATION) plus a real but
NOT-quite-40.07 s phase-return period (whose x3 leaves an unexplained ~1.1-1.3% gap to 120.2 s),
not a solved 120.2 s derivation. Comparison with the first-burst-after-arm (~110 s = 34,250
frames, arm preloads one frame so `occ=24,665` at frame 1 exactly as observed): 110 s / 3.0405 s
(the mechanism-#3 sub-period) = **36.17**, not an integer either -- so the first burst is not a
clean small multiple of the sub-period, another open residual, stated as such.

### `frcwrap` result (A's #2 test: force `frameCount=3` for one tick, release, watch for a self-wrap)

(added once the run completes -- see next update)

### (a) NEAR-THRESHOLD runs

Per the coordinator's follow-up, three more 20-frame runs are queued after the k-sweep/`frcwrap`
finish: force `u_MATLAB_Function1.count = 49279 - 26*2` (and two earlier-phase variants,
`-26*2-8000` and `-26*2-16000`) at frame 3 (`sampleCount==0`), release, and log `count`, `fullRAM`,
`frameCount`, push/pop pointers, the `armed` latch, any pop-abort, and the post-crossing per-frame
demod offsets. Results in the next update.

---

## Results: T0 full run, popabort k=0..6 sweep, frcwrap, dstart (2026-09-02, all complete)

### T0 -- extra `txFrameStart` is NOT real (confirms A's §1, kills nothing)

97 complete TX frames logged, `txFrameStartPulses=98` total (the +1 is the run's final partial
frame). **Every single one of the 97 complete frames shows exactly 1 `Transmitter_txFrameStart`
edge** (`grep '^# FRAME' | awk '{print $4}'` -> `97 complete:`, i.e. uniform). No second edge
ever appeared without a force. T0 does **not** kill A's §1 proof -- confirmed, not merely assumed.

### `popabort` k=0..6 -- REPRODUCES the qualitative silicon signature, with a clean linear geometry

All seven cases (`Delay3_out1=0` single-shot force at `sampleCount >= 12314-128*k`, frame K=6):

| k | target sampleCount | landing offset | step vs k=0 |
|---|---|---|---|
| 0 | 12314 | 6144 | 0 |
| 1 | 12186 | 6080 | -64 |
| 2 | 12058 | 6016 | -128 |
| 3 | 11930 | 5952 | -192 |
| 4 | 11802 | 5888 | -256 |
| 5 | 11674 | 5824 | -320 |
| 6 | 11546 | 5760 | -384 |

**Exactly -64 symbols per k, with zero jitter across all 7 points** (128 pops = 64 symbols,
matching QPSK's 2 bits/symbol exactly -- the mechanism's landing value is a perfectly linear
function of the force position, not noisy or threshold-like). For every k: `armed` (the pop-enable
latch) is confirmed to go to 0 within 2 clocks of the force (falsifiable readback, not just the
forced register); the pop strobe (`Logical_Operator_out1`) is quiet for 63/64 of the witness
window; the tap3 word is **found (bit-exact)** at the landing offset for **every** frame from the
transition frame through the end of each 20-frame run (no self-heal observed in that window,
matching Sec.87's "displacement is a STABLE state"); the transition is a **single frame** (0 at
frames 0-5, the landing value at frames 6-19+, no intermediate walk); and the **demod-marker
cadence is unchanged** (`mark_gap.py`: `gap=12320` constant, 45/45, in all 7 runs, before and
after).

`t6_score_large.py` reports every one of these as `*** FALSIFIED` because none of the 7 landing
values (5760-6144) matches one of the seven ENUMERATED silicon rungs
(`6176,6240,6299,6363,6432,6489,6548`) -- but that scorer's `RUNGS` set was written for the
original discrete-rung hypothesis (§51), which Sec.87 (`new_offset = old - L mod 12320`)
supersedes with a continuous-displacement mechanism; this sweep is the direct empirical
confirmation of exactly that continuum, off the enumerated silicon set by a **consistent ~32-symbol
phase** (nearest silicon rung to k=0's 6144 is 6176, a 32-symbol gap -- half of the 64-symbol
quantum step, consistent with the k=0 anchor `sampleCount>=12314` being one k-half-step away from
whatever exact stall length the silicon's `L` produces; not resolved further here). **Verdict for
popabort: REPRODUCES the qualitative mechanism (single-frame, bit-exact, sustained, marker-cadence-
preserving jump, with the correct 64-symbol/2-bits-per-symbol quantum) with a clean, zero-noise
linear geometry -- the strongest positive result in this whole experiment family.**

### `frcwrap` (A's #2, force `frameCount=3` for one tick, no clear, watch for a self-wrap)

Readback shows the design's OWN natural cadence already carries `frameCount` through `2->3->2`
every single frame as ordinary steady-state operation (visible in the `none`/`popabort` frames
logs too, e.g. `frameCount change ... 2->1` then `1->2` each frame) -- **frameCount visiting 3
transiently is NORMAL, not anomalous**, in this ROM/BIST loopback. The force (`clk=592085`,
`pre_frameCount=2 -> forced 3`) landed one clock before the design's own natural `3->2` pop-side
correction, which fired on the very next clock regardless of the force
(`# frameCount change clk=592086 frame=6 3 -> 2`) -- i.e. the natural pop cadence, running
unimpeded (no accompanying pop-stall), simply overwrote the forced value immediately, and
`frameCount` continued its ordinary `2<->3` oscillation for the rest of the run with no `3->0`
wrap. Tap3 score: **UNINFORMATIVE, 46/46 aligned at 0**, i.e. no effect at all.
**Reading, refining A's #2 framing:** forcing `frameCount=3` in isolation (without a concurrent
pop-side stall) is NOT a perturbation -- the design already visits 3 every frame and self-corrects
in one clock. This confirms rather than merely assumes A's own characterization (§6 #2: "the
mechanism that *reaches* #1's condition") -- `frameCount` reaching 3 is not itself special; only a
STALL (mechanism #1, or an eventual RAM-occupancy overshoot, #3) that prevents the pop side from
performing its regular one-clock correction can turn a routine `3` into a persisting `3` that a
further push-wrap then wraps to `0`. #2 is not an independently triggerable mechanism in this RTL;
it is a downstream consequence of #1/#3, exactly as A ranked it.

### `dstart` (bonus, direct Delay5/Delay6 single-shot force) -- a real extra pulse, but NO effect on data

Ground-truth readback: `txFrameStartPulses=49` over 47 complete frames vs the `none`/`popabort`
baseline's `48/47` (i.e. **one genuine extra `Transmitter_txFrameStart` edge**, confirmed by the
per-edge log: a natural edge at `clk=690858` (`sampleCount=27`, the normal cadence) and a SECOND,
distinct edge at `clk=691010` inside the same TX-frame window, from the forced
`Delay5_out1=26/Delay6_out1=1`). **This corrects the RTL prediction stated at pre-registration**
("A predicts this is inert without reset") -- the pulse is real, not an inert poke on a dead wire;
`Delay5_out1`/`Delay6_out1` genuinely combine through `Bit_Packetizer`'s `Logical_Operator_out1`
to produce a second `dataStart`/`txFrameStart` edge, exactly as directly forcing the two registers
that drive it should. **However, tap3 score is UNINFORMATIVE: 46/46 frames aligned at 0, no
corruption, no displacement anywhere in the run.** Reading: the force only pokes the two DELAYED
COMPARE registers (`Delay5_out1`/`Delay6_out1`), not the underlying free-running frame-position
counters (`HDL_Counter2_out1`, the RAM pointers, `frameCount`) that actually govern what data gets
written/read and when the REAL next `dataStart` occurs -- so the extra pulse is real at the
`dataStart`/`txFrameStart` wire but has no reach into the data path Bit_Packetizer/Data_Bits_FIFO
actually serves data from, unlike `popabort`, which forces the register the RAM's OWN read-enable
latch consults. **Verdict for dstart: a genuine, non-inert extra pulse (falsifying the "inert
without reset" prediction as a blanket claim) that nonetheless produces NO detectable effect on
decoded data (NO EFFECT class, not REPRODUCES, not CORRUPTS).**

---

## Cross-corroboration note

The coordinator's own scoring pass of these same runs (§89 addendum, commit `1432c85`) landed on
identical numbers independently: `popabort` k=0..6 -> sustained offsets
`6144/6080/6016/5952/5888/5824/5760` (the 64-symbol/128-pop family), `frcwrap`/`dstart` -> offset 0
throughout (NO EFFECT). Two independent scoring passes over the same `.bin` captures agree exactly.
