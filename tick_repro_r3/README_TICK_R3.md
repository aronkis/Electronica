# Reproducing a timing insertion at R3 (61.44 MSPS / f1536) in Simulink

Companion to `../tick_repro/` (the 240k board-148 +256-sample tick), adapted to
the **higher-rate R3 rung**: 61.44 MSPS SSI, sps=4, 15.36 Msym/s, f1536 frame.
Same structure — raw capture + modem state + a Simulink testbench that injects a
timing insertion and shows the receiver's frame-offset step.

## Important scope note (read this)

The periodic +256-sample **device tick is a 240k / board-148 phenomenon.** This
session's fresh per-frame R3 telemetry (`two_jup/r3cap/`, `frame_taxonomy.py`)
did **NOT** find the periodic tick at R3 — the R3 losses were:
- **forward 146→148 ~14%**: sustained, CFO-stable → **146 TX-EVM margin**;
- **reverse 148→146 ~21%**: bursty, strongly CFO-dither-correlated → **146 RX
  carrier-tracking instability**.

So this package is **not** a claim that the tick recurs at R3. It reproduces the
receiver's **response to a timing insertion at the R3 geometry** — the analogous
displacement, useful for debugging the higher-rate FTS/Preamble Detector in
Simulink and for asking "what would a sample insertion do at R3?". The +32-symbol
displacement the 240k tick causes maps, at sps=4, to **128 samples** (vs 256 at
sps=8); the testbench defaults to the same **+32-symbol** processing-domain
effect and lets you set any value.

## Modem state (set the Simulink R3 RX up with exactly these)

| Quantity | Value | Source |
|---|---|---|
| Symbol rate `Rsym` | 15.36 Msym/s (61.44 MSPS / 4) | `evm/evm_config_1536k.m` |
| Samples/symbol `sps` | 4 | R3 rung |
| Sample rate `Fs` | 61.44 MHz | `Rsym*sps` |
| RRC | `rcosdesign(0.5, 4, 4)` (β=0.5, span=4) | stock sps4 design point |
| Preamble | 13-bit Barker, π/4-Gray QPSK (unchanged) | `commhdlQPSKTxRxParameters` |
| `DataBitsPerPacket` | 24640 (385×64-bit words) | `frame_config_k5.m` f1536 |
| Frame length | **12333 symbols = 49332 samples** | `13 + 24640/2` |
| FEC | K=5 conv `[35 23]` octal, rate-1/2, +4 tail | `frame_config_k5.m` |
| Interleaver | block 1537×16 | `frame_config_k5.m` f1536 |
| Insertion (default) | **+32 symbols = 128 samples** (set freely) | processing-domain analog of the 240k tick |

### Hardware/session state of the reference capture
- Deployed image **B** (`64bb24766032a868bae8a8268986cfb3`, f1536, carries P1E v3).
- R3 arm: profile `lvds_61p44_fdd_jupiter`, `-r 15360`; CFO offset policy
  (146 RX LO 1900002500 +2.4k off-null, 148 RX LO 2000000000); SSI 146 tx0=c3d4,
  148 tx0=c5d3 (see `two_jup/bringup_r2r3.sh`). `rx_input_select`(0x114)=1.

## Files

- **`README_TICK_R3.md`** — this file.
- **Raw capture:** `../two_jup/r3cap/20260729_135508_fwd/pair.iq` — int16 I,Q,
  **4 000 000 complex samples @ 61.44 Msps**, 148 RX forward, wedge-checked
  healthy (90% pass). (Reverse: `../two_jup/r3cap/20260729_135821_rev/pair.iq`.)
  Regenerate fresh with `../two_jup/capture_r3.sh A` (or `B`).
- **`tb_tick_r3.m`** — the R3 Simulink testbench (STAGE A synth demonstration,
  **validated**; STAGE B drives the real RTL Preamble Detector from an
  f1536-assembled model). Reuses `../tick_repro/make_spliced_iq.m` (added to path
  automatically) with sps=4, spf=49332.
- The splice generator lives in `../tick_repro/make_spliced_iq.m` (rate-agnostic;
  call with `sps=4, spf=49332` for R3 diagnostics).

## Run

```
matlab
>> cd tick_repro_r3
>> out = tb_tick_r3;                 % STAGE A: synth +32-symbol step at f1536
% for the RTL PD (STAGE B): assemble the f1536 loopback model with the p1d
% overlay, load_system('commhdlQPSKTxRxLoopback'), then rerun tb_tick_r3.
```

Sample-level spliced capture for the netlist cross-check (obj_byte_f1536):
```
>> make_spliced_iq('../two_jup/r3cap/20260729_135508_fwd/pair.iq', ...
       '/tmp/r3_spliced.iq', 2000000, 128, 'repeat', 4, 49332)   % +32 sym @ sps4
```
