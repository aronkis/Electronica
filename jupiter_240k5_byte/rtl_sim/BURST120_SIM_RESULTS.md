# 120-s periodic RX-DSP BER burst — netlist hunt (2026-08-28 evening, off-rig)

Hardware facts under test: 148 FPGA-internal loopback, ROM/BIST TX source: BIST errors burst
(~200 k / 10 s, ≈50 errors per frame, ≈3 s) at 33.6 s and 153.7 s after the arm (period 120.2 s);
framesync intact, carrier-reset count 0; same bursts with the daemon byte-plane source (garbage-header
frames) and on air; tracking cals, host, TX byte plane, RF excluded.

## 1. Free-running counters / accumulators in the flashed netlist (`s1_rtl_beatfix3`)

Rates: fabric clk 122.88/125 MHz; `clk_enable` = sample rate 61.44 MSPS; `enb_1_2_0` = 30.72 M (1-of-2
phase); symbols 15.36 Msym/s (sps 4); air frame = 12,333 symbol slots = 197,328 clks (0.8 ms).
Everything below is reset by the modem soft reset (0x000 pulse of the arm) — HDL Coder async `reset`.

| block (file) | register | width / type | rate | free-running? | wrap period | datapath effect of a wrap |
|---|---|---|---|---|---|---|
| Peak_Search | `timing_Reference_out1` | ufix14, counts 0..12332 per valid symbol | symbol | yes (mod 12333, the frame reference) | 0.8 ms (by design) | none by design; a slip between this and the TX frame period = E5 class |
| Peak_Search | `timing_Reference_Long_out1` | uint32 free-running | symbol | yes | 2^32/15.36e6 = **279.6 s** | telemetry only (`p1c_treflong`) — no datapath use |
| Timing_Adjust | `timing_Reference_out1` | ufix14 mod 12333 | symbol | yes | 0.8 ms | frame alignment reference |
| Integrator (CFE) | `HDL_Counter_out1` (Reset_Generator) | ufix13 0..4096 | enb_1_2_0 | yes | 133 µs | resets the 4th-power integrator window (by design) |
| Integrator (CFE) | `Integ_Reg_out1_re/im` | sfix32_En24, sum of 4097 inputs, **no saturation** (HDL Coder wrap) | enb_1_2_0 | window-reset | — | an overflowing window sum gives a wrong angle → wrong CFO estimate for one estimate (1/8 weight after Average_Estimates) |
| Average_Estimates | `Unit_Delay_Enabled_Resettable_Synchronous_out1` | sfix24_En13 (8-estimate sum) | per window | reset every 8 | — | CFO estimate applied to the DDS |
| Coarse_Frequency_Compensator / DDS | `Delay_out1` (freq word) | sfix40_En39 | — | no (held) | — | — |
| NCO (in DDS) | `accphase_reg` | sfix21 phase accumulator, inc = freq word[38:18] | enb_1_2_0 | yes | 2^21/inc samples (14.6 Hz per LSB) | natural 2π wrap — benign by construction |
| Carrier_Synchronizer / Loop_Filter_block | `Unit_Delay_Enabled_Resettable_Synchronous1_out1` | **sfix39_En39** integrator (range ±0.5, all-fraction) | symbol | integrates phase error; no saturation | wraps if it drifts to ±0.5 | a wrap flips the PLL frequency term → loss of carrier lock → BER burst until re-lock |
| Carrier_Synchronizer / Loop_Filter_block | `Unit_Delay_Enabled_Resettable_Synchronous_out1` | sfix29_En29 | symbol | — | — | proportional path |
| Symbol_Synchronizer / Loop_Filter_block1 | `Delay2_reg[0..1]` | **sfix40 integer** integrator | symbol | integrates TED error; no saturation | wraps at ±2^39 | timing-loop frequency term flips → symbol slips / BER burst |
| Symbol_Synchronizer / Interpolation_Control | `countReg`, `muReg` | sfix11 | sample | mod-1 NCO (by design) | per symbol | benign |
| Automatic_Gain_Control / Loop_Filter | `Delay2_reg_re/im[0..1]` | sfix34_En28 complex-gain integrator (±32) | symbol | integrates complex error; no saturation | wraps at ±32 gain | gain flips → BER burst until re-converged |
| RxAlign / FEC wrapper | `oc`, `skip`, `sk` | uint16 per frame | bit | per frame | — | frame-relative only |
| FEC wrapper / QPSK_Rx / Receiver | `cnt_*` (frame_start, vit_reset, deint_valid, dec_bits, descr_in) | uint32 | various | yes | 2^32/rate (hours) | telemetry only |
| Capture_Data_Bits (BIST) | `count_out`, `packets_out`, `bit_errors_out` | uint32 | bit/frame | yes | hours | telemetry only |
| RstCsCounter, PdTelemetry, FrameStat*, FecCounters, BeatObs/Bf* | counters/timestamps | uint32 | clk | yes | 2^32/125 MHz = **34.4 s** (clk-rate ones) | telemetry / byte-plane instruments — none feed the demod |
| TX: End_Generator | frame symbol counter | ufix14 0..12319 | symbol | yes (mod 12320) | 0.8 ms | TX frame period (12,320 symbols + preamble = 12,333 slots) |
| TX: Bit_Packetizer, HDL_Data_Scrambler | small counters / LFSR | — | — | per frame | — | — |

