# SIMULINK BEAT HUNT — does the ~120 s silicon error-burst beat reproduce in the model?

Status: IN PROGRESS (12 h prefix dwell running; launched 2026-08-18 14:45 EDT, ETA ~03:00 EDT 08-19)

## Question
Silicon (two boards, bit-identical, deterministic, reset-seeded), digital loopback,
ROM message source: fabric BER counter (Capture_Data_Bits `bit_errors_out`, AXI 0x108)
bursts every **119.75 s ± 1.5** (silicon frame period 803.2 us ⇒ **beat ≈ 149,100
f1536 frames**), burst duration 5–8 s, sizes quantized in two alternating species
(~293.2k / ~215.0k errors), quiet floor ~57–61 err/s (~0.05 err/frame), first burst
at arm + ~153 s (~frame 190,500). Framesync ~1256/s vs structural 1245.
Candidate mechanism: beat between frame-scale counters (Data_Bits_FIFO "count to
12332" vs End_Generator "count to 12319", delta 13); RTL sim shows a periodic
double-syncPulse.

**Invariant is FRAMES**: 1.5× period = **223,700 f1536 frames**.

## Methodology
- Model: `jupiter_240k5_byte/commhdlQPSKTxRxLoopback.slx`, assembled byte variant
  **frame=f1536, sps=4** (matches silicon: both sps4; model rail 15.36 MHz ⇒ model
  frame period = 12333 sym × 4 / 15.36e6 = **3.2117 ms**; silicon rail 61.44 MHz ⇒
  803.2 us. Same frame arithmetic, 4× time scale). 223,700 frames ⇒ StopTime ≈ 718.5 s
  model time.
- Runner: `jupiter_240k5_byte/sim_beat_f1536.m` (committed). Harness is the proven
  `sim_byte_gate_k5` run-D configuration (digital loopback, `tx_data_source=0` = ROM —
  the exact silicon config), with the gate's sim-only chart stubs (BIST msgdec disp
  removal; RxAlign 41→25) applied verbatim, and these long-dwell changes:
  - **No full-rate logging** (gate logs modulator symbols + byte_rx per beat — that
    would be O(100 GB) at this dwell). Instead: decimated logging (decimation 12333 ≈
    4 samples/frame at the 15.36 MHz rail) of cumulative `bit_errors_out`,
    `packets_out`, `cap_out`.
  - **syncPulse counter**: cumulative counter chart tapped inside the DUT copy at
    `Frequency and Time Synchronizer/Packet Controller/syncPulse`, logged decimated
    (`sync_count`) — the model-side analogue of the silicon framesync counter
    (structural rate 1.0/frame; silicon showed 1256/1245 ≈ 1.0088/frame).
  - **Data Bits FIFO sim-only assertions disabled** in the harness copy
    (`Bit Packetizer/Data Bits FIFO/No HDL/No HDL/Assertion{,1}`) — silicon has no
    assertion; a long continuous-feed run WILL hit the known +26 bits/frame fill drift
    (see `jupiter_240k5_byte/FIFO_DRIFT_FINDING.md`: overflow at ~frame 948 for f1536
    arithmetic) and the sim must keep going to expose whatever the overflow does to
    the air. Each assertion input is instead fed to a cumulative violation-beat
    counter (`fifo_ov_viol`, `fifo_un_viol`), logged decimated — a direct probe of
    the candidate mechanism.
- Per-frame CSV (`frame, cum_bit_errors, cum_sync, cum_packets, cum_fifo_ov_beats,
  cum_fifo_un_beats`) + .mat under `jupiter_240k5_byte/beat_run/` (data not committed).
- Sim-mode ladder: rapid → accelerator → normal; calibration = 200 frames, tic/toc.

## Calibration (2026-08-18)
- Sim-mode ladder result: **rapid accelerator** (first rung; built and ran clean).
- Command: `BEAT_CAL_ONLY=1 matlab -batch "run('.../sim_beat_f1536.m')"` (env
  QPSK_FRAME=f1536 QPSK_SPS=4 set inside the script).
- **200 frames in 2780 s wall = 0.0719 frames/s-wall** (tic/toc around `sim`,
  rapid build/warmup excluded). Note: a 5-frame warmup ran ~100x faster —
  pre-sync the receiver idles; the steady-state (post-sync) rate is the honest
  number and is what's quoted.
- Instrument sanity at 200 frames: bit_errors=51 (known startup/warmup garbage
  frame, then flat — matches gate run D), packets=198, sync_count=198 (exactly
  1/frame, zero extra pulses), fifo_ov_viol=fifo_un_viol=0, 800 log samples
  (4/frame as designed).

## Projection / launch decision
- 223,700 frames / 0.0719 f/s = **864 h wall (~36 days)** — far beyond the 20 h
  gate. Even one full beat period (149,100 frames) is ~576 h. **The silicon
  beat period is unreachable in Simulink at this model's throughput — stated
  plainly**: the 1.5x-beat dwell and the first-burst equivalent (~frame
  190,500) cannot be covered.
- Launched instead: the longest useful ~12 h prefix = **3,106 frames**
  (StopTime 9.976 s model time), `BEAT_FPS=0.0719` (calibration skipped),
  detached `setsid nohup matlab -batch ... & disown`, log
  `jupiter_240k5_byte/beat_run/sim_beat_f1536.log` (+ /tmp/beat_dwell.out).
- What the prefix CAN cover (per the RTL counter-survey in SIM_WEDGE_REPRO.md):
  the first Data-Bits-FIFO fill-to-full event (~frame 948 by the +26/frame
  drift arithmetic — the sim-only assertions are disabled and replaced by
  violation counters, so the run continues THROUGH it and shows what overflow
  does to the air), the predicted dbfw wrap/frame-boundary alignment (~frame
  1,890) and ~1.6 cycles of the 1,895-frame alignment period, and ~1 cycle of
  the 3,081-frame (12333-vs-12320 lcm) candidate. It CANNOT see the 12,320- or
  24,640-frame recurrences, the 149,100-frame silicon beat, or the first
  silicon burst.

## Results
TBD

## Verdict
TBD