Numerology: no free-running counter in the DEMOD datapath has a 2^N wrap at 120.2 s (34.4 s = 2^32 clks
matches only the FIRST burst, and only telemetry/instrument counters run at clk rate; the 279.6-s
symbol counter is telemetry). A period that is not a power-of-two wrap of any native rate points to a
DRIFTING LOOP INTEGRATOR (rate set by a tiny residual bias, not by a clock) — the three unsaturated
integrators above (carrier-sync sfix39_En39, symbol-sync sfix40, AGC sfix34_En28) are the candidates
whose wrap would produce exactly "framesync intact, no carrier reset, ~3 s of BER 4e-3, then recovery".
The E5 slip (Peak_Search reference vs TX frame) is the fourth candidate (garbage-header frames, no bit-error
flood) — the ROM run's BIST error count (≈50/frame, not ≈6,000/frame) argues against a whole-frame misalignment.

## 2. Forced-state experiments (Verilator, `obj_burst` = `--public-flat-rw` of the flashed netlist, ROM/BIST loopback exactly as the hardware ROM run)

`sim_burst_force.cpp NF K sel prefix`: per decoded frame it logs BIST bit errors; at frame K the selected
register is forced to its wrap edge (cs: carrier integrator → +max; ss: symbol integrator → +max; agc:
gain integrator re → +max; integ: CFE window sum → +max; ps/ta: Peak_Search / Timing_Adjust reference +32).
Control = no force. Prediction if a candidate is the mechanism: BIST errors jump to ~50/frame right after
K and recover after ~3,700 frames (3 s of air) — the run length here (260 frames) can only show onset and
the first ~180 frames of the episode.

### Results (frames 83+ = after the force at frame 80; BIST bit errors per decoded frame; control = 0.0/frame throughout)

| sel | forced register | errors/frame after force | framesync | carrier resets | reading |
|---|---|---|---|---|---|
| none | — | **0.0** (132 frames) | ok | 0 | clean loopback baseline, as on hardware between bursts |
| cs | carrier-sync integrator sfix39_En39 → +max | — | **LOST: no frame decoded after the force (stuck at 81)** | 0 | a carrier-integrator wrap kills framesync → NOT the hardware burst (0x104 kept 1355/s) |
| ss | symbol-sync loop-filter error delay (sfix40 `Delay2_reg`, an error impulse into the timing loop; the real integrator `Delay6/Delay_out1` is CLAMPED by `IntegClamp`) | **59.9/frame** (47–68, jittery), persistent ≥ 34 frames | ok | 0 | **matches the hardware burst signature** (≈50/frame, framesync intact, no reset); no recovery within 0.3 s of air (hardware recovers after ~3 s — beyond this run) |
| agc | AGC complex-gain integrator re → +max | 0.0 | ok | 0 | no effect — AGC excluded |
| integ | CFE 4097-sample window sum → +max | one frame of 32 errors, then 0 | ok | **2** | a window-sum overflow = a CFO step + carrier reset — excluded (hardware rstcs stayed 0) |
| ps | Peak_Search frame reference +32 symbols | **48/frame constant**, persistent | ok | 0 | a reference/alignment shift gives the same magnitude class as the hardware burst, as a steady offset |
| ta | Timing_Adjust frame reference +32 symbols | **68/frame constant**, persistent | ok | 0 | same class |

## 3. Verdict

- The hardware burst signature (≈50 BIST errors per frame for ~3 s, framesync intact, no carrier reset) is
  reproduced ONLY by disturbances of the **symbol-timing / frame-reference plane**: a kick into the
  symbol-sync loop (ss) or a shift of the Peak_Search/Timing_Adjust frame reference (ps/ta). Carrier-loop,
  AGC and coarse-frequency-estimator overflows produce the wrong signature (loss of framesync, or a carrier
  reset) and are excluded.
- **No native free-running counter wraps at 120.2 s** (table §1): the recurrence is not a 2^N/clock wrap.
  The 34.4 s first occurrence matches 2^32 fabric clocks, but the only clk-rate 32-bit counters are
  telemetry/instrument counters with no demod fan-in. The period is therefore set by a slow DRIFT in the
  timing plane whose rate is fixed by a small constant bias (rounding/TED bias at exactly zero SRO — the
  loopback case — and the same bias plus the real SRO on air). The symbol-sync integrator is clamped
  (`IntegClamp` ±0x1EB852), so a classic integrator wrap is ruled out there; the remaining candidates are
  (a) the interpolator NCO / `countReg` accumulating a rounding bias until a symbol slip (E5 family:
  Peak_Search then latches a wrong `timingOffset`, Timing_Adjust re-aligns ~3 s later), (b) the
  carrier-loop integrator drifting toward its unclamped ±0.5 wrap slowly — excluded by the cs result
  (framesync would be lost, and it is not).
- **Leading mechanism: a periodic symbol-timing slip (E5 class) with a ~120-s period at zero SRO**, i.e. the
  same defect already localised on the reverse leg (`Peak_Search` +32 false `timingOffset` at negative SRO),
  now seen at its zero-SRO beat period. The 3-s recovery is Timing_Adjust/Peak_Search re-latching a correct
  offset on a later frame (`done`/`success` cycle), not a carrier reset.
- Not established by this sim (needs > 100 s of air = infeasible at 15 k clk/s): the drift itself and the
  recovery. Both are cheap to witness on hardware (below).

## 4. Cheapest hardware witnesses (zero-build, probe-4 image on 148, loopback ROM source)

1. **Timing-loop gain knob**: write `ss_integ_gain` (register 0x17C) to half and to double its default via
   DRA before the arm, repeat the 5-min BIST series. A drift-driven slip changes its period with the loop's
   integral gain (or vanishes at gain 0 if the integrator's bias is the driver); the carrier-loop knob
   `cs_integ_gain` (0x174) is the control and should not move the period. 10 min per point, no build.
2. **Peak_Search telemetry across a burst**: sample the PdTelemetry/p1c registers (`p1c_tref`, `p1c_heldts`,
   `p1c_runmax`, the latched `timingOffset` if mapped) every 1 s through a burst; a jump of `timingOffset`
   by ±1/±32 at burst onset and its return at burst end is the direct witness of the E5 mechanism.
3. **Reverse leg cross-check** (already have it): 146→148 reverse PER 1.39 % shows no 3 % burst component,
   which means 148's TX + 146's RX do not burst in that window — consistent with a receiver-side timing
   event whose phase/period differs per board and per arm.

## 5. Fix proposal (not built)

If witness 1/2 confirm the E5 slip: the reverse-leg E5 patch (accept a one-strobe-short frame in
`Timing_Adjust`/`Peak_Search` instead of latching the +32 offset; re-latch the reference on the next
`success` without waiting for a full `done` cycle) applies to both legs and would shorten the 3-s episode to
one frame. A/B it in the E5 tap harness (`wrap_byte_taps_e5.v` + `sim_byte_taps_e5.cpp`) on the −15 k
coupled stimulus first; only then a build. If witness 1 shows the period scaling with `ss_integ_gain`, the
additional fix is a leak (or a deadband) on the timing-loop integrator so a zero-SRO bias cannot drift it.

Runs: `burst_runs/<sel>_frames.txt` (columns: packet, BIST errors in that frame, clks since previous frame,
rstcs count, forced flag); driver `sim_burst_force.cpp`, model `obj_burst/` (flat-rw, `wrap_byte_bf2.v`,
`s1_rtl_beatfix3`). Build: `verilator -O2 -Wno-fatal --public-flat-rw -CFLAGS -O2 --cc wrap_byte_bf2.v -y
s1_rtl_beatfix3/hdlsrc/commhdlQPSKTxRxLoopback --exe sim_burst_force.cpp -Mdir obj_burst --top-module wrap_byte_ce`.
Trap hit twice: `pgrep -f` with the target string anywhere in the caller's command line kills the caller —
build the pattern from variables.

## 6. Re-target (coordinator, evening): the burst is bit-deterministic and gain/lineage independent → a fixed digital schedule

### 6.1 Deterministic schedulers / modulo-N counters in the flashed netlist (non-power-of-two periods)

f1536 profile from the netlist itself: TX frame = **12,333 symbol slots** (`End_Generator` counts 0..12319 = 12,320
data symbols + 13 preamble; `Data_Bits_FIFO` 24,640 data bits per frame, 2-frame RAM of 49,280 bits), **49,332 samples
per frame** (`Preamble_Detector` pop-delay shift register is exactly 49,332 deep at `enb_1_2_0` = one frame), so
sps = 4 and one frame = 49,332 samples = 0.8029 ms at 61.44 MSPS → 1245.5 frames/s (the ROM run's 1355/s framesync
count includes something the byte path does not; not resolved here). 120.2 s = 149,700 frames = 1.846e9 symbols =
7.385e9 samples.

| scheduler | modulus / length | rate | period | notes |
|---|---|---|---|---|
| Peak_Search / Timing_Adjust `timing_Reference` | 12,333 | symbol | 0.803 ms | frame reference |
| Preamble_Detector `FIFO` push/pop address counters | **12,333** | symbol | 0.803 ms | RAM AddrWidth 14 (16,384 words), wrap forced at 12,333 |
| Preamble_Detector `FIFO` occupancy counter (`Validate_Input_Push_Pop` / `MATLAB_Function_block1`) | **12,334** (0..12,333) | symbol | — | FULL = 12,333 (`Compare_To_Constant1`), EMPTY = 0 |
| Preamble_Detector pop = push delayed by `Delay10_reg` | 49,332 cycles | enb_1_2_0 | one frame | pop strobe pattern = push pattern one frame earlier |
| Reset_Generator (CFE integrator window) | 4,097 | enb_1_2_0 | 66.7 µs | beat with the frame: LCM = 4,097 frames = 3.29 s |
| Average_Estimates | 8 windows | — | 0.53 ms | beat with frame: 16,388 frames = 13.2 s |
| End_Generator (TX) | 12,320 | symbol | — | TX data length |
| Data_Bits_FIFO (TX) | 49,280 bits / 24,666 | bit | 2 frames / 1 frame | consistent with 12,333 |
| RAM_Frame_Status_Indicator (TX) | 24,640 | bit | 1 frame | consistent |
| Message_Generator (ROM source) `indexCount` | 24,640 | bit | 1 frame | ROM content per frame; no longer cycle found |
| TxInterleaveK5 / RxDeint | 1,537-row interleaver, 16-bit counters | bit | per frame | |
| Rate_Handle | 4 | — | — | sps phase |
| Phase_Ambiguity_Estimator | 8 | frame | 6.4 ms | |
| FrameStat*, PdTelemetry, FecCounters, BeatObs/Bf* | 32-bit saturating/free counters | clk/frame | 34.4 s (clk) … hours | observers only; lean image e49c011b (no Bf*) bursts identically → excluded |

No scheduler has a 120.2-s period, and no combination of the moduli above beats at 120.2 s (all frame-relative
beats are ≤ 13.2 s). The 34.4-s first occurrence measured from T0 (= scorer/DMA start, not the arm) is exactly
2^32 clk at 125 MHz — but the only clk-rate 32-bit counters are observers.

### 6.2 The mechanism that IS in the netlist: the preamble-detector delay FIFO runs exactly FULL and DROPS a symbol on any +1 occupancy excursion

`Preamble_Detector` delays the symbol stream by one frame through `FIFO` (RAM) whose pop strobe is the push
strobe delayed by exactly 49,332 sample cycles. Steady-state occupancy is therefore the number of symbol strobes
in the last 49,332 cycles = **12,333 = FULL** (confirmed in sim: `occ=12333` on every decoded frame of the
control run). `Validate_Input_Push_Pop` implements `push_on_full_FIFO = push & ~pop & (occ == 12333)` →
**`valid_push = 0`: the incoming symbol is silently discarded** (and the occupancy counter, modulus 12,334, would
wrap to 0 = EMPTY on the next increment, blocking pops). So whenever the symbol synchronizer delivers one more
strobe in a 49,332-cycle window than it delivered in the previous window — i.e. whenever the interpolator's strobe
phase advances by one full symbol relative to the sample clock — exactly **one symbol is deleted** at the
preamble-detector input. That is the E5 "symbol-deletion episode" already characterised on the reverse leg
(one strobe deleted every ~33 frames at 2.5 ppm SRO, Peak_Search then latching a +32 false `timingOffset`),
now seen at zero SRO: the residual strobe-phase drift of the fixed-point interpolator/timing loop in loopback
advances one symbol per **120.2 s**, and each deletion costs the ~3-s re-alignment episode
(Timing_Adjust/Peak_Search `done`/`success` cycle), with framesync intact and no carrier reset — exactly the
hardware signature. Deterministic and gain-independent: the deletion is a hard digital event; in a noise-free
loopback the strobe-phase drift is a deterministic limit cycle of the timing NCO (`Interpolation_Control`
sfix11_En10 quantisation), so the schedule and the corrupted frames (hence the bit-identical error counts) repeat
exactly across runs and images; only a change of profile/frame length would move it. On air the real SRO adds to
the same drift, so the period shortens (reverse leg: one deletion per ~33 frames at 2.5 ppm).

Why the first burst sits ~43 s after the arm while the period is 120.2 s: the occupancy starts at 0 at the reset
and fills to 12,333 in one frame; the first deletion occurs when the accumulated strobe-phase drift first reaches
one symbol, from whatever phase the timing loop settled at after lock — a fraction of a period, not a full one.

### 6.3 Forced-state runs for this mechanism (launched; results pending — nemo is saturated by the concurrent E5-fix A/B runs, ~1 frame per 100 s)

`sim_burst_force.cpp` selectors added: `fpush` (advance the FIFO push address by 1 = one extra symbol in the
RAM), `fpop` (advance the pop address = one symbol skipped), `focc` (occupancy set to FULL — a no-op in steady
state, confirms FULL is the resting point), `foccp1` (occupancy 12,334 = counter past FULL). The adjacent
E5-fix track already runs the direct deletion selectors (`slip1`, `slipm1`, `slip32`, `edge`, in
`e5fix_runs/orig_*` vs `fix_*` on `s1_rtl_e5fix` = patched `Peak_Search.v`); their per-frame BIST logs are the
definitive A/B for this mechanism and should be read when they pass frame ~100 (`e5fix_runs/*_frames.txt`,
columns: packet, BIST errors, clks, rstcs, forced, occ). Mine: `burst_runs/fifo_*_frames.txt`.

### 6.4 Cheapest hardware witness (zero-build, probe-4 image on 148, loopback ROM source)

`PdTelemetry` (already in the flashed lineage) streams a 7-slot record per preamble event containing
`fifoEnt` (the FIFO occupancy), `tOff` (latched timingOffset), `vPop`, `done/succ/newPk`, `runMax` on the IQ
debug mux (`iq_debug_mux` 0x10C). Capture the debug IQ across a burst window (the existing `capture_r3`
tooling) and decode the records: the prediction is `fifoEnt` = 12,333 steady, a push-on-full event (occupancy
excursion / `vPop` gap) at burst onset, `tOff` jumping by +32 (or ±1) for the burst duration and returning at its
end. That is a direct witness of the deletion + E5 re-latch, with no build.

### 6.5 Fix proposal (not built)

1. Give the delay FIFO slack: size the RAM/occupancy for 12,333 + margin (the RAM already has 16,384 words), set
   FULL at 12,333 + N with pop-before-push priority so a +1 strobe excursion is buffered instead of discarded; the
   one-frame delay is then 12,333 ± jitter, which Timing_Adjust already tolerates. One-module RTL change
   (`FIFO.v` counter wrap values + `Validate_Input_Push_Pop` constant).
2. Keep the reverse-leg E5 patch on `Peak_Search`/`Timing_Adjust` (accept a one-strobe-short frame; re-latch on
   `success`) so any residual deletion costs one frame, not ~3 s. A/B both in the same forced-`slip1` harness.

## 7. Overnight follow-ups (coordinator brief 22:xx): decoder, NCO-drift prediction, FIFO-slack A/B

### 7.1 `two_jup/sim_repro/pdtelemetry_decode.py` — PROVEN on the RTL module

Verilator TB `two_jup/sim_repro/tb_pdtel.cpp` (also `rtl_sim/tb_pdtel.cpp`, `obj_pdtel/`) drives `PdTelemetry.v` alone
with known fields (one symbol valid per 4 enb cycles = sps 4, then an idle stretch) and writes telI/telQ exactly
in the `iio_readdev` int16 I,Q interleaved format. Findings that change the pre-registration
(`two_jup/DELAYFIFO_WITNESS_PREREG.md`):
- **Emission order is s0, s2, s3, s4, s5, s6, zeros — the RTL skips slot 1** (dI/dQ is never on the stream). At
  line rate (4 enb cycles per symbol) each record carries only s0, s2, s3, s4: tRef, tOff, flags, taRef, accOff,
  fifoEnt, vPop, tRefLong, runMax. heldTs (s5) and beatCnt/symCtr (s6) appear only when symbols are ≥ 6 cycles apart.
- **`fifoEnt` is packed as 9 bits** (`& 511`): FULL = 12,333 reads **45**; a +1 excursion (12,334) reads **46**;
  the wrap-to-0 reads 0. P1 in the pre-reg must therefore be "fifoEnt = 45 on every record", P2 "a record with 46
  (or 0) and/or vPop = 0", not 12,333/12,334.
- `vPop` and the flags are sticky-OR over the symbol interval (`aVPop || vPop`), so a missed pop shows as vPop = 0
  on the record AFTER the interval in which no pop occurred.
- Decoder verified field-for-field on the synthetic stream: taRef/accOff/fifoEnt/vPop/tRefLong/runMax/heldTs/beatCnt/
  symCtr all recover the TB values; the tOff change point is reported at the right record; summary prints
  fifoEnt min/max/mode (with the 45 = FULL reminder), tOff values and change points, vPop = 0 record count.
  Usage: `pdtelemetry_decode.py capture.bin [--max N] [--csv out.csv] [--quiet]`.

### 7.2 NCO-drift prediction (Task 2) — what the netlist arithmetic allows, and what it does not predict

Timing NCO (`Interpolation_Control.v`): `countReg` is sfix11_En10 (1/1024 sample); each sample it is decremented by
`256 + Delta` (Delta = loop-filter output `v`, sfix11_En10, clamped to ±255/1024); on underflow a symbol strobe is
issued and `mu` = the fractional remainder ×4 (2 bits of headroom). With Delta = 0 the step is exactly 256/1024 =
1/4 sample → exactly 4 samples per symbol, zero drift by construction. Any drift therefore comes ONLY from the
loop-filter output: `v = K1·e + clamp(∫K2·e)` quantised to 1/1024, K1 = 0xFFD8 14E/2^25 ≈ −0.0129 (·2^-24 scaling of e),
K2 ≈ −0.0000041, integrator clamp ±0x1EB852/2^23 = ±0.24. In noise-free loopback the Gardner TED error `e` is a
deterministic function of the ROM data pattern and the sampling phase; a nonzero mean of `e` over the pattern drives
`v` to a nonzero quantised average `v̄` (units of 1/1024 sample per symbol), and the strobe phase then advances by
`v̄` per symbol. The delay FIFO drops one symbol per full-symbol excursion, so the period is

    T = (4096 / |v̄|_units) symbols / 15.36e6   →   T = 120.2 s  ⇔  |v̄| = 4096 / (120.2 × 15.36e6) = 2.2e-6 units

i.e. a mean `v` of 2.2 millionths of an LSB — a limit cycle in which `v` sits at 0 except for one −1-LSB (or +1-LSB)
sample every ~450,000 symbols (≈ 37 frames). That is arithmetically possible (the integrator path accumulates `e`
with K2 ≈ 4e-6 per symbol and the clamp/quantiser releases one LSB when it crosses a threshold) but it is not a
closed-form prediction: it depends on the TED bias for this ROM pattern. The sim measures it directly — `slack_score.py`
prints `cnt`/`mu` at every frame start; a +1-LSB step in `cnt` every ~37 frames (or an accumulated 5–6 LSB over the
200-frame runs) is the number to look for. Status at the time of writing: 14 frames in, `cnt`=773 `mu`=20 constant
in every run (no drift visible yet, consistent with ≤ 1 LSB per 37 frames). Result appended when the runs finish.

Rate-dependence constraint (BEAT_BISECTION_PLAN.md: 1245 f/s → 119.75 s; 341 f/s degraded → 6.7 s; 34 f/s → 37-s
bursts / 67 s): under this model the excursion cadence is set by the timing-loop bias, which is NOT a function of the
frame rate as such but of the received signal (SNR, SRO, TED self-noise). A degraded link at 341 f/s has real SRO
and a far noisier TED, so a much larger |v̄| — hence a much shorter period — is expected qualitatively, and a 34 f/s
link is re-acquiring constantly (each acquisition re-seats occupancy), which produces burst-like structure of its own.
So the constraint set is COMPATIBLE with a bias-driven strobe drift but is NOT PREDICTED by it in numbers; the model
does not give a single 1/rate law, and neither do the measurements. The FIFO-drop MECHANISM (a +1 excursion deletes a
symbol inside the delay path and shifts data vs marker) is independent of what drives the excursion — this is exactly
the split the pre-registration names: the fabric `pd_fifo_full_drop` counter must fire once per burst for the
mechanism; the trigger question is answered by whether the count of excursions scales with link state.
